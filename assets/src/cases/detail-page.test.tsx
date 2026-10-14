import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Link, MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import type { components } from "@/api/schema";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import { CaseDetailPage } from "@/cases/detail-page";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

const timestamp = "2026-10-04T01:00:00Z";
const caseId = "00000000-0000-4000-8000-000000000001";
const reportId = "00000000-0000-4000-8000-000000000002";
const oldReportId = "00000000-0000-4000-8000-000000000003";
const report: components["schemas"]["Report"] = {
  id: reportId,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content: {},
  content_digest: "a".repeat(64),
  generated_at: timestamp,
  revision: 1,
  document: {
    title: "Physical host recovered",
    outcome: "Resolved",
    opened_at: timestamp,
    finished_at: timestamp,
    target_id: null,
    source: "fixture",
    source_ref: "case-report",
    severity: "warning",
    conditions: [],
    case_symptom: null,
    actions: [],
    verifications: [],
    cited_evidence: [],
    conclusion: "The current recovery was verified.",
    conclusion_turn_id: null,
    recovery_reviews: [],
    stop_reason: null,
    required_human_input: null,
    case_id: caseId,
    case_revision: 2,
    digest: "a".repeat(64),
    text: "Exact report document",
  },
};

const reportSummary: components["schemas"]["ReportSummary"] = {
  id: reportId,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content_digest: report.content_digest,
  generated_at: timestamp,
  revision: 1,
  operation_count: 0,
  verification_count: 0,
};
const snapshot: components["schemas"]["CaseSnapshot"] = {
  case: {
    id: caseId,
    trigger_kind: "manual",
    source: "fixture",
    source_ref: "case-report",
    split_parent_id: null,
    title: "Physical host recovered",
    severity: "warning",
    condition_count: 0,
    firing_condition_count: 0,
    report_language: "en",
    status: "resolved",
    operator_action: "none",
    pending_proposal_id: null,
    initial_context: {},
    case_symptom: null,
    authority_setting_id: caseId,
    authority_setting_revision: 1,
    authority_mode: "auto",
    limits: {
      max_elapsed_seconds: 600,
      max_resolver_turns: 10,
      max_target_requests: 20,
      max_effects: 10,
      max_related_targets: 10,
      max_ai_usage_units: 100_000,
      max_no_progress_turns: 3,
    },
    cancel_requested: false,
    stop_reason: null,
    required_human_input: null,
    resolved_at: timestamp,
    initial_target_id: null,
    selected_target_id: null,
    selected_target_revision: null,
    current_owner_id: null,
    revision: 2,
    inserted_at: timestamp,
    updated_at: timestamp,
  },
  ai_usage: {
    reported_input_tokens: 0,
    reported_output_tokens: 0,
    reported_total_tokens: 0,
    reported_invocations: 0,
    unknown_invocations: 0,
    pending_invocations: 0,
    not_dispatched_invocations: 0,
    budget_charged_units: 0,
    unknown_reserved_units: 0,
    pending_reserved_units: 0,
    complete: true,
  },
  conditions: [],
  condition_context: { groups: null, assessments: null },
  resolution_runs: [],
  proposals: [],
  operations: [],
  verification_attempts: [],
  reports: [{ ...reportSummary, id: oldReportId, case_revision: 1 }, reportSummary],
};

function openSnapshot(
  id = caseId,
  title = snapshot.case.title,
): components["schemas"]["CaseSnapshot"] {
  return { ...snapshot, case: { ...snapshot.case, id, title, status: "running" }, reports: [] };
}

