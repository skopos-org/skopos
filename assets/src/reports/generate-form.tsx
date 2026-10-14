import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { ApiError, apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { components } from "@/api/schema";
import { clearStoredRequest, readStoredRequest } from "@/api/stored-request";
import { useAuthentication } from "@/auth/context";
import { PagedSelect } from "@/components/paged-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";

type CaseSummary = components["schemas"]["CaseSummary"];
type Choice = CaseSummary & { name: string };
type GenerationRequest = { caseId: string; caseRevision: number };
type ReportReceipt = Pick<
  components["schemas"]["ReportSummary"],
  "id" | "case_id" | "case_revision"
>;
type Props = { onGenerated: () => Promise<void>; onClose: () => void };

export function ReportGenerateForm(props: Props) {
  const { account } = useAuthentication();
  return <GenerateForm key={`${account?.id}:${account?.role}`} {...props} />;
}

function GenerateForm({ onGenerated, onClose }: Props) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [selected, setSelected] = useState<Choice | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const storageKey = `skopos.report-generation:${account?.id}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): GenerationRequest => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("caseId" in value) ||
        typeof value.caseId !== "string" ||
        !value.caseId ||
        !("caseRevision" in value) ||
        typeof value.caseRevision !== "number" ||
        !Number.isSafeInteger(value.caseRevision) ||
        value.caseRevision < 1
      )
        throw new Error("Invalid generation request");
      return { caseId: value.caseId, caseRevision: value.caseRevision };
    }),
  );
  const busy = useRef(false);
  const mounted = useRef(false);
  const read = useRef<AbortController | null>(null);
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const load = useCallback(async (after: string | undefined, signal: AbortSignal) => {
    const page = await apiClient
      .GET("/api/v1/cases/summaries", { params: { query: { limit: 50, after } }, signal })
      .then(apiData);
    return {
      ...page,
      data: page.data.filter((item) => item.status !== "running").map(choice),
    };
  }, []);

  function clearRequest(intent: GenerationRequest) {
    if (!clearStoredRequest(storageKey, intent)) return;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
  }

  async function complete(report: ReportReceipt, intent: GenerationRequest) {
    if (
      report.case_id !== intent.caseId ||
      report.case_revision !== intent.caseRevision ||
      !report.id
    )
      throw new Error(t("reports.generationUnknown"));
    if (!mounted.current) return;
    await onGenerated();
    clearRequest(intent);
    if (mounted.current) onClose();
  }

  async function readReceipt(intent: GenerationRequest) {
    read.current?.abort();
    const controller = new AbortController();
    read.current = controller;
    const report = await apiClient
      .GET("/api/v1/cases/{case_id}/reports/{case_revision}", {
        params: { path: { case_id: intent.caseId, case_revision: intent.caseRevision } },
        signal: controller.signal,
      })
      .then(apiData);
    controller.signal.throwIfAborted();
    await complete(report.data, intent);
  }

  async function checkResult() {
    if (!saved.intent || busy.current || !mounted.current) return;
    busy.current = true;
    setPending(true);
    try {
      await readReceipt(saved.intent);
    } catch {
      if (mounted.current) setError(t("reports.generationUnknown"));
    } finally {
      if (mounted.current) {
        busy.current = false;
        setPending(false);
      }
    }
  }

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      read.current?.abort();
    };
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (
      !selected ||
      !canOperate ||
      saved.intent ||
      saved.unreadable ||
      busy.current ||
      !mounted.current
    )
      return;
    busy.current = true;
    setPending(true);
    setError("");
    const controller = new AbortController();
    read.current = controller;
    let intent: GenerationRequest | null = null;
    let dispatched = false;
    let received = false;
    try {
      const page = await apiClient
        .GET("/api/v1/cases/summaries", {
          params: { query: { ids: [selected.id], limit: 1 } },
          querySerializer: commaSeparatedQuery,
          signal: controller.signal,
        })
        .then(apiData);
      controller.signal.throwIfAborted();
      const current = page.data.find((item) => item.id === selected.id);
      setSelected(current ? choice(current) : null);
      if (!current || current.status === "running") throw new Error(t("reports.caseUnavailable"));
      if (current.revision !== selected.revision) throw new Error(t("cases.stateChanged"));
      intent = { caseId: current.id, caseRevision: current.revision };
      sessionStorage.setItem(storageKey, JSON.stringify(intent));
      setSaved({ intent: intent, unreadable: false });
      dispatched = true;
      const report = await apiClient
        .POST("/api/v1/cases/{case_id}/reports", {
          params: { path: { case_id: current.id } },
          body: { report: { expected_case_revision: current.revision } },
        })
        .then(apiData);
      received = true;
      await complete(report.data, intent);
    } catch (failure) {
      const rejected =
        dispatched &&
        !received &&
        failure instanceof ApiError &&
        [400, 401, 403, 404, 409, 422].includes(failure.status);
      if (rejected && intent) {
        try {
          clearRequest(intent);
        } catch {
          if (mounted.current) setError(t("reports.generationUnknown"));
          return;
        }
      }
      if (!mounted.current || controller.signal.aborted) return;
      if (intent && dispatched && !rejected) {
        if (!received) {
          try {
            await readReceipt(intent);
            return;
          } catch {
            /* Keep the original request for a read-only check. */
          }
        }
        if (mounted.current) setError(t("reports.generationUnknown"));
      } else {
        setError(
          intent && !dispatched
            ? t("reports.generationSaveFailed")
            : failure instanceof Error
              ? failure.message
              : t("reports.requestFailed"),
        );
      }
    } finally {
      if (mounted.current) {
        busy.current = false;
        setPending(false);
      }
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t("reports.generate")}</CardTitle>
        <CardDescription>{t("reports.generateDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="space-y-4" onSubmit={submit}>
          <PagedSelect
            id="report-case"
            label={t("reports.case")}
            selected={selected}
            onChange={setSelected}
            load={load}
            display={(item) => `${item.title} · ${item.report_language} · r${item.revision}`}
            placeholder={t("reports.chooseCase")}
            disabled={pending || !canOperate || !!saved.intent || saved.unreadable}
          />
          {(error || saved.intent || saved.unreadable) && (
            <Alert variant="destructive">
              <AlertDescription>{error || t("reports.generationUnknown")}</AlertDescription>
            </Alert>
          )}
          <div className="flex flex-wrap gap-2">
            {saved.intent && (
              <Button
                type="button"
                variant="outline"
                onClick={() => void checkResult()}
                disabled={pending}
              >
                {t("reports.checkGeneration")}
              </Button>
            )}
            <Button
              type="submit"
              disabled={pending || !selected || !canOperate || !!saved.intent || saved.unreadable}
            >
              {pending && <Spinner />}
              {t("reports.generate")}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

function choice(item: CaseSummary): Choice {
  return { ...item, name: item.title };
}
