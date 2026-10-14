import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { AuditPage } from "@/audits/page";

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
const receiptId = "20000000-0000-4000-8000-000000000071";
const selectedId = "20000000-0000-4000-8000-000000000072";
const key = "skopos.audit-deactivation:audit-admin";
const original = {
  id: receiptId,
  name: "Original audit",
  revision: 1,
  active: true,
  desired_outcome: "Storage health is normal",
  cron_expression: "0 * * * *",
  timezone: "Etc/UTC",
  report_language: "en",
  next_run_at: "2026-10-05T01:00:00Z",
  target_ids: [selectedId],
  management_boundary_id: null,
};
function auditScreen(account = { id: "audit-admin", role: "admin" }) {
  return (
    <AuthenticationContext.Provider value={{ account } as Authentication}>
      <MemoryRouter>
        <AuditPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
}
function list(request: Request, schedule = original) {
  return Response.json({
    data: new URL(request.url).pathname === "/api/v1/audit-schedules/summaries" ? [schedule] : [],
    page: { next: null },
  });
}
async function choose() {
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Deactivate" }));
  return user;
}

test("lost Audit deactivation survives reload and confirms the original ID without another POST", async () => {
  await i18n.changeLanguage("en");
  const key = "skopos.audit-deactivation:audit-admin";
  let canonical = {
    id: receiptId,
    name: "Original audit",
    revision: 1,
    active: true,
    desired_outcome: "Storage health is normal",
    cron_expression: "0 * * * *",
    timezone: "Etc/UTC",
    report_language: "en",
    next_run_at: "2026-10-05T01:00:00Z",
    target_ids: [selectedId],
    management_boundary_id: null,
  };
  let canRead = false;
  const requests: Array<{ method: string; path: string }> = [];
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    requests.push({ method: request.method, path });
    if (request.method === "POST") {
      expect(path).toBe(`/api/v1/audit-schedules/${receiptId}/deactivate`);
      expect(await request.json()).toEqual({ audit_schedule: { expected_revision: 1 } });
      expect(JSON.parse(sessionStorage.getItem(key)!)).toEqual({ id: receiptId, revision: 1 });
      canonical = { ...canonical, revision: 2, active: false };
      return Response.json({ error: { message: "Response lost after commit" } }, { status: 503 });
    }
    if (path === `/api/v1/audit-schedules/${receiptId}`) {
      if (canonical.active || canRead) return Response.json({ data: canonical });
      return Response.json({ error: { message: "Storage unavailable" } }, { status: 500 });
    }
    return Response.json({
      data: path === "/api/v1/audit-schedules/summaries" ? [canonical] : [],
      page: { next: null },
    });
  });
  render(auditScreen());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Deactivate" }));
  await user.click(screen.getByRole("button", { name: "Deactivate schedule" }));
  const check = await screen.findByRole("button", { name: "Check deactivation result" });
  await waitFor(() => expect(check.hasAttribute("disabled")).toBe(false));
  const original = sessionStorage.getItem(key);
  expect(original).not.toBeNull();
  cleanup();
  canRead = true;
  render(auditScreen());
  await user.click(await screen.findByRole("button", { name: "Check deactivation result" }));
  await screen.findByText("Deactivated: Original audit");
  expect(sessionStorage.getItem(key)).toBeNull();
  expect(requests.filter((request) => request.method === "POST")).toEqual([
    { method: "POST", path: `/api/v1/audit-schedules/${receiptId}/deactivate` },
  ]);
  expect(
    requests.filter((request) => request.path === `/api/v1/audit-schedules/${receiptId}`).length,
  ).toBeGreaterThanOrEqual(2);
});

test.each(["stale", "inactive", "unavailable"])(
  "a %s Audit precheck sends no deactivation",
  async (state) => {
    await i18n.changeLanguage("en");
    let posts = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") posts++;
      if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`)
        return state === "unavailable"
          ? Response.json({ error: { message: "Scope storage unavailable" } }, { status: 500 })
          : Response.json({
              data: {
                ...original,
                revision: state === "stale" ? 2 : 1,
                active: state !== "inactive",
              },
            });
      return list(request);
    });
    render(auditScreen());
    const user = await choose();
    await user.click(screen.getByRole("button", { name: "Deactivate schedule" }));
    await screen.findByText(
      state === "unavailable"
        ? "Scope storage unavailable"
        : "The schedule changed. Refresh it before deactivating.",
    );
    expect(posts).toBe(0);
    expect(sessionStorage.getItem(key)).toBeNull();
    expect(screen.queryByText("Deactivated: Original audit")).toBeNull();
  },
);

test("Audit deactivation receipt saving failure sends no POST", async () => {
  await i18n.changeLanguage("en");
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "POST") posts++;
    if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`)
      return Response.json({ data: original });
    return list(request);
  });
  render(auditScreen());
  const user = await choose();
  const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new Error("Storage unavailable");
  });
  try {
    await user.click(screen.getByRole("button", { name: "Deactivate schedule" }));
    await screen.findByText("Could not save the request. No deactivation was submitted.");
    expect(posts).toBe(0);
    expect(sessionStorage.getItem(key)).toBeNull();
  } finally {
    saving.mockRestore();
  }
});

