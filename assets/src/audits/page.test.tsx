import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { AuditPage } from "@/audits/page";

const windowUUID = (n: number) => `20000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const windowSchedule = (n: number) => ({
  id: windowUUID(n),
  name: `Window schedule ${n}`,
  revision: 1,
  active: true,
  cron_expression: "0 * * * *",
  timezone: "Etc/UTC",
  report_language: "en",
  next_run_at: "2026-10-05T01:00:00Z",
  management_boundary_id: null,
});
const windowRun = (n: number) => ({
  id: windowUUID(n + 100),
  audit_schedule_id: windowUUID(90),
  status: "failed",
  target_id: null,
  target_key: `Window host ${n}`,
  case_id: null,
  scheduled_for: "2026-10-05T01:00:00Z",
});

test("Audit current windows reach item51 and an off-page schedule without full catalog reads", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    if (
      url.pathname === "/api/v1/audit-schedules/summaries" ||
      url.pathname === "/api/v1/audit-runs/summaries"
    ) {
      expect(url.searchParams.get("limit")).toBe("50");
      const indices = url.searchParams.has("after")
        ? [51]
        : Array.from({ length: 50 }, (_, n) => n + 1);
      return Response.json({
        data: indices.map((index) =>
          url.pathname.includes("schedules") ? windowSchedule(index) : windowRun(index),
        ),
        page: { next: indices[0] === 51 ? null : "tail" },
      });
    }
    if (url.pathname === `/api/v1/audit-schedules/${windowUUID(90)}`)
      return Response.json({
        data: {
          ...windowSchedule(90),
          desired_outcome: "Exact off-page objective",
          target_ids: Array.from({ length: 51 }, (_, n) => windowUUID(n + 200)),
        },
      });
    if (url.pathname === "/api/v1/targets/summaries") {
      const ids = url.searchParams.get("ids")!.split(",");
      expect(ids.length).toBeLessThanOrEqual(50);
      return Response.json({
        data: ids.map((id) => ({ id, name: `Scope ${id}` })),
        page: { next: null },
      });
    }
    throw new Error(`Unexpected catalog read ${url.pathname}`);
  });
  render(auditScreen({ id: "audit-viewer", role: "viewer" }));
  const user = userEvent.setup();
  const schedules = screen.getByRole("region", { name: "Schedules" });
  const runs = screen.getByRole("region", { name: "Audit runs" });
  await within(schedules).findByText("Window schedule 1");
  await within(runs).findByText("Window host 1");
  expect(requests).toHaveLength(2);
  await user.click(within(schedules).getByRole("button", { name: "Next" }));
  await within(schedules).findByText("Window schedule 51");
  await user.click(within(runs).getByRole("button", { name: "Next" }));
  await within(runs).findByText("Window host 51");
  await user.click(within(runs).getByRole("button", { name: "Review schedule" }));
  await screen.findByText("Exact off-page objective");
  await screen.findByText(`Scope ${windowUUID(200)}`, { exact: false });
  const scopeNext = screen
    .getAllByRole("button", { name: "Next" })
    .find((button) => !button.hasAttribute("disabled"))!;
  await user.click(scopeNext);
  await screen.findByText(`Scope ${windowUUID(250)}`);
  await user.click(screen.getByRole("button", { name: "Close" }));
  expect(screen.queryByText("Exact off-page objective")).toBeNull();
  expect(requests.some((url) => url.pathname === "/api/v1/targets")).toBe(false);
});

test("Audit page errors retain the complete current window and retry its cursor", async () => {
  await i18n.changeLanguage("en");
  let fail = true;
  const cursors: Array<string | null> = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/audit-schedules/summaries") {
      const after = url.searchParams.get("after");
      cursors.push(after);
      if (after && fail)
        return Response.json({ error: { message: "Storage unavailable" } }, { status: 500 });
      return Response.json({
        data: [windowSchedule(after ? 51 : 1)],
        page: { next: after ? null : "tail" },
      });
    }
    return Response.json({ data: [], page: { next: null } });
  });
  render(auditScreen({ id: "audit-viewer", role: "viewer" }));
  const user = userEvent.setup();
  const schedules = screen.getByRole("region", { name: "Schedules" });
  await within(schedules).findByText("Window schedule 1");
  await user.click(within(schedules).getByRole("button", { name: "Next" }));
  await waitFor(() => expect(screen.getAllByRole("alert").length).toBeGreaterThan(1));
  expect(within(schedules).getByText("Window schedule 1")).toBeDefined();
  fail = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await within(schedules).findByText("Window schedule 51");
  expect(cursors).toEqual([null, "tail", "tail"]);
});

test("an accepted Audit creation refreshes the page selected while its acknowledgement was pending", async () => {
  await i18n.changeLanguage("en");
  vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
  const cursors: Array<string | null> = [];
  let resolvePost!: (response: Response) => void;
  let canonical: Record<string, unknown> = {};
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts++;
      const input = await request.json();
      canonical = { ...input.audit_schedule, id: receiptId, revision: 1 };
      return new Promise<Response>((resolve) => {
        resolvePost = resolve;
      });
    }
    if (url.pathname === "/api/v1/audit-schedules/summaries") {
      const after = url.searchParams.get("after");
      cursors.push(after);
      return Response.json({
        data: [windowSchedule(after ? 51 : 1)],
        page: { next: after ? null : "tail" },
      });
    }
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  await waitFor(() => expect(posts).toBe(1));
  const schedules = screen.getByRole("region", { name: "Schedules" });
  await user.click(within(schedules).getByRole("button", { name: "Next" }));
  await within(schedules).findByText("Window schedule 51");
  await act(async () => resolvePost(Response.json({ data: canonical }, { status: 201 })));
  await screen.findByText("Registered: Receipt audit");
  expect(cursors).toEqual([null, "tail", "tail"]);
  expect(within(schedules).queryByText("Window schedule 1")).toBeNull();
  expect(posts).toBe(1);
});

test("an off-page Period Audit Run hash loads exact diagnostics and aborts on close", async () => {
  await i18n.changeLanguage("en");
  const runId = windowUUID(151);
  let detailRead!: Request;
  let resolveDetail!: (response: Response) => void;
  wire.mockImplementation(async (request: Request) => {
    if (new URL(request.url).pathname === `/api/v1/audit-runs/${runId}`) {
      detailRead = request;
      return new Promise<Response>((resolve) => {
        resolveDetail = resolve;
      });
    }
    return Response.json({ data: [], page: { next: null } });
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "audit-viewer", role: "viewer" } } as Authentication}
    >
      <MemoryRouter initialEntries={[`/audits#audit-run-${runId}`]}>
        <AuditPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await waitFor(() => expect(detailRead).toBeDefined());
  await userEvent.setup().click(screen.getByRole("button", { name: "Close" }));
  expect(detailRead.signal.aborted).toBe(true);
  await act(async () =>
    resolveDetail(
      Response.json({ data: { ...windowRun(51), reason: "Private late diagnostics" } }),
    ),
  );
  expect(screen.queryByText("Private late diagnostics")).toBeNull();
});

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

