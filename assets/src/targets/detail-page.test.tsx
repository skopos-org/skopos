import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Link, MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { apiClient } from "@/api/client";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetDetailPage } from "@/targets/detail-page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  wire.mockReset();
  sessionStorage.clear();
});

function response(data: unknown) {
  return { data, response: new Response() };
}

type ReadOptions = {
  params?: {
    path?: { id?: string };
    query?: {
      target_id?: string;
      active?: boolean;
      limit?: number;
      after?: string;
      ids?: string[];
    };
  };
  signal?: AbortSignal;
};

function installDetail() {
  const calls: Array<{ path: string; options: ReadOptions }> = [];
  const method = (index: number, targetId = "selected") => ({
    id: targetId === "selected" ? `method-${index}` : `other-method-${index}`,
    target_id: targetId,
    provider_id: "credentials",
    name: targetId === "selected" ? `Method ${index}` : `Other method ${index}`,
    method: "ssh",
    endpoint: "ssh://host",
    priority: index,
    revision: 3,
    capabilities: [],
    check: { current: true, observed_capabilities: [], message: null },
  });
  const read = (path: string, options: ReadOptions = {}) => {
    calls.push({ path, options });
    const query = options.params?.query ?? {};
    switch (path) {
      case "/api/v1/targets/{id}":
        return Promise.resolve(
          response({
            data: {
              id: options.params?.path?.id,
              name: options.params?.path?.id === "selected" ? "Selected host" : "Other host",
              kind: "host",
              type_id: "custom-os",
              active: true,
              revision: 2,
              facts: { manufacturer: "Vendor" },
              operating_instructions: "Keep the boot disk",
              management_boundary_id: null,
            },
          }),
        );
      case "/api/v1/target-types":
        return Promise.resolve(
          response({
            data: {
              types: [{ id: "custom-os", access_method_types: ["ssh"] }],
              methods: [],
              categories: [],
            },
          }),
        );
      case "/api/v1/access-methods":
        expect(query).toMatchObject({
          target_id: expect.stringMatching(/^(selected|other)$/),
          active: true,
          limit: 50,
        });
        return Promise.resolve(
          response({
            data: query.after
              ? [method(51, query.target_id)]
              : Array.from({ length: 50 }, (_, i) => method(i + 1, query.target_id)),
            page: { next: query.after ? null : "method-cursor" },
          }),
        );
      case "/api/v1/providers/references":
        return Promise.resolve(
          response({
            data: [
              {
                id: "credentials",
                name: "Current credentials",
                kind: "target",
                adapter_type: "ssh",
                enabled: true,
                revision: 7,
                access_method_profile: { method: "ssh" },
              },
            ],
            page: { next: null },
          }),
        );
      case "/api/v1/external-identities":
      case "/api/v1/target-relationships":
        expect(query).toMatchObject({
          target_id: expect.stringMatching(/^(selected|other)$/),
          active: true,
          limit: 50,
        });
        return Promise.resolve(response({ data: [], page: { next: null } }));
      case "/api/v1/targets/{target_id}/files":
        return Promise.resolve(response({ data: [], page: { next: null } }));
      default:
        return Promise.reject(new Error(`Forbidden global read: ${path}`));
    }
  };
  const get = vi.spyOn(apiClient, "GET").mockImplementation(read as typeof apiClient.GET);
  return { get, calls, method, read };
}

function showDetail(role = "viewer", path = "/targets/selected") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role } } as Authentication}>
      <MemoryRouter initialEntries={[path]}>
        <Link to="/targets/other">Other target</Link>
        <Routes>
          <Route path="/targets/:targetId" element={<TargetDetailPage />} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("Target detail reads its selected identity and finite current pages without global collections", async () => {
  await i18n.changeLanguage("en");
  const { get, calls } = installDetail();
  showDetail();
  await screen.findByRole("heading", { name: "Selected host" });
  expect(screen.getByText("Vendor")).toBeTruthy();
  expect(screen.getByText("Keep the boot disk")).toBeTruthy();
  const section = await screen.findByRole("region", { name: "Access methods" });
  await within(section).findByText("Method 50");
  expect(within(section).queryByText("Method 51")).toBeNull();
  expect(within(section).getAllByText("Preferred")).toHaveLength(1);
  const user = userEvent.setup();
  await user.click(within(section).getByRole("button", { name: "Next" }));
  await within(section).findByText("Method 51");
  expect(within(section).queryByText("Method 1")).toBeNull();
  expect(within(section).queryByText("Preferred")).toBeNull();
  await user.click(within(section).getByRole("button", { name: "Previous" }));
  await within(section).findByText("Method 50");
  expect(
    calls
      .filter((item) => item.path === "/api/v1/access-methods")
      .map((item) => item.options.params?.query?.after),
  ).toEqual([undefined, "method-cursor", undefined]);
  expect(
    calls.some((item) =>
      [
        "/api/v1/providers",
        "/api/v1/targets",
        "/api/v1/management-boundaries",
        "/api/v1/inventory-imports",
      ].includes(item.path),
    ),
  ).toBe(false);
  await waitFor(() =>
    expect(calls.filter((item) => item.path === "/api/v1/providers/references")).toHaveLength(3),
  );
  get.mockRejectedValueOnce(new Error("Next page response lost"));
  await user.click(within(section).getByRole("button", { name: "Next" }));
  await within(section).findByRole("alert");
  expect(within(section).getByText("Method 50")).toBeTruthy();
  await user.click(within(section).getByRole("button", { name: "Refresh" }));
  await within(section).findByText("Method 51");
  expect(within(section).queryByText("Method 50")).toBeNull();
  expect(within(section).queryByRole("alert")).toBeNull();
});

