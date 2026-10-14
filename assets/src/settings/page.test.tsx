import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import type { components } from "@/api/schema";
import i18n from "@/i18n/config";
import { SetupPage } from "@/settings/page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
afterEach(() => {
  cleanup();
  wire.mockReset();
});
function account(index: number): components["schemas"]["Account"] {
  return {
    id: `account-${index}`,
    email: `account${index}@example.com`,
    role: index === 1 ? "admin" : "operator",
    role_version: 1,
    preferred_language: "en",
    inserted_at: "2026-10-04T00:00:00Z",
    updated_at: "2026-10-04T00:00:00Z",
  };
}
function page(data: unknown[], next: string | null = null) {
  return Response.json({ data, page: { next } });
}
function oidc() {
  return Response.json({
    data: { enabled: false, callback_uri: "https://skopos.example/callback" },
  });
}
function show(role = "admin") {
  return render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role }, oidcEnabled: false } as Authentication}
    >
      <MemoryRouter initialEntries={["/settings"]}>
        <SetupPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("Settings account administration retains one page and reaches accounts beyond the first fifty", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/oidc/provider") return Promise.resolve(oidc());
    requests.push(url);
    return Promise.resolve(
      url.searchParams.has("after")
        ? page([account(51)])
        : page(
            Array.from({ length: 50 }, (_, i) => account(i + 1)),
            "account-cursor",
          ),
    );
  });
  show();
  await screen.findByText("account50@example.com");
  expect(screen.queryByText("account51@example.com")).toBeNull();
  expect(requests).toHaveLength(1);
  expect(requests[0].searchParams.get("limit")).toBe("50");
  expect(screen.queryByRole("combobox", { name: "account1@example.com: Role" })).toBeNull();
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("account51@example.com");
  expect(screen.queryByText("account50@example.com")).toBeNull();
  expect(requests).toHaveLength(2);
  expect(requests[1].searchParams.get("after")).toBe("account-cursor");
  await user.click(screen.getByRole("button", { name: "Previous" }));
  await screen.findByText("account50@example.com");
  expect(screen.queryByText("account51@example.com")).toBeNull();
  await waitFor(() => expect(requests).toHaveLength(3));
});

test("An account creation HTTP error keeps the form and never reports success", async () => {
  await i18n.changeLanguage("en");
  const requests: Request[] = [];
  wire.mockImplementation((request: Request) => {
    if (new URL(request.url).pathname === "/api/v1/oidc/provider") return Promise.resolve(oidc());
    requests.push(request);
    return Promise.resolve(
      request.method === "POST"
        ? Response.json({ error: { code: "validation_failed" } }, { status: 422 })
        : page([account(1)]),
    );
  });
  show();
  await screen.findByText("account1@example.com");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.createTitle") }));
  await user.type(
    screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") }),
    "new@example.com",
  );
  await user.type(screen.getByLabelText(i18n.t("setup.accounts.password")), "fixture password");
  await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.create") }));
  await screen.findByText(i18n.t("setup.accounts.requestFailed"));
  expect(screen.queryByText(i18n.t("setup.accounts.created"))).toBeNull();
  expect(screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") })).toHaveProperty(
    "value",
    "new@example.com",
  );
  expect(requests.filter((r) => r.method === "POST")).toHaveLength(1);
  expect(requests.filter((r) => r.method === "GET")).toHaveLength(1);
});

test("Failed next-page reads retry their cursor and a lost role acknowledgement is recovered without resending", async () => {
  await i18n.changeLanguage("en");
  let failNext = true;
  let stored = account(51);
  const reads: URL[] = [];
  const patches: unknown[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/oidc/provider") return oidc();
    if (request.method === "PATCH") {
      expect(url.pathname).toBe("/api/v1/accounts/account-51/role");
      patches.push(await request.json());
      stored = { ...stored, role: "viewer", role_version: 2 };
      throw new Error("lost role acknowledgement");
    }
    reads.push(url);
    if (!url.searchParams.has("after")) return page([account(1)], "account-cursor");
    expect(url.searchParams.get("after")).toBe("account-cursor");
    return failNext
      ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
      : page([stored]);
  });
  show();
  await screen.findByText("account1@example.com");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText(i18n.t("setup.accounts.loadFailed"));
  expect(screen.getByText("account1@example.com")).toBeTruthy();
  failNext = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  const form = (await screen.findByText("account51@example.com")).closest("form")!;
  await user.click(within(form).getByRole("combobox"));
  await user.click(
    await screen.findByRole("option", { name: i18n.t("setup.accounts.roles.viewer") }),
  );
  await user.click(within(form).getByRole("button", { name: i18n.t("setup.accounts.saveRole") }));
  await screen.findByText(i18n.t("setup.accounts.requestFailed"));
  expect(patches).toEqual([{ account: { role: "viewer" } }]);
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => {
    const current = screen.getByText("account51@example.com").closest("form")!;
    expect(
      within(current).getByRole("button", { name: i18n.t("setup.accounts.saveRole") }),
    ).toHaveProperty("disabled", true);
    expect(within(current).getByRole("combobox").textContent).toContain(
      i18n.t("setup.accounts.roles.viewer"),
    );
  });
  expect(patches).toHaveLength(1);
  expect(reads.slice(1).every((url) => url.searchParams.get("after") === "account-cursor")).toBe(
    true,
  );
});