test("initial Audit read failure is visible to a viewer and retries without writes", async () => {
  await i18n.changeLanguage("en");
  let fail = true;
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    if (new URL(request.url).pathname === "/api/v1/audit-schedules/summaries")
      return fail
        ? Response.json({ error: { message: "Storage unavailable" } }, { status: 500 })
        : Response.json({ data: [windowSchedule(51)], page: { next: null } });
    return Response.json({ data: [], page: { next: null } });
  });
  render(auditScreen({ id: "audit-viewer", role: "viewer" }));
  await screen.findByText(i18n.t("audits.requestFailed"));
  fail = false;
  await userEvent.setup().click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Window schedule 51");
  expect(screen.queryByText(i18n.t("audits.requestFailed"))).toBeNull();
});

test("failed Audit Run labels do not publish a partial window and retry the same cursor", async () => {
  await i18n.changeLanguage("en");
  let fail = true;
  const cursors: Array<string | null> = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/audit-runs/summaries") {
      const after = url.searchParams.get("after");
      cursors.push(after);
      const index = after ? 51 : 1;
      return Response.json({
        data: [{ ...windowRun(index), target_id: windowUUID(index) }],
        page: { next: after ? null : "tail" },
      });
    }
    if (url.pathname === "/api/v1/targets/summaries") {
      const id = url.searchParams.get("ids")!;
      expect(id.split(",")).toHaveLength(1);
      if (id === windowUUID(51) && fail)
        return Response.json({ error: { message: "Label storage unavailable" } }, { status: 500 });
      return Response.json({ data: [{ id, name: `Exact host ${id}` }], page: { next: null } });
    }
    return Response.json({ data: [], page: { next: null } });
  });
  render(auditScreen({ id: "audit-viewer", role: "viewer" }));
  const user = userEvent.setup();
  const runs = screen.getByRole("region", { name: "Audit runs" });
  await within(runs).findByText(`Exact host ${windowUUID(1)}`);
  await user.click(within(runs).getByRole("button", { name: "Next" }));
  await screen.findByText(i18n.t("audits.requestFailed"));
  expect(within(runs).queryByText(`Exact host ${windowUUID(51)}`)).toBeNull();
  expect(within(runs).getByText(`Exact host ${windowUUID(1)}`)).toBeDefined();
  fail = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await within(runs).findByText(`Exact host ${windowUUID(51)}`);
  expect(cursors).toEqual([null, "tail", "tail"]);
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  wire.mockReset();
  sessionStorage.clear();
});