test("Target navigation aborts a pending page and ignores its late response", async () => {
  await i18n.changeLanguage("en");
  const { get, calls, method } = installDetail();
  const shown = showDetail();
  const user = userEvent.setup();
  await screen.findByRole("heading", { name: "Selected host" });
  const section = screen.getByRole("region", { name: "Access methods" });
  await within(section).findByText("Method 50");
  let settle!: (result: ReturnType<typeof response>) => void;
  let signal: AbortSignal | undefined;
  get.mockImplementationOnce(((_path: string, options: ReadOptions) => {
    signal = options.signal;
    return new Promise<ReturnType<typeof response>>((resolve) => {
      settle = resolve;
    });
  }) as typeof apiClient.GET);
  await user.click(within(section).getByRole("button", { name: "Next" }));
  await user.click(screen.getByRole("link", { name: "Other target" }));
  await screen.findByRole("heading", { name: "Other host" });
  await screen.findByText("Other method 50");
  expect(screen.queryByText("Method 50")).toBeNull();
  expect(signal?.aborted).toBe(true);
  const references = calls.filter((call) => call.path === "/api/v1/providers/references").length;
  await act(async () =>
    settle(response({ data: [{ ...method(99), name: "Old late method" }], page: { next: null } })),
  );
  expect(screen.queryByText("Old late method")).toBeNull();
  expect(calls.filter((call) => call.path === "/api/v1/providers/references")).toHaveLength(
    references,
  );
  shown.unmount();
  expect(calls.every((call) => !call.options.signal || call.options.signal.aborted)).toBe(true);
});

test("Method check response loss and refresh failure never repeat the remote check", async () => {
  await i18n.changeLanguage("en");
  const { get, method, read } = installDetail();
  let failRead = false;
  get.mockImplementation(((path: string, options: ReadOptions) => {
    if (path === "/api/v1/access-methods" && failRead) {
      failRead = false;
      return Promise.reject(new Error("Stored check read failed"));
    }
    return read(path, options);
  }) as typeof apiClient.GET);
  const post = vi.spyOn(apiClient, "POST").mockImplementation(() => {
    failRead = true;
    return Promise.reject(new Error("Remote check response lost"));
  });
  showDetail("admin");
  const user = userEvent.setup();
  const section = await screen.findByRole("region", { name: "Access methods" });
  await within(section).findByText("Method 50");
  await user.click(within(section).getAllByRole("button", { name: "Check" })[0]);
  await within(section).findByRole("alert");
  expect(within(section).getByText("Method 50")).toBeTruthy();
  await user.click(within(section).getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(within(section).queryByRole("alert")).toBeNull());
  expect(post).toHaveBeenCalledOnce();
  expect(post).toHaveBeenCalledWith("/api/v1/access-methods/{id}/check", {
    params: { path: { id: method(1).id } },
    body: { access_method: { expected_revision: 3 } },
  });
});