test.each(["closing", "changing accounts", "changing roles"])(
  "%s during Audit deactivation precheck ignores the late read and sends no POST",
  async (change) => {
    await i18n.changeLanguage("en");
    let resolveRead!: (response: Response) => void;
    let reading!: Request;
    let posts = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") posts++;
      if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`) {
        reading = request;
        return new Promise<Response>((resolve) => {
          resolveRead = resolve;
        });
      }
      return list(request);
    });
    const view = render(auditScreen());
    const user = await choose();
    await user.click(screen.getByRole("button", { name: "Deactivate schedule" }));
    await waitFor(() => expect(reading).toBeDefined());
    if (change === "closing") await user.click(screen.getByRole("button", { name: "Cancel" }));
    else
      view.rerender(
        auditScreen(
          change === "changing accounts"
            ? { id: "other-admin", role: "admin" }
            : { id: "audit-admin", role: "viewer" },
        ),
      );
    expect(reading.signal.aborted).toBe(true);
    await act(async () => resolveRead(Response.json({ data: original })));
    expect(posts).toBe(0);
    expect(sessionStorage.getItem(key)).toBeNull();
    expect(screen.queryByRole("button", { name: "Deactivate schedule" })).toBeNull();
  },
);

test.each([409, 422, 503])(
  "a late Audit deactivation %s response after account change handles only its original receipt",
  async (status) => {
    await i18n.changeLanguage("en");
    let resolvePost!: (response: Response) => void;
    let posts = 0;
    let reads = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") {
        posts++;
        return new Promise<Response>((resolve) => {
          resolvePost = resolve;
        });
      }
      if (new URL(request.url).pathname === `/api/v1/audit-schedules/${receiptId}`) {
        reads++;
        return Response.json({ data: original });
      }
      return list(request);
    });
    const view = render(auditScreen());
    const user = await choose();
    await user.click(screen.getByRole("button", { name: "Deactivate schedule" }));
    await waitFor(() => expect(posts).toBe(1));
    const saved = sessionStorage.getItem(key);
    expect(saved).not.toBeNull();
    view.rerender(auditScreen({ id: "other-admin", role: "admin" }));
    await act(async () =>
      resolvePost(Response.json({ error: { message: "Late response" } }, { status })),
    );
    await waitFor(() => expect(sessionStorage.getItem(key)).toBe(status === 503 ? saved : null));
    expect(sessionStorage.getItem("skopos.audit-deactivation:other-admin")).toBeNull();
    expect(posts).toBe(1);
    expect(reads).toBe(1);
    expect(screen.queryByText("Deactivated: Original audit")).toBeNull();
  },
);

test.each(["active", "unchanged revision", "foreign ID", "storage failure", "missing"])(
  "an uncertain deactivation stays retained on %s rather than permitting another POST",
  async (state) => {
    await i18n.changeLanguage("en");
    const saved = JSON.stringify({ id: receiptId, revision: 1 });
    sessionStorage.setItem(key, saved);
    let posts = 0;
    const paths: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") posts++;
      const path = new URL(request.url).pathname;
      if (path === `/api/v1/audit-schedules/${receiptId}`) {
        paths.push(path);
        if (state === "storage failure" || state === "missing")
          return Response.json(
            { error: { message: state } },
            { status: state === "missing" ? 404 : 500 },
          );
        return Response.json({
          data: {
            ...original,
            id: state === "foreign ID" ? selectedId : receiptId,
            revision: state === "unchanged revision" ? 1 : 2,
            active: state === "active",
          },
        });
      }
      return list(request);
    });
    render(auditScreen());
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Check deactivation result" }));
    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "Check deactivation result" }).hasAttribute("disabled"),
      ).toBe(false),
    );
    expect(sessionStorage.getItem(key)).toBe(saved);
    await user.click(screen.getByRole("button", { name: "Deactivate" }));
    expect(screen.queryByRole("button", { name: "Deactivate schedule" })).toBeNull();
    expect(screen.queryByText("Deactivated: Original audit")).toBeNull();
    expect(posts).toBe(0);
    expect(paths).toEqual([`/api/v1/audit-schedules/${receiptId}`]);
  },
);

test("an unreadable deactivation receipt blocks a new operation", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem(key, JSON.stringify({ id: receiptId, revision: "1" }));
  wire.mockImplementation(async (request: Request) => list(request));
  render(auditScreen());
  await screen.findByText(
    "The saved deactivation request could not be read. No new deactivation will be submitted.",
  );
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Deactivate" }));
  expect(screen.queryByRole("button", { name: "Deactivate schedule" })).toBeNull();
  expect(wire.mock.calls.every(([request]) => request.method === "GET")).toBe(true);
});