test("Audit target choices reach Target51 and retain explicit selections from both pages", async () => {
  await i18n.changeLanguage("en");
  const uuid = (n: number) => `20000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const posts: Record<string, unknown>[] = [];
  const choices: URL[] = [];

  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      const body = await request.json();
      posts.push(body);
      return Response.json(
        { data: { ...body.audit_schedule, id: body.audit_schedule.registration_id, revision: 1 } },
        { status: 201 },
      );
    }
    if (url.pathname === "/api/v1/targets/summaries") {
      choices.push(url);
      expect(url.searchParams.get("limit")).toBe("50");
      expect(url.searchParams.get("active")).toBe("true");
      const indices = url.searchParams.has("after")
        ? [51]
        : Array.from({ length: 50 }, (_, n) => n + 1);
      return Response.json({
        data: indices.map((n) => ({ id: uuid(n), name: `Scope Target ${n}`, active: true })),
        page: { next: url.searchParams.has("after") ? null : "target-tail" },
      });
    }
    return Response.json({ data: [], page: { next: null } });
  });

  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "audit-admin", role: "admin" } } as Authentication}
    >
      <MemoryRouter>
        <AuditPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Add audit schedule" }));
  await user.type(screen.getByLabelText("Name"), "Two host audit");
  await user.type(
    screen.getByLabelText("Desired outcome (observable state)"),
    "Storage health is normal",
  );
  const targets = screen.getByRole("group", { name: "Targets" });
  await user.click(await within(targets).findByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Scope Target 1" }));
  await user.keyboard("{Escape}");
  await user.click(within(targets).getByRole("button", { name: "Next" }));
  await waitFor(() => expect(choices).toHaveLength(2));
  await user.click(within(targets).getByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Scope Target 51" }));
  await user.keyboard("{Escape}");
  await user.click(within(targets).getByRole("combobox", { name: "Targets" }));
  const retained = await screen.findByRole("option", { name: "Scope Target 1" });
  expect(retained.getAttribute("aria-selected")).toBe("true");
  await user.click(retained);
  await user.keyboard("{Escape}");
  expect(within(targets).getByRole("combobox", { name: "Targets" }).textContent).not.toContain(
    "Scope Target 1",
  );
  await user.click(within(targets).getByRole("button", { name: "Previous" }));
  await waitFor(() => expect(choices).toHaveLength(3));
  await user.click(within(targets).getByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Scope Target 1" }));
  await user.keyboard("{Escape}");
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({
    audit_schedule: { target_ids: [uuid(1), uuid(51)], management_boundary_id: null },
  });
});

test("the actual Audit form sends its chosen registration identity and selected Target scope", async () => {
  await i18n.changeLanguage("en");
  const id = "20000000-0000-4000-8000-000000000055";
  const targetId = "20000000-0000-4000-8000-000000000056";
  vi.spyOn(crypto, "randomUUID").mockReturnValue(id);
  const posts: Record<string, unknown>[] = [];

  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      expect(url.pathname).toBe("/api/v1/audit-schedules");
      const body = await request.json();
      posts.push(body);
      return Response.json({ data: { ...body.audit_schedule, id, revision: 1 } }, { status: 201 });
    }
    return Response.json({
      data:
        url.pathname === "/api/v1/targets/summaries"
          ? [{ id: targetId, name: "Selected Linux", active: true }]
          : [],
      page: { next: null },
    });
  });

  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "audit-admin", role: "admin" } } as Authentication}
    >
      <MemoryRouter>
        <AuditPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );

  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Add audit schedule" }));
  await user.type(screen.getByLabelText("Name"), "Daily host audit");
  await user.type(
    screen.getByLabelText("Desired outcome (observable state)"),
    "Storage health is normal",
  );
  await user.click(screen.getByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Selected Linux" }));
  await user.keyboard("{Escape}");
  await user.click(screen.getByRole("button", { name: "Create schedule" }));

  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toEqual({
    audit_schedule: {
      registration_id: id,
      name: "Daily host audit",
      desired_outcome: "Storage health is normal",
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      cron_expression: "0 * * * *",
      report_language: "en",
      target_ids: [targetId],
      management_boundary_id: null,
    },
  });
  await screen.findByText("Registered: Daily host audit");
  expect(sessionStorage.getItem("skopos.audit-registration:audit-admin")).toBeNull();
});

test("a lost Audit registration survives reload and confirms the original schedule without another POST", async () => {
  await i18n.changeLanguage("en");
  const id = "20000000-0000-4000-8000-000000000057";
  const targetId = "20000000-0000-4000-8000-000000000058";
  const key = "skopos.audit-registration:audit-admin";
  vi.spyOn(crypto, "randomUUID").mockReturnValue(id);
  let schedule: Record<string, unknown> | null = null;
  let canRead = false;
  let posts = 0;
  const exactReads: string[] = [];

  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts++;
      const input = await request.json();
      const intent = JSON.parse(sessionStorage.getItem(key)!);
      expect(Object.keys(intent).sort()).toEqual(["digest", "id"]);
      expect(intent.id).toBe(id);
      expect(intent.digest).toMatch(/^[0-9a-f]{64}$/);
      expect(sessionStorage.getItem(key)).not.toContain("Storage health is normal");
      schedule = { ...input.audit_schedule, id, revision: 1, active: true };
      return Response.json({ error: { message: "Response lost after commit" } }, { status: 503 });
    }
    if (url.pathname === `/api/v1/audit-schedules/${id}`) {
      exactReads.push(url.pathname);
      return canRead
        ? Response.json({ data: schedule })
        : Response.json({ error: { message: "Receipt storage unavailable" } }, { status: 500 });
    }
    return Response.json({
      data:
        url.pathname === "/api/v1/targets/summaries"
          ? [{ id: targetId, name: "Selected Linux", active: true }]
          : [],
      page: { next: null },
    });
  });

  function show() {
    return render(
      <AuthenticationContext.Provider
        value={{ account: { id: "audit-admin", role: "admin" } } as Authentication}
      >
        <MemoryRouter>
          <AuditPage />
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
  }
  show();
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Add audit schedule" }));
  await user.type(screen.getByLabelText("Name"), "Recovered audit");
  await user.type(
    screen.getByLabelText("Desired outcome (observable state)"),
    "Storage health is normal",
  );
  await user.click(await screen.findByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Selected Linux" }));
  await user.keyboard("{Escape}");
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  await screen.findByText("Registration could not be confirmed.");
  expect(posts).toBe(1);
  const original = sessionStorage.getItem(key);
  expect(original).not.toBeNull();

  cleanup();
  canRead = true;
  show();
  await user.click(await screen.findByRole("button", { name: "Check registration result" }));
  await screen.findByText("Registered: Recovered audit");
  expect(posts).toBe(1);
  expect(exactReads.length).toBeGreaterThan(0);
  expect(exactReads.every((path) => path === `/api/v1/audit-schedules/${id}`)).toBe(true);
  expect(sessionStorage.getItem(key)).toBeNull();
});

const registrationKey = "skopos.audit-registration:audit-admin";
const receiptId = "20000000-0000-4000-8000-000000000059";
const selectedId = "20000000-0000-4000-8000-000000000060";

function auditScreen(account = { id: "audit-admin", role: "admin" }) {
  return (
    <AuthenticationContext.Provider value={{ account } as Authentication}>
      <MemoryRouter>
        <AuditPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
}

async function fillAudit() {
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Add audit schedule" }));
  await user.type(screen.getByLabelText("Name"), "Receipt audit");
  await user.type(
    screen.getByLabelText("Desired outcome (observable state)"),
    "Storage health is normal",
  );
  await user.click(await screen.findByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Selected Linux" }));
  await user.keyboard("{Escape}");
  return user;
}

function scopeResponse(request: Request) {
  return Response.json({
    data:
      new URL(request.url).pathname === "/api/v1/targets/summaries"
        ? [{ id: selectedId, name: "Selected Linux", active: true }]
        : [],
    page: { next: null },
  });
}

test("Audit management boundary choices reach Boundary51 and send only its exact ID", async () => {
  await i18n.changeLanguage("en");
  const uuid = (n: number) => `30000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const posts: Record<string, unknown>[] = [];
  const cursors: Array<string | null> = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      const body = await request.json();
      posts.push(body.audit_schedule);
      return Response.json(
        { data: { ...body.audit_schedule, id: body.audit_schedule.registration_id, revision: 1 } },
        { status: 201 },
      );
    }
    if (
      url.pathname === "/api/v1/management-boundaries" &&
      url.searchParams.get("active") === "true"
    ) {
      expect(url.searchParams.get("limit")).toBe("50");
      cursors.push(url.searchParams.get("after"));
      const tail = url.searchParams.has("after");
      return Response.json({
        data: (tail ? [51] : Array.from({ length: 50 }, (_, n) => n + 1)).map((n) => ({
          id: uuid(n),
          name: `Boundary ${n}`,
          active: true,
        })),
        page: { next: tail ? null : "boundary-tail" },
      });
    }
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  await user.click(screen.getByRole("combobox", { name: "Scope" }));
  await user.click(await screen.findByRole("option", { name: "Management boundary" }));
  const choices = screen.getByRole("group", { name: "Management boundary" });
  await user.click(await within(choices).findByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Boundary 1" }));
  await user.click(within(choices).getByRole("button", { name: "Next" }));
  await waitFor(() => expect(cursors).toEqual([null, "boundary-tail"]));
  await user.click(within(choices).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Boundary 51" }));
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  await screen.findByText("Registered: Receipt audit");
  expect(posts).toHaveLength(1);
  expect(posts[0]).toMatchObject({ target_ids: [], management_boundary_id: uuid(51) });
});

test("Audit receipt persistence failure sends no creation request", async () => {
  await i18n.changeLanguage("en");
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "POST") posts++;
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new Error("Quota exceeded");
  });
  try {
    await user.click(screen.getByRole("button", { name: "Create schedule" }));
    await screen.findByText("Could not save the request. No schedule was submitted.");
    expect(posts).toBe(0);
    expect(sessionStorage.getItem(registrationKey)).toBeNull();
  } finally {
    saving.mockRestore();
  }
});

