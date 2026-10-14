import { render, screen, waitFor, cleanup, within, act } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetFileSection } from "@/targets/file-section";
import { CaseCreatePage } from "@/cases/create-page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

function listedFile(index: number) {
  return {
    id: `file-${index}`,
    target_id: "target-1",
    name: `File ${index}`,
    media_type: "application/octet-stream",
    status: "ready",
    size_bytes: 5,
    received_bytes: 5,
    sha256: digest,
    expected_sha256: digest,
    expires_at: "2099-01-01T00:00:00Z",
    revision: 1,
    request_id: null,
    completion_reason: "upload",
    inserted_at: "2026-10-04T00:00:00Z",
    updated_at: "2026-10-04T00:00:00Z",
  };
}
function showFiles(role = "viewer") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

function showCase(fileId = "") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter initialEntries={[`/cases/new?target=target-1&file=${fileId}`]}>
        <Routes>
          <Route path="/cases/new" element={<CaseCreatePage />} />
          <Route path="/cases/:id" element={<p>Case created</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("Case attachment keeps the linked file outside the current metadata page", async () => {
  await i18n.changeLanguage("en");
  const pages: URL[] = [];
  let submitted: Record<string, unknown> | undefined;
  let knownReads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/targets/summaries")
      return Response.json({
        data: [{ id: "target-1", name: "Device", active: true }],
        page: { next: null },
      });
    if (url.pathname.endsWith("/files")) {
      pages.push(url);
      return Response.json({
        data: [listedFile(1)],
        page: { next: url.searchParams.has("after") ? null : "file-cursor" },
      });
    }
    if (url.pathname.endsWith("/files/file-999")) {
      knownReads += 1;
      return Response.json({ data: listedFile(999) });
    }
    if (url.pathname === "/api/v1/cases" && request.method === "POST") {
      submitted = (await request.json()).case;
      return Response.json({ data: { id: "case-1" } });
    }
    throw Error("Unexpected request");
  });
  showCase("file-999");
  const choice = await screen.findByRole("combobox", { name: i18n.t("files.select") });
  await waitFor(() => expect(choice.textContent).toContain("File 999"));
  expect(pages).toHaveLength(1);
  expect(pages[0].searchParams.get("limit")).toBe("50");
  const user = userEvent.setup();
  await user.type(screen.getByLabelText("Title"), "Use linked file");
  await user.type(screen.getByLabelText("Desired outcome"), "Apply the supplied payload");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(knownReads).toBeGreaterThanOrEqual(2);
  expect(submitted?.initial_context).toEqual({
    desired_outcome: "Apply the supplied payload",
    files: {
      attachment: {
        id: "file-999",
        target_id: "target-1",
        name: "File 999",
        media_type: "application/octet-stream",
        size_bytes: 5,
        sha256: digest,
      },
    },
  });
});

test("Case attachment reaches a ready file after an incomplete page and retains it when paging back", async () => {
  await i18n.changeLanguage("en");
  let rejected = false;
  const writes: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method !== "GET") writes.push(request.method);
    if (url.pathname === "/api/v1/targets/summaries")
      return Response.json({
        data: [{ id: "target-1", name: "Device", active: true }],
        page: { next: null },
      });
    if (url.pathname.endsWith("/files"))
      return Response.json({
        data: url.searchParams.has("after")
          ? [listedFile(51)]
          : [{ ...listedFile(1), status: "uploading", sha256: null }],
        page: { next: url.searchParams.has("after") ? null : "file-cursor" },
      });
    if (url.pathname.endsWith("/files/file-51"))
      return Response.json({ data: { ...listedFile(51), status: rejected ? "revoked" : "ready" } });
    throw Error("Unexpected request");
  });
  showCase();
  const user = userEvent.setup();
  const group = await screen.findByRole("group", { name: i18n.t("files.select") });
  await waitFor(() =>
    expect(within(group).getByRole("button", { name: "Next" }).hasAttribute("disabled")).toBe(
      false,
    ),
  );
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "File 51" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(
      false,
    ),
  );
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() => expect(within(group).getByRole("combobox").textContent).toContain("File 51"));
  await user.type(screen.getByLabelText("Title"), "Use tail file");
  await user.type(screen.getByLabelText("Desired outcome"), "Apply payload");
  rejected = true;
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findAllByText(i18n.t("files.unavailable"));
  expect(writes).toEqual([]);
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "No file" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(
      false,
    ),
  );
});