test.each(["lost acknowledgement", "accepted then read failure"])(
  "Account creation %s is recovered by reads without replaying the creation",
  async (failure) => {
    await i18n.changeLanguage("en");
    let stored = [account(1)];
    let failRead = false;
    const posts: unknown[] = [];
    wire.mockImplementation(async (request: Request) => {
      if (new URL(request.url).pathname === "/api/v1/oidc/provider") return oidc();
      if (request.method === "POST") {
        posts.push(await request.json());
        const created = { ...account(2), email: "new@example.com" };
        stored = [account(1), created];
        if (failure === "lost acknowledgement") throw new Error("lost creation acknowledgement");
        failRead = true;
        return Response.json({ data: created }, { status: 201 });
      }
      return failRead
        ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
        : page(stored);
    });
    show();
    await screen.findByText("account1@example.com");
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.createTitle") }));
    await user.type(
      screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") }),
      "new@example.com",
    );
    await user.type(screen.getByLabelText(i18n.t("setup.accounts.password")), "fixture password");
    await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.create") }));
    await screen.findByText(
      i18n.t(
        failure === "accepted then read failure"
          ? "setup.accounts.loadFailed"
          : "setup.accounts.requestFailed",
      ),
    );
    if (failure === "accepted then read failure") {
      expect(screen.queryByLabelText(i18n.t("setup.accounts.password"))).toBeNull();
      expect(screen.getByText(i18n.t("setup.accounts.created"))).toBeTruthy();
    } else {
      expect(screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") })).toHaveProperty(
        "value",
        "new@example.com",
      );
      expect(screen.queryByText(i18n.t("setup.accounts.created"))).toBeNull();
    }
    failRead = false;
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await screen.findByText("new@example.com");
    expect(posts).toEqual([
      { account: { email: "new@example.com", password: "fixture password", role: "operator" } },
    ]);
  },
);

test("Initial account read failure is retryable and late creation after leaving Settings starts no reads", async () => {
  await i18n.changeLanguage("en");
  let failRead = true;
  let finish!: (value: Response) => void;
  const requests: Request[] = [];
  wire.mockImplementation((request: Request) => {
    if (new URL(request.url).pathname === "/api/v1/oidc/provider") return Promise.resolve(oidc());
    requests.push(request);
    if (request.method === "POST")
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    return Promise.resolve(
      failRead
        ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
        : page([account(1)]),
    );
  });
  const view = show();
  await screen.findByText(i18n.t("setup.accounts.loadFailed"));
  expect(screen.queryByText("account1@example.com")).toBeNull();
  const user = userEvent.setup();
  failRead = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("account1@example.com");
  await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.createTitle") }));
  await user.type(
    screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") }),
    "new@example.com",
  );
  await user.type(screen.getByLabelText(i18n.t("setup.accounts.password")), "fixture password");
  await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.create") }));
  await waitFor(() => expect(requests.at(-1)?.method).toBe("POST"));
  expect(screen.getByRole("button", { name: "Refresh" })).toHaveProperty("disabled", true);
  expect(screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") })).toHaveProperty(
    "disabled",
    true,
  );
  const before = requests.length;
  view.unmount();
  await act(async () => finish(Response.json({ data: account(2) }, { status: 201 })));
  expect(requests).toHaveLength(before);
});

test.each(["operator", "viewer"])(
  "%s cannot enter account administration from Settings",
  async (role) => {
    await i18n.changeLanguage("en");
    show(role);
    expect(screen.queryByRole("button", { name: i18n.t("setup.accounts.createTitle") })).toBeNull();
    expect(screen.getByText(i18n.t("setup.readOnly"))).toBeTruthy();
    expect(wire).not.toHaveBeenCalled();
  },
);

test("A superseded account read cannot clear a newer role draft or replace the current page", async () => {
  await i18n.changeLanguage("en");
  let reads = 0;
  let finish!: (value: Response) => void;
  let old!: Request;
  wire.mockImplementation((request: Request) => {
    if (new URL(request.url).pathname === "/api/v1/oidc/provider") return Promise.resolve(oidc());
    if (request.method === "POST")
      return Promise.resolve(Response.json({ data: account(3) }, { status: 201 }));
    reads += 1;
    if (reads === 2) {
      old = request;
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    }
    return Promise.resolve(
      page(reads === 1 ? [account(1), account(2)] : [account(1), account(2), account(3)]),
    );
  });
  show();
  await screen.findByText("account2@example.com");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.createTitle") }));
  await user.type(
    screen.getByRole("textbox", { name: i18n.t("setup.accounts.email") }),
    "new@example.com",
  );
  await user.type(screen.getByLabelText(i18n.t("setup.accounts.password")), "fixture password");
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(reads).toBe(2));
  await user.click(screen.getByRole("button", { name: i18n.t("setup.accounts.create") }));
  await screen.findByText("account3@example.com");
  expect(old.signal.aborted).toBe(true);
  const form = screen.getByText("account2@example.com").closest("form")!;
  await user.click(within(form).getByRole("combobox"));
  await user.click(
    await screen.findByRole("option", { name: i18n.t("setup.accounts.roles.viewer") }),
  );
  await act(async () => finish(page([account(1), account(2)])));
  expect(screen.getByText("account3@example.com")).toBeTruthy();
  expect(within(form).getByRole("combobox").textContent).toContain(
    i18n.t("setup.accounts.roles.viewer"),
  );
  expect(
    within(form).getByRole("button", { name: i18n.t("setup.accounts.saveRole") }),
  ).toHaveProperty("disabled", false);
  expect(reads).toBe(3);
});
