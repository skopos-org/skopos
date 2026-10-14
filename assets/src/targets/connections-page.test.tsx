import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import type { components } from "@/api/schema";
import i18n from "@/i18n/config";
import { TargetConnectionsPage } from "@/targets/connections-page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});
function provider(
  index: number,
  kind: "target" | "inventory" = "target",
  enabled = false,
): components["schemas"]["ProviderSummary"] {
  return {
    id: `provider-${index}`,
    name: `Connection ${index}`,
    kind,
    adapter_type: kind === "target" ? "http-api" : "netbox",
    enabled,
    revision: 3,
    check: {
      status: null,
      category: null,
      message: null,
      checked_revision: null,
      checked_at: null,
    },
  };
}
function show(role = "viewer") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role } } as Authentication}>
      <MemoryRouter initialEntries={["/targets/connections"]}>
        <TargetConnectionsPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}
function page(data: unknown[], next: string | null = null) {
  return Response.json({ data, page: { next } });
}

test("Connections retain only the requested metadata page and can reach tail connections", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    if (url.pathname !== "/api/v1/providers/summaries")
      return Promise.resolve(Response.json({}, { status: 404 }));
    return Promise.resolve(
      url.searchParams.has("after")
        ? page([provider(51)])
        : page(
            Array.from({ length: 50 }, (_, index) => provider(index + 1)),
            "next-connections",
          ),
    );
  });
  show();
  await screen.findByText("Connection 50");
  expect(requests).toHaveLength(1);
  expect(requests[0].pathname).toBe("/api/v1/providers/summaries");
  expect(requests[0].searchParams.get("kinds")).toBe("target,inventory");
  expect(requests[0].searchParams.get("limit")).toBe("50");
  expect(screen.queryByRole("button", { name: "Enable" })).toBeNull();
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("Connection 51");
  expect(screen.queryByText("Connection 1")).toBeNull();
  expect(requests[1].searchParams.get("after")).toBe("next-connections");
  await user.click(screen.getByRole("button", { name: "Previous" }));
  await screen.findByText("Connection 50");
  expect(screen.queryByText("Connection 51")).toBeNull();
});

test("Connections show initial read failures and retry the failed next page without hiding the last page", async () => {
  await i18n.changeLanguage("en");
  let fail = true;
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    if (fail)
      return Promise.resolve(Response.json({ error: { code: "internal_error" } }, { status: 500 }));
    return Promise.resolve(
      url.searchParams.has("after")
        ? page([provider(51)])
        : page([provider(1)], "next-connections"),
    );
  });
  show();
  await screen.findByText(i18n.t("targets.requestFailed"));
  expect(screen.queryByText(i18n.t("common.loading"))).toBeNull();
  const user = userEvent.setup();
  fail = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Connection 1");
  fail = true;
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText(i18n.t("targets.requestFailed"));
  expect(screen.getByText("Connection 1")).toBeTruthy();
  fail = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Connection 51");
  expect(requests.at(-1)?.searchParams.get("after")).toBe("next-connections");
});

test("Connection check lost acknowledgements and refresh failures never replay remote mutations", async () => {
  await i18n.changeLanguage("en");
  let stored = provider(1, "inventory");
  let failRead = false;
  const posted: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "GET") {
      expect(url.pathname).toBe("/api/v1/providers/summaries");
      if (failRead) return Response.json({ error: { code: "internal_error" } }, { status: 500 });
      return page([stored]);
    }
    expect(request.method).toBe("POST");
    expect(await request.json()).toMatchObject({ provider: { expected_revision: 3 } });
    posted.push(url.pathname);
    if (url.pathname.endsWith("/check")) {
      stored = { ...stored, check: { ...stored.check, status: "passed", checked_revision: 3 } };
      throw new Error("lost acknowledgement");
    }
    stored = { ...stored, enabled: url.pathname.endsWith("/enable") };
    failRead = stored.enabled;
    return Response.json({ data: stored });
  });
  show("admin");
  await screen.findByText("Connection 1");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Check" }));
  await screen.findByRole("alert");
  expect(posted).toEqual(["/api/v1/providers/provider-1/check"]);
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("The current configuration passed its connection check.");
  expect(posted).toHaveLength(1);
  await user.click(screen.getByRole("button", { name: "Enable" }));
  await screen.findByRole("alert");
  expect(posted).toEqual([
    "/api/v1/providers/provider-1/check",
    "/api/v1/providers/provider-1/enable",
  ]);
  expect((screen.getByRole("button", { name: "Enable" }) as HTMLButtonElement).disabled).toBe(true);
  failRead = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByRole("button", { name: "Disable" });
  expect(posted).toHaveLength(2);
  await user.click(screen.getByRole("button", { name: "Disable" }));
  await screen.findByRole("button", { name: "Enable" });
  expect(posted).toEqual([
    "/api/v1/providers/provider-1/check",
    "/api/v1/providers/provider-1/enable",
    "/api/v1/providers/provider-1/disable",
  ]);
});

test("Leaving Connections aborts its read and a late reply cannot load another page", async () => {
  await i18n.changeLanguage("en");
  let request: Request;
  let finish!: (response: Response) => void;
  wire.mockImplementation((next: Request) => {
    request = next;
    return new Promise<Response>((resolve) => {
      finish = resolve;
    });
  });
  const view = show();
  await waitFor(() => expect(wire).toHaveBeenCalledTimes(1));
  view.unmount();
  expect(request!.signal.aborted).toBe(true);
  await act(async () => {
    finish(page([provider(1)], "late-cursor"));
  });
  expect(wire).toHaveBeenCalledTimes(1);
});

test("Leaving Connections while a mutation is pending suppresses late follow-up reads", async () => {
  await i18n.changeLanguage("en");
  let finish!: (response: Response) => void;
  const requests: Request[] = [];
  wire.mockImplementation((request: Request) => {
    requests.push(request);
    if (request.method === "GET") return Promise.resolve(page([provider(1)]));
    return new Promise<Response>((resolve) => {
      finish = resolve;
    });
  });
  const view = show("admin");
  await screen.findByText("Connection 1");
  await userEvent.setup().click(screen.getByRole("button", { name: "Enable" }));
  await waitFor(() => expect(requests).toHaveLength(2));
  view.unmount();
  await act(async () => {
    finish(Response.json({ data: provider(1, "target", true) }));
  });
  expect(requests.map((request) => request.method)).toEqual(["GET", "POST"]);
});

test("Connections display outdated checks honestly and operator accounts remain read only", async () => {
  await i18n.changeLanguage("en");
  const outdated = {
    ...provider(1, "inventory"),
    check: { ...provider(1).check, status: "passed", checked_revision: 2, message: "Old check" },
  };
  wire.mockResolvedValue(page([outdated]));
  show("admin");
  await screen.findByText("Check the current configuration before enabling it.");
  expect((screen.getByRole("button", { name: "Enable" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByRole("button", { name: "Add Target connection" }).getAttribute("href")).toBe(
    "/targets/connections/new",
  );
  cleanup();
  wire.mockResolvedValue(page([outdated]));
  show("operator");
  await screen.findByText("Connection 1");
  expect(screen.queryByRole("button", { name: "Check" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Enable" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Add Target connection" })).toBeNull();
});
