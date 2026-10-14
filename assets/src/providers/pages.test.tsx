import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import {
  AIProviderPage,
  SignalProviderPage,
  SignalProviderCreatePage,
  AIProviderCreatePage,
} from "@/providers/pages";
import { OnboardingPage } from "@/settings/onboarding-page";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
  vi.restoreAllMocks();
});

function signalCreationScreen(accountId = "account-1") {
  return (
    <AuthenticationContext.Provider
      value={{ account: { id: accountId, role: "admin", role_version: 1 } } as Authentication}
    >
      <MemoryRouter initialEntries={["/signals/new/alertmanager-webhook"]}>
        <Routes>
          <Route path="/signals/new/:providerType" element={<SignalProviderCreatePage />} />
          <Route path="/signals" element={<div>Signal registration confirmed</div>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
}
function showSignalCreation() {
  return render(signalCreationScreen());
}

test("Signal registration retains only its original ID after lost acknowledgement and reload confirms it without resending", async () => {
  await i18n.changeLanguage("en");
  let registeredId = "";
  let posts = 0;
  const reads: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts++;
      const input = await request.json();
      registeredId = input.provider.registration_id;
      expect(
        JSON.parse(sessionStorage.getItem("skopos.provider-registration:account-1:signal")!),
      ).toEqual({ id: registeredId });
      return Response.json({ error: { code: "internal_error" } }, { status: 503 });
    }
    reads.push(url.pathname);
    return Response.json({
      data: {
        ...metadata(1, "signal"),
        id: registeredId,
        revision: 1,
        enabled: false,
        configuration: { source: "prometheus" },
        inserted_at: "2026-10-05T00:00:00Z",
        updated_at: "2026-10-05T00:00:00Z",
      },
    });
  });
  const view = showSignalCreation();
  const user = userEvent.setup();
  await user.type(screen.getByLabelText(i18n.t("cases.name")), "Prometheus Signal");
  await user.type(screen.getByLabelText(i18n.t("cases.source")), "prometheus");
  await user.type(
    screen.getByLabelText(i18n.t("cases.webhookSecret")),
    "private-secret-for-registration",
  );
  await user.click(screen.getByRole("button", { name: i18n.t("cases.addSignal") }));
  await screen.findByText(i18n.t("setup.registrationUnknown"));
  expect(posts).toBe(1);
  expect(sessionStorage.getItem("skopos.provider-registration:account-1:signal")).not.toContain(
    "private-secret-for-registration",
  );
  view.unmount();
  showSignalCreation();
  await user.click(screen.getByRole("button", { name: i18n.t("setup.checkRegistration") }));
  await screen.findByText("Signal registration confirmed");
  expect(posts).toBe(1);
  expect(reads).toEqual([`/api/v1/providers/${registeredId}`]);
  expect(sessionStorage.getItem("skopos.provider-registration:account-1:signal")).toBeNull();
});

test("registration storage failure sends no request and preserves the entered form", async () => {
  await i18n.changeLanguage("en");
  wire.mockImplementation(() => {
    throw new Error("No HTTP request should be made");
  });
  showSignalCreation();
  const user = userEvent.setup();
  await user.type(screen.getByLabelText(i18n.t("cases.name")), "Storage-fault Signal");
  await user.type(screen.getByLabelText(i18n.t("cases.source")), "prometheus");
  await user.type(
    screen.getByLabelText(i18n.t("cases.webhookSecret")),
    "private-storage-test-secret",
  );
  const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new Error("Storage unavailable");
  });
  try {
    await user.click(screen.getByRole("button", { name: i18n.t("cases.addSignal") }));
    await screen.findByText(i18n.t("setup.registrationUnavailable"));
    expect(wire).not.toHaveBeenCalled();
    expect(screen.getByLabelText(i18n.t("cases.name"))).toHaveProperty(
      "value",
      "Storage-fault Signal",
    );
  } finally {
    saving.mockRestore();
  }
});