test("scoped identity and relationship pages resolve exact peer and boundary labels over HTTP", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const reads: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const url = new URL(request.url, "http://localhost");
    reads.push(url);
    const query = url.searchParams;
    let data: unknown;
    switch (url.pathname) {
      case "/api/v1/targets/selected":
        data = {
          data: {
            id: "selected",
            name: "Selected host",
            kind: "host",
            type_id: "custom-os",
            active: true,
            revision: 2,
            facts: {},
            operating_instructions: "",
            management_boundary_id: "chosen-boundary",
          },
        };
        break;
      case "/api/v1/target-types":
        data = { data: { types: [], methods: [], categories: [] } };
        break;
      case "/api/v1/management-boundaries/chosen-boundary":
        data = {
          data: {
            id: "chosen-boundary",
            name: "Chosen boundary",
            operating_instructions: "Full boundary instructions",
          },
        };
        break;
      case "/api/v1/external-identities":
        expect(query.get("target_id")).toBe("selected");
        expect(query.get("active")).toBe("true");
        expect(query.get("limit")).toBe("50");
        data = {
          data: query.has("after")
            ? [{ id: "id-51", source: "monitor", kind: "host", value: "Identity 51" }]
            : Array.from({ length: 50 }, (_, index) => ({
                id: `id-${index}`,
                source: "monitor",
                kind: "host",
                value: `Identity ${index + 1}`,
              })),
          page: { next: query.has("after") ? null : "identities-later" },
        };
        break;
      case "/api/v1/target-relationships":
        expect(query.get("target_id")).toBe("selected");
        expect(query.get("active")).toBe("true");
        expect(query.get("limit")).toBe("50");
        data = {
          data: query.has("after")
            ? [
                {
                  id: "relation-51",
                  source_target_id: "peer-51",
                  destination_target_id: "selected",
                  kind: "hosted_by",
                },
              ]
            : Array.from({ length: 50 }, (_, index) => ({
                id: `relation-${index}`,
                source_target_id: "selected",
                destination_target_id: index % 2 ? "peer-2" : "peer-1",
                kind: "hosted_by",
              })),
          page: { next: query.has("after") ? null : "relations-later" },
        };
        break;
      case "/api/v1/targets/references": {
        expect(query.get("limit")).toBe("100");
        expect(query.has("ids[]")).toBe(false);
        const ids = query.get("ids");
        expect(ids === "peer-1,peer-2" || ids === "peer-51").toBe(true);
        data = {
          data: ids!.split(",").map((id) => ({ id, name: `Name of ${id}` })),
          page: { next: null },
        };
        break;
      }
      case "/api/v1/access-methods":
      case "/api/v1/targets/selected/files":
        data = { data: [], page: { next: null } };
        break;
      default:
        throw new Error(`Unexpected global read ${url.pathname}`);
    }
    return new Response(JSON.stringify(data), { headers: { "Content-Type": "application/json" } });
  });
  showDetail();
  await screen.findByRole("heading", { name: "Selected host" });
  expect(screen.getByText("host · Chosen boundary")).toBeTruthy();
  expect(screen.queryByText("Full boundary instructions")).toBeNull();
  const identities = screen.getByRole("region", { name: i18n.t("targets.identities") });
  const relationships = screen.getByRole("region", { name: i18n.t("targets.layerRelationships") });
  await within(identities).findByText("Identity 50");
  await within(relationships).findAllByText(/Name of peer-2/);
  expect(reads.some((url) => url.searchParams.has("after"))).toBe(false);
  const user = userEvent.setup();
  await user.click(within(identities).getByRole("button", { name: "Next" }));
  await within(identities).findByText("Identity 51");
  expect(within(identities).queryByText("Identity 50")).toBeNull();
  expect(within(relationships).getAllByText("hosted_by")).toHaveLength(50);
  await user.click(within(relationships).getByRole("button", { name: "Next" }));
  await within(relationships).findByText("Supports · Name of peer-51");
  expect(within(relationships).getAllByText("hosted_by")).toHaveLength(1);
});

test("editing a later Method uses its referenced Provider revision without loading all credentials", async () => {
  await i18n.changeLanguage("en");
  const { method } = installDetail();
  const patch = vi
    .spyOn(apiClient, "PATCH")
    .mockResolvedValue(response({ data: { ...method(51), revision: 4 } }) as never);
  const post = vi
    .spyOn(apiClient, "POST")
    .mockResolvedValue(response({ data: { ...method(51), revision: 5 } }) as never);
  showDetail("admin");
  const user = userEvent.setup();
  const section = await screen.findByRole("region", { name: "Access methods" });
  await within(section).findByText("Method 50");
  await user.click(within(section).getByRole("button", { name: "Next" }));
  await within(section).findByText("Method 51");
  await user.click(
    within(section).getByRole("button", { name: i18n.t("targets.editAccessMethod") }),
  );
  expect(within(section).getByText("Current credentials")).toBeTruthy();
  const endpoint = within(section).getByRole("textbox", { name: "Endpoint" });
  await user.clear(endpoint);
  await user.type(endpoint, "ssh://updated-host");
  await user.click(within(section).getByRole("button", { name: "Save access method" }));
  await within(section).findByText("Method 50");
  expect(within(section).queryByText("Method 51")).toBeNull();
  expect(patch).toHaveBeenCalledOnce();
  expect(patch).toHaveBeenCalledWith("/api/v1/access-methods/{id}", {
    params: { path: { id: "method-51" } },
    body: {
      access_method: {
        name: "Method 51",
        endpoint: "ssh://updated-host",
        provider_revision: 7,
        priority: 51,
        capabilities: [],
        expected_revision: 3,
      },
    },
  });
  expect(post).toHaveBeenCalledWith("/api/v1/access-methods/{id}/check", {
    params: { path: { id: "method-51" } },
    body: { access_method: { expected_revision: 4 } },
  });
});