test.each(["invalid JSON", JSON.stringify({ id: receiptId }), "unavailable storage"])(
  "an unreadable saved Audit receipt blocks creation: %s",
  async (stored) => {
    await i18n.changeLanguage("en");
    const getItem = sessionStorage.getItem.bind(sessionStorage);
    const reading =
      stored === "unavailable storage"
        ? vi.spyOn(sessionStorage, "getItem").mockImplementation((key) => {
            if (key === registrationKey) throw new Error("Unavailable");
            return getItem(key);
          })
        : null;
    if (!reading) sessionStorage.setItem(registrationKey, stored);
    try {
      wire.mockImplementation(async (request: Request) => scopeResponse(request));
      render(auditScreen());
      await screen.findByText(
        "The saved registration request could not be read. No new schedule will be submitted.",
      );
      const user = userEvent.setup();
      await user.click(screen.getByRole("button", { name: "Add audit schedule" }));
      expect(screen.queryByRole("button", { name: "Create schedule" })).toBeNull();
      expect(wire.mock.calls.every(([request]) => request.method === "GET")).toBe(true);
    } finally {
      reading?.mockRestore();
    }
  },
);

test.each(["foreign ID", "different scope", "different objective", "missing", "storage failure"])(
  "an unknown Audit receipt remains retained without another POST: %s",
  async (result) => {
    await i18n.changeLanguage("en");
    vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
    let canonical: Record<string, unknown> = {};
    let posts = 0;
    const reads: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const path = new URL(request.url).pathname;
      if (request.method === "POST") {
        posts++;
        const body = await request.json();
        canonical = { ...body.audit_schedule, id: receiptId, revision: 1 };
        return Response.json({ error: { message: "Response lost" } }, { status: 503 });
      }
      if (path === `/api/v1/audit-schedules/${receiptId}`) {
        reads.push(path);
        if (result === "missing" || result === "storage failure")
          return Response.json(
            { error: { message: result } },
            { status: result === "missing" ? 404 : 500 },
          );
        const response = { ...canonical };
        if (result === "foreign ID") response.id = selectedId;
        if (result === "different scope") response.target_ids = [];
        if (result === "different objective") response.desired_outcome = "Different objective";
        return Response.json({ data: response });
      }
      return scopeResponse(request);
    });
    render(auditScreen());
    const user = await fillAudit();
    await user.click(screen.getByRole("button", { name: "Create schedule" }));
    const check = await screen.findByRole("button", { name: "Check registration result" });
    await waitFor(() => expect(check.hasAttribute("disabled")).toBe(false));
    const original = sessionStorage.getItem(registrationKey);
    expect(original).not.toBeNull();
    cleanup();
    render(auditScreen());
    await user.click(await screen.findByRole("button", { name: "Check registration result" }));
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "Check registration result" }).hasAttribute("disabled"),
      ).toBe(false),
    );
    expect(sessionStorage.getItem(registrationKey)).toBe(original);
    expect(screen.queryByRole("button", { name: "Create schedule" })).toBeNull();
    expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
    expect(posts).toBe(1);
    expect(reads).toEqual([
      `/api/v1/audit-schedules/${receiptId}`,
      `/api/v1/audit-schedules/${receiptId}`,
    ]);
  },
);

