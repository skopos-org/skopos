import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetPage } from "@/targets/page";

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

function target(index: number) {
  return {
    id: `target-${index}`,
    name: `Host ${index}`,
    kind: "host",
    type_id: "custom-os",
    active: true,
    revision: 2,
    management_boundary_id: null,
    method_count: 101,
    relationship_count: 51,
    has_operating_instructions: true,
    methods: [],
  };
}
function show(role = "viewer") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role } } as Authentication}>
      <MemoryRouter>
        <TargetPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}
function reply(data: unknown) {
  return Response.json(data);
}

test("The Target page opens on topology with connected and isolated Targets", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    if (url.pathname === "/api/v1/target-relationships") {
      if (url.searchParams.has("target_id"))
        expect(url.searchParams.get("target_id")).toBe("target-1");
      expect(url.searchParams.get("limit")).toBe("50");
      return Promise.resolve(
        reply({
          data: [
            {
              id: "edge",
              source_target_id: "target-1",
              destination_target_id: "target-2",
              kind: "hosted_by",
              active: true,
            },
          ],
          page: { next: null },
        }),
      );
    }
    expect(url.pathname).toBe("/api/v1/targets/summaries");
    return Promise.resolve(
      reply({
        data: url.searchParams.has("ids") ? [target(1), target(2)] : [target(1), target(9)],
        page: { next: null },
      }),
    );
  });
  show();
  const topology = await screen.findByRole("region", { name: "Infrastructure topology" });
  await within(topology).findByText("Host 2");
  expect(within(topology).getByText("Host 1")).toBeTruthy();
  expect(within(topology).getByText("Host 9")).toBeTruthy();
  const inventory = screen.getByRole("region", { name: "Target list" });
  expect(
    topology.compareDocumentPosition(inventory) & Node.DOCUMENT_POSITION_FOLLOWING,
  ).toBeTruthy();
  expect(requests).toHaveLength(3);
  expect(requests.every((url) => !url.searchParams.has("after"))).toBe(true);
  expect(
    requests
      .find((url) => url.pathname === "/api/v1/target-relationships")
      ?.searchParams.has("target_id"),
  ).toBe(false);
  const user = userEvent.setup();
  const first = within(inventory).getByRole("link", { name: "Host 1" }).closest("tr")!;
  await user.click(within(first).getByRole("button", { name: "View topology" }));
  await within(screen.getByRole("region", { name: "Infrastructure topology" })).findByText(
    /Selected Target and active related Targets/,
  );
  await user.click(screen.getByRole("button", { name: "Show overview" }));
  await within(screen.getByRole("region", { name: "Infrastructure topology" })).findByText(
    "Host 9",
  );
});

test("Target inventory searches server pages with truthful counts and no global detail reads", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  sessionStorage.setItem("skopos.session", "fixture-token");
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    if (url.pathname === "/api/v1/target-relationships")
      return Promise.resolve(reply({ data: [], page: { next: null } }));
    expect(url.pathname).toBe("/api/v1/targets/summaries");
    expect(url.searchParams.get("active")).toBe("true");
    expect(url.searchParams.get("limit")).toBe("50");
    const search = url.searchParams.get("query");
    return Promise.resolve(
      reply({
        data: search
          ? [target(999)]
          : url.searchParams.has("after")
            ? [target(51)]
            : Array.from({ length: 50 }, (_, i) => target(i + 1)),
        page: { next: search || url.searchParams.has("after") ? null : "inventory-cursor" },
      }),
    );
  });
  show();
  const list = await screen.findByRole("region", { name: "Target list" });
  const user = userEvent.setup();
  await within(list).findByRole("link", { name: "Host 50" });
  const row = within(list).getByRole("link", { name: "Host 1" }).closest("tr")!;
  expect(within(row).getByText("101")).toBeTruthy();
  expect(within(row).getByText("51")).toBeTruthy();
  expect(within(row).getByText("✓")).toBeTruthy();
  await user.click(within(list).getByRole("button", { name: "Next" }));
  await within(list).findByRole("link", { name: "Host 51" });
  expect(within(list).queryByRole("link", { name: "Host 1" })).toBeNull();
  await user.click(within(list).getByRole("button", { name: "Previous" }));
  await within(list).findByRole("link", { name: "Host 50" });
  await user.type(within(list).getByRole("textbox"), "outside-first-page");
  await within(list).findByRole("link", { name: "Host 999" });
  expect(requests.at(-1)?.searchParams.get("query")).toBe("outside-first-page");
  expect(requests.at(-1)?.searchParams.has("after")).toBe(false);
});

