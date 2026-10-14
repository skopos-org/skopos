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

type Report = components["schemas"]["ReportSummary"] & { name: string };
type Provider = components["schemas"]["ProviderSummary"];
type DeliveryRequest = components["schemas"]["CreateDeliveryRequest"]["delivery"];
type DeliveryReceipt = Pick<
  components["schemas"]["DeliverySummary"],
  "id" | "report_id" | "report_revision" | "provider_id" | "provider_revision"
>;
type Props = { initialReportId: string; onEnqueued: () => Promise<void>; onClose: () => void };

async function readReports(
  after: string | undefined,
  ids: string[] | undefined,
  signal: AbortSignal,
) {
  const page = await apiClient
    .GET("/api/v1/reports", {
      params: { query: { limit: ids ? 1 : 50, after, ids } },
      querySerializer: commaSeparatedQuery,
      signal,
    })
    .then(apiData);
  signal.throwIfAborted();
  if (!page.data.length) return { ...page, data: [] as Report[] };
  const cases = await apiClient
    .GET("/api/v1/cases/summaries", {
      params: {
        query: { ids: [...new Set(page.data.map((report) => report.case_id))], limit: 100 },
      },
      querySerializer: commaSeparatedQuery,
      signal,
    })
    .then(apiData);
  signal.throwIfAborted();
  const titles = new Map(cases.data.map((incident) => [incident.id, incident.title]));
  return {
    ...page,
    data: page.data.map((report) => ({
      ...report,
      name: `${titles.get(report.case_id) ?? report.case_id} · ${report.language} · r${report.case_revision}`,
    })),
  };
}

async function readDestinations(
  after: string | undefined,
  ids: string[] | undefined,
  signal: AbortSignal,
) {
  return apiClient
    .GET("/api/v1/providers/summaries", {
      params: {
        query: { kinds: ["notification"], eligible: true, limit: ids ? 1 : 50, after, ids },
      },
      querySerializer: commaSeparatedQuery,
      signal,
    })
    .then(apiData);
}

export function DeliveryCreateForm(props: Props) {
  const { account } = useAuthentication();
  return <CreateForm key={`${account?.id}:${account?.role}:${props.initialReportId}`} {...props} />;
}