function renderDetail(role: "viewer" | "operator" | "admin" = "viewer") {
  return render(
    <AuthenticationContext.Provider
      value={{ account: { id: oldReportId, role } } as Authentication}
    >
      <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
        <Link to={`/cases/${reportId}`}>Other Case</Link>
        <Routes>
          <Route path="/cases/:caseId" element={<CaseDetailPage />} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("admin handoff pages eligible accounts and keeps the independently loaded current owner", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  const account = (id: string, email: string) => ({
    id,
    email,
    role: "operator",
    role_version: 1,
    preferred_language: "en",
    inserted_at: timestamp,
    updated_at: timestamp,
  });
  const current = account(oldReportId, "current@example.test");
  const tail = account(reportId, "tail@example.test");
  const first = Array.from({ length: 50 }, (_, index) =>
    account(
      `10000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      `member${index}@example.test`,
    ),
  );
  const requests: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === `/api/v1/cases/${caseId}`)
      return new Response(
        JSON.stringify({
          data: {
            ...openSnapshot(),
            case: { ...openSnapshot().case, current_owner_id: oldReportId },
          },
        }),
      );
    if (url.pathname === "/api/v1/accounts") {
      requests.push(url);
      const ids = url.searchParams.get("ids");
      if (ids) {
        expect(url.searchParams.get("limit")).toBe("1");
        expect(url.searchParams.has("roles")).toBe(false);
        return new Response(
          JSON.stringify({ data: [ids === oldReportId ? current : tail], page: { next: null } }),
        );
      }
      expect(url.searchParams.get("roles")).toBe("admin,operator");
      expect(url.searchParams.get("limit")).toBe("50");
      return new Response(
        JSON.stringify(
          url.searchParams.has("after")
            ? { data: [tail], page: { next: null } }
            : { data: first, page: { next: "accounts-next" } },
        ),
      );
    }
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail("admin");
  await user.click(await screen.findByText("Assignment and cancellation"));
  const group = await screen.findByRole("group", { name: "Handoff owner" });
  await waitFor(() =>
    expect(within(group).getByRole("combobox").textContent).toContain("current@example.test"),
  );
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() => expect(within(group).getByText("Page 2")).toBeTruthy());
  expect(within(group).getByRole("combobox").textContent).toContain("current@example.test");
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "tail@example.test" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").textContent).toContain("tail@example.test"),
  );
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() => expect(within(group).getByText("Page 1")).toBeTruthy());
  expect(within(group).getByRole("combobox").textContent).toContain("tail@example.test");
  expect(requests.filter((url) => !url.searchParams.has("ids"))).toHaveLength(3);
  expect(requests.some((url) => url.searchParams.get("ids") === oldReportId)).toBe(true);
  expect(requests.some((url) => url.searchParams.get("ids") === reportId)).toBe(true);
  expect(wire.mock.calls.every(([request]) => (request as Request).method === "GET")).toBe(true);
});

test("handoff rechecks a changed owner role before dispatch and requires an eligible selection", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  const owner = {
    id: oldReportId,
    email: "owner@example.test",
    role: "operator",
    role_version: 1,
    preferred_language: "en",
    inserted_at: timestamp,
    updated_at: timestamp,
  };
  const peer = { ...owner, id: reportId, email: "peer@example.test" };
  let ownerReads = 0;
  const posts: unknown[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      expect(url.pathname).toBe(`/api/v1/cases/${caseId}/handoff`);
      posts.push(await request.json());
      return new Response(JSON.stringify({ data: {} }));
    }
    if (url.pathname === `/api/v1/cases/${caseId}`) {
      const next = openSnapshot();
      next.case.current_owner_id = oldReportId;
      return new Response(JSON.stringify({ data: next }));
    }
    if (url.pathname === "/api/v1/accounts") {
      const id = url.searchParams.get("ids");
      const data =
        id === oldReportId
          ? [{ ...owner, ...(++ownerReads > 1 ? { role: "viewer", role_version: 2 } : {}) }]
          : [peer];
      return new Response(JSON.stringify({ data, page: { next: null } }));
    }
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail("admin");
  await user.click(await screen.findByText("Assignment and cancellation"));
  const group = await screen.findByRole("group", { name: "Handoff owner" });
  const form = group.closest("form")!;
  const handoff = within(form).getByRole("button", { name: "Handoff" });
  await waitFor(() => expect(handoff.hasAttribute("disabled")).toBe(false));
  await user.click(handoff);
  await screen.findByText("Select an administrator or operator account.");
  expect(within(form).getByText("Viewer")).toBeTruthy();
  expect(within(group).getByRole("combobox").textContent).toContain("owner@example.test");
  expect(handoff.hasAttribute("disabled")).toBe(true);
  expect(posts).toEqual([]);
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "peer@example.test" }));
  await waitFor(() => expect(handoff.hasAttribute("disabled")).toBe(false));
  await user.click(handoff);
  await waitFor(() =>
    expect(posts).toEqual([{ case: { expected_revision: 2, owner_id: reportId } }]),
  );
  expect(ownerReads).toBe(2);
});

test("handoff account failures and missing identities do not hide the Case and recover by reads", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  let identityState = "failed";
  let pageFails = true;
  const account = {
    id: oldReportId,
    email: "recovered@example.test",
    role: "operator",
    role_version: 1,
    preferred_language: "en",
    inserted_at: timestamp,
    updated_at: timestamp,
  };
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === `/api/v1/cases/${caseId}`)
      return new Response(JSON.stringify({ data: openSnapshot() }));
    if (url.pathname === "/api/v1/accounts") {
      const known = url.searchParams.has("ids");
      if (known ? identityState === "failed" : pageFails)
        return new Response(JSON.stringify({ error: { message: "Accounts unavailable" } }), {
          status: 503,
        });
      return new Response(
        JSON.stringify({
          data: known && identityState === "missing" ? [] : [account],
          page: { next: null },
        }),
      );
    }
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail("admin");
  await screen.findByRole("heading", { name: snapshot.case.title });
  await user.click(screen.getByText("Assignment and cancellation"));
  const group = await screen.findByRole("group", { name: "Handoff owner" });
  const form = group.closest("form")!;
  await within(form).findByText("Could not load the selected account. Refresh to retry.");
  const handoff = within(form).getByRole("button", { name: "Handoff" });
  expect(handoff.hasAttribute("disabled")).toBe(true);
  pageFails = false;
  await user.click(within(group).getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(within(group).queryByRole("alert")).toBeNull());
  identityState = "missing";
  await user.click(within(form).getByRole("button", { name: "Refresh" }));
  await within(form).findByText("Select an administrator or operator account.");
  expect(within(group).getByRole("combobox").textContent).toContain(oldReportId);
  expect(handoff.hasAttribute("disabled")).toBe(true);
  identityState = "ready";
  await user.click(within(form).getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(handoff.hasAttribute("disabled")).toBe(false));
  expect(within(group).getByRole("combobox").textContent).toContain("recovered@example.test");
  expect(wire.mock.calls.every(([request]) => (request as Request).method === "GET")).toBe(true);
});

test.each(["identity", "submission"])(
  "leaving a Case aborts a late handoff %s read without dispatch",
  async (stage) => {
    await i18n.changeLanguage("en");
    const user = userEvent.setup();
    let identityReads = 0;
    let heldRequest: Request | undefined;
    let finish: ((response: Response) => void) | undefined;
    const account = {
      id: oldReportId,
      email: "old-owner@example.test",
      role: "operator",
      role_version: 1,
      preferred_language: "en",
      inserted_at: timestamp,
      updated_at: timestamp,
    };
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (url.pathname === `/api/v1/cases/${caseId}`)
        return new Response(JSON.stringify({ data: openSnapshot() }));
      if (url.pathname === `/api/v1/cases/${reportId}`) {
        const next = openSnapshot(reportId, "New Case");
        next.case.current_owner_id = reportId;
        return new Response(JSON.stringify({ data: next }));
      }
      if (url.pathname === "/api/v1/accounts") {
        const id = url.searchParams.get("ids");
        if (id === oldReportId && ++identityReads === (stage === "identity" ? 1 : 2)) {
          heldRequest = request;
          return new Promise<Response>((resolve) => {
            finish = resolve;
          });
        }
        return new Response(
          JSON.stringify({
            data: [
              {
                ...account,
                ...(id === reportId ? { id: reportId, email: "new-owner@example.test" } : {}),
              },
            ],
            page: { next: null },
          }),
        );
      }
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    renderDetail("admin");
    await user.click(await screen.findByText("Assignment and cancellation"));
    if (stage === "submission") {
      const handoff = screen.getByRole("button", { name: "Handoff" });
      await waitFor(() => expect(handoff.hasAttribute("disabled")).toBe(false));
      await user.click(handoff);
    }
    await waitFor(() => expect(finish).toBeDefined());
    await user.click(screen.getByRole("link", { name: "Other Case" }));
    await screen.findByRole("heading", { name: "New Case" });
    expect(heldRequest!.signal.aborted).toBe(true);
    await act(async () => {
      finish!(new Response(JSON.stringify({ data: [account], page: { next: null } })));
    });
    await user.click(screen.getByText("Assignment and cancellation"));
    const group = screen.getByRole("group", { name: "Handoff owner" });
    await waitFor(() =>
      expect(within(group).getByRole("combobox").textContent).toContain("new-owner@example.test"),
    );
    expect(within(group).getByRole("combobox").textContent).not.toContain("old-owner@example.test");
    expect(wire.mock.calls.every(([request]) => (request as Request).method === "GET")).toBe(true);
  },
);

test.each([false, true])(
  "accepted=%s handoff with a failed reread recovers by GET without replay",
  async (accepted) => {
    await i18n.changeLanguage("en");
    const user = userEvent.setup();
    let submitted = false;
    let readFails = true;
    const posts: unknown[] = [];
    const account = {
      id: oldReportId,
      email: "owner@example.test",
      role: "operator",
      role_version: 1,
      preferred_language: "en",
      inserted_at: timestamp,
      updated_at: timestamp,
    };
    const peer = { ...account, id: reportId, email: "peer@example.test" };
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        expect(url.pathname).toBe(`/api/v1/cases/${caseId}/handoff`);
        posts.push(await request.json());
        submitted = true;
        if (!accepted) throw new TypeError("response lost");
        return new Response(JSON.stringify({ data: {} }));
      }
      if (url.pathname === `/api/v1/cases/${caseId}`) {
        if (submitted && readFails)
          return new Response(JSON.stringify({ error: { message: "Case unavailable" } }), {
            status: 503,
          });
        const next = openSnapshot();
        next.case.current_owner_id = submitted ? reportId : oldReportId;
        next.case.revision = submitted ? 3 : 2;
        return new Response(JSON.stringify({ data: next }));
      }
      if (url.pathname === "/api/v1/accounts")
        return new Response(
          JSON.stringify({
            data: url.searchParams.get("ids") === oldReportId ? [account] : [peer],
            page: { next: null },
          }),
        );
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    renderDetail("admin");
    await user.click(await screen.findByText("Assignment and cancellation"));
    const group = await screen.findByRole("group", { name: "Handoff owner" });
    await waitFor(() =>
      expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
    );
    await user.click(within(group).getByRole("combobox"));
    await user.click(await screen.findByRole("option", { name: "peer@example.test" }));
    const handoff = screen.getByRole("button", { name: "Handoff" });
    await waitFor(() => expect(handoff.hasAttribute("disabled")).toBe(false));
    await user.click(handoff);
    await screen.findByText(
      accepted
        ? "Request accepted. Refresh to load the current Case."
        : "Could not confirm the result. Refresh to check.",
    );
    expect(handoff.hasAttribute("disabled")).toBe(true);
    expect(posts).toEqual([{ case: { expected_revision: 2, owner_id: reportId } }]);
    readFails = false;
    await user.click(screen.getAllByRole("button", { name: "Refresh" })[0]!);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Handoff" }).hasAttribute("disabled")).toBe(false),
    );
    expect(screen.getByRole("combobox").textContent).toContain("peer@example.test");
    expect(posts).toHaveLength(1);
  },
);

test.each(["viewer", "operator"] as const)(
  "%s Case view does not load administrator handoff choices",
  async (role) => {
    await i18n.changeLanguage("en");
    wire.mockImplementation(
      async (request: Request) =>
        new Response(
          JSON.stringify(
            new URL(request.url).pathname === `/api/v1/cases/${caseId}`
              ? { data: openSnapshot() }
              : { data: [], page: { next: null } },
          ),
        ),
    );
    renderDetail(role);
    await screen.findByRole("heading", { name: snapshot.case.title });
    if (role === "operator")
      await userEvent.setup().click(screen.getByText("Assignment and cancellation"));
    expect(screen.queryByRole("button", { name: "Handoff" })).toBeNull();
    expect(
      wire.mock.calls.some(
        ([request]) => new URL((request as Request).url).pathname === "/api/v1/accounts",
      ),
    ).toBe(false);
  },
);

test("changing Case hides the previous Case immediately and aborts its late reads", async () => {
  await i18n.changeLanguage("en");
  let oldRead: Request | undefined;
  let finishOld: ((response: Response) => void) | undefined;
  let finishNew: ((response: Response) => void) | undefined;
  let oldReads = 0;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (path === `/api/v1/cases/${caseId}`) {
      if (++oldReads === 2) {
        oldRead = request;
        return new Promise<Response>((resolve) => {
          finishOld = resolve;
        });
      }
      return new Response(JSON.stringify({ data: openSnapshot() }));
    }
    if (path === `/api/v1/cases/${reportId}`)
      return new Promise<Response>((resolve) => {
        finishNew = resolve;
      });
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail();
  await screen.findByRole("heading", { name: snapshot.case.title });
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(finishOld).toBeDefined());
  await user.click(screen.getByRole("link", { name: "Other Case" }));
  expect(screen.queryByRole("heading", { name: snapshot.case.title })).toBeNull();
  expect(oldRead!.signal.aborted).toBe(true);
  await act(async () => {
    finishOld!(new Response(JSON.stringify({ data: openSnapshot() })));
  });
  expect(screen.queryByRole("heading", { name: snapshot.case.title })).toBeNull();
  await act(async () => {
    finishNew!(new Response(JSON.stringify({ data: openSnapshot(reportId, "New Case") })));
  });
  await screen.findByRole("heading", { name: "New Case" });
  expect(oldReads).toBe(2);
});

test("an older Refresh response cannot replace the latest Case revision", async () => {
  await i18n.changeLanguage("en");
  let reads = 0;
  let finishOld: ((response: Response) => void) | undefined;
  let oldRead: Request | undefined;
  wire.mockImplementation(async (request: Request) => {
    if (new URL(request.url).pathname === `/api/v1/cases/${caseId}`) {
      if (++reads === 2) {
        oldRead = request;
        return new Promise<Response>((resolve) => {
          finishOld = resolve;
        });
      }
      const next = openSnapshot(caseId, reads === 3 ? "Newest Case" : snapshot.case.title);
      if (reads === 3) next.case.revision = 3;
      return new Response(JSON.stringify({ data: next }));
    }
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail();
  await screen.findByRole("heading", { name: snapshot.case.title });
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(finishOld).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByRole("heading", { name: "Newest Case" });
  expect(oldRead!.signal.aborted).toBe(true);
  await act(async () => {
    finishOld!(new Response(JSON.stringify({ data: openSnapshot(caseId, "Stale Case") })));
  });
  expect(screen.queryByRole("heading", { name: "Stale Case" })).toBeNull();
  expect(screen.getByRole("heading", { name: "Newest Case" })).toBeDefined();
});

test.each([false, true])(
  "accepted=%s mutation with a failed reread is recovered by GET without replay",
  async (accepted) => {
    await i18n.changeLanguage("en");
    let submitted = false;
    let readFails = true;
    const posts: Array<{ path: string; body: unknown }> = [];
    wire.mockImplementation(async (request: Request) => {
      const path = new URL(request.url).pathname;
      if (request.method === "POST") {
        posts.push({ path, body: await request.json() });
        submitted = true;
        if (!accepted) throw new TypeError("response lost");
        return new Response(JSON.stringify({ data: {} }));
      }
      if (path === `/api/v1/cases/${caseId}`) {
        if (submitted && readFails)
          return new Response(JSON.stringify({ error: { message: "Reload unavailable" } }), {
            status: 503,
          });
        const next = openSnapshot();
        if (submitted) {
          next.case.current_owner_id = oldReportId;
          next.case.revision = 3;
        }
        return new Response(JSON.stringify({ data: next }));
      }
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    renderDetail("operator");
    await screen.findByRole("heading", { name: snapshot.case.title });
    const user = userEvent.setup();
    await user.click(screen.getByText("Assignment and cancellation"));
    await user.click(screen.getByRole("button", { name: "Claim" }));
    await screen.findByText(
      accepted
        ? "Request accepted. Refresh to load the current Case."
        : "Could not confirm the result. Refresh to check.",
    );
    expect(screen.getByRole("button", { name: "Claim" })).toHaveProperty("disabled", true);
    expect(posts).toEqual([
      { path: `/api/v1/cases/${caseId}/claim`, body: { case: { expected_revision: 2 } } },
    ]);
    readFails = false;
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Claim" })).toBeNull());
    expect(posts).toHaveLength(1);
    expect(screen.queryByText("Reload unavailable")).toBeNull();
  },
);

test("a late mutation receipt after navigation does not reread or change the old Case", async () => {
  await i18n.changeLanguage("en");
  let finishPost: ((response: Response) => void) | undefined;
  let oldReads = 0;
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (request.method === "POST") {
      ++posts;
      expect(path).toBe(`/api/v1/cases/${caseId}/claim`);
      return new Promise<Response>((resolve) => {
        finishPost = resolve;
      });
    }
    if (path === `/api/v1/cases/${caseId}`) {
      ++oldReads;
      return new Response(JSON.stringify({ data: openSnapshot() }));
    }
    if (path === `/api/v1/cases/${reportId}`)
      return new Response(JSON.stringify({ data: openSnapshot(reportId, "New Case") }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail("operator");
  await screen.findByRole("heading", { name: snapshot.case.title });
  const user = userEvent.setup();
  await user.click(screen.getByText("Assignment and cancellation"));
  await user.click(screen.getByRole("button", { name: "Claim" }));
  await waitFor(() => expect(finishPost).toBeDefined());
  await user.click(screen.getByRole("link", { name: "Other Case" }));
  await screen.findByRole("heading", { name: "New Case" });
  await act(async () => {
    finishPost!(new Response(JSON.stringify({ data: {} })));
  });
  expect(oldReads).toBe(1);
  expect(posts).toBe(1);
  expect(screen.getByRole("heading", { name: "New Case" })).toBeDefined();
});

test("101 current Target identities are read in finite batches without scanning opaque context", async () => {
  await i18n.changeLanguage("en");
  const ids = Array.from(
    { length: 100 },
    (_, index) => `10000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
  );
  const batches: string[][] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    if (url.pathname === `/api/v1/cases/${caseId}`) {
      const next = openSnapshot();
      next.case.selected_target_id = caseId;
      next.case.initial_context = { unreferenced_target_id: oldReportId };
      return new Response(JSON.stringify({ data: next }));
    }
    if (url.pathname.endsWith("/turns"))
      return new Response(
        JSON.stringify({
          data: ids.map((id, ordinal) => ({
            id,
            ordinal,
            case_id: caseId,
            status: "completed",
            progress_kind: "hypothesis",
            completed_at: timestamp,
            inserted_at: timestamp,
            source_turn_id: id,
            summary: {
              target_id: id,
              relationship: null,
              type: "target_selection",
              reason: "Selected target",
              outcome: "decision",
            },
          })),
          page: { next: null },
        }),
      );
    if (url.pathname === "/api/v1/targets/summaries") {
      const selected = url.searchParams.get("ids")!.split(",");
      batches.push(selected);
      expect(url.searchParams.get("limit")).toBe("100");
      return new Response(
        JSON.stringify({
          data: selected.map((id) => ({
            id,
            name: `Target ${id}`,
            kind: "host",
            type_id: "custom-os",
          })),
          page: { next: null },
        }),
      );
    }
    expect(url.pathname).not.toBe("/api/v1/targets");
    expect(url.pathname).not.toBe("/api/v1/providers");
    expect(url.pathname).not.toBe("/api/v1/access-methods");
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail();
  await screen.findByRole("heading", { name: snapshot.case.title });
  expect(batches.map((batch) => batch.length)).toEqual([100, 1]);
  expect(batches.flat()).toEqual([caseId, ...ids]);
  expect(batches.flat()).not.toContain(oldReportId);
});

test("metadata failure preserves the current window and a missing Target retains its ID after Refresh", async () => {
  await i18n.changeLanguage("en");
  let mode: "found" | "error" | "missing" = "found";
  let reads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === `/api/v1/cases/${caseId}`) {
      const next = openSnapshot();
      ++reads;
      return new Response(JSON.stringify({ data: next }));
    }
    if (url.pathname.endsWith("/turns"))
      return new Response(
        JSON.stringify({
          data: [
            {
              id: caseId,
              ordinal: 1,
              case_id: caseId,
              status: "completed",
              progress_kind: "hypothesis",
              completed_at: timestamp,
              inserted_at: timestamp,
              summary: {
                target_id: reportId,
                relationship: null,
                type: "target_selection",
                reason: "Target identity receipt",
                outcome: "decision",
              },
            },
          ],
          page: { next: null },
        }),
      );
    if (url.pathname === "/api/v1/targets/summaries")
      return mode === "error"
        ? new Response(JSON.stringify({ error: { message: "Target metadata unavailable" } }), {
            status: 503,
          })
        : new Response(
            JSON.stringify({
              data:
                mode === "missing"
                  ? []
                  : [
                      {
                        id: reportId,
                        name: "Known retired host",
                        kind: "host",
                        type_id: "custom-os",
                      },
                    ],
              page: { next: null },
            }),
          );
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  renderDetail();
  await screen.findByRole("heading", { name: snapshot.case.title });
  const user = userEvent.setup();
  await user.click(screen.getByText("Target identity receipt"));
  await screen.findByText("Known retired host");
  mode = "error";
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Target metadata unavailable");
  expect(screen.getByText("Known retired host")).toBeDefined();
  mode = "missing";
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(screen.queryByText("Known retired host")).toBeNull());
  expect(screen.getByText(reportId)).toBeDefined();
  expect(screen.queryByText("Target metadata unavailable")).toBeNull();
  expect(reads).toBe(3);
});

