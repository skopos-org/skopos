import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import type { components } from "@/api/schema";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { ReportPage } from "@/reports/page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
const id = (n: number) => `10000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const timestamp = "2026-10-05T01:00:00Z";
function destination(n: number): components["schemas"]["ProviderSummary"] {
  return {
    id: id(n),
    name: `Destination ${n}`,
    kind: "notification",
    adapter_type: "http-webhook",
    enabled: false,
    revision: 1,
    check: {
      status: "passed",
      category: null,
      message: null,
      checked_revision: 1,
      checked_at: timestamp,
    },
  };
}
function page(accountId = id(700), role = "admin") {
  return (
    <AuthenticationContext.Provider value={{ account: { id: accountId, role } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
}
function empty(url: URL) {
  if (url.pathname === "/api/v1/report-setting")
    return Response.json({
      data: {
        id: id(600),
        automatic_case_reports_enabled: false,
        revision: 1,
        changed_by_id: null,
        updated_at: timestamp,
      },
    });
  return Response.json({ data: [], page: { next: null } });
}
afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("Reports manages destination 51 through summary pages and reads configuration only when opened", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    reads.push(url);
    if (url.pathname === "/api/v1/providers/summaries") {
      expect(url.searchParams.get("kinds")).toBe("notification");
      expect(url.searchParams.get("limit")).toBe("50");
      return Response.json({
        data: url.searchParams.has("after")
          ? [destination(51)]
          : Array.from({ length: 50 }, (_, n) => destination(n + 1)),
        page: { next: url.searchParams.has("after") ? null : "notification-tail" },
      });
    }
    if (url.pathname === `/api/v1/providers/${id(51)}`)
      return Response.json({
        data: { ...destination(51), configuration: { url: "https://receiver.example/51" } },
      });
    return empty(url);
  });
  render(page());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
  const panel = screen
    .getByRole("heading", { name: "Notification connections" })
    .closest("section")!;
  await within(panel).findByText("Destination 1");
  expect(reads.filter((url) => url.pathname.match(/providers\/[0-9a-f-]{36}$/))).toHaveLength(0);
  await user.click(within(panel).getByRole("button", { name: "Next" }));
  await within(panel).findByText("Destination 51");
  expect(within(panel).queryByText("Destination 1")).toBeNull();
  await user.click(within(panel).getByRole("button", { name: "Details" }));
  await within(panel).findByText("https://receiver.example/51");
  expect(reads.filter((url) => url.pathname === `/api/v1/providers/${id(51)}`)).toHaveLength(1);
  await user.click(within(panel).getByRole("button", { name: "Previous" }));
  await within(panel).findByText("Destination 1");
  expect(within(panel).queryByText("https://receiver.example/51")).toBeNull();
  expect(reads.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(3);
});

test("lost destination registration remains identified across closing and reopening and is checked without resubmitting", async () => {
  await i18n.changeLanguage("en");
  let originalId = "";
  let accepted = false;
  let posts = 0;
  const receiptIds: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      const input = await request.json();
      originalId = input.provider.registration_id;
      posts++;
      const stored = sessionStorage.getItem(`skopos.notification-request:${id(700)}`)!;
      expect(JSON.parse(stored).id).toBe(originalId);
      expect(stored).not.toContain("test-only-signing-secret");
      expect(stored).not.toContain("https://receiver.example/new");
      return Response.json({ error: { message: "Acknowledgement lost" } }, { status: 503 });
    }
    if (url.pathname.startsWith("/api/v1/providers/") && !url.pathname.endsWith("summaries")) {
      receiptIds.push(url.pathname.split("/").at(-1)!);
      return accepted
        ? Response.json({
            data: {
              ...destination(51),
              id: originalId,
              name: "New destination",
              configuration: { url: "https://receiver.example/new" },
            },
          })
        : Response.json({ error: { message: "Not found" } }, { status: 404 });
    }
    return empty(url);
  });
  render(page());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
  await waitFor(() =>
    expect(
      (screen.getByRole("button", { name: "Add webhook destination" }) as HTMLButtonElement)
        .disabled,
    ).toBe(false),
  );
  await user.type(screen.getByRole("textbox", { name: "Name" }), "New destination");
  await user.type(
    screen.getByRole("textbox", { name: "HTTPS webhook URL" }),
    "https://receiver.example/new",
  );
  await user.type(screen.getByLabelText("Signing secret"), "test-only-signing-secret-1234567890");
  await user.click(screen.getByRole("button", { name: "Add webhook destination" }));
  await screen.findByText("Could not confirm the destination operation. Check the current result.");
  expect(
    (screen.getByRole("button", { name: "Add webhook destination" }) as HTMLButtonElement).disabled,
  ).toBe(true);
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  accepted = true;
  await user.click(screen.getByRole("button", { name: "Manage destinations" }));
  await user.click(await screen.findByRole("button", { name: "Check result" }));
  await screen.findByText("Destination operation confirmed: New destination");
  expect(posts).toBe(1);
  expect(receiptIds).toEqual([originalId, originalId]);
  expect(sessionStorage.getItem(`skopos.notification-request:${id(700)}`)).toBeNull();
});

test("lost connection check cannot reuse an older check and reads a newly recorded failed result without repeating the check", async () => {
  await i18n.changeLanguage("en");
  let completed = false;
  let posts = 0;
  let windows = 0;
  const current = { ...destination(51), configuration: { url: "https://receiver.example/51" } };
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    const check = completed
      ? {
          ...current.check,
          status: "failed",
          category: "unreachable",
          message: "Receiver unavailable",
          checked_at: "2026-10-05T01:02:00Z",
        }
      : current.check;
    if (request.method === "POST") {
      expect(url.pathname).toBe(`/api/v1/providers/${id(51)}/check`);
      expect(await request.json()).toEqual({ provider: { expected_revision: 1 } });
      posts++;
      return Response.json({ error: { message: "Check acknowledgement lost" } }, { status: 503 });
    }
    if (url.pathname === "/api/v1/providers/summaries")
      return Response.json({
        data: [++windows === 1 ? destination(51) : destination(1)],
        page: { next: null },
      });
    if (url.pathname === `/api/v1/providers/${id(51)}`)
      return Response.json({ data: { ...current, check } });
    return empty(url);
  });
  render(page());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
  await screen.findByText("Destination 51");
  await user.click(screen.getByRole("button", { name: "Check" }));
  await screen.findByText("Could not confirm the destination operation. Check the current result.");
  expect((screen.getByRole("button", { name: "Check" }) as HTMLButtonElement).disabled).toBe(true);
  completed = true;
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  await user.click(screen.getByRole("button", { name: "Manage destinations" }));
  await user.click(screen.getByRole("button", { name: "Check result" }));
  await screen.findByText("Receiver unavailable");
  expect(posts).toBe(1);
  expect(sessionStorage.getItem(`skopos.notification-request:${id(700)}`)).toBeNull();
});

test.each(["enable", "disable"] as const)(
  "lost %s acknowledgement retains its original revision until the requested state is read",
  async (action) => {
    await i18n.changeLanguage("en");
    let completed = false;
    let posts = 0;
    const old = { ...destination(51), enabled: action === "disable" };
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      const current = completed ? { ...old, enabled: action === "enable", revision: 2 } : old;
      if (request.method === "POST") {
        expect(url.pathname).toBe(`/api/v1/providers/${id(51)}/${action}`);
        expect(await request.json()).toEqual({ provider: { expected_revision: 1 } });
        posts++;
        return Response.json({ error: { message: "Acknowledgement lost" } }, { status: 503 });
      }
      if (url.pathname === "/api/v1/providers/summaries")
        return Response.json({ data: [current], page: { next: null } });
      if (url.pathname === `/api/v1/providers/${id(51)}`)
        return Response.json({
          data: { ...current, configuration: { url: "https://receiver.example/51" } },
        });
      return empty(url);
    });
    render(page());
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
    await screen.findByText("Destination 51");
    await user.click(
      screen.getByRole("button", { name: action === "enable" ? "Enable" : "Disable" }),
    );
    await screen.findByText(
      "Could not confirm the destination operation. Check the current result.",
    );
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    completed = true;
    await user.click(screen.getByRole("button", { name: "Manage destinations" }));
    await user.click(screen.getByRole("button", { name: "Check result" }));
    await screen.findByText("Destination operation confirmed: Destination 51");
    expect(posts).toBe(1);
    expect(sessionStorage.getItem(`skopos.notification-request:${id(700)}`)).toBeNull();
  },
);

test.each(["create", "check"])(
  "%s stops before POST when its original request cannot be saved",
  async (operation) => {
    await i18n.changeLanguage("en");
    const posts: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        posts.push(url.pathname);
        throw new Error("Unexpected dispatch");
      }
      if (url.pathname === "/api/v1/providers/summaries")
        return Response.json({ data: [destination(51)], page: { next: null } });
      if (url.pathname === `/api/v1/providers/${id(51)}`)
        return Response.json({
          data: { ...destination(51), configuration: { url: "https://receiver.example/51" } },
        });
      return empty(url);
    });
    render(page());
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
    await screen.findByText("Destination 51");
    const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
      throw new Error("Storage full");
    });
    try {
      if (operation === "create") {
        await user.type(screen.getByRole("textbox", { name: "Name" }), "Unsaved destination");
        await user.type(
          screen.getByRole("textbox", { name: "HTTPS webhook URL" }),
          "https://receiver.example/new",
        );
        await user.type(
          screen.getByLabelText("Signing secret"),
          "test-only-signing-secret-1234567890",
        );
      }
      await user.click(
        screen.getByRole("button", {
          name: operation === "create" ? "Add webhook destination" : "Check",
        }),
      );
      await screen.findByText(
        "Could not save the request. No destination operation was submitted.",
      );
      expect(posts).toEqual([]);
      expect(sessionStorage.getItem(`skopos.notification-request:${id(700)}`)).toBeNull();
    } finally {
      saving.mockRestore();
    }
  },
);

test("switching accounts aborts a destination preflight and never submits its late result", async () => {
  await i18n.changeLanguage("en");
  let flight: Request | undefined;
  let finish: ((result: Response) => void) | undefined;
  const posts: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts.push(url.pathname);
      throw new Error("Unexpected dispatch");
    }
    if (url.pathname === "/api/v1/providers/summaries")
      return Response.json({ data: [destination(51)], page: { next: null } });
    if (url.pathname === `/api/v1/providers/${id(51)}`) {
      flight = request;
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    }
    return empty(url);
  });
  const view = render(page());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
  await screen.findByText("Destination 51");
  await user.click(screen.getByRole("button", { name: "Check" }));
  await waitFor(() => expect(flight).toBeTruthy());
  view.rerender(page(id(701), "viewer"));
  expect(flight!.signal.aborted).toBe(true);
  finish!(Response.json({ data: { ...destination(51), configuration: {} } }));
  await waitFor(() => expect(screen.queryByRole("button", { name: "Check" })).toBeNull());
  expect(screen.queryByRole("button", { name: "Add webhook destination" })).toBeNull();
  expect(posts).toEqual([]);
});

test.each([409, 503])(
  "a late registration response %s after closing keeps the truthful original request state",
  async (status) => {
    await i18n.changeLanguage("en");
    let finish: ((result: Response) => void) | undefined;
    let posts = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "POST") {
        posts++;
        return new Promise<Response>((resolve) => {
          finish = resolve;
        });
      }
      return empty(new URL(request.url));
    });
    render(page());
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
    await waitFor(() =>
      expect(
        (screen.getByRole("button", { name: "Add webhook destination" }) as HTMLButtonElement)
          .disabled,
      ).toBe(false),
    );
    await user.type(screen.getByRole("textbox", { name: "Name" }), "Late destination");
    await user.type(
      screen.getByRole("textbox", { name: "HTTPS webhook URL" }),
      "https://receiver.example/late",
    );
    await user.type(screen.getByLabelText("Signing secret"), "test-only-signing-secret-1234567890");
    await user.click(screen.getByRole("button", { name: "Add webhook destination" }));
    await waitFor(() => expect(finish).toBeTruthy());
    const key = `skopos.notification-request:${id(700)}`;
    const original = sessionStorage.getItem(key);
    expect(original).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    finish!(Response.json({ error: { message: "Late response" } }, { status }));
    if (status === 409) await waitFor(() => expect(sessionStorage.getItem(key)).toBeNull());
    await user.click(screen.getByRole("button", { name: "Manage destinations" }));
    await waitFor(() =>
      expect(
        (screen.getByRole("button", { name: "Add webhook destination" }) as HTMLButtonElement)
          .disabled,
      ).toBe(status === 503),
    );
    expect(sessionStorage.getItem(key)).toBe(status === 503 ? original : null);
    expect(posts).toBe(1);
  },
);

test("failed destination page keeps the last good window, retries only that page and cancels detail on leaving", async () => {
  await i18n.changeLanguage("en");
  let failing = true;
  let detail: Request | undefined;
  let finish: ((result: Response) => void) | undefined;
  const windows: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/providers/summaries") {
      windows.push(url.searchParams.get("after") ?? "first");
      if (url.searchParams.has("after") && failing)
        return Response.json(
          { error: { message: "Destination storage unavailable" } },
          { status: 500 },
        );
      return Response.json({
        data: [destination(url.searchParams.has("after") ? 51 : 1)],
        page: { next: url.searchParams.has("after") ? null : "tail" },
      });
    }
    if (url.pathname === `/api/v1/providers/${id(51)}`) {
      detail = request;
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    }
    return empty(url);
  });
  render(page());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Manage destinations" }));
  const panel = screen.getByRole("region", { name: "Notification connections" });
  await within(panel).findByText("Destination 1");
  await user.click(within(panel).getByRole("button", { name: "Next" }));
  await within(panel).findByRole("alert");
  expect(within(panel).getByText("Destination 1")).toBeTruthy();
  expect((within(panel).getByRole("button", { name: "Check" }) as HTMLButtonElement).disabled).toBe(
    true,
  );
  failing = false;
  await user.click(within(panel).getByRole("button", { name: "Refresh" }));
  await within(panel).findByText("Destination 51");
  await user.click(within(panel).getByRole("button", { name: "Details" }));
  await waitFor(() => expect(detail).toBeTruthy());
  await user.click(within(panel).getByRole("button", { name: "Previous" }));
  await within(panel).findByText("Destination 1");
  expect(detail!.signal.aborted).toBe(true);
  finish!(
    Response.json({
      data: { ...destination(51), configuration: { url: "https://late.example/ignored" } },
    }),
  );
  expect(within(panel).queryByText("https://late.example/ignored")).toBeNull();
  expect(windows).toEqual(["first", "tail", "tail", "first"]);
});