test("relationship creation reaches an unrelated Target on a later page and retains its selection", async () => {
  await i18n.changeLanguage("en");
  const { get, read } = installDetail();
  const queries: unknown[] = [];
  get.mockImplementation(((path: string, options: ReadOptions) => {
    if (path === "/api/v1/targets/references") {
      queries.push(options.params?.query);
      return Promise.resolve(
        response({
          data: options.params?.query?.after
            ? [{ id: "unrelated-51", name: "Unrelated target 51" }]
            : Array.from({ length: 50 }, (_, index) => ({
                id: `destination-${index}`,
                name: `Destination ${index}`,
              })),
          page: { next: options.params?.query?.after ? null : "destination-later" },
        }),
      );
    }
    return read(path, options);
  }) as typeof apiClient.GET);
  const post = vi.spyOn(apiClient, "POST").mockResolvedValue(response({ data: {} }) as never);
  showDetail("admin", "/targets/selected?action=relationship");
  const user = userEvent.setup();
  const group = await screen.findByRole("group", { name: i18n.t("targets.destinationTarget") });
  await waitFor(() =>
    expect(within(group).getByRole("combobox")).toHaveProperty("disabled", false),
  );
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox")).toHaveProperty("disabled", false),
  );
  await user.click(within(group).getByRole("combobox"));
  await user.click(screen.getByRole("option", { name: "Unrelated target 51" }));
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox")).toHaveProperty("disabled", false),
  );
  await user.click(within(group).getByRole("combobox"));
  expect(screen.getAllByRole("option")).toHaveLength(51);
  expect(screen.getByRole("option", { name: "Unrelated target 51", selected: true })).toBeTruthy();
  await user.keyboard("{Escape}");
  await user.type(
    screen.getByRole("textbox", { name: i18n.t("targets.relationshipKind") }),
    "hosted_by",
  );
  await user.click(screen.getByRole("button", { name: i18n.t("targets.addRelationship") }));
  await waitFor(() => expect(post).toHaveBeenCalledOnce());
  expect(post).toHaveBeenCalledWith("/api/v1/target-relationships", {
    body: {
      relationship: {
        source_target_id: "selected",
        destination_target_id: "unrelated-51",
        kind: "hosted_by",
        facts: {},
        valid_until: null,
      },
    },
  });
  expect(queries).toEqual([
    { active: true, exclude_id: "selected", limit: 50, after: undefined },
    { active: true, exclude_id: "selected", limit: 50, after: "destination-later" },
    { active: true, exclude_id: "selected", limit: 50, after: undefined },
  ]);
});

test.each([401, 404, 500])(
  "selected Target read failure %s is truthful and retries only reads",
  async (status) => {
    await i18n.changeLanguage("en");
    let targetReads = 0;
    const writes: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      if (request.method !== "GET") writes.push(request.method);
      const path = new URL(request.url, "http://localhost").pathname;
      if (path === "/api/v1/targets/selected") {
        if (++targetReads === 1)
          return new Response(JSON.stringify({ error: { code: "unavailable" } }), { status });
        return new Response(
          JSON.stringify({
            data: {
              id: "selected",
              name: "Selected host",
              kind: "host",
              type_id: "custom-os",
              active: true,
              revision: 2,
              facts: {},
              operating_instructions: "",
              management_boundary_id: null,
            },
          }),
        );
      }
      if (path === "/api/v1/target-types")
        return new Response(JSON.stringify({ data: { types: [], methods: [], categories: [] } }));
      if (
        [
          "/api/v1/access-methods",
          "/api/v1/external-identities",
          "/api/v1/target-relationships",
          "/api/v1/targets/selected/files",
        ].includes(path)
      )
        return new Response(JSON.stringify({ data: [], page: { next: null } }));
      throw new Error("Unexpected global read");
    });
    showDetail();
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toBe(
      i18n.t(status === 404 ? "targets.targetNotFound" : "targets.requestFailed"),
    );
    await userEvent.setup().click(screen.getByRole("button", { name: "Refresh" }));
    await screen.findByRole("heading", { name: "Selected host" });
    expect(targetReads).toBe(2);
    expect(writes).toEqual([]);
  },
);