test("Phoenix changed events refresh labels and preserve an in-flight history selection", async () => {
  await i18n.changeLanguage("en");
  const originalSocket = globalThis.WebSocket;
  class WireSocket {
    static instances: WireSocket[] = [];
    readyState = 0;
    onopen: (() => void) | null = null;
    onmessage: ((event: { data: string }) => void) | null = null;
    onclose: ((event: { code: number; reason: string }) => void) | null = null;
    topic = "";
    joinRef = "";
    constructor() {
      WireSocket.instances.push(this);
      queueMicrotask(() => {
        this.readyState = 1;
        this.onopen?.();
      });
    }
    send(message: string) {
      const [joinRef, ref, topic, event] = JSON.parse(message);
      if (event === "phx_join") {
        this.topic = topic;
        this.joinRef = joinRef;
        queueMicrotask(() =>
          this.onmessage?.({
            data: JSON.stringify([
              joinRef,
              ref,
              topic,
              "phx_reply",
              { status: "ok", response: {} },
            ]),
          }),
        );
      }
    }
    changed() {
      this.onmessage?.({ data: JSON.stringify([this.joinRef, null, this.topic, "changed", {}]) });
    }
    close() {
      this.readyState = 3;
      this.onclose?.({ code: 1000, reason: "closed" });
    }
  }
  vi.stubGlobal("WebSocket", WireSocket);
  sessionStorage.setItem("skopos.session", "fixture");
  let label = "Original live label";
  let failRead = false;
  let olderReads = 0;
  let olderRequest: Request | undefined;
  let finishOlder: ((response: Response) => void) | undefined;
  const turnPage = (older: boolean) =>
    new Response(
      JSON.stringify({
        data: [
          {
            id: older ? reportId : caseId,
            ordinal: older ? 1 : 2,
            case_id: caseId,
            status: "completed",
            progress_kind: "hypothesis",
            completed_at: timestamp,
            inserted_at: timestamp,
            summary: {
              target_id: older ? reportId : caseId,
              relationship: null,
              type: "target_selection",
              reason: older ? "Older live receipt" : "Live target receipt",
              outcome: "decision",
            },
          },
        ],
        page: { next: older ? null : "older-turns" },
      }),
    );
  const methods: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    methods.push(request.method);
    const url = new URL(request.url);
    if (url.pathname === `/api/v1/cases/${caseId}`)
      return failRead
        ? new Response(JSON.stringify({ error: { message: "Live Case unavailable" } }), {
            status: 503,
          })
        : new Response(JSON.stringify({ data: openSnapshot() }));
    if (url.pathname.endsWith("/turns")) {
      const older = url.searchParams.has("after");
      if (older && ++olderReads === 1) {
        olderRequest = request;
        return new Promise<Response>((resolve) => {
          finishOlder = resolve;
        });
      }
      return turnPage(older);
    }
    if (url.pathname === "/api/v1/targets/summaries")
      return new Response(
        JSON.stringify({
          data: url.searchParams
            .get("ids")!
            .split(",")
            .map((id) => ({ id, name: label, kind: "host", type_id: "custom-os" })),
          page: { next: null },
        }),
      );
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  try {
    renderDetail();
    await screen.findByRole("heading", { name: snapshot.case.title });
    await waitFor(() => expect(WireSocket.instances[0]?.topic).toBe(`case:${caseId}`));
    const socket = WireSocket.instances[0];
    const user = userEvent.setup();
    await user.click(screen.getByText("Live target receipt"));
    await screen.findByText(label);
    label = "Updated live label";
    await act(async () => {
      socket.changed();
    });
    await screen.findByText(label);
    expect(screen.queryByText("Original live label")).toBeNull();
    await user.click(screen.getByRole("button", { name: "Next" }));
    await waitFor(() => expect(finishOlder).toBeDefined());
    await act(async () => {
      socket.changed();
    });
    expect(olderRequest!.signal.aborted).toBe(false);
    await act(async () => {
      finishOlder!(turnPage(true));
    });
    await screen.findByText("Older live receipt");
    expect(screen.getByText("Page 2")).toBeDefined();
    await waitFor(() => expect(olderReads).toBe(2));
    failRead = true;
    await act(async () => {
      socket.changed();
    });
    await screen.findByText("Live Case unavailable");
    expect(screen.getByText("Older live receipt")).toBeDefined();
    failRead = false;
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await waitFor(() => expect(screen.queryByText("Live Case unavailable")).toBeNull());
    expect(screen.getByText("Page 2")).toBeDefined();
    expect(methods.every((method) => method === "GET")).toBe(true);
  } finally {
    cleanup();
    vi.stubGlobal("WebSocket", originalSocket);
  }
});

afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("initial Case read failure is visible and Refresh retries only reads", async () => {
  await i18n.changeLanguage("en");
  let fails = true;
  const methods: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    methods.push(request.method);
    const url = new URL(request.url);
    if (url.pathname === `/api/v1/cases/${caseId}`) {
      return fails
        ? new Response(JSON.stringify({ error: { message: "Case storage unavailable" } }), {
            status: 503,
          })
        : new Response(
            JSON.stringify({
              data: { ...snapshot, case: { ...snapshot.case, status: "running" }, reports: [] },
            }),
          );
    }
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
        <Routes>
          <Route path="/cases/:caseId" element={<CaseDetailPage />} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("Case storage unavailable");
  expect(screen.queryByRole("heading", { name: snapshot.case.title })).toBeNull();
  fails = false;
  await userEvent.setup().click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByRole("heading", { name: snapshot.case.title });
  expect(screen.queryByText("Case storage unavailable")).toBeNull();
  expect(methods.every((method) => method === "GET")).toBe(true);
});

test.each([false, true])(
  "pending Proposal read failure=%s keeps the case visible without inferring approval from history",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    const proposal: components["schemas"]["Proposal"] = {
      id: reportId,
      case_id: caseId,
      resolution_run_id: caseId,
      source_turn_id: caseId,
      proposed_for_id: caseId,
      target_id: caseId,
      access_method_id: caseId,
      provider_id: caseId,
      status: "awaiting_human",
      authority_mode: "ask",
      case_generation: 1,
      target_revision: 1,
      access_method_revision: 1,
      provider_revision: 1,
      request_kind: "effect",
      purpose: "remediation",
      tool_id: "fixture",
      capability: "fixture",
      operation: "repair",
      selectors: {},
      parameters: { command: "repair service", padding: "x".repeat(64_000) },
      reason: "Current exact request requires approval",
      evidence_ids: [],
      delay_seconds: 0,
      affected_conditions: [],
      expected_result: {},
      verification_intent: {},
      verification_tool: {},
      preflight_status: "cleared",
      preflight_reason: null,
      proposal_digest: "a".repeat(64),
      expires_at: timestamp,
      revision: 1,
      inserted_at: timestamp,
      updated_at: timestamp,
    };
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const path = new URL(request.url, "http://localhost").pathname;
      requests.push(path);
      if (path === `/api/v1/cases/${caseId}`)
        return new Response(
          JSON.stringify({
            data: {
              ...snapshot,
              case: {
                ...snapshot.case,
                status: "running",
                authority_mode: "ask",
                operator_action: "decision_required",
                pending_proposal_id: reportId,
              },
              proposals: [],
              reports: [],
            },
          }),
        );
      if (path === `/api/v1/proposals/${reportId}`)
        return fails
          ? new Response(JSON.stringify({ error: { message: "Proposal storage unavailable" } }), {
              status: 500,
            })
          : new Response(JSON.stringify({ data: proposal }));
      if (path.startsWith("/api/v1/proposals/"))
        throw new Error("Unselected Proposal must stay unloaded");
      if (
        [
          "/api/v1/targets/summaries",
          "/api/v1/providers/summaries",
          "/api/v1/access-methods",
        ].includes(path)
      ) {
        const query = new URL(request.url).searchParams;
        if (query.has("ids")) {
          expect(query.get("ids")).toBe(caseId);
          expect(query.get("limit")).toBe("100");
          expect(query.has("active")).toBe(false);
          expect(query.has("eligible")).toBe(false);
          return new Response(
            JSON.stringify({
              data: [
                {
                  id: caseId,
                  name:
                    path === "/api/v1/targets/summaries"
                      ? "Retired host beyond first page"
                      : path === "/api/v1/access-methods"
                        ? "Retired management path"
                        : "Connection provider",
                  kind: "host",
                  type_id: "custom-os",
                  method: "ssh",
                  target_id: caseId,
                  active: false,
                },
              ],
              page: { next: null },
            }),
          );
        }
      }
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    render(
      <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
        <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
          <Routes>
            <Route path="/cases/:caseId" element={<CaseDetailPage />} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    expect(await screen.findByRole("heading", { name: "Physical host recovered" })).toBeDefined();
    expect(screen.getByText("Activity history")).toBeDefined();
    if (fails) {
      expect(await screen.findByText("Proposal storage unavailable")).toBeDefined();
      expect(screen.queryByRole("button", { name: "Approve" })).toBeNull();
      expect(screen.queryByRole("button", { name: "Reject" })).toBeNull();
    } else {
      expect(await screen.findByText("Current exact request requires approval")).toBeDefined();
      expect(screen.getByRole("button", { name: "Approve" })).toBeDefined();
      expect(screen.getByText(/Retired host beyond first page/)).toBeDefined();
      expect(screen.getByText(/Retired management path/)).toBeDefined();
      expect(screen.getByText(/Connection provider/)).toBeDefined();
    }
    expect(requests).not.toContain("/api/v1/targets");
    expect(requests).not.toContain("/api/v1/providers");
    expect(requests.filter((path) => path.startsWith("/api/v1/proposals/"))).toEqual([
      `/api/v1/proposals/${reportId}`,
    ]);
  },
);