test("Selected topology pages only its relations and resolves known peer summaries", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  let failTail = true;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    if (url.pathname === "/api/v1/target-relationships") {
      if (!url.searchParams.has("target_id"))
        return Promise.resolve(reply({ data: [], page: { next: null } }));
      expect(url.searchParams.get("target_id")).toBe("target-1");
      expect(url.searchParams.get("active")).toBe("true");
      expect(url.searchParams.get("limit")).toBe("50");
      if (url.searchParams.has("after") && failTail) {
        failTail = false;
        return Promise.reject(new Error("Next relationship page failed"));
      }
      const index = url.searchParams.has("after") ? 51 : 2;
      return Promise.resolve(
        reply({
          data: [
            {
              id: `relation-${index}`,
              source_target_id: "target-1",
              destination_target_id: `target-${index}`,
              kind: "connected_to",
              active: true,
            },
          ],
          page: { next: index === 2 ? "relation-cursor" : null },
        }),
      );
    }
    expect(url.pathname).toBe("/api/v1/targets/summaries");
    const ids = url.searchParams.get("ids");
    return Promise.resolve(
      reply({
        data: ids
          ? ids.split(",").map((id) => target(Number(id.replace("target-", ""))))
          : [target(1)],
        page: { next: null },
      }),
    );
  });
  show();
  const list = await screen.findByRole("region", { name: "Target list" });
  const user = userEvent.setup();
  await user.click(await within(list).findByRole("button", { name: "View topology" }));
  const topology = await screen.findByRole("region", { name: "Infrastructure topology" });
  await within(topology).findByText("Host 2");
  expect(within(topology).getByText(/Selected Target and active related Targets/)).toBeTruthy();
  expect(within(topology).queryByRole("button", { name: "Add relationship" })).toBeNull();
  await user.click(within(topology).getByRole("button", { name: "Next" }));
  await within(topology).findByRole("alert");
  expect(within(topology).getByText("Host 2")).toBeTruthy();
  await user.click(within(topology).getByRole("button", { name: "Refresh" }));
  await within(topology).findByText("Host 51");
  expect(within(topology).queryByText("Host 2")).toBeNull();
  expect(
    requests.filter((url) => url.searchParams.has("ids")).map((url) => url.searchParams.get("ids")),
  ).toEqual(["target-1,target-2", "target-1,target-51"]);
});

test("Changing topology Target aborts old relations before any peer lookup", async () => {
  await i18n.changeLanguage("en");
  const metadata: string[] = [];
  let oldRequest!: Request;
  let settle!: (response: Response) => void;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/target-relationships") {
      if (url.searchParams.get("target_id") === "target-1") {
        oldRequest = request;
        return new Promise<Response>((resolve) => {
          settle = resolve;
        });
      }
      return Promise.resolve(reply({ data: [], page: { next: null } }));
    }
    expect(url.pathname).toBe("/api/v1/targets/summaries");
    const ids = url.searchParams.get("ids");
    if (ids) metadata.push(ids);
    return Promise.resolve(
      reply({ data: ids ? [target(700)] : [target(1), target(700)], page: { next: null } }),
    );
  });
  show();
  const user = userEvent.setup();
  const list = screen.getByRole("region", { name: "Target list" });
  const first = (await within(list).findByRole("link", { name: "Host 1" })).closest("tr")!;
  await user.click(within(first).getByRole("button", { name: "View topology" }));
  const second = within(list).getByRole("link", { name: "Host 700" }).closest("tr")!;
  await user.click(within(second).getByRole("button", { name: "View topology" }));
  const topology = screen.getByRole("region", { name: "Infrastructure topology" });
  await within(topology).findByText("Host 700");
  expect(oldRequest.signal.aborted).toBe(true);
  await act(async () =>
    settle(
      reply({
        data: [
          {
            id: "late",
            source_target_id: "target-1",
            destination_target_id: "target-201",
            kind: "connected_to",
            active: true,
          },
        ],
        page: { next: null },
      }),
    ),
  );
  expect(metadata).toEqual(["target-700"]);
  expect(within(topology).queryByText("Host 201")).toBeNull();
});

test("An unavailable selected Target is a read error rather than an empty graph", async () => {
  await i18n.changeLanguage("en");
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    return Promise.resolve(
      reply({
        data:
          url.pathname === "/api/v1/targets/summaries" && !url.searchParams.has("ids")
            ? [target(1)]
            : [],
        page: { next: null },
      }),
    );
  });
  show();
  await userEvent.setup().click(await screen.findByRole("button", { name: "View topology" }));
  const topology = screen.getByRole("region", { name: "Infrastructure topology" });
  await within(topology).findByRole("alert");
  expect(within(topology).queryByText(/0 relationships/)).toBeNull();
  expect(within(topology).queryByText("Host 1")).toBeNull();
});

