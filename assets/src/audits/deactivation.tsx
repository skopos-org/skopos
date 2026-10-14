import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { ApiError, apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { clearStoredRequest, readStoredRequest } from "@/api/stored-request";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";

type Schedule = components["schemas"]["AuditSchedule"];
type Selection = Pick<Schedule, "id" | "name" | "revision">;
type Intent = { id: string; revision: number };
type Props = {
  schedule: Selection | null;
  onChanged: (id: string) => Promise<void>;
  onClose: () => void;
};

export function AuditDeactivation(props: Props) {
  const { account } = useAuthentication();
  return <Deactivation key={`${account?.id}:${account?.role}`} {...props} />;
}

function Deactivation({ schedule, onChanged, onClose }: Props) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const storageKey = `skopos.audit-deactivation:${account?.id}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): Intent => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("id" in value) ||
        typeof value.id !== "string" ||
        !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.id) ||
        !("revision" in value) ||
        typeof value.revision !== "number" ||
        !Number.isSafeInteger(value.revision) ||
        value.revision < 1
      )
        throw new Error("Unreadable Audit deactivation request");
      return { id: value.id, revision: value.revision };
    }),
  );
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [confirmed, setConfirmed] = useState<string | null>(null);
  const mounted = useRef(false);
  const busy = useRef(false);
  const read = useRef<AbortController | null>(null);
  const scheduleId = schedule?.id;
  const scheduleRevision = schedule?.revision;
  const selected = useRef({ id: scheduleId, revision: scheduleRevision });

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      read.current?.abort();
    };
  }, []);
  useLayoutEffect(() => {
    selected.current = { id: scheduleId, revision: scheduleRevision };
    read.current?.abort();
  }, [scheduleId, scheduleRevision]);

  async function readSchedule(id: string) {
    read.current?.abort();
    const controller = new AbortController();
    read.current = controller;
    const { data } = await apiClient
      .GET("/api/v1/audit-schedules/{id}", {
        params: { path: { id } },
        signal: controller.signal,
      })
      .then(apiData);
    controller.signal.throwIfAborted();
    if (data.id !== id) throw new Error(t("audits.deactivationUnknown"));
    return data;
  }

  function clearIntent(intent: Intent) {
    if (!clearStoredRequest(storageKey, intent)) return false;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
    return true;
  }

  async function confirm(current: Schedule, intent: Intent, fromWrite: boolean) {
    if (
      current.id !== intent.id ||
      current.active !== false ||
      !Number.isSafeInteger(current.revision) ||
      current.revision <= intent.revision ||
      (fromWrite && current.revision !== intent.revision + 1)
    )
      throw new Error(t("audits.deactivationUnknown"));
    if (!mounted.current) return;
    if (sessionStorage.getItem(storageKey) !== JSON.stringify(intent))
      throw new Error(t("audits.deactivationUnknown"));
    await onChanged(intent.id);
    if (!mounted.current) return;
    if (!clearIntent(intent)) throw new Error(t("audits.deactivationUnknown"));
    setConfirmed(current.name);
    setError("");
    onClose();
  }

  async function checkResult() {
    if (!saved.intent || busy.current || !mounted.current) return;
    busy.current = true;
    setPending(true);
    try {
      await confirm(await readSchedule(saved.intent.id), saved.intent, false);
    } catch {
      if (mounted.current) setError(t("audits.deactivationUnknown"));
    } finally {
      busy.current = false;
      if (mounted.current) setPending(false);
    }
  }

  async function deactivate() {
    if (
      !schedule ||
      account?.role !== "admin" ||
      saved.intent ||
      saved.unreadable ||
      busy.current ||
      !mounted.current
    )
      return;
    const intent = { id: schedule.id, revision: schedule.revision };
    busy.current = true;
    setPending(true);
    setError("");
    setConfirmed(null);
    let saving = false;
    let dispatched = false;
    let received = false;
    try {
      const current = await readSchedule(intent.id);
      if (
        !mounted.current ||
        selected.current?.id !== intent.id ||
        selected.current.revision !== intent.revision
      )
        return;
      if (current.active !== true || current.revision !== intent.revision)
        throw new Error(t("audits.scheduleChanged"));
      saving = true;
      sessionStorage.setItem(storageKey, JSON.stringify(intent));
      saving = false;
      setSaved({ intent, unreadable: false });
      dispatched = true;
      const { data } = await apiClient
        .POST("/api/v1/audit-schedules/{id}/deactivate", {
          params: { path: { id: intent.id } },
          body: { audit_schedule: { expected_revision: intent.revision } },
        })
        .then(apiData);
      received = true;
      if (mounted.current && selected.current?.id === intent.id) await confirm(data, intent, true);
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
          if (mounted.current) setError(t("audits.deactivationReceiptUnavailable"));
          return;
        }
      }
      if (!mounted.current || selected.current?.id !== intent.id) return;
      if (dispatched && !rejected) {
        if (!received) {
          try {
            await confirm(await readSchedule(intent.id), intent, false);
            return;
          } catch {
            /* Only the saved original result can be checked; never resend. */
          }
        }
        if (mounted.current) setError(t("audits.deactivationUnknown"));
      } else
        setError(
          !dispatched && saving
            ? t("audits.deactivationSaveFailed")
            : failure instanceof Error
              ? failure.message
              : t("audits.requestFailed"),
        );
    } finally {
      busy.current = false;
      if (mounted.current) setPending(false);
    }
  }

  if (!schedule && !saved.intent && !saved.unreadable && !confirmed) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>{t("audits.confirmDeactivate")}</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        {error && (!saved.intent || error !== t("audits.deactivationUnknown")) && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}
        {saved.unreadable && (
          <Alert variant="destructive">
            <AlertDescription>{t("audits.deactivationReceiptUnavailable")}</AlertDescription>
          </Alert>
        )}
        {saved.intent && (
          <Alert>
            <AlertDescription>{t("audits.deactivationUnknown")}</AlertDescription>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pending}
              onClick={() => void checkResult()}
            >
              {pending && <Spinner />}
              {t("audits.checkDeactivation")}
            </Button>
          </Alert>
        )}
        {confirmed && (
          <Alert>
            <AlertDescription>
              {t("audits.deactivationConfirmed", { name: confirmed })}
            </AlertDescription>
          </Alert>
        )}
        {schedule && !saved.intent && !saved.unreadable && (
          <div className="space-y-3">
            <p className="font-medium">{schedule.name}</p>
            <p className="text-sm text-muted-foreground">{t("audits.deactivateConfirmation")}</p>
            <Button
              type="button"
              variant="destructive"
              disabled={pending}
              onClick={() => void deactivate()}
            >
              {pending && <Spinner />}
              {t("audits.confirmDeactivate")}
            </Button>
          </div>
        )}
        {schedule && (
          <Button type="button" variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
        )}
      </CardContent>
    </Card>
  );
}