function CreateForm({ initialReportId, onEnqueued, onClose }: Props) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [report, setReport] = useState<Report | null>(null);
  const [provider, setProvider] = useState<Provider | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const storageKey = `skopos.delivery-request:${account?.id}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): DeliveryRequest => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("report_id" in value) ||
        typeof value.report_id !== "string" ||
        !value.report_id ||
        !("provider_id" in value) ||
        typeof value.provider_id !== "string" ||
        !value.provider_id ||
        !("idempotency_key" in value) ||
        typeof value.idempotency_key !== "string" ||
        !value.idempotency_key ||
        value.idempotency_key.length > 1024 ||
        !("report_revision" in value) ||
        typeof value.report_revision !== "number" ||
        !Number.isSafeInteger(value.report_revision) ||
        value.report_revision < 1 ||
        !("provider_revision" in value) ||
        typeof value.provider_revision !== "number" ||
        !Number.isSafeInteger(value.provider_revision) ||
        value.provider_revision < 1
      )
        throw new Error("Invalid delivery request");
      return {
        report_id: value.report_id,
        report_revision: value.report_revision,
        provider_id: value.provider_id,
        provider_revision: value.provider_revision,
        idempotency_key: value.idempotency_key,
      };
    }),
  );
  const [reportIdToRead] = useState(() => saved.intent?.report_id ?? initialReportId);
  const [providerIdToRead] = useState(() => saved.intent?.provider_id);
  const mounted = useRef(false);
  const busy = useRef(false);
  const initialRead = useRef<AbortController | null>(null);
  const submissionRead = useRef<AbortController | null>(null);
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const loadReports = useCallback(
    (after: string | undefined, signal: AbortSignal) => readReports(after, undefined, signal),
    [],
  );
  const loadProviders = useCallback(
    (after: string | undefined, signal: AbortSignal) => readDestinations(after, undefined, signal),
    [],
  );

  function clearRequest(intent: DeliveryRequest) {
    if (!clearStoredRequest(storageKey, intent)) return;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
  }
  async function complete(receipt: DeliveryReceipt, intent: DeliveryRequest) {
    if (
      !receipt.id ||
      receipt.report_id !== intent.report_id ||
      receipt.report_revision !== intent.report_revision ||
      receipt.provider_id !== intent.provider_id ||
      receipt.provider_revision !== intent.provider_revision
    )
      throw new Error(t("reports.deliveryAcceptanceUnknown"));
    if (!mounted.current) return;
    await onEnqueued();
    clearRequest(intent);
    if (mounted.current) onClose();
  }
  async function readReceipt(intent: DeliveryRequest) {
    submissionRead.current?.abort();
    const controller = new AbortController();
    submissionRead.current = controller;
    const receipt = await apiClient
      .GET("/api/v1/deliveries/receipt", {
        params: { query: { idempotency_key: intent.idempotency_key } },
        signal: controller.signal,
      })
      .then(apiData);
    controller.signal.throwIfAborted();
    await complete(receipt.data, intent);
  }
  async function checkResult() {
    if (!saved.intent || busy.current || !mounted.current) return;
    busy.current = true;
    setPending(true);
    try {
      await readReceipt(saved.intent);
    } catch {
      if (mounted.current) setError(t("reports.deliveryAcceptanceUnknown"));
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
      initialRead.current?.abort();
      submissionRead.current?.abort();
    };
  }, []);
  useEffect(() => {
    if (!reportIdToRead) return;
    const controller = new AbortController();
    initialRead.current = controller;
    void readReports(undefined, [reportIdToRead], controller.signal)
      .then((page) => {
        if (controller.signal.aborted) return;
        const current = page.data.find((item) => item.id === reportIdToRead);
        setReport(current ?? null);
        if (!current) setError(t("reports.reportUnavailable"));
      })
      .catch((failure: unknown) => {
        if (!controller.signal.aborted)
          setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
      });
    return () => controller.abort();
  }, [reportIdToRead, t]);
  useEffect(() => {
    if (!providerIdToRead) return;
    const controller = new AbortController();
    void apiClient
      .GET("/api/v1/providers/summaries", {
        params: { query: { ids: [providerIdToRead], kinds: ["notification"], limit: 1 } },
        querySerializer: commaSeparatedQuery,
        signal: controller.signal,
      })
      .then(apiData)
      .then((page) => {
        if (!controller.signal.aborted)
          setProvider(page.data.find((item) => item.id === providerIdToRead) ?? null);
      })
      .catch((failure: unknown) => {
        if (!controller.signal.aborted)
          setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
      });
    return () => controller.abort();
  }, [providerIdToRead, t]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (
      !mounted.current ||
      busy.current ||
      !canOperate ||
      saved.intent ||
      saved.unreadable ||
      !report ||
      !provider
    )
      return;
    busy.current = true;
    setPending(true);
    setError("");
    initialRead.current?.abort();
    const controller = new AbortController();
    submissionRead.current = controller;
    let intent: DeliveryRequest | null = null;
    let dispatched = false;
    let received = false;
    try {
      const [reports, providers] = await Promise.all([
        readReports(undefined, [report.id], controller.signal),
        readDestinations(undefined, [provider.id], controller.signal),
      ]);
      controller.signal.throwIfAborted();
      const currentReport = reports.data.find((item) => item.id === report.id);
      const currentProvider = providers.data.find((item) => item.id === provider.id);
      setReport(currentReport ?? null);
      setProvider(currentProvider ?? null);
      if (!currentReport) throw new Error(t("reports.reportUnavailable"));
      if (!currentProvider) throw new Error(t("reports.destinationUnavailable"));
      if (
        currentReport.revision !== report.revision ||
        currentProvider.revision !== provider.revision
      )
        throw new Error(t("cases.stateChanged"));
      intent = {
        report_id: currentReport.id,
        report_revision: currentReport.revision,
        provider_id: currentProvider.id,
        provider_revision: currentProvider.revision,
        idempotency_key: crypto.randomUUID(),
      };
      sessionStorage.setItem(storageKey, JSON.stringify(intent));
      setSaved({ intent: intent, unreadable: false });
      dispatched = true;
      const receipt = await apiClient
        .POST("/api/v1/deliveries", {
          body: { delivery: intent },
        })
        .then(apiData);
      received = true;
      await complete(receipt.data, intent);
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
          if (mounted.current) setError(t("reports.deliveryAcceptanceUnknown"));
          return;
        }
      }
      if (!mounted.current || controller.signal.aborted) return;
      if (!dispatched) controller.abort();
      if (intent && dispatched && !rejected) {
        if (!received) {
          try {
            await readReceipt(intent);
            return;
          } catch {
            /* Preserve the original key for a read-only check. */
          }
        }
        if (mounted.current) setError(t("reports.deliveryAcceptanceUnknown"));
      } else
        setError(
          intent && !dispatched
            ? t("reports.deliveryRequestSaveFailed")
            : failure instanceof Error
              ? failure.message
              : t("reports.requestFailed"),
        );
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
        <CardTitle>{t("reports.deliver")}</CardTitle>
        <CardDescription>{t("reports.deliverDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="space-y-4" onSubmit={submit}>
          <PagedSelect
            id="delivery-report"
            label={t("reports.report")}
            selected={report}
            onChange={(item) => {
              initialRead.current?.abort();
              setReport(item);
            }}
            load={loadReports}
            placeholder={reportIdToRead || t("reports.chooseReport")}
            disabled={pending || !canOperate || !!saved.intent || saved.unreadable}
          />
          <PagedSelect
            id="delivery-provider"
            label={t("reports.destination")}
            selected={provider}
            onChange={setProvider}
            load={loadProviders}
            placeholder={providerIdToRead || t("reports.chooseDestination")}
            disabled={pending || !canOperate || !!saved.intent || saved.unreadable}
          />
          {(error || saved.intent || saved.unreadable) && (
            <Alert variant="destructive">
              <AlertDescription>{error || t("reports.deliveryAcceptanceUnknown")}</AlertDescription>
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
              disabled={
                pending || !report || !provider || !canOperate || !!saved.intent || saved.unreadable
              }
            >
              {pending && <Spinner />}
              {t("reports.createDelivery")}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