test.each(["lost response", "read failure", "navigation"])(
  "Relation %s recovers by reads without resending",
  async (failure) => {
    await i18n.changeLanguage("en");
    let stored = false;
    let failRead = false;
    let settleEffect!: (response: Response) => void;
    let reads = 0;
    const effects: unknown[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        effects.push(await request.json());
        stored = true;
        failRead = failure === "read failure";
        if (failure === "navigation")
          return new Promise<Response>((resolve) => {
            settleEffect = resolve;
          });
        if (failure === "lost response") throw new Error("Acknowledgement lost");
        return reply({ data: { id: "stored-relation" } });
      }
      if (url.pathname === "/api/v1/target-relationships") {
        reads++;
        if (failRead) {
          failRead = false;
          throw new Error("Stored relation read failed");
        }
        return reply({
          data: stored
            ? [
                {
                  id: "stored-relation",
                  source_target_id: "target-1",
                  destination_target_id: "target-900",
                  kind: "hosted_by",
                  active: true,
                },
              ]
            : [],
          page: { next: null },
        });
      }
      if (url.pathname === "/api/v1/targets/references") {
        expect(url.searchParams.get("exclude_id")).toBe("target-1");
        expect(url.searchParams.get("limit")).toBe("50");
        return reply({
          data: url.searchParams.has("after")
            ? [target(900)]
            : Array.from({ length: 50 }, (_, i) => target(i + 2)),
          page: { next: url.searchParams.has("after") ? null : "destination-cursor" },
        });
      }
      expect(url.pathname).toBe("/api/v1/targets/summaries");
      return reply({
        data: url.searchParams.has("ids")
          ? url.searchParams
              .get("ids")!
              .split(",")
              .map((id) => target(Number(id.replace("target-", ""))))
          : [{ ...target(1), relationship_count: stored ? 52 : 51 }],
        page: { next: null },
      });
    });
    const shown = show("admin");
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "View topology" }));
    const topology = await screen.findByRole("region", { name: "Infrastructure topology" });
    await within(topology).findByText("Host 1");
    await user.click(within(topology).getByRole("button", { name: "Add relationship" }));
    const destinations = within(topology).getByRole("group", { name: "Destination Target" });
    await user.click(within(destinations).getByRole("button", { name: "Next" }));
    await user.click(within(destinations).getByRole("combobox"));
    await user.click(await screen.findByRole("option", { name: "Host 900" }));
    await within(topology).findAllByText("Host 900");
    await waitFor(() =>
      expect(within(topology).getByRole("button", { name: "Save relationship" })).toHaveProperty(
        "disabled",
        false,
      ),
    );
    await user.click(within(topology).getByRole("button", { name: "Save relationship" }));
    if (failure === "navigation") {
      const before = reads;
      shown.unmount();
      await act(async () => settleEffect(reply({ data: { id: "stored-relation" } })));
      expect(reads).toBe(before);
      expect(effects).toHaveLength(1);
      return;
    }
    await within(topology).findByRole("alert");
    expect(effects).toEqual([
      {
        relationship: {
          source_target_id: "target-1",
          destination_target_id: "target-900",
          kind: "hosted_by",
          facts: {},
          valid_until: null,
        },
      },
    ]);
    expect(within(topology).queryByRole("button", { name: "Save relationship" })).toBeNull();
    await user.click(within(topology).getByRole("button", { name: "Refresh" }));
    await within(topology).findByText(/1 relationships/);
    expect(effects).toHaveLength(1);
    await within(screen.getByRole("region", { name: "Target list" })).findByText("52");
  },
);

test("Search replacement aborts an old inventory response and keeps failures visible", async () => {
  await i18n.changeLanguage("en");
  let settle!: (response: Response) => void;
  let oldRequest!: Request;
  let fail = true;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/target-relationships")
      return Promise.resolve(reply({ data: [], page: { next: null } }));
    if (!url.searchParams.get("query")) {
      oldRequest = request;
      return new Promise<Response>((resolve) => {
        settle = resolve;
      });
    }
    if (fail) {
      fail = false;
      return Promise.reject(new Error("Search read failed"));
    }
    return Promise.resolve(reply({ data: [target(999)], page: { next: null } }));
  });
  const shown = show();
  const user = userEvent.setup();
  const list = screen.getByRole("region", { name: "Target list" });
  await user.type(within(list).getByRole("textbox"), "z");
  await within(list).findByRole("alert");
  expect(oldRequest.signal.aborted).toBe(true);
  await user.click(within(list).getByRole("button", { name: "Refresh" }));
  await within(list).findByRole("link", { name: "Host 999" });
  await act(async () => settle(reply({ data: [target(1)], page: { next: null } })));
  expect(within(list).queryByRole("link", { name: "Host 1" })).toBeNull();
  shown.unmount();
});
