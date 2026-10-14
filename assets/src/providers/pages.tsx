import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Activity, ArrowLeft, Bot, BrainCircuit, Webhook } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate, useLocation, useNavigate, useParams } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { ApiError, apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import { clearStoredRequest, readStoredRequest } from "@/api/stored-request";
import { usePagedData, type PageData } from "@/api/use-paged-data";
import { PageControls } from "@/components/page-controls";
import type { components } from "@/api/schema";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { Label } from "@/components/ui/label";
import { AIProviderCreateForm, ProviderSetup } from "@/providers/ai-section";
import { ProviderChoiceCard } from "@/providers/choice-card";
import { SignalProviderCreateForm, SignalProviderSection } from "@/providers/signal-section";
import { loadSetupReadiness, type SetupReadiness } from "@/settings/data";

type ProviderPageKind = "ai" | "signal";
type AIService = components["schemas"]["AIService"];
type SignalAdapter = "alertmanager-webhook" | "generic-webhook" | "zabbix-webhook";

async function loadAIServices(signal?: AbortSignal): Promise<AIService[]> {
  return apiClient
    .GET("/api/v1/ai-services", { signal })
    .then(apiData)
    .then((response) => response.data);
}

const signalChoices = {
  "alertmanager-webhook": {
    title: "Alertmanager",
    description: "cases.choiceAlertmanager",
    icon: Activity,
  },
  "zabbix-webhook": {
    title: "Zabbix",
    description: "cases.choiceZabbix",
    icon: Webhook,
  },
  "generic-webhook": {
    title: "Generic Webhook",
    description: "cases.choiceGenericWebhook",
    icon: Webhook,
  },
} as const;

const aiAuthDescriptions: Record<AIService["auth"], string> = {
  api_key: "setup.cardApiKey",
  optional_api_key: "setup.cardOptionalApiKey",
  none: "setup.cardNoCredential",
  service_account_json: "setup.cardServiceAccount",
  oauth_access_token: "setup.cardOAuth",
};

const featuredAIServices = [
  "openai",
  "anthropic",
  "google",
  "google_vertex",
  "azure",
  "amazon_bedrock",
  "openrouter",
  "ollama",
];

type ProviderSummary = components["schemas"]["ProviderSummary"];
type Assignment = components["schemas"]["AIUsageRoleAssignment"];
type ProviderWindow = PageData<ProviderSummary> & {
  assignments: Assignment[];
  readiness: SetupReadiness;
  services: AIService[];
};

function ProviderPage({ kind }: { kind: ProviderPageKind }) {
  const { account } = useAuthentication();
  return (
    <ProviderListing
      key={`${account?.id}:${account?.role}:${account?.role_version}:${kind}`}
      kind={kind}
    />
  );
}

function ProviderListing({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const location = useLocation();
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";
  const created = (location.state as { created?: ProviderPageKind } | null)?.created === kind;

  const load = useCallback(
    async (after: string | undefined, signal: AbortSignal): Promise<ProviderWindow> => {
      const owner = new AbortController();
      signal = AbortSignal.any([signal, owner.signal]);
      try {
        const [page, readiness, services] = await Promise.all([
          apiClient
            .GET("/api/v1/providers/summaries", {
              params: { query: { kinds: [kind], limit: 50, after } },
              querySerializer: commaSeparatedQuery,
              signal,
            })
            .then(apiData),
          loadSetupReadiness(signal),
          kind === "ai" ? loadAIServices(signal) : Promise.resolve([]),
        ]);
        const roles =
          kind === "ai" && page.data.length
            ? await apiClient
                .GET("/api/v1/ai-usage-role-assignments", {
                  params: { query: { provider_ids: page.data.map((item) => item.id), limit: 100 } },
                  querySerializer: commaSeparatedQuery,
                  signal,
                })
                .then(apiData)
            : { data: [], page: { next: null } };
        if (roles.page.next) throw new Error("Provider role page is incomplete");
        signal.throwIfAborted();
        return { ...page, assignments: roles.data, readiness, services };
      } catch (cause) {
        owner.abort();
        throw cause;
      }
    },
    [kind],
  );
  const pages = usePagedData<ProviderSummary, ProviderWindow>(load);
  const currentPage = useRef(pages.retry);
  useLayoutEffect(() => {
    currentPage.current = pages.retry;
  });
  const refresh = useCallback(async () => {
    setError("");
    await currentPage.current();
  }, []);
  const snapshot = pages.view;

  useEffect(() => {
    if (!snapshot || !location.hash) return;
    const frame = window.requestAnimationFrame(() => {
      document.getElementById(location.hash.slice(1))?.scrollIntoView();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [location.hash, snapshot]);

  if (!snapshot && pages.pending) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  return (
    <div className="space-y-6 p-6 lg:p-8">
      {(error || !!pages.error) && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error || t("setup.requestFailed")}</AlertDescription>
        </Alert>
      )}
      {created && (
        <Alert>
          <AlertDescription>
            {t(kind === "ai" ? "setup.aiCreated" : "cases.signalCreated")}
          </AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("setup.readOnly")}</AlertDescription>
        </Alert>
      )}
      <Button
        size="sm"
        variant="outline"
        disabled={pages.pending}
        onClick={() => void refresh().catch(() => {})}
      >
        {t("common.refresh")}
      </Button>
      {snapshot && (
        <>
          {kind === "ai" ? (
            <ProviderSetup
              key={snapshot.index}
              providers={snapshot.data}
              services={snapshot.services}
              assignments={snapshot.assignments}
              authorityMode={snapshot.readiness.authority_mode}
              reviewerAvailable={snapshot.readiness.reviewer}
              soleReviewerProviderId={snapshot.readiness.sole_reviewer_provider_id}
              canManage={canManage}
              onRefresh={refresh}
              onError={setError}
            />
          ) : (
            <SignalProviderSection
              providers={snapshot.data}
              canManage={canManage}
              onRefresh={refresh}
              onError={setError}
            />
          )}
          <PageControls
            index={snapshot.index}
            hasNext={!!snapshot.page.next}
            pending={pages.pending}
            previous={pages.previous}
            next={pages.next}
          />
        </>
      )}
    </div>
  );
}

export function AIProviderPage() {
  return <ProviderPage kind="ai" />;
}

export function SignalProviderPage() {
  return <ProviderPage kind="signal" />;
}

function ProviderCreatePage({ kind }: { kind: ProviderPageKind }) {
  const { account } = useAuthentication();
  const { providerType } = useParams();
  return (
    <ProviderCreation
      key={`${account?.id}:${account?.role}:${account?.role_version}:${kind}:${providerType}`}
      kind={kind}
    />
  );
}

function ProviderCreation({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const navigate = useNavigate();
  const { providerType } = useParams();
  const [error, setError] = useState("");
  const [services, setServices] = useState<AIService[] | null>(null);
  const [serviceQuery, setServiceQuery] = useState("");
  const storageKey = `skopos.provider-registration:${account?.id}:${kind}`;
  const [saved, setSaved] = useState(() =>
    readStoredRequest(storageKey, (value): { id: string } => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("id" in value) ||
        typeof value.id !== "string" ||
        !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.id)
      )
        throw new Error("Invalid registration identity");
      return { id: value.id };
    }),
  );
  const original = useRef(saved.intent);
  const mounted = useRef(false);
  const busy = useRef(false);
  const read = useRef<AbortController | null>(null);
  const [reading, setReading] = useState(false);
  const [sending, setSending] = useState(false);
  const canManage = account?.role === "admin";
  const overview = kind === "ai" ? "/ai" : "/signals";
  const choiceEntries = Object.entries(signalChoices);
  const aiService = services?.find((item) => item.id === providerType);
  const filteredServices = (services ?? [])
    .filter((service) =>
      `${service.name} ${service.id}`
        .toLocaleLowerCase()
        .includes(serviceQuery.trim().toLocaleLowerCase()),
    )
    .sort((left, right) => {
      const leftRank = featuredAIServices.indexOf(left.id);
      const rightRank = featuredAIServices.indexOf(right.id);
      if (leftRank !== -1 || rightRank !== -1) {
        if (leftRank === -1) return 1;
        if (rightRank === -1) return -1;
        return leftRank - rightRank;
      }
      return left.name.localeCompare(right.name);
    });
  const selectedChoice = choiceEntries.find(([id]) => id === providerType)?.[1];
  const selected = kind === "ai" ? aiService?.id : selectedChoice ? providerType : undefined;

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      read.current?.abort();
    };
  }, []);

  function clearOriginal(id: string) {
    if (original.current?.id !== id || !clearStoredRequest(storageKey, { id }))
      throw new Error("Registration identity changed");
    original.current = null;
    if (mounted.current) setSaved({ intent: null, unreadable: false });
  }

  function confirm(provider: components["schemas"]["Provider"], id: string) {
    if (!mounted.current || original.current?.id !== id) return;
    if (provider.id !== id || provider.kind !== kind || provider.revision < 1)
      throw new Error("Registration result does not match its identity");
    clearOriginal(id);
    void navigate(overview, { replace: true, state: { created: kind } });
  }

  async function register(
    input: Omit<components["schemas"]["CreateProviderRequest"]["provider"], "registration_id">,
  ) {
    if (!mounted.current || busy.current || original.current || saved.unreadable)
      throw new Error("Registration pending");
    busy.current = true;
    setSending(true);
    let id: string | undefined;
    try {
      id = crypto.randomUUID();
      try {
        sessionStorage.setItem(storageKey, JSON.stringify({ id }));
      } catch (cause) {
        setSaved({ intent: null, unreadable: true });
        throw cause;
      }
      original.current = { id };
      setSaved({ intent: { id }, unreadable: false });
      const result = await apiClient
        .POST("/api/v1/providers", {
          body: { provider: { ...input, registration_id: id } },
        })
        .then(apiData);
      confirm(result.data, id);
    } catch (cause) {
      if (
        mounted.current &&
        id &&
        original.current?.id === id &&
        cause instanceof ApiError &&
        [400, 403, 409, 422].includes(cause.status)
      )
        clearOriginal(id);
      throw cause;
    } finally {
      busy.current = false;
      if (mounted.current) setSending(false);
    }
  }

  async function checkRegistration() {
    const id = original.current?.id;
    if (!id || busy.current) return;
    busy.current = true;
    setReading(true);
    setError("");
    const owner = new AbortController();
    read.current = owner;
    try {
      const result = await apiClient
        .GET("/api/v1/providers/{id}", { params: { path: { id } }, signal: owner.signal })
        .then(apiData);
      if (!owner.signal.aborted) confirm(result.data, id);
    } catch {
      if (mounted.current && !owner.signal.aborted) setError(t("setup.registrationUnknown"));
    } finally {
      busy.current = false;
      if (mounted.current) setReading(false);
    }
  }

  useEffect(() => {
    if (kind !== "ai") return;
    const owner = new AbortController();
    loadAIServices(owner.signal)
      .then((items) => {
        if (!owner.signal.aborted) setServices(items);
      })
      .catch(() => {
        if (!owner.signal.aborted) setError(t("setup.requestFailed"));
      });
    return () => {
      owner.abort();
    };
  }, [kind, t]);

  if (kind === "ai" && !services && !saved.intent && !saved.unreadable) {
    if (error) {
      return (
        <div className="p-6">
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        </div>
      );
    }
    return (
      <div className="p-8">
        <Spinner />
      </div>
    );
  }

  if (providerType && !selected && (kind !== "ai" || services))
    return <Navigate to={`${overview}/new`} replace />;

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to={selected ? `${overview}/new` : overview}>
            <ArrowLeft />
            {t(
              selected
                ? kind === "ai"
                  ? "setup.backToAITypes"
                  : "cases.backToSignalTypes"
                : kind === "ai"
                  ? "setup.backToAI"
                  : "cases.backToSignals",
            )}
          </Link>
        </Button>
        <h1 className="text-2xl font-semibold tracking-tight">
          {(kind === "ai" ? aiService?.name : selectedChoice?.title) ??
            t(kind === "ai" ? "setup.chooseAIType" : "cases.chooseSignalType")}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {t(
            kind === "ai"
              ? "setup.chooseAITypeDescription"
              : selectedChoice
                ? selectedChoice.description
                : "cases.chooseSignalTypeDescription",
          )}
        </p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {(saved.intent || saved.unreadable) && (
        <Alert>
          <AlertDescription>
            <p>
              {t(saved.unreadable ? "setup.registrationUnavailable" : "setup.registrationUnknown")}
            </p>
            {saved.intent && (
              <Button
                size="sm"
                variant="outline"
                disabled={reading || sending}
                onClick={() => void checkRegistration()}
              >
                {reading && <Spinner />}
                {t("setup.checkRegistration")}
              </Button>
            )}
          </AlertDescription>
        </Alert>
      )}
      {!canManage ? (
        <Alert>
          <AlertDescription>{t("setup.readOnly")}</AlertDescription>
        </Alert>
      ) : kind === "ai" && !selected ? (
        <div className="space-y-4">
          <div className="max-w-md space-y-2">
            <Label htmlFor="ai-service-search">{t("setup.searchAIServices")}</Label>
            <Input
              id="ai-service-search"
              type="search"
              value={serviceQuery}
              onChange={(event) => setServiceQuery(event.target.value)}
              placeholder={t("setup.searchAIServicesPlaceholder")}
            />
          </div>
          {filteredServices.length > 0 ? (
            <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              {filteredServices.map((service) => (
                <ProviderChoiceCard
                  key={service.id}
                  to={`/ai/new/${service.id}`}
                  title={service.name}
                  description={t(
                    service.id === "openai"
                      ? "setup.choiceOpenAI"
                      : service.id === "anthropic"
                        ? "setup.choiceAnthropic"
                        : aiAuthDescriptions[service.auth],
                  )}
                  icon={service.id === "openai" ? BrainCircuit : Bot}
                />
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">{t("setup.noAIServicesFound")}</p>
          )}
        </div>
      ) : !selected ? (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {choiceEntries.map(([id, item]) => (
            <ProviderChoiceCard
              key={id}
              to={`${overview}/new/${id}`}
              title={item.title}
              description={t(item.description)}
              icon={item.icon}
            />
          ))}
        </div>
      ) : kind === "ai" ? (
        <fieldset disabled={!!saved.intent || saved.unreadable}>
          <AIProviderCreateForm service={aiService!} onRegister={register} onError={setError} />
        </fieldset>
      ) : (
        <fieldset disabled={!!saved.intent || saved.unreadable}>
          <SignalProviderCreateForm
            adapterType={selected as SignalAdapter}
            onRegister={register}
            onError={setError}
          />
        </fieldset>
      )}
    </div>
  );
}

export function AIProviderCreatePage() {
  return <ProviderCreatePage kind="ai" />;
}

export function SignalProviderCreatePage() {
  return <ProviderCreatePage kind="signal" />;
}