test("a rejected registration keeps input and clears only its original identity", async () => {
  await i18n.changeLanguage("en");
  let posts = 0;
  wire.mockImplementation(() => {
    posts++;
    return Promise.resolve(
      Response.json({ error: { code: "validation_failed" } }, { status: 422 }),
    );
  });
  showSignalCreation();
  const user = userEvent.setup();
  await user.type(screen.getByLabelText(i18n.t("cases.name")), "Rejected Signal");
  await user.type(screen.getByLabelText(i18n.t("cases.source")), "prometheus");
  await user.type(
    screen.getByLabelText(i18n.t("cases.webhookSecret")),
    "private-rejection-test-secret",
  );
  await user.click(screen.getByRole("button", { name: i18n.t("cases.addSignal") }));
  await screen.findByText(i18n.t("cases.requestFailed"));
  expect(posts).toBe(1);
  expect(screen.getByLabelText(i18n.t("cases.name"))).toHaveProperty("value", "Rejected Signal");
  expect(screen.queryByText(i18n.t("setup.registrationUnknown"))).toBeNull();
  expect(sessionStorage.getItem("skopos.provider-registration:account-1:signal")).toBeNull();
});

test("a saved AI registration can be confirmed even when its service catalog is unavailable", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem(
    "skopos.provider-registration:account-1:ai",
    JSON.stringify({ id: id(51) }),
  );
  const methods: string[] = [];
  wire.mockImplementation((request: Request) => {
    methods.push(request.method);
    if (new URL(request.url).pathname === "/api/v1/ai-services")
      return Promise.resolve(Response.json({ error: { code: "internal_error" } }, { status: 500 }));
    return Promise.resolve(
      Response.json({
        data: {
          ...metadata(51),
          configuration: {},
          inserted_at: "2026-10-05T00:00:00Z",
          updated_at: "2026-10-05T00:00:00Z",
        },
      }),
    );
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role: "admin", role_version: 1 } } as Authentication}
    >
      <MemoryRouter initialEntries={["/ai/new/openai"]}>
        <Routes>
          <Route path="/ai/new/:providerType" element={<AIProviderCreatePage />} />
          <Route path="/ai" element={<div>AI registration confirmed</div>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await userEvent
    .setup()
    .click(await screen.findByRole("button", { name: i18n.t("setup.checkRegistration") }));
  await screen.findByText("AI registration confirmed");
  expect(methods.every((method) => method === "GET")).toBe(true);
});

test("AI registration sends the composed model and role input with one original identity", async () => {
  await i18n.changeLanguage("en");
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "GET")
      return Response.json({
        data: [
          {
            id: "openai",
            name: "OpenAI",
            auth: "api_key",
            endpoint_required: false,
            configuration_fields: [],
          },
        ],
      });
    posts++;
    const input = await request.json();
    expect(input.provider).toMatchObject({
      name: "Chosen AI",
      kind: "ai",
      adapter_type: "req-llm",
      usage_scope: "all",
      usage_priority: 100,
      configuration: { provider: "openai", model: "selected-model" },
      credentials: { api_key: "private-ai-test-secret" },
    });
    expect(input.provider.configuration).not.toHaveProperty("max_tokens");
    expect(
      JSON.parse(sessionStorage.getItem("skopos.provider-registration:account-1:ai")!),
    ).toEqual({ id: input.provider.registration_id });
    return Response.json(
      {
        data: {
          ...metadata(51),
          id: input.provider.registration_id,
          enabled: false,
          configuration: input.provider.configuration,
          inserted_at: "2026-10-05T00:00:00Z",
          updated_at: "2026-10-05T00:00:00Z",
        },
      },
      { status: 201 },
    );
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role: "admin", role_version: 1 } } as Authentication}
    >
      <MemoryRouter initialEntries={["/ai/new/openai"]}>
        <Routes>
          <Route path="/ai/new/:providerType" element={<AIProviderCreatePage />} />
          <Route path="/ai" element={<div>AI registration confirmed</div>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText(i18n.t("setup.name")), "Chosen AI");
  await user.type(screen.getByLabelText(i18n.t("setup.model")), "selected-model");
  const outputLimit = screen.getByLabelText(i18n.t("setup.maxTokens")) as HTMLInputElement;
  expect(outputLimit.value).toBe("");
  expect(outputLimit.required).toBe(false);
  expect(outputLimit.max).toBe("");
  await user.type(
    screen.getByLabelText(i18n.t("setup.aiFields.api_key")),
    "private-ai-test-secret",
  );
  await user.click(screen.getByRole("button", { name: i18n.t("setup.addConnection") }));
  await screen.findByText("AI registration confirmed");
  expect(posts).toBe(1);
  expect(sessionStorage.getItem("skopos.provider-registration:account-1:ai")).toBeNull();
});