test.each([422, 409, 503])(
  "a late Audit creation response after account change handles only the original receipt: %s",
  async (status) => {
    await i18n.changeLanguage("en");
    vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
    let resolvePost!: (response: Response) => void;
    let posts = 0;
    let receiptReads = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") {
        posts++;
        return new Promise<Response>((resolve) => {
          resolvePost = resolve;
        });
      }
      if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`) receiptReads++;
      return scopeResponse(request);
    });
    const view = render(auditScreen());
    const user = await fillAudit();
    await user.click(screen.getByRole("button", { name: "Create schedule" }));
    await waitFor(() => expect(posts).toBe(1));
    const original = sessionStorage.getItem(registrationKey);
    view.rerender(auditScreen({ id: "different-admin", role: "admin" }));
    await act(async () =>
      resolvePost(Response.json({ error: { message: "Late response" } }, { status })),
    );
    await waitFor(() =>
      expect(sessionStorage.getItem(registrationKey)).toBe(status === 503 ? original : null),
    );
    expect(sessionStorage.getItem("skopos.audit-registration:different-admin")).toBeNull();
    expect(receiptReads).toBe(0);
    expect(posts).toBe(1);
    expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
  },
);

test("closing the Audit form aborts its pending scope read and ignores a late response", async () => {
  await i18n.changeLanguage("en");
  let choiceRequest!: Request;
  let resolveChoices!: (response: Response) => void;
  wire.mockImplementation(async (request: Request) => {
    if (new URL(request.url).pathname === "/api/v1/targets/summaries") {
      choiceRequest = request;
      return new Promise<Response>((resolve) => {
        resolveChoices = resolve;
      });
    }
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Add audit schedule" }));
  await waitFor(() => expect(choiceRequest).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  expect(choiceRequest.signal.aborted).toBe(true);
  await act(async () =>
    resolveChoices(
      Response.json({ data: [{ id: selectedId, name: "Late target" }], page: { next: null } }),
    ),
  );
  expect(screen.queryByRole("group", { name: "Targets" })).toBeNull();
  expect(wire.mock.calls.every(([request]) => request.method === "GET")).toBe(true);
});

test("an Audit result cannot confirm a different request currently saved for the account", async () => {
  await i18n.changeLanguage("en");
  vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
  let canonical: Record<string, unknown> = {};
  let canRead = false;
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "POST") {
      posts++;
      const input = await request.json();
      canonical = { ...input.audit_schedule, id: receiptId, revision: 1 };
      return Response.json({ error: { message: "Lost response" } }, { status: 503 });
    }
    if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`)
      return canRead
        ? Response.json({ data: canonical })
        : Response.json({ error: { message: "Unavailable" } }, { status: 500 });
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  const check = await screen.findByRole("button", { name: "Check registration result" });
  await waitFor(() => expect(check.hasAttribute("disabled")).toBe(false));
  const other = JSON.stringify({ id: selectedId, digest: "b".repeat(64) });
  sessionStorage.setItem(registrationKey, other);
  canRead = true;
  await user.click(check);
  await waitFor(() => expect(check.hasAttribute("disabled")).toBe(false));
  expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
  expect(screen.queryByRole("button", { name: "Create schedule" })).toBeNull();
  expect(sessionStorage.getItem(registrationKey)).toBe(other);
  expect(posts).toBe(1);
});