test("Case attachment read failure requires a read-only refresh and expired files cannot be submitted", async () => {
  await i18n.changeLanguage("en");
  let outcome = "failed";
  const writes: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (request.method !== "GET") writes.push(request.method);
    if (path === "/api/v1/targets/summaries")
      return Response.json({
        data: [{ id: "target-1", name: "Device", active: true }],
        page: { next: null },
      });
    if (path.endsWith("/files"))
      return Response.json({ data: [listedFile(1)], page: { next: null } });
    if (path.endsWith("/files/file-999"))
      return outcome === "failed"
        ? Response.json({ error: { code: "failed" } }, { status: 503 })
        : Response.json({
            data: {
              ...listedFile(999),
              expires_at: outcome === "expired" ? "2000-01-01T00:00:00Z" : "2099-01-01T00:00:00Z",
            },
          });
    throw Error("Unexpected request");
  });
  showCase("file-999");
  const group = await screen.findByRole("group", { name: i18n.t("files.select") });
  await within(group).findByRole("alert");
  expect(screen.queryByText(i18n.t("files.unavailable"))).toBeNull();
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
  const user = userEvent.setup();
  outcome = "expired";
  await user.click(within(group).getByRole("button", { name: "Refresh" }));
  await screen.findByText(i18n.t("files.unavailable"));
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
  outcome = "ready";
  await user.click(within(group).getByRole("button", { name: "Refresh" }));
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(
      false,
    ),
  );
  expect(writes).toEqual([]);
});

test("Case attachment expires according to its exact metadata even when its page contains an older expiry", async () => {
  await i18n.changeLanguage("en");
  wire.mockImplementation((request: Request) => {
    const path = new URL(request.url).pathname;
    if (path === "/api/v1/targets/summaries")
      return Promise.resolve(
        Response.json({
          data: [{ id: "target-1", name: "Device", active: true }],
          page: { next: null },
        }),
      );
    if (path.endsWith("/files"))
      return Promise.resolve(Response.json({ data: [listedFile(999)], page: { next: null } }));
    return Promise.resolve(
      Response.json({
        data: { ...listedFile(999), expires_at: new Date(Date.now() + 500).toISOString() },
      }),
    );
  });
  showCase("file-999");
  await screen.findByText("File 999");
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(false);
  await screen.findByText(i18n.t("files.unavailable"));
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
});

test("Lost file removal acknowledgement recovers the known file by GET without repeating DELETE", async () => {
  await i18n.changeLanguage("en");
  let removed = false;
  let readFailed = true;
  const writes: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (request.method === "DELETE") {
      writes.push(request.method);
      removed = true;
      throw Error("lost removal acknowledgement");
    }
    if (path.endsWith("/files"))
      return Response.json({ data: [listedFile(removed ? 51 : 1)], page: { next: null } });
    expect(path).toBe("/api/v1/targets/target-1/files/file-1");
    return readFailed
      ? Response.json({ error: { code: "failed" } }, { status: 503 })
      : Response.json({ data: { ...listedFile(1), status: "revoked" } });
  });
  showFiles("operator");
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Remove" }));
  await screen.findByText("File 51");
  await waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  const known = screen.getByText("File 1").closest("div.space-y-2")!;
  expect(within(known as HTMLElement).queryByRole("button", { name: "Use in Case" })).toBeNull();
  expect(
    within(known as HTMLElement)
      .getByRole("button", { name: "Remove" })
      .hasAttribute("disabled"),
  ).toBe(true);
  readFailed = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Removed");
  expect(writes).toEqual(["DELETE"]);
});

