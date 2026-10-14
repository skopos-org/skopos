import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { ApiError, apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { clearStoredRequest, readStoredRequest } from "@/api/stored-request";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";

type Setting = components["schemas"]["ReportSetting"];
type Intent = { id: string; revision: number; enabled: boolean };

export function AutomaticReportSetting({ refreshKey }: { refreshKey: number }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const canManage = account?.role === "admin";
  const storageKey = `skopos.automatic-report-setting:${account?.id}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): Intent => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("id" in value) ||
        typeof value.id !== "string" ||
        !value.id ||
        !("revision" in value) ||
        typeof value.revision !== "number" ||
        !Number.isSafeInteger(value.revision) ||
        value.revision < 1 ||
        !("enabled" in value) ||
        typeof value.enabled !== "boolean"
      )
        throw new Error("Invalid automatic report setting request");
      return { id: value.id, revision: value.revision, enabled: value.enabled };
    }),
  );
  const [setting, setSetting] = useState<Setting | null>(null);
  const [readStatus, setReadStatus] = useState({ refreshKey, reading: true });
  const reading = readStatus.refreshKey !== refreshKey || readStatus.reading;
  const [writing, setWriting] = useState(false);
  const [error, setError] = useState("");
  const mounted = useRef(false);
  const busy = useRef(false);
  const read = useRef<AbortController | null>(null);

  const readCurrent = useCallback(() => {
    read.current?.abort();
    const controller = new AbortController();
    read.current = controller;
    return apiClient
      .GET("/api/v1/report-setting", { signal: controller.signal })
      .then(apiData)
      .then(({ data }) => {
        controller.signal.throwIfAborted();
        if (!mounted.current) return;
        setSetting(data);
        setError("");
        return data;
      })
      .catch((failure: unknown) => {
        if (!controller.signal.aborted && mounted.current)
          setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
        throw failure;
      })
      .finally(() => {
        if (!controller.signal.aborted && mounted.current)
          setReadStatus({ refreshKey, reading: false });
      });
  }, [t, refreshKey]);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      read.current?.abort();
    };
  }, []);
  useEffect(() => {
    void readCurrent().catch(() => {});
    return () => read.current?.abort();
  }, [readCurrent]);

  function clearIntent(intent: Intent) {
    if (!clearStoredRequest(storageKey, intent)) return;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
  }

  function confirm(current: Setting, intent: Intent, fromWrite: boolean) {
    if (
      current.id !== intent.id ||
      !Number.isSafeInteger(current.revision) ||
      current.revision <= intent.revision ||
      (fromWrite && current.revision !== intent.revision + 1) ||
      current.automatic_case_reports_enabled !== intent.enabled
    )
      throw new Error(t("reports.automaticUnknown"));
    if (!mounted.current) return;
    if (fromWrite) {
      read.current?.abort();
      setReadStatus({ refreshKey, reading: false });
    }
    clearIntent(intent);
    setSetting(current);
    setError("");
  }

  async function checkResult() {
    if (!saved.intent || busy.current || reading || !mounted.current) return;
    busy.current = true;
    setReadStatus({ refreshKey, reading: true });
    const intent = saved.intent;
    try {
      const current = await readCurrent();
      if (current && mounted.current) confirm(current, intent, false);
    } catch {
      if (mounted.current) setError(t("reports.automaticUnknown"));
    } finally {
      busy.current = false;
    }
  }

  async function update(enabled: boolean) {
    if (
      !canManage ||
      !setting ||
      reading ||
      error ||
      saved.intent ||
      saved.unreadable ||
      busy.current ||
      !mounted.current
    )
      return;
    busy.current = true;
    setWriting(true);
    const intent = { id: setting.id, revision: setting.revision, enabled };
    let dispatched = false;
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(intent));
      setSaved({ intent, unreadable: false });
      dispatched = true;
      const result = await apiClient
        .PUT("/api/v1/report-setting", {
          body: {
            report_setting: {
              expected_revision: intent.revision,
              automatic_case_reports_enabled: enabled,
            },
          },
        })
        .then(apiData);
      confirm(result.data, intent, true);
    } catch (failure) {
      const rejected =
        failure instanceof ApiError && [400, 401, 403, 404, 409, 422].includes(failure.status);
      try {
        if (rejected) clearIntent(intent);
      } catch {
        if (mounted.current) setError(t("reports.automaticReceiptUnavailable"));
        return;
      }
      if (mounted.current)
        setError(
          !dispatched
            ? t("reports.automaticReceiptUnavailable")
            : rejected
              ? failure.message
              : t("reports.automaticUnknown"),
        );
    } finally {
      if (mounted.current) setWriting(false);
      busy.current = false;
    }
  }

  const message =
    error ||
    (saved.unreadable
      ? t("reports.automaticReceiptUnavailable")
      : saved.intent && !writing
        ? t("reports.automaticUnknown")
        : "");
  return (
    <section
      className="space-y-4 rounded-lg border bg-card p-5"
      aria-label={t("reports.automaticTitle")}
    >
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="max-w-3xl">
          <h2 className="font-semibold">{t("reports.automaticTitle")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.automaticDescription")}</p>
          {!canManage && (
            <p className="mt-2 text-xs text-muted-foreground">{t("reports.automaticAdminOnly")}</p>
          )}
        </div>
        <div className="flex items-center gap-3">
          {(reading || writing) && <Spinner />}
          <Label htmlFor="automatic-case-reports">
            {setting
              ? t(
                  setting.automatic_case_reports_enabled
                    ? "reports.automaticOn"
                    : "reports.automaticOff",
                )
              : t("common.loading")}
          </Label>
          <Switch
            id="automatic-case-reports"
            checked={setting?.automatic_case_reports_enabled ?? false}
            disabled={!canManage || !setting || reading || writing || !!message}
            onCheckedChange={(enabled) => void update(enabled)}
          />
        </div>
      </div>
      {message && (
        <Alert variant="destructive">
          <AlertDescription>{message}</AlertDescription>
        </Alert>
      )}
      {(error || saved.intent) && (
        <Button
          variant="outline"
          disabled={reading || writing}
          onClick={() => {
            if (saved.intent) void checkResult();
            else {
              setReadStatus({ refreshKey, reading: true });
              void readCurrent().catch(() => {});
            }
          }}
        >
          {t(saved.intent ? "reports.checkGeneration" : "reports.refresh")}
        </Button>
      )}
    </section>
  );
}