test.each(["closing", "changing accounts", "changing roles"])(
  "%s during an Audit result check aborts the read and preserves the original receipt",
  async (change) => {
    await i18n.changeLanguage("en");
    vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
    let canonical: Record<string, unknown> = {};
    let reads = 0;
    let resolveCheck!: (response: Response) => void;
    let checking!: Request;
    let posts = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") {
        posts++;
        const input = await request.json();
        canonical = { ...input.audit_schedule, id: receiptId, revision: 1 };
        return Response.json({ error: { message: "Lost response" } }, { status: 503 });
      }
      if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`) {
        reads++;
        if (reads === 1)
          return Response.json({ error: { message: "Unavailable" } }, { status: 500 });
        checking = request;
        return new Promise<Response>((resolve) => {
          resolveCheck = resolve;
        });
      }
      return scopeResponse(request);
    });
    const view = render(auditScreen());
    const user = await fillAudit();
    await user.click(screen.getByRole("button", { name: "Create schedule" }));
    const check = await screen.findByRole("button", { name: "Check registration result" });
    await waitFor(() => expect(check.hasAttribute("disabled")).toBe(false));
    const original = sessionStorage.getItem(registrationKey);
    await user.click(check);
    await waitFor(() => expect(checking).toBeDefined());
    if (change === "closing") await user.click(screen.getByRole("button", { name: "Cancel" }));
    else
      view.rerender(
        auditScreen(
          change === "changing accounts"
            ? { id: "different-admin", role: "admin" }
            : { id: "audit-admin", role: "viewer" },
        ),
      );
    expect(checking.signal.aborted).toBe(true);
    await act(async () => resolveCheck(Response.json({ data: canonical })));
    expect(sessionStorage.getItem(registrationKey)).toBe(original);
    expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
    expect(posts).toBe(1);
  },
);

test("a late accepted Audit creation after closing remains confirmable without resending", async () => {
  await i18n.changeLanguage("en");
  vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
  let canonical: Record<string, unknown> = {};
  let resolvePost!: (response: Response) => void;
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "POST") {
      posts++;
      const input = await request.json();
      canonical = { ...input.audit_schedule, id: receiptId, revision: 1 };
      return new Promise<Response>((resolve) => {
        resolvePost = resolve;
      });
    }
    if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`)
      return Response.json({ data: canonical });
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  await waitFor(() => expect(posts).toBe(1));
  const original = sessionStorage.getItem(registrationKey);
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  await act(async () => resolvePost(Response.json({ data: canonical }, { status: 201 })));
  expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
  expect(sessionStorage.getItem(registrationKey)).toBe(original);
  await user.click(screen.getByRole("button", { name: "Check registration result" }));
  await screen.findByText("Registered: Receipt audit");
  expect(sessionStorage.getItem(registrationKey)).toBeNull();
  expect(posts).toBe(1);
});

