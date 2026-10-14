import { useEffect, useLayoutEffect, useRef, useState, type FormEvent } from "react";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import { useTranslation } from "react-i18next";
import { ApiError, apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { clearStoredRequest, readStoredRequest } from "@/api/stored-request";
import { usePagedData } from "@/api/use-paged-data";
import { useAuthentication } from "@/auth/context";
import { FormMultiSelect, FormSelect } from "@/components/form-select";
import { PageControls } from "@/components/page-controls";
import { PagedSelect } from "@/components/paged-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type Target = components["schemas"]["TargetSummary"];
type Boundary = components["schemas"]["ManagementBoundarySummary"];
type Schedule = components["schemas"]["AuditSchedule"];
type Request = components["schemas"]["CreateAuditScheduleRequest"]["audit_schedule"];
type Intent = { id: string; digest: string };
type Props = { open: boolean; onCreated: (id: string) => Promise<void> };

function readTargets(after: string | undefined, signal: AbortSignal) {
  return apiClient
    .GET("/api/v1/targets/summaries", {
      params: { query: { active: true, limit: 50, after } },
      signal,
    })
    .then(apiData);
}

function readBoundaries(after: string | undefined, signal: AbortSignal) {
  return apiClient
    .GET("/api/v1/management-boundaries", {
      params: { query: { active: true, limit: 50, after } },
      signal,
    })
    .then(apiData);
}

export function AuditCreateForm({ open, onCreated }: Props) {
  const { account } = useAuthentication();
  return <Editor key={`${account?.id}:${account?.role}`} open={open} onCreated={onCreated} />;
}

function Editor({ open, onCreated }: Props) {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [scope, setScope] = useState("targets");
  const [targets, setTargets] = useState<Target[]>([]);
  const [boundary, setBoundary] = useState<Boundary | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [confirmed, setConfirmed] = useState<string | null>(null);
  const storageKey = `skopos.audit-registration:${account?.id}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): Intent => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("id" in value) ||
        typeof value.id !== "string" ||
        !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.id) ||
        !("digest" in value) ||
        typeof value.digest !== "string" ||
        !/^[0-9a-f]{64}$/.test(value.digest)
      )
        throw new Error("Unreadable Audit registration request");
      return { id: value.id, digest: value.digest };
    }),
  );
  const mounted = useRef(false);
  const busy = useRef(false);
  const read = useRef<AbortController | null>(null);
  const currentlyOpen = useRef(open);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      read.current?.abort();
    };
  }, []);
  useLayoutEffect(() => {
    currentlyOpen.current = open;
    if (!open) read.current?.abort();
  }, [open]);

  function clearIntent(intent: Intent) {
    if (!clearStoredRequest(storageKey, intent)) return false;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
    return true;
  }

  async function confirm(schedule: Schedule, intent: Intent) {
    if (
      schedule.id !== intent.id ||
      !Number.isSafeInteger(schedule.revision) ||
      schedule.revision < 1 ||
      requestDigest(schedule) !== intent.digest
    )
      throw new Error(t("audits.creationUnknown"));
    if (!mounted.current) return;
    if (sessionStorage.getItem(storageKey) !== JSON.stringify(intent))
      throw new Error(t("audits.creationUnknown"));
    await onCreated(intent.id);
    if (!mounted.current) return;
    if (!clearIntent(intent)) throw new Error(t("audits.creationUnknown"));
    setConfirmed(schedule.name);
    setError("");
  }

  async function readReceipt(intent: Intent) {
    read.current?.abort();
    const controller = new AbortController();
    read.current = controller;
    const { data } = await apiClient
      .GET("/api/v1/audit-schedules/{id}", {
        params: { path: { id: intent.id } },
        signal: controller.signal,
      })
      .then(apiData);
    controller.signal.throwIfAborted();
    await confirm(data, intent);
  }

  async function checkResult() {
    if (!saved.intent || busy.current || !mounted.current) return;
    busy.current = true;
    setPending(true);
    try {
      await readReceipt(saved.intent);
    } catch {
      if (mounted.current) setError(t("audits.creationUnknown"));
    } finally {
      busy.current = false;
      if (mounted.current) setPending(false);
    }
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (
      account?.role !== "admin" ||
      busy.current ||
      !open ||
      saved.intent ||
      saved.unreadable ||
      !mounted.current
    )
      return;
    const form = new FormData(event.currentTarget);
    const targetIds = scope === "targets" ? targets.map((item) => item.id).sort() : [];
    const boundaryId = scope === "boundary" ? boundary?.id : null;
    if ((!targetIds.length && scope === "targets") || (!boundaryId && scope === "boundary")) {
      setError(t("audits.scopeRequired"));
      return;
    }
    setPending(true);
    busy.current = true;
    setError("");
    setConfirmed(null);
    const request: Request = {
      registration_id: crypto.randomUUID(),
      name: formValue(form, "name"),
      desired_outcome: formValue(form, "desired_outcome"),
      timezone: formValue(form, "timezone"),
      cron_expression: formValue(form, "cron_expression"),
      report_language: formValue(form, "report_language") === "ja" ? "ja" : "en",
      target_ids: targetIds,
      management_boundary_id: boundaryId || null,
    };
    const intent = { id: request.registration_id, digest: requestDigest(request) };
    let dispatched = false;
    let received = false;
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(intent));
      setSaved({ intent, unreadable: false });
      dispatched = true;
      const { data } = await apiClient
        .POST("/api/v1/audit-schedules", {
          body: { audit_schedule: request },
        })
        .then(apiData);
      received = true;
      if (mounted.current && currentlyOpen.current) await confirm(data, intent);
    } catch (failure) {
      const rejected =
        dispatched &&
        !received &&
        failure instanceof ApiError &&
        [400, 401, 403, 404, 409, 422].includes(failure.status);
      if (rejected) {
        try {
          clearIntent(intent);
        } catch {
          if (mounted.current) setError(t("audits.creationReceiptUnavailable"));
          return;
        }
      }
      if (!mounted.current || !currentlyOpen.current) return;
      if (dispatched && !rejected) {
        if (!received) {
          try {
            await readReceipt(intent);
            return;
          } catch {
            /* The saved original request remains; checking never repeats creation. */
          }
        }
        if (mounted.current) setError(t("audits.creationUnknown"));
      } else
        setError(
          !dispatched
            ? t("audits.creationSaveFailed")
            : failure instanceof Error
              ? failure.message
              : t("audits.requestFailed"),
        );
    } finally {
      busy.current = false;
      if (mounted.current) setPending(false);
    }
  }

  if (!open && !saved.intent && !saved.unreadable && !confirmed) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>{t("audits.addSchedule")}</CardTitle>
        <CardDescription>{t("audits.scheduleDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        {error && (!saved.intent || error !== t("audits.creationUnknown")) && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}
        {saved.unreadable && (
          <Alert variant="destructive">
            <AlertDescription>{t("audits.creationReceiptUnavailable")}</AlertDescription>
          </Alert>
        )}
        {saved.intent && (
          <Alert>
            <AlertDescription>{t("audits.creationUnknown")}</AlertDescription>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pending}
              onClick={() => void checkResult()}
            >
              {pending && <Spinner />}
              {t("audits.checkRegistration")}
            </Button>
          </Alert>
        )}
        {confirmed && (
          <Alert>
            <AlertDescription>
              {t("audits.registrationConfirmed", { name: confirmed })}
            </AlertDescription>
          </Alert>
        )}
        {open && !saved.intent && !saved.unreadable && (
          <form onSubmit={create} className="grid gap-4 md:grid-cols-2">
            <Field id="audit-name" name="name" label={t("audits.name")} />
            <Field
              id="audit-timezone"
              name="timezone"
              label={t("audits.timezone")}
              defaultValue={Intl.DateTimeFormat().resolvedOptions().timeZone}
            />
            <div className="space-y-2 md:col-span-2">
              <Label htmlFor="audit-desired-outcome">{t("audits.desiredOutcome")}</Label>
              <Textarea id="audit-desired-outcome" name="desired_outcome" required />
            </div>
            <Field
              id="audit-cron"
              name="cron_expression"
              label={t("audits.cron")}
              defaultValue="0 * * * *"
            />
            <div className="space-y-2">
              <Label htmlFor="audit-language">{t("audits.reportLanguage")}</Label>
              <FormSelect
                id="audit-language"
                name="report_language"
                defaultValue={i18n.resolvedLanguage === "ja" ? "ja" : "en"}
                options={[
                  { value: "en", label: "English" },
                  { value: "ja", label: "日本語" },
                ]}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="audit-scope">{t("audits.scope")}</Label>
              <FormSelect
                id="audit-scope"
                value={scope}
                onValueChange={(value) => value && setScope(value)}
                options={[
                  { value: "targets", label: t("audits.selectedTargets") },
                  { value: "boundary", label: t("audits.managementBoundary") },
                ]}
              />
            </div>
            {scope === "targets" ? (
              <TargetChoices selected={targets} onChange={setTargets} disabled={pending} />
            ) : (
              <PagedSelect
                id="audit-boundary"
                label={t("audits.managementBoundary")}
                selected={boundary}
                onChange={setBoundary}
                load={readBoundaries}
                placeholder={t("audits.chooseBoundary")}
                disabled={pending}
              />
            )}
            <div className="md:col-span-2">
              <Button type="submit" disabled={pending}>
                {pending && <Spinner />}
                {t("audits.create")}
              </Button>
            </div>
          </form>
        )}
      </CardContent>
    </Card>
  );
}

function TargetChoices({
  selected,
  onChange,
  disabled,
}: {
  selected: Target[];
  onChange: (items: Target[]) => void;
  disabled: boolean;
}) {
  const { t } = useTranslation();
  const page = usePagedData(readTargets);
  const items = [...(page.view?.data ?? [])];
  for (const item of selected) if (!items.some((choice) => choice.id === item.id)) items.push(item);
  return (
    <div className="space-y-2" role="group" aria-label={t("audits.targets")}>
      <Label htmlFor="audit-targets">{t("audits.targets")}</Label>
      <FormMultiSelect
        key={selected.map((item) => item.id).join(":")}
        id="audit-targets"
        value={selected.map((item) => item.id)}
        onValueChange={(ids) => onChange(items.filter((item) => ids.includes(item.id)))}
        options={items.map((item) => ({ value: item.id, label: item.name }))}
        placeholder={t("audits.targets")}
        disabled={disabled || page.pending || !!page.error}
      />
      <PageControls
        index={page.view?.index ?? 0}
        hasNext={!!page.view?.page.next}
        pending={disabled || page.pending}
        previous={page.previous}
        next={page.next}
      />
      {page.error != null && (
        <Alert variant="destructive">
          <AlertDescription>{t("audits.requestFailed")}</AlertDescription>
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={() => void page.retry().catch(() => {})}
          >
            {t("common.refresh")}
          </Button>
        </Alert>
      )}
    </div>
  );
}

function Field({
  id,
  name,
  label,
  defaultValue,
}: {
  id: string;
  name: string;
  label: string;
  defaultValue?: string;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} name={name} defaultValue={defaultValue} required />
    </div>
  );
}

function formValue(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function requestDigest(
  request: Pick<
    Schedule,
    "name" | "desired_outcome" | "timezone" | "cron_expression" | "report_language"
  > & { target_ids?: string[]; management_boundary_id?: string | null },
) {
  return bytesToHex(
    sha256(
      new TextEncoder().encode(
        JSON.stringify([
          request.name.trim(),
          request.desired_outcome.trim(),
          request.timezone.trim(),
          request.cron_expression.trim(),
          request.report_language,
          [...new Set(request.target_ids ?? [])].sort(),
          request.management_boundary_id ?? null,
        ]),
      ),
    ),
  );
}
