import { useEffect, useRef, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { ApiError, apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { components } from "@/api/schema";
import { clearStoredRequest, readStoredRequest } from "@/api/stored-request";
import { usePagedData } from "@/api/use-paged-data";
import { useAuthentication } from "@/auth/context";
import { PageControls } from "@/components/page-controls";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type Provider = components["schemas"]["Provider"];
type Summary = components["schemas"]["ProviderSummary"];
type Intent =
  | { action: "create"; id: string }
  | {
      action: "check" | "enable" | "disable";
      id: string;
      revision: number;
      checkedAt: string | null;
    };

type Props = { canManage: boolean };

function readDestinations(after: string | undefined, signal: AbortSignal) {
  return apiClient
    .GET("/api/v1/providers/summaries", {
      params: { query: { kinds: ["notification"], limit: 50, after } },
      querySerializer: commaSeparatedQuery,
      signal,
    })
    .then(apiData);
}

export function NotificationProviderSection(props: Props) {
  const { account } = useAuthentication();
  return <Destinations key={`${account?.id}:${account?.role}`} {...props} />;
}

function Destinations({ canManage }: Props) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [pending, setPending] = useState<string | null>(null);
  const [error, onError] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [confirmed, setConfirmed] = useState<{
    name: string;
    check: Provider["check"] | null;
  } | null>(null);
  const storageKey = `skopos.notification-request:${account?.id}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): Intent => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("id" in value) ||
        typeof value.id !== "string" ||
        !/^[0-9a-f-]{36}$/i.test(value.id) ||
        !("action" in value) ||
        !["create", "check", "enable", "disable"].includes(String(value.action))
      )
        throw new Error("Invalid destination request");
      if (value.action === "create") return { action: "create", id: value.id };
      if (
        !("revision" in value) ||
        typeof value.revision !== "number" ||
        !Number.isSafeInteger(value.revision) ||
        value.revision < 1 ||
        !("checkedAt" in value) ||
        (value.checkedAt !== null && typeof value.checkedAt !== "string")
      )
        throw new Error("Invalid destination request");
      return {
        action: value.action,
        id: value.id,
        revision: value.revision,
        checkedAt: value.checkedAt,
      } as Intent;
    }),
  );
  const mounted = useRef(false);
  const busy = useRef(false);
  const read = useRef<AbortController | null>(null);
  const page = usePagedData(readDestinations);
  const notificationProviders = page.view?.data ?? [];
  const readPending = page.pending || !!page.error;
  const blocked = pending !== null || readPending || !!saved.intent || saved.unreadable;

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      read.current?.abort();
    };
  }, []);

  function clearIntent(intent: Intent) {
    if (!clearStoredRequest(storageKey, intent)) return;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
  }

  async function confirm(provider: Provider, intent: Intent) {
    if (provider.id !== intent.id || provider.kind !== "notification" || provider.revision < 1)
      throw new Error(t("reports.destinationOperationUnknown"));
    if (
      intent.action === "check" &&
      (provider.revision !== intent.revision ||
        provider.check.checked_revision !== intent.revision ||
        provider.check.status === null ||
        !provider.check.checked_at ||
        !Number.isFinite(Date.parse(provider.check.checked_at)) ||
        (intent.checkedAt !== null &&
          Date.parse(provider.check.checked_at) <= Date.parse(intent.checkedAt)))
    )
      throw new Error(t("reports.destinationOperationUnknown"));
    if (
      (intent.action === "enable" || intent.action === "disable") &&
      (provider.revision <= intent.revision || provider.enabled !== (intent.action === "enable"))
    )
      throw new Error(t("reports.destinationOperationUnknown"));
    if (!mounted.current) return;
    await page.retry();
    if (!mounted.current) return;
    clearIntent(intent);
    setConfirmed({ name: provider.name, check: intent.action === "check" ? provider.check : null });
    onError("");
  }

  async function readReceipt(intent: Intent) {
    read.current?.abort();
    const controller = new AbortController();
    read.current = controller;
    const { data } = await apiClient
      .GET("/api/v1/providers/{id}", {
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
    setPending("receipt");
    try {
      await readReceipt(saved.intent);
    } catch {
      if (mounted.current) onError(t("reports.destinationOperationUnknown"));
    } finally {
      if (mounted.current) {
        busy.current = false;
        setPending(null);
      }
    }
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const element = event.currentTarget;
    if (await operate({ action: "create", form: new FormData(element) })) element.reset();
  }

  async function providerAction(provider: Summary, action: "check" | "enable" | "disable") {
    await operate({ action, provider });
  }

  async function operate(
    input:
      | { action: "create"; form: FormData }
      | { action: "check" | "enable" | "disable"; provider: Summary },
  ) {
    if (!canManage || blocked || busy.current || !mounted.current) return false;
    busy.current = true;
    setPending(input.action === "create" ? "create" : `${input.provider.id}-${input.action}`);
    onError("");
    setConfirmed(null);
    const controller = new AbortController();
    read.current = controller;
    let intent: Intent | null = null;
    let dispatched = false;
    let received = false;
    let saving = false;
    try {
      if (input.action === "create") intent = { action: "create", id: crypto.randomUUID() };
      else {
        const { data } = await apiClient
          .GET("/api/v1/providers/{id}", {
            params: { path: { id: input.provider.id } },
            signal: controller.signal,
          })
          .then(apiData);
        controller.signal.throwIfAborted();
        if (
          data.id !== input.provider.id ||
          data.kind !== "notification" ||
          data.revision !== input.provider.revision
        )
          throw new Error(t("cases.stateChanged"));
        intent = {
          action: input.action,
          id: data.id,
          revision: data.revision,
          checkedAt: data.check.checked_at,
        };
      }
      saving = true;
      sessionStorage.setItem(storageKey, JSON.stringify(intent));
      setSaved({ intent, unreadable: false });
      dispatched = true;
      let result;
      if (input.action === "create") {
        const configuration: Record<string, string> = { url: formValue(input.form, "url") };
        const ca = formValue(input.form, "ca_certificate");
        if (ca) configuration.ca_certificate = ca;
        result = await apiClient.POST("/api/v1/providers", {
          body: {
            provider: {
              registration_id: intent.id,
              name: formValue(input.form, "name"),
              kind: "notification",
              adapter_type: "http-webhook",
              configuration,
              credentials: { signing_secret: formValue(input.form, "signing_secret") },
            },
          },
        });
      } else {
        const options = {
          params: { path: { id: intent.id } },
          body: { provider: { expected_revision: input.provider.revision } },
        };
        result = await (input.action === "check"
          ? apiClient.POST("/api/v1/providers/{id}/check", options)
          : input.action === "enable"
            ? apiClient.POST("/api/v1/providers/{id}/enable", options)
            : apiClient.POST("/api/v1/providers/{id}/disable", options));
      }
      const { data } = apiData(result);
      received = true;
      await confirm(data, intent);
      return mounted.current;
    } catch (failure) {
      const rejected =
        dispatched &&
        !received &&
        failure instanceof ApiError &&
        [400, 401, 403, 404, 409, 422].includes(failure.status);
      if (rejected && intent) {
        try {
          clearIntent(intent);
        } catch {
          if (mounted.current) onError(t("reports.destinationOperationUnknown"));
          return false;
        }
      }
      if (!mounted.current || controller.signal.aborted) return false;
      if (dispatched && intent && !rejected) {
        if (!received) {
          try {
            await readReceipt(intent);
            return mounted.current;
          } catch {
            /* Preserve the original intent; recovery only reads the current factual result. */
          }
        }
        if (mounted.current) onError(t("reports.destinationOperationUnknown"));
      } else
        onError(
          saving && !dispatched
            ? t("reports.destinationOperationSaveFailed")
            : failure instanceof Error
              ? failure.message
              : t("reports.requestFailed"),
        );
      return false;
    } finally {
      if (mounted.current) {
        busy.current = false;
        setPending(null);
      }
    }
  }

  return (
    <section className="space-y-4" aria-label={t("reports.connections")}>
      <div>
        <h2 className="text-xl font-semibold">{t("reports.connections")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("reports.connectionsDescription")}</p>
      </div>
      <Button
        variant="outline"
        disabled={page.pending || pending !== null}
        onClick={() => void page.retry().catch(() => {})}
      >
        {t("reports.refresh")}
      </Button>
      {page.pending && <Spinner />}
      {(error || page.error || saved.intent || saved.unreadable) && (
        <Alert variant="destructive">
          <AlertDescription>
            {error ||
              t(
                saved.intent || saved.unreadable
                  ? "reports.destinationOperationUnknown"
                  : "reports.requestFailed",
              )}
          </AlertDescription>
          {saved.intent && (
            <Button
              size="sm"
              variant="outline"
              disabled={pending !== null}
              onClick={() => void checkResult()}
            >
              {t("reports.checkGeneration")}
            </Button>
          )}
        </Alert>
      )}
      {confirmed && (
        <Alert variant={confirmed.check?.status === "failed" ? "destructive" : "default"}>
          <AlertDescription>
            {t("reports.destinationOperationConfirmed", { name: confirmed.name })}
            {confirmed.check && (
              <p>
                {t(
                  confirmed.check.status === "passed"
                    ? "reports.checkPassed"
                    : "reports.checkRequired",
                )}
              </p>
            )}
            {confirmed.check?.message && <p>{confirmed.check.message}</p>}
          </AlertDescription>
        </Alert>
      )}
      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle>{t("reports.addConnection")}</CardTitle>
            <CardDescription>{t("reports.secretDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
              <Field id="notification-name" name="name" label={t("reports.name")} />
              <Field
                id="notification-url"
                name="url"
                label={t("reports.webhookUrl")}
                type="url"
                placeholder="https://…"
              />
              <Field
                id="notification-secret"
                name="signing_secret"
                label={t("reports.signingSecret")}
                type="password"
                minLength={32}
              />
              <div className="space-y-2 md:col-span-2">
                <Label htmlFor="notification-ca">{t("reports.caCertificate")}</Label>
                <Textarea id="notification-ca" name="ca_certificate" />
              </div>
              <div className="md:col-span-2">
                <Button type="submit" disabled={blocked}>
                  {pending === "create" && <Spinner />}
                  {t("reports.addConnection")}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      )}
      <div className="grid gap-4 xl:grid-cols-2">
        {notificationProviders.map((provider) => {
          const passed =
            provider.check.status === "passed" &&
            provider.check.checked_revision === provider.revision;
          return (
            <Card key={provider.id}>
              <CardHeader>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <CardTitle>{provider.name}</CardTitle>
                    <CardDescription>{provider.adapter_type}</CardDescription>
                  </div>
                  <Badge variant={provider.enabled ? "default" : "outline"}>
                    {t(provider.enabled ? "reports.enabled" : "reports.disabled")}
                  </Badge>
                </div>
              </CardHeader>
              <CardContent className="space-y-3">
                <Button
                  size="sm"
                  variant="ghost"
                  aria-expanded={selectedId === provider.id}
                  onClick={() => setSelectedId(selectedId === provider.id ? null : provider.id)}
                >
                  {t(selectedId === provider.id ? "reports.hideDetails" : "reports.viewDetails")}
                </Button>
                {selectedId === provider.id && (
                  <DestinationDetails
                    key={`${provider.id}:${provider.revision}`}
                    summary={provider}
                  />
                )}
                <p className="text-sm text-muted-foreground">
                  {t(passed ? "reports.checkPassed" : "reports.checkRequired")}
                </p>
                {provider.check.status === "failed" && provider.check.message && (
                  <details className="text-sm text-destructive">
                    <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                    <p>{provider.check.message}</p>
                  </details>
                )}
                {canManage && (
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={blocked}
                      onClick={() => void providerAction(provider, "check")}
                    >
                      {pending === `${provider.id}-check` && <Spinner />}
                      {t("reports.check")}
                    </Button>
                    {provider.enabled ? (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={blocked}
                        onClick={() => void providerAction(provider, "disable")}
                      >
                        {t("reports.disable")}
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        disabled={!passed || blocked}
                        onClick={() => void providerAction(provider, "enable")}
                      >
                        {t("reports.enable")}
                      </Button>
                    )}
                  </div>
                )}
              </CardContent>
            </Card>
          );
        })}
        {page.view && notificationProviders.length === 0 && (
          <Card className="xl:col-span-2">
            <CardContent className="py-8 text-center text-sm text-muted-foreground">
              {t("reports.noConnections")}
            </CardContent>
          </Card>
        )}
      </div>
      <PageControls
        index={page.view?.index ?? 0}
        hasNext={!!page.view?.page.next}
        pending={page.pending || pending !== null}
        previous={() => {
          setSelectedId(null);
          page.previous();
        }}
        next={() => {
          setSelectedId(null);
          page.next();
        }}
      />
    </section>
  );
}

function DestinationDetails({ summary }: { summary: Summary }) {
  const { t } = useTranslation();
  const [provider, setProvider] = useState<Provider | null>(null);
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    void apiClient
      .GET("/api/v1/providers/{id}", {
        params: { path: { id: summary.id } },
        signal: controller.signal,
      })
      .then(apiData)
      .then(({ data }) => {
        controller.signal.throwIfAborted();
        if (
          data.id !== summary.id ||
          data.kind !== "notification" ||
          data.revision < summary.revision
        )
          throw new Error(t("cases.stateChanged"));
        setProvider(data);
        setError("");
      })
      .catch((failure: unknown) => {
        if (!controller.signal.aborted)
          setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
      });
    return () => controller.abort();
  }, [summary.id, summary.revision, attempt, t]);
  return error ? (
    <Alert variant="destructive">
      <AlertDescription>{error}</AlertDescription>
      <Button size="sm" variant="outline" onClick={() => setAttempt((value) => value + 1)}>
        {t("reports.refresh")}
      </Button>
    </Alert>
  ) : provider ? (
    <p className="break-all text-sm text-muted-foreground">
      {typeof provider.configuration.url === "string" ? provider.configuration.url : ""}
    </p>
  ) : (
    <Spinner />
  );
}

function formValue(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}
function Field({
  id,
  name,
  label,
  type = "text",
  placeholder,
  minLength,
}: {
  id: string;
  name: string;
  label: string;
  type?: string;
  placeholder?: string;
  minLength?: number;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input
        id={id}
        name={name}
        type={type}
        placeholder={placeholder}
        minLength={minLength}
        required
        autoComplete={type === "password" ? "off" : undefined}
      />
    </div>
  );
}