test("Leaving the file page releases a pending removal without issuing follow-up metadata reads", async () => {
  await i18n.changeLanguage("en");
  let finish: (value: Response) => void = () => {};
  const requests: string[] = [];
  wire.mockImplementation((request: Request) => {
    requests.push(request.method);
    if (request.method === "DELETE")
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    return Promise.resolve(Response.json({ data: [listedFile(1)], page: { next: null } }));
  });
  const view = showFiles("operator");
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Remove" }));
  view.unmount();
  await act(async () => {
    finish(Response.json({ data: { ...listedFile(1), status: "revoked" } }));
  });
  expect(requests).toEqual(["GET", "DELETE"]);
});

test("Changing the Case Target releases the old selected file and ignores its late reply", async () => {
  await i18n.changeLanguage("en");
  let finish: (value: Response) => void = () => {};
  let oldRequest: Request | undefined;
  let submitted: Record<string, unknown> | undefined;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (path === "/api/v1/targets/summaries")
      return Response.json({
        data: [
          { id: "target-1", name: "Device 1", active: true },
          { id: "target-2", name: "Device 2", active: true },
        ].filter(
          (target) =>
            !new URL(request.url).searchParams.has("ids") ||
            target.id === new URL(request.url).searchParams.get("ids"),
        ),
        page: { next: null },
      });
    if (path.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    if (path.endsWith("/files/file-999")) {
      oldRequest = request;
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    }
    if (path === "/api/v1/cases") {
      submitted = (await request.json()).case;
      return Response.json({ data: { id: "case-2" } });
    }
    throw Error("Unexpected request");
  });
  showCase("file-999");
  await waitFor(() => expect(oldRequest).toBeDefined());
  const user = userEvent.setup();
  await user.click(screen.getByRole("combobox", { name: i18n.t("cases.initialTarget") }));
  await user.click(await screen.findByRole("option", { name: "Device 2" }));
  expect(oldRequest!.signal.aborted).toBe(true);
  await act(async () => {
    finish(Response.json({ data: listedFile(999) }));
  });
  expect(screen.getByRole("combobox", { name: i18n.t("files.select") }).textContent).toContain(
    "No file",
  );
  expect(screen.queryByText("File 999")).toBeNull();
  await user.type(screen.getByLabelText("Title"), "Investigate second device");
  await user.type(screen.getByLabelText("Desired outcome"), "Restore service");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(submitted?.initial_target_id).toBe("target-2");
  expect(submitted?.initial_context).toEqual({ desired_outcome: "Restore service" });
});

test("Leaving Case creation during attachment recheck prevents a later Case submission", async () => {
  await i18n.changeLanguage("en");
  let reads = 0;
  let held: Request | undefined;
  let finish: (value: Response) => void = () => {};
  const writes: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url).pathname;
    if (request.method !== "GET") writes.push(request.method);
    if (path === "/api/v1/targets/summaries")
      return Response.json({
        data: [{ id: "target-1", name: "Device", active: true }],
        page: { next: null },
      });
    if (path.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    if (path.endsWith("/files/file-999")) {
      reads += 1;
      if (reads === 1) return Response.json({ data: listedFile(999) });
      held = request;
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    }
    throw Error("Unexpected request");
  });
  const view = showCase("file-999");
  await screen.findByText("File 999");
  const user = userEvent.setup();
  await user.type(screen.getByLabelText("Title"), "Use file");
  await user.type(screen.getByLabelText("Desired outcome"), "Apply payload");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await waitFor(() => expect(held).toBeDefined());
  view.unmount();
  expect(held!.signal.aborted).toBe(true);
  await act(async () => {
    finish(Response.json({ data: listedFile(999) }));
  });
  expect(writes).toEqual([]);
});