test("a former account registration acknowledgement cannot navigate or clear its saved identity", async () => {
  await i18n.changeLanguage("en");
  let finish!: (response: Response) => void;
  let registeredId = "";
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    posts++;
    registeredId = (await request.json()).provider.registration_id;
    return new Promise<Response>((resolve) => {
      finish = resolve;
    });
  });
  const view = showSignalCreation();
  const user = userEvent.setup();
  await user.type(screen.getByLabelText(i18n.t("cases.name")), "Previous account Signal");
  await user.type(screen.getByLabelText(i18n.t("cases.source")), "prometheus");
  await user.type(
    screen.getByLabelText(i18n.t("cases.webhookSecret")),
    "private-previous-account-secret",
  );
  await user.click(screen.getByRole("button", { name: i18n.t("cases.addSignal") }));
  await waitFor(() => expect(finish).toBeTypeOf("function"));
  view.rerender(signalCreationScreen("different-account"));
  await act(async () => {
    finish(
      Response.json(
        {
          data: {
            ...metadata(1, "signal"),
            id: registeredId,
            configuration: {},
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          },
        },
        { status: 201 },
      ),
    );
  });
  expect(screen.queryByText("Signal registration confirmed")).toBeNull();
  expect(screen.getByLabelText(i18n.t("cases.name"))).toHaveProperty("value", "");
  expect(sessionStorage.getItem("skopos.provider-registration:account-1:signal")).toBe(
    JSON.stringify({ id: registeredId }),
  );
  expect(
    sessionStorage.getItem("skopos.provider-registration:different-account:signal"),
  ).toBeNull();
  expect(posts).toBe(1);
});
const id = (n: number) => `10000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const metadata = (n: number, kind = "ai") => ({
  id: id(n),
  name: `Connection ${n}`,
  kind,
  adapter_type: kind === "ai" ? "req-llm" : "alertmanager-webhook",
  enabled: true,
  revision: 1,
  ai_service: "openai",
  ai_model: "example-model",
  check: { status: "passed", checked_revision: 1, checked_at: null, category: null, message: null },
});
const readiness = {
  ai: true,
  resolver: true,
  reviewer: true,
  authority: true,
  signal: true,
  target: true,
  complete: true,
  authority_mode: "auto",
  sole_reviewer_provider_id: id(51),
  first_target_id: id(100),
};
const page = (data: unknown[], next: string | null = null) =>
  Response.json({ data, page: { next } });
function show(kind = "ai", role = "admin") {
  return render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role, role_version: 1 } } as Authentication}
    >
      <MemoryRouter initialEntries={[kind === "ai" ? "/ai" : "/signals"]}>
        {kind === "ai" ? <AIProviderPage /> : <SignalProviderPage />}
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("AI pages keep fifty metadata cards, use global Reviewer facts and fetch only the selected configuration", async () => {
  await i18n.changeLanguage("en");
  let changes = 0;
  const requests: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "PATCH") {
      const input = await request.json();
      expect(input.provider.configuration).not.toHaveProperty("max_tokens");
      changes++;
      return Response.json({ data: {} });
    }
    requests.push(url);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    if (url.pathname === "/api/v1/ai-services")
      return Promise.resolve(
        Response.json({
          data: [
            {
              id: "openai",
              name: "OpenAI",
              auth: "api_key",
              endpoint_required: false,
              configuration_fields: [],
            },
          ],
        }),
      );
    if (url.pathname === "/api/v1/providers/summaries")
      return Promise.resolve(
        url.searchParams.has("after")
          ? page([metadata(51)])
          : page(
              Array.from({ length: 50 }, (_, n) => metadata(n + 1)),
              "ai-cursor",
            ),
      );
    if (url.pathname === "/api/v1/ai-usage-role-assignments") {
      const ids = url.searchParams.get("provider_ids")!.split(",");
      return Promise.resolve(
        page(
          ids.map((provider_id) => ({
            id: provider_id,
            provider_id,
            role: provider_id === id(51) ? "reviewer" : "resolver",
            enabled: true,
            priority: 100,
            revision: 1,
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          })),
        ),
      );
    }
    if (url.pathname === `/api/v1/providers/${id(51)}`)
      return Promise.resolve(
        Response.json({
          data: {
            ...metadata(51),
            configuration: {
              provider: "openai",
              model: "example-model",
              endpoint: "https://api.example/v1",
              max_tokens: 65_536,
            },
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          },
        }),
      );
    throw new Error(`Unexpected request ${url}`);
  });
  show();
  await screen.findByText("Connection 50");
  expect(screen.queryByText("Connection 51")).toBeNull();
  expect(screen.queryByText(/None is assigned, so changes cannot run automatically/)).toBeNull();
  expect(requests.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(1);
  expect(
    requests
      .find((url) => url.pathname === "/api/v1/ai-usage-role-assignments")!
      .searchParams.get("provider_ids")!
      .split(","),
  ).toHaveLength(50);
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("Connection 51");
  expect(screen.queryByText("Connection 50")).toBeNull();
  await user.click(screen.getByRole("button", { name: "Connection 51: Settings" }));
  await user.click(screen.getByRole("button", { name: i18n.t("setup.edit") }));
  await waitFor(() =>
    expect(screen.getByLabelText("Model")).toHaveProperty("value", "example-model"),
  );
  const outputLimit = screen.getByLabelText(i18n.t("setup.maxTokens"));
  expect(outputLimit).toHaveProperty("value", "65536");
  expect(requests.filter((url) => url.pathname === `/api/v1/providers/${id(51)}`)).toHaveLength(1);
  expect(
    requests.some((url) =>
      [
        "/api/v1/providers",
        "/api/v1/targets",
        "/api/v1/access-methods",
        "/api/v1/authority-setting",
      ].includes(url.pathname),
    ),
  ).toBe(false);
  await user.clear(outputLimit);
  await user.click(screen.getByRole("button", { name: i18n.t("setup.saveConnection") }));
  await waitFor(() => expect(changes).toBe(1));
});

test("Signal changes refresh the current window and HTTP failure never repeats a write", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  let posts = 0;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts++;
      return Promise.resolve(
        Response.json({ error: { code: "internal_error" } }, { status: posts === 1 ? 503 : 200 }),
      );
    }
    reads.push(url);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    if (url.pathname === "/api/v1/providers/summaries")
      return Promise.resolve(
        url.searchParams.has("after")
          ? page([metadata(51, "signal")])
          : page([metadata(1, "signal")], "signal-cursor"),
      );
    throw new Error(`Unexpected request ${url}`);
  });
  show("signal");
  await screen.findByText("Connection 1");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("Connection 51");
  await user.click(screen.getByRole("button", { name: "Check" }));
  await screen.findByText(i18n.t("cases.requestFailed"));
  expect(posts).toBe(1);
  expect(reads.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(2);
  await user.click(screen.getByRole("button", { name: "Check" }));
  await waitFor(() =>
    expect(reads.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(3),
  );
  expect(posts).toBe(2);
  expect(
    reads
      .filter((url) => url.pathname === "/api/v1/providers/summaries")
      .at(-1)!
      .searchParams.get("after"),
  ).toBe("signal-cursor");
  expect(reads.every((url) => url.pathname !== "/api/v1/ai-usage-role-assignments")).toBe(true);
  expect(screen.queryByText("Connection 1")).toBeNull();
});

test("required readiness failure stays visible and readonly refresh retries without a write", async () => {
  await i18n.changeLanguage("en");
  let attempts = 0;
  const methods: string[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    methods.push(request.method);
    if (url.pathname === "/api/v1/authority-setting/readiness") {
      attempts++;
      return Promise.resolve(
        attempts === 1
          ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
          : Response.json({ data: readiness }),
      );
    }
    return Promise.resolve(page([metadata(51, "signal")]));
  });
  show("signal", "viewer");
  await screen.findByText(i18n.t("setup.requestFailed"));
  expect(screen.queryByText("Connection 51")).toBeNull();
  await userEvent.setup().click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Connection 51");
  expect(screen.queryByRole("button", { name: "Check" })).toBeNull();
  expect(methods.every((method) => method === "GET")).toBe(true);
});

test("account changes abort the prior Provider page and discard late results", async () => {
  await i18n.changeLanguage("en");
  let first: (value: Response) => void = () => {};
  let oldSignal: AbortSignal | undefined;
  let pages = 0;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    pages++;
    if (pages === 1) {
      oldSignal = request.signal;
      return new Promise<Response>((resolve) => {
        first = resolve;
      });
    }
    return Promise.resolve(page([metadata(2, "signal")]));
  });
  const view = show("signal");
  await waitFor(() => expect(pages).toBe(1));
  view.rerender(
    <AuthenticationContext.Provider
      value={
        { account: { id: "different-account", role: "viewer", role_version: 1 } } as Authentication
      }
    >
      <MemoryRouter>
        <SignalProviderPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("Connection 2");
  expect(oldSignal!.aborted).toBe(true);
  first(page([metadata(1, "signal")]));
  await waitFor(() => expect(screen.queryByText("Connection 1")).toBeNull());
  expect(screen.queryByRole("button", { name: "Check" })).toBeNull();
});

test("onboarding uses only server readiness and sends the operator to the returned Target", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    requests.push(new URL(request.url));
    return Promise.resolve(
      Response.json({ data: { ...readiness, target: false, complete: false } }),
    );
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role: "admin", role_version: 1 } } as Authentication}
    >
      <MemoryRouter>
        <OnboardingPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByRole("button", { name: i18n.t("onboarding.steps.target.action") });
  expect(
    screen
      .getByRole("button", { name: i18n.t("onboarding.steps.target.action") })
      .getAttribute("href"),
  ).toBe(`/targets/${id(100)}`);
  expect(requests.map((url) => url.pathname)).toEqual(["/api/v1/authority-setting/readiness"]);
});

test("a selected AI detail with a changed revision cannot populate an editing form", async () => {
  await i18n.changeLanguage("en");
  let details = 0;
  let metadataRevision = 1;
  const writes: string[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (request.method !== "GET") writes.push(request.method);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    if (url.pathname === "/api/v1/ai-services")
      return Promise.resolve(
        Response.json({
          data: [
            {
              id: "openai",
              name: "OpenAI",
              auth: "api_key",
              endpoint_required: false,
              configuration_fields: [],
            },
          ],
        }),
      );
    if (url.pathname === "/api/v1/providers/summaries")
      return Promise.resolve(
        page([
          {
            ...metadata(51),
            revision: metadataRevision,
            check: { ...metadata(51).check, checked_revision: metadataRevision },
          },
        ]),
      );
    if (url.pathname === "/api/v1/ai-usage-role-assignments") return Promise.resolve(page([]));
    if (url.pathname === `/api/v1/providers/${id(51)}`) {
      details++;
      return Promise.resolve(
        Response.json({
          data: {
            ...metadata(51),
            revision: 2,
            configuration: { provider: "openai", model: "changed-model" },
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          },
        }),
      );
    }
    throw new Error(`Unexpected request ${url}`);
  });
  show();
  await screen.findByText("Connection 51");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Connection 51: Settings" }));
  await user.click(screen.getByRole("button", { name: i18n.t("setup.edit") }));
  await screen.findByText(i18n.t("setup.requestFailed"));
  expect(screen.queryByLabelText("Model")).toBeNull();
  metadataRevision = 2;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() =>
    expect(screen.getByLabelText("Model")).toHaveProperty("value", "changed-model"),
  );
  expect(details).toBe(2);
  expect(writes).toEqual([]);
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByLabelText("Model")).toBeNull();
});