test("an accepted Audit creation keeps its receipt when the list refresh fails", async () => {
  await i18n.changeLanguage("en");
  vi.spyOn(crypto, "randomUUID").mockReturnValue(receiptId);
  let canonical: Record<string, unknown> = {};
  let accepted = false;
  let refreshFails = true;
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (request.method === "POST") {
      posts++;
      const input = await request.json();
      canonical = { ...input.audit_schedule, id: receiptId, revision: 1 };
      accepted = true;
      return Response.json({ data: canonical }, { status: 201 });
    }
    if (path === `/api/v1/audit-schedules/${receiptId}`) return Response.json({ data: canonical });
    if (path === "/api/v1/audit-schedules/summaries" && accepted && refreshFails)
      return Response.json({ error: { message: "List storage unavailable" } }, { status: 500 });
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  const check = await screen.findByRole("button", { name: "Check registration result" });
  await waitFor(() => expect(check.hasAttribute("disabled")).toBe(false));
  expect(sessionStorage.getItem(registrationKey)).not.toBeNull();
  expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
  refreshFails = false;
  await user.click(check);
  await screen.findByText("Registered: Receipt audit");
  expect(sessionStorage.getItem(registrationKey)).toBeNull();
  expect(posts).toBe(1);
});

test("a selected Target that became inactive is rejected by the server without an accepted receipt", async () => {
  await i18n.changeLanguage("en");
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "POST") {
      posts++;
      expect((await request.json()).audit_schedule.target_ids).toEqual([selectedId]);
      return Response.json(
        {
          error: {
            code: "validation_failed",
            message: "Request validation failed",
            details: { fields: ["schedule"] },
          },
        },
        { status: 422 },
      );
    }
    return scopeResponse(request);
  });
  render(auditScreen());
  const user = await fillAudit();
  await user.click(screen.getByRole("button", { name: "Create schedule" }));
  await screen.findByText("Request validation failed");
  expect(sessionStorage.getItem(registrationKey)).toBeNull();
  expect(screen.queryByRole("button", { name: "Check registration result" })).toBeNull();
  expect(screen.queryByText("Registered: Receipt audit")).toBeNull();
  expect(posts).toBe(1);
});