test("Target files retain one metadata page and reach files beyond the first fifty", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    return Promise.resolve(
      Response.json({
        data: url.searchParams.has("after")
          ? [listedFile(51)]
          : Array.from({ length: 50 }, (_, i) => listedFile(i + 1)),
        page: { next: url.searchParams.has("after") ? null : "file-cursor" },
      }),
    );
  });
  showFiles();
  await screen.findByText("File 50");
  expect(screen.queryByText("File 51")).toBeNull();
  expect(requests).toHaveLength(1);
  expect(requests[0].searchParams.get("limit")).toBe("50");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("File 51");
  expect(screen.queryByText("File 50")).toBeNull();
  expect(requests[1].pathname).toBe("/api/v1/targets/target-1/files");
  expect(requests[1].searchParams.get("after")).toBe("file-cursor");
  await user.click(screen.getByRole("button", { name: "Previous" }));
  await screen.findByText("File 50");
  expect(screen.queryByText("File 51")).toBeNull();
});

test("A lost upload chunk reply refreshes the known file outside the visible page and resumes only remaining bytes", async () => {
  await i18n.changeLanguage("en");
  let stored: Record<string, unknown> | null = null;
  const offsets: number[] = [];
  const bytes: number[] = [];
  let knownReads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname.endsWith("target-file-limits"))
      return Response.json({ data: { chunk_bytes: 3, max_size_bytes: 10 } });
    if (url.pathname.endsWith("/files") && request.method === "GET")
      return Response.json({
        data: Array.from({ length: 50 }, (_, i) => listedFile(i + 1)),
        page: { next: "file-cursor" },
      });
    if (url.pathname.endsWith("/files") && request.method === "POST") {
      stored = {
        ...(await request.json()).file,
        id: "file-999",
        target_id: "target-1",
        status: "uploading",
        received_bytes: 0,
        sha256: null,
        expires_at: "2099-01-01T00:00:00Z",
        revision: 1,
      };
      return Response.json({ data: stored }, { status: 201 });
    }
    if (request.method === "PUT") {
      offsets.push(Number(url.pathname.split("/").at(-1)));
      bytes.push(...new Uint8Array(await request.arrayBuffer()));
      stored = { ...stored, received_bytes: bytes.length };
      if (offsets.length === 1) throw new Error("lost chunk acknowledgement");
      return Response.json({ data: stored });
    }
    if (url.pathname.endsWith("/complete")) {
      stored = { ...stored, status: "ready", sha256: digest };
      return Response.json({ data: stored });
    }
    expect(url.pathname).toBe("/api/v1/targets/target-1/files/file-999");
    knownReads += 1;
    return Response.json({ data: stored });
  });
  showFiles("operator");
  await screen.findByText("File 50");
  const input = new File([new Uint8Array([255, 0, 1, 2, 255])], "payload.bin", {
    type: "application/octet-stream",
  });
  const user = userEvent.setup();
  await user.upload(screen.getByLabelText("Add file"), input);
  await screen.findByText("3 / 5 B · application/octet-stream");
  expect(offsets).toEqual([0]);
  expect(knownReads).toBeGreaterThan(0);
  await user.click(screen.getByRole("button", { name: "Resume upload" }));
  await user.upload(screen.getByLabelText("Add file"), input);
  await waitFor(() =>
    expect(
      screen
        .getAllByRole("button", { name: "Use in Case" })
        .some((link) => link.getAttribute("href")?.endsWith("file=file-999")),
    ).toBe(true),
  );
  expect(offsets).toEqual([0, 3]);
  expect(bytes).toEqual([255, 0, 1, 2, 255]);
});