test.each([false, true])(
  "history window read failure=%s preserves data and ignores an old refresh after navigation",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    const receiptRequests: Record<string, string[]> = {
      turns: [],
      proposals: [],
      "condition-history": [],
      operations: [],
      "verification-attempts": [],
    };
    let delayedRefresh: ((response: Response) => void) | undefined;
    let delayedResponse: Response | undefined;
    let failNext = fails;
    const referenceIds: string[] = [];
    const conditions: components["schemas"]["CaseCondition"][] = [reportId, oldReportId].map(
      (id) => ({
        id,
        signal_correlation_id: id,
        target_id: null,
        predicate: "Service unavailable",
        subject_ref: {},
        state: "firing",
        recovery_status: "needs_observation",
        recovery_evidence_ids: [],
        first_fired_at: timestamp,
        current_occurred_at: timestamp,
        revision: 1,
        membership_id: id,
        attached_at: timestamp,
      }),
    );
    const currentContext: components["schemas"]["TurnConditionContext"] = {
      id: caseId,
      ordinal: 9,
      revision: 1,
      completed_at: timestamp,
      condition_revisions: conditions.map(({ id, revision }) => ({ id, revision })),
      condition_groups: [
        {
          condition_ids: conditions.map(({ id }) => id),
          assessment: "independent",
          reason: "Current independent causes remain visible",
          evidence_ids: [],
        },
      ],
      condition_assessments: [
        {
          condition_id: reportId,
          revision: 1,
          status: "unknown",
          reason: "Current recovery still requires observation",
          evidence_ids: [],
        },
      ],
    };
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const url = new URL(request.url, "http://localhost");
      if (url.pathname === "/api/v1/targets/summaries") {
        const id = url.searchParams.get("ids")!;
        referenceIds.push(id);
        expect(url.searchParams.get("limit")).toBe("100");
        return new Response(
          JSON.stringify({
            data: [
              {
                id,
                name: id === caseId ? "Latest host label" : "Older host label",
                kind: "host",
                type_id: "custom-os",
              },
            ],
            page: { next: null },
          }),
        );
      }
      if (url.pathname === `/api/v1/cases/${caseId}`) {
        return new Response(
          JSON.stringify({
            data: {
              ...snapshot,
              case: {
                ...snapshot.case,
                trigger_kind: "signal",
                status: "running",
                condition_count: 2,
                firing_condition_count: 2,
              },
              conditions,
              condition_context: { groups: currentContext, assessments: currentContext },
              reports: [],
            },
          }),
        );
      }
      const collection = url.pathname.split("/").at(-1)!;
      if (collection in receiptRequests) {
        const after = url.searchParams.get("after");
        receiptRequests[collection].push(after ?? "first");
        if (after) expect(after).toBe(`older-${collection}`);
        const item =
          collection === "condition-history"
            ? {
                id: `membership-${after ? "old" : "latest"}`,
                case_id: caseId,
                condition_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                attached_at: timestamp,
                detached_at: after ? timestamp : null,
                reason: "Historical split",
              }
            : collection === "turns"
              ? {
                  id: `turns-${after ? "old" : "latest"}`,
                  case_id: caseId,
                  resolution_run_id: caseId,
                  ordinal: after ? 1 : 2,
                  status: "completed",
                  progress_kind: "hypothesis",
                  revision: 1,
                  inserted_at: timestamp,
                  updated_at: timestamp,
                  started_at: timestamp,
                  completed_at: timestamp,
                  summary: {
                    outcome: "decision",
                    type: "handoff",
                    reason: `${after ? "Older" : "Latest"} turns receipt`,
                    target_id: null,
                    capability: null,
                    operation: null,
                    failure_category: null,
                    failure_message: null,
                    relationship: null,
                  },
                }
              : {
                  id: `${collection}-${after ? "old" : "latest"}`,
                  revision: 1,
                  capability: "fixture",
                  operation: `${after ? "Older" : "Latest"} ${collection} receipt`,
                  status:
                    collection === "proposals"
                      ? "authorized"
                      : collection === "operations"
                        ? "applied"
                        : "verified",
                  target_id: collection === "proposals" ? (after ? oldReportId : caseId) : null,
                  proposal_id: null,
                  outcome_category: null,
                  completed_at: timestamp,
                  updated_at: timestamp,
                  accepted_at: timestamp,
                  inserted_at: timestamp,
                  source_turn_id: caseId,
                  access_method_id: caseId,
                  proposal_digest: "a".repeat(64),
                };
        return new Response(
          JSON.stringify({
            data: [item],
            page: { next: after ? null : `older-${collection}` },
          }),
        );
      }
      if (url.pathname.endsWith("/evidence")) {
        const after = url.searchParams.get("after");
        requests.push(after ?? "first");
        if (after && failNext) {
          failNext = false;
          return new Response(
            JSON.stringify({ error: { message: "History storage unavailable" } }),
            { status: 500 },
          );
        }
        const evidence: components["schemas"]["EvidenceSummary"] = {
          id: after ? oldReportId : reportId,
          case_id: caseId,
          resolution_run_id: caseId,
          turn_id: null,
          kind: "observation",
          source: "fixture",
          source_ref: "history-window",
          summary: {
            status: "applied",
            category: null,
            target_id: null,
            condition_id: null,
            title: after ? "Older window receipt" : "Latest window receipt",
            target_label: null,
          },
          observed_at: timestamp,
          inserted_at: timestamp,
          updated_at: timestamp,
        };
        const response = new Response(
          JSON.stringify({ data: [evidence], page: { next: after ? null : "older-cursor" } }),
        );
        if (requests.length === 2 && after === null) {
          delayedResponse = response;
          return new Promise<Response>((resolve) => {
            delayedRefresh = resolve;
          });
        }
        return response;
      }
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    render(
      <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
        <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
          <Routes>
            <Route path="/cases/:caseId" element={<CaseDetailPage />} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    expect(await screen.findByText("Latest window receipt")).toBeDefined();
    expect(screen.getByText("Latest turns receipt")).toBeDefined();
    const user = userEvent.setup();
    await user.click(screen.getByText(/Latest proposals receipt/));
    expect(screen.getAllByText("Latest host label").length).toBeGreaterThan(0);
    expect(screen.getByText("Current independent causes remain visible")).toBeDefined();
    expect(screen.getByText("Current recovery still requires observation")).toBeDefined();
    expect(screen.getByText(/Latest operations receipt/)).toBeDefined();
    expect(screen.getByText(/Latest proposals receipt/)).toBeDefined();
    expect(screen.getByText(/Latest verification-attempts receipt/)).toBeDefined();
    expect(requests).toEqual(["first"]);
    expect(screen.queryByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeNull();
    expect(screen.queryByText("Older window receipt")).toBeNull();
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await waitFor(() => expect(delayedRefresh).toBeDefined());
    await user.click(screen.getByRole("button", { name: "Next" }));
    if (fails) {
      expect(await screen.findByText("History storage unavailable")).toBeDefined();
      expect(screen.getByText("Latest window receipt")).toBeDefined();
      expect(screen.getByText("Page 1")).toBeDefined();
      expect(requests).toEqual(["first", "first", "older-cursor"]);
      await user.click(screen.getByRole("button", { name: "Next" }));
    }
    expect(await screen.findByText("Older window receipt")).toBeDefined();
    expect(screen.getByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeDefined();
    expect(screen.getByText("Older turns receipt")).toBeDefined();
    expect(screen.queryByText("Latest turns receipt")).toBeNull();
    await user.click(screen.getByText(/Older proposals receipt/));
    expect(screen.getAllByText("Older host label").length).toBeGreaterThan(0);
    expect(screen.queryByText("Latest host label")).toBeNull();
    expect(screen.getByText("Current independent causes remain visible")).toBeDefined();
    expect(screen.getByText("Current recovery still requires observation")).toBeDefined();
    expect(screen.getByText(/Older operations receipt/)).toBeDefined();
    expect(screen.getByText(/Older proposals receipt/)).toBeDefined();
    expect(screen.getByText(/Older verification-attempts receipt/)).toBeDefined();
    expect(screen.queryByText(/Latest operations receipt/)).toBeNull();
    expect(screen.queryByText(/Latest proposals receipt/)).toBeNull();
    expect(screen.queryByText(/Latest verification-attempts receipt/)).toBeNull();
    expect(screen.queryByText("Latest window receipt")).toBeNull();
    const expected = fails
      ? ["first", "first", "older-cursor", "older-cursor"]
      : ["first", "first", "older-cursor"];
    expect(requests).toEqual(expected);
    await act(async () => {
      delayedRefresh?.(delayedResponse!);
    });
    expect(screen.queryByText("Latest window receipt")).toBeNull();
    expect(screen.getByText("Older window receipt")).toBeDefined();
    expect(screen.getByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeDefined();
    expect(screen.queryByText(/Latest operations receipt/)).toBeNull();
    await user.click(screen.getByRole("button", { name: "Previous" }));
    expect(await screen.findByText("Latest window receipt")).toBeDefined();
    expect(screen.queryByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeNull();
    expect(screen.queryByText("Older window receipt")).toBeNull();
    await user.click(screen.getByText(/Latest proposals receipt/));
    expect(screen.getAllByText("Latest host label").length).toBeGreaterThan(0);
    expect(screen.queryByText("Older host label")).toBeNull();
    expect(referenceIds).toEqual([caseId, oldReportId, caseId]);
    expect(requests).toEqual([...expected, "first"]);
    for (const [collection, calls] of Object.entries(receiptRequests)) {
      expect(calls).toEqual(
        expected
          .map((cursor) => (cursor === "first" ? cursor : `older-${collection}`))
          .concat("first"),
      );
    }
  },
);

test.each([false, true])(
  "case report read failure=%s keeps the case available and reads only its current report",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const path = new URL(request.url, "http://localhost").pathname;
      requests.push(path);
      if (path === `/api/v1/cases/${caseId}`)
        return new Response(JSON.stringify({ data: snapshot }));
      if (path === `/api/v1/reports/${reportId}`) {
        return fails
          ? new Response(JSON.stringify({ error: { message: "Report storage unavailable" } }), {
              status: 500,
            })
          : new Response(JSON.stringify({ data: report }));
      }
      if (path.startsWith("/api/v1/reports/"))
        throw new Error("Historical report must stay unloaded");
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    render(
      <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
        <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
          <Routes>
            <Route path="/cases/:caseId" element={<CaseDetailPage />} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    expect(await screen.findByRole("heading", { name: "Physical host recovered" })).toBeDefined();
    if (fails) {
      expect(await screen.findByText("Report storage unavailable")).toBeDefined();
      expect(await screen.findByText("Activity history")).toBeDefined();
    } else {
      expect(await screen.findByText("The current recovery was verified.")).toBeDefined();
    }
    await waitFor(() =>
      expect(requests.filter((path) => path.startsWith("/api/v1/reports/"))).toEqual([
        `/api/v1/reports/${reportId}`,
      ]),
    );
  },
);