test("Case creation refetches a selected ready file and submits its exact reference without bytes", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const reference = {
    id: "file-1",
    target_id: "target-1",
    name: "payload.bin",
    media_type: "application/octet-stream",
    size_bytes: 5,
    sha256: digest,
  };
  let submitted: Record<string, unknown> | undefined;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url, "http://localhost").pathname;
    if (path === "/api/v1/targets/summaries")
      return new Response(
        JSON.stringify({
          data: [{ id: "target-1", name: "device", active: true }],
          page: { next: null },
        }),
      );
    if (path.endsWith("/files"))
      return new Response(
        JSON.stringify({
          data: [{ ...reference, status: "ready", expires_at: "2099-01-01T00:00:00Z" }],
          page: { next: null },
        }),
      );
    if (path.endsWith("/files/file-1"))
      return new Response(
        JSON.stringify({
          data: { ...reference, status: "ready", expires_at: "2099-01-01T00:00:00Z" },
        }),
      );
    if (path === "/api/v1/cases" && request.method === "POST") {
      submitted = (await request.json()).case;
      return new Response(JSON.stringify({ data: { id: "case-1" } }));
    }
    throw Error("Unexpected Case API request");
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter initialEntries={["/cases/new?target=target-1&file=file-1"]}>
        <Routes>
          <Route path="/cases/new" element={<CaseCreatePage />} />
          <Route path="/cases/:id" element={<p>Case created</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await screen.findByText("payload.bin");
  await user.type(screen.getByLabelText("Title"), "Apply supplied file");
  await user.type(
    screen.getByLabelText("Desired outcome"),
    "Use the supplied payload to configure the device",
  );
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(submitted?.initial_target_id).toBe("target-1");
  expect(submitted?.initial_context).toEqual({
    desired_outcome: "Use the supplied payload to configure the device",
    files: { attachment: reference },
  });
});
const digest = "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd";
afterEach(() => {
  cleanup();
  wire.mockReset();
  vi.restoreAllMocks();
  sessionStorage.clear();
});

test("download requests authenticated binary chunks and refuses corrupt bytes before saving", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const file = {
    id: "file-1",
    target_id: "target-1",
    name: "payload.bin",
    media_type: "application/octet-stream",
    size_bytes: 5,
    received_bytes: 5,
    status: "ready",
    sha256: digest,
    expires_at: "2099-01-01T00:00:00Z",
  };
  let corrupt = false;
  let saved: Blob | undefined;
  const create = vi.spyOn(URL, "createObjectURL").mockImplementation((blob) => {
    saved = blob as Blob;
    return "blob:fixture";
  });
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  wire.mockImplementation(async (request: Request) => {
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const path = new URL(request.url, "http://localhost").pathname;
    if (path.endsWith("target-file-limits"))
      return new Response(JSON.stringify({ data: { chunk_bytes: 3, max_size_bytes: 10 } }));
    if (path.endsWith("/files"))
      return new Response(JSON.stringify({ data: [file], page: { next: null } }));
    if (path.includes("/chunks/")) {
      expect(request.headers.get("Accept")).toBe("application/octet-stream");
      const offset = Number(path.split("/").at(-1));
      return new Response(new Uint8Array(offset === 0 ? [255, 0, 1] : [2, corrupt ? 0 : 255]));
    }
    return new Response(JSON.stringify({ data: file }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Download" }));
  await waitFor(() => expect(create).toHaveBeenCalledTimes(1));
  expect(Array.from(new Uint8Array(await saved!.arrayBuffer()))).toEqual([255, 0, 1, 2, 255]);
  await waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  corrupt = true;
  await user.click(screen.getByRole("button", { name: "Download" }));
  await screen.findByText("File integrity verification failed.");
  expect(create).toHaveBeenCalledTimes(1);
});

test("operator uploads exact binary and can use only its completed reference in a Case", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const bytes: number[] = [];
  let file: Record<string, unknown> | null = null;
  wire.mockImplementation(async (request: Request) => {
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const path = new URL(request.url, "http://localhost").pathname;
    const data = (value: unknown, status = 200) =>
      new Response(JSON.stringify({ data: value }), {
        status,
        headers: { "Content-Type": "application/json" },
      });
    if (path.endsWith("target-file-limits"))
      return data({ chunk_bytes: 3, max_size_bytes: 10, lifetime_seconds: 86400 });
    if (path.endsWith("/files") && request.method === "GET")
      return new Response(JSON.stringify({ data: file ? [file] : [], page: { next: null } }));
    if (path.endsWith("/files") && request.method === "POST") {
      const input = (await request.json()).file;
      expect(input.expected_sha256).toBe(digest);
      file = {
        ...input,
        id: "file-1",
        target_id: "target-1",
        request_id: null,
        status: "uploading",
        received_bytes: 0,
        size_bytes: 5,
        sha256: null,
        expires_at: "2099-01-01T00:00:00Z",
      };
      return data(file, 201);
    }
    if (request.method === "PUT") {
      expect(request.headers.get("Content-Type")).toBe("application/octet-stream");
      expect(Number(path.split("/").at(-1))).toBe(bytes.length);
      bytes.push(...new Uint8Array(await request.arrayBuffer()));
      file = { ...file, received_bytes: bytes.length };
      return data(file);
    }
    if (path.endsWith("/complete")) {
      file = { ...file, status: "ready", sha256: digest };
      return data(file);
    }
    if (request.method === "GET") return data(file);
    throw Error("Unexpected file API request");
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.upload(
    await screen.findByLabelText("Add file"),
    new File([new Uint8Array([255, 0, 1, 2, 255])], "payload.bin", {
      type: "application/octet-stream",
    }),
  );
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Use in Case" }).getAttribute("href")).toBe(
      "/cases/new?target=target-1&file=file-1",
    ),
  );
  expect(bytes).toEqual([255, 0, 1, 2, 255]);
  expect(screen.getByText(digest)).toBeTruthy();
});

test("after a lost chunk reply, reloading exposes persisted progress and an explicit resume sends only remaining bytes", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const bytes: number[] = [];
  let file: Record<string, unknown> | null = null;
  let lost = false;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url, "http://localhost").pathname;
    const data = (value: unknown) => new Response(JSON.stringify({ data: value }));
    if (path.endsWith("target-file-limits")) return data({ chunk_bytes: 3, max_size_bytes: 10 });
    if (path.endsWith("/files") && request.method === "GET")
      return new Response(JSON.stringify({ data: file ? [file] : [], page: { next: null } }));
    if (path.endsWith("/files") && request.method === "POST") {
      file = {
        ...(await request.json()).file,
        id: "file-1",
        target_id: "target-1",
        status: "uploading",
        received_bytes: 0,
        sha256: null,
        expires_at: "2099-01-01T00:00:00Z",
      };
      return data(file);
    }
    if (request.method === "PUT") {
      expect(Number(path.split("/").at(-1))).toBe(bytes.length);
      bytes.push(...new Uint8Array(await request.arrayBuffer()));
      file = { ...file, received_bytes: bytes.length };
      if (!lost) {
        lost = true;
        throw new TypeError("Lost HTTP response");
      }
      return data(file);
    }
    if (path.endsWith("/complete")) {
      file = { ...file, status: "ready", sha256: digest };
      return data(file);
    }
    return data(file);
  });
  const view = () => (
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
  const user = userEvent.setup();
  const local = new File([new Uint8Array([255, 0, 1, 2, 255])], "payload.bin", {
    type: "application/octet-stream",
  });
  const first = render(view());
  await user.upload(await screen.findByLabelText("Add file"), local);
  await screen.findByText("File transfer failed. Refresh to check progress before trying again.");
  expect(bytes).toEqual([255, 0, 1]);
  first.unmount();
  render(view());
  await screen.findByText("3 / 5 B · application/octet-stream");
  expect(screen.queryByRole("button", { name: "Use in Case" })).toBeNull();
  await user.click(screen.getByRole("button", { name: "Resume upload" }));
  await user.upload(screen.getByLabelText("Add file"), local);
  await screen.findByText("Ready");
  expect(bytes).toEqual([255, 0, 1, 2, 255]);
});
