import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
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

test("Report windows resolve only current Case and Target labels and latest delivery counts without whole catalogs", async () => {
  await i18n.changeLanguage("en");
  const uuid = (n: number) => `20000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
  const reads: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    reads.push(url);
    if (
      ["/api/v1/cases", "/api/v1/targets", "/api/v1/providers", "/api/v1/deliveries"].includes(
        url.pathname,
      )
    )
      return Response.json(
        { error: { message: "Whole catalog reads are forbidden" } },
        { status: 500 },
      );
    if (url.pathname === "/api/v1/reports") {
      expect(url.searchParams.get("limit")).toBe("50");
      const indices = url.searchParams.has("after")
        ? [51]
        : Array.from({ length: 50 }, (_, n) => n + 1);
      return Response.json({
        data: indices.map((n) => ({ ...summary, id: uuid(n + 1000), case_id: uuid(n + 2000) })),
        page: { next: url.searchParams.has("after") ? null : "report-tail" },
      });
    }
    if (url.pathname === "/api/v1/cases/summaries") {
      const ids = url.searchParams.get("ids")!.split(",");
      expect(ids.length).toBeLessThanOrEqual(50);
      return Response.json({
        data: ids.map((caseId) => {
          const n = Number(caseId.slice(-12)) - 2000;
          return {
            ...reportCase(n),
            id: caseId,
            title: `Window Case ${n}`,
            selected_target_id: uuid(n + 3000),
          };
        }),
        page: { next: null },
      });
    }
    if (url.pathname === "/api/v1/targets/summaries") {
      const ids = url.searchParams.get("ids")!.split(",");
      expect(ids.length).toBeLessThanOrEqual(50);
      return Response.json({
        data: ids.map((targetId) => ({
          id: targetId,
          name: `Window Target ${Number(targetId.slice(-12)) - 3000}`,
        })),
        page: { next: null },
      });
    }
    if (url.pathname === "/api/v1/deliveries/latest") {
      const ids = url.searchParams.get("report_ids")!.split(",");
      expect(ids.length).toBeLessThanOrEqual(50);
      return Response.json({
        data: ids.map((reportId) => ({
          report_id: reportId,
          status: "delivered",
          attempt_count: 51,
        })),
      });
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  await screen.findByRole("link", { name: "Window Case 1" });
  const history = screen.getByRole("region", { name: "Report history" });
  await userEvent.setup().click(within(history).getByRole("button", { name: "Next" }));
  await within(history).findByRole("link", { name: "Window Target 51" });
  expect(within(history).getByRole("link", { name: "Window Case 51" })).toBeTruthy();
  expect(within(history).queryByRole("link", { name: "Window Case 1" })).toBeNull();
  expect(within(history).getByText("×51")).toBeTruthy();
  expect(
    reads
      .filter((url) => url.pathname === "/api/v1/cases/summaries")
      .map((url) => url.searchParams.get("ids")!.split(",").length),
  ).toEqual([50, 1]);
});

test("failed report page and body reads preserve history, and closing aborts a pending body", async () => {
  await i18n.changeLanguage("en");
  let bodyRequest: Request | undefined;
  let finishBody: ((response: Response) => void) | undefined;
  let bodyReads = 0;
  let pageReads = 0;
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/api/v1/reports") {
      pageReads++;
      if (url.searchParams.has("after"))
        return new Response(
          JSON.stringify({ error: { message: "Report page storage unavailable" } }),
          { status: 500 },
        );
      return new Response(JSON.stringify({ data: [summary], page: { next: "older-reports" } }));
    }
    if (url.pathname === `/api/v1/reports/${reportId}`) {
      bodyReads++;
      if (bodyReads === 1) {
        bodyRequest = request;
        return new Promise<Response>((resolve) => {
          finishBody = resolve;
        });
      }
      return new Response(
        JSON.stringify({ error: { message: "Report body storage unavailable" } }),
        { status: 500 },
      );
    }
    if (url.pathname === "/api/v1/report-setting")
      return new Response(JSON.stringify({ data: setting }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("3 operations · 2 checks");
  const user = userEvent.setup();
  await user.click(
    within(screen.getByRole("region", { name: "Report history" })).getByRole("button", {
      name: "Next",
    }),
  );
  expect(await screen.findByText("Report page storage unavailable")).toBeDefined();
  expect(
    within(screen.getByRole("region", { name: "Report history" })).getByText("Page 1"),
  ).toBeDefined();
  expect(document.getElementById(`report-${reportId}`)).not.toBeNull();
  expect(pageReads).toBe(2);
  await user.click(screen.getByRole("button", { name: "Details" }));
  await waitFor(() => expect(bodyRequest).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Hide details" }));
  expect(bodyRequest?.signal.aborted).toBe(true);
  await user.click(screen.getByRole("button", { name: "Details" }));
  expect(await screen.findByText("Report body storage unavailable")).toBeDefined();
  await act(async () => {
    finishBody?.(new Response(JSON.stringify({ data: full })));
  });
  expect(screen.queryByText("The selected recovery was verified.")).toBeNull();
  expect(document.querySelector("pre")).toBeNull();
  expect(bodyReads).toBe(2);
  expect(pageReads).toBe(2);
});

const timestamp = "2026-10-04T01:00:00Z";
const caseId = "00000000-0000-4000-8000-000000000001";
const reportId = "00000000-0000-4000-8000-000000000002";
const olderId = "00000000-0000-4000-8000-000000000003";
const summary: components["schemas"]["ReportSummary"] = {
  id: reportId,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content_digest: "a".repeat(64),
  generated_at: timestamp,
  revision: 1,
  operation_count: 3,
  verification_count: 2,
};
const full: components["schemas"]["Report"] = {
  id: summary.id,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content_digest: summary.content_digest,
  generated_at: timestamp,
  revision: 1,
  content: { padding: "x".repeat(10_000_000) },
  document: {
    title: "Physical host recovered",
    outcome: "Resolved",
    opened_at: timestamp,
    finished_at: timestamp,
    target_id: null,
    source: "fixture",
    source_ref: "report-capacity",
    severity: "warning",
    conditions: [],
    case_symptom: null,
    actions: [],
    verifications: [],
    cited_evidence: [],
    conclusion: "The selected recovery was verified.",
    conclusion_turn_id: null,
    recovery_reviews: [],
    stop_reason: null,
    required_human_input: null,
    case_id: caseId,
    case_revision: 2,
    digest: summary.content_digest,
    text: "Exact report document",
  },
};
const setting: components["schemas"]["ReportSetting"] = {
  id: caseId,
  automatic_case_reports_enabled: false,
  changed_by_id: null,
  revision: 1,
  updated_at: timestamp,
};

function reportCase(index: number): components["schemas"]["CaseSummary"] {
  return {
    id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
    title: `Completed Case ${index}`,
    status: "resolved",
    revision: 7,
    report_language: "en",
    initial_target_id: null,
    selected_target_id: null,
    inserted_at: timestamp,
    updated_at: timestamp,
  };
}

function reportEditor(accountId = "operator-1") {
  return (
    <AuthenticationContext.Provider
      value={{ account: { id: accountId, role: "operator" } } as Authentication}
    >
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
}

function showReportEditor() {
  return render(reportEditor());
}

test("Report generation reaches Case 51, retains the off-page selection and rechecks its exact revision", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  const submissions: unknown[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/cases/summaries") {
      reads.push(url);
      return Response.json({
        data:
          url.searchParams.has("after") || url.searchParams.has("ids")
            ? [reportCase(51)]
            : Array.from({ length: 50 }, (_, index) => reportCase(index + 1)),
        page: {
          next: url.searchParams.has("after") || url.searchParams.has("ids") ? null : "cases-tail",
        },
      });
    }
    if (request.method === "POST") {
      expect(url.pathname).toBe(`/api/v1/cases/${reportCase(51).id}/reports`);
      submissions.push(await request.json());
      return Response.json(
        { data: { ...summary, case_id: reportCase(51).id, case_revision: 7 } },
        { status: 201 },
      );
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  await screen.findByText("Report history");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  const group = await screen.findByRole("group", { name: "Completed Case" });
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Completed Case 51 · en · r7" }));
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").textContent).toContain("Completed Case 51"),
  );
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await waitFor(() => expect(submissions).toEqual([{ report: { expected_case_revision: 7 } }]));
  expect(
    reads.map((url) => [
      url.searchParams.get("limit"),
      url.searchParams.get("after"),
      url.searchParams.get("ids"),
    ]),
  ).toEqual([
    ["50", null, null],
    ["50", "cases-tail", null],
    ["50", null, null],
    ["1", null, reportCase(51).id],
  ]);
});

test("a lost generation response survives page reload and recovers by Case revision without another POST", async () => {
  await i18n.changeLanguage("en");
  const requests: string[] = [];
  let recovered = false;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === `/api/v1/cases/${reportCase(51).id}/reports/7`)
      return recovered
        ? Response.json({ data: { ...summary, case_id: reportCase(51).id, case_revision: 7 } })
        : Response.json({ error: { message: "Receipt not yet available" } }, { status: 404 });
    if (request.method === "POST")
      return Response.json(
        { error: { message: "Response lost after generation" } },
        { status: 503 },
      );
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  await screen.findByText("Report history");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  const choice = await screen.findByRole("combobox", { name: "Completed Case" });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Completed Case 51 · en · r7" }));
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  expect(
    await screen.findByText("Could not confirm report generation. Check the result."),
  ).toBeDefined();
  expect(
    (screen.getByRole("button", { name: "Generate report" }) as HTMLButtonElement).disabled,
  ).toBe(true);
  expect(requests.filter((item) => item.startsWith("POST"))).toEqual([
    `POST /api/v1/cases/${reportCase(51).id}/reports`,
  ]);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(1);
  cleanup();
  recovered = true;
  showReportEditor();
  await screen.findByText("Report history");
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await user.click(await screen.findByRole("button", { name: "Check result" }));
  await waitFor(() =>
    expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(2),
  );
  await waitFor(() => expect(screen.queryByRole("group", { name: "Completed Case" })).toBeNull());
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
});

async function chooseCompletedCase() {
  await screen.findByText("Report history");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  const choice = await screen.findByRole("combobox", { name: "Completed Case" });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Completed Case 51 · en · r7" }));
  return user;
}

test.each(["missing", "running", "changed", "failed", "foreign"])(
  "generation recheck blocks a %s Case without posting",
  async (condition) => {
    await i18n.changeLanguage("en");
    const posted: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        posted.push(url.pathname);
        return Response.json({ data: summary }, { status: 201 });
      }
      if (url.pathname === "/api/v1/cases/summaries") {
        if (url.searchParams.has("ids")) {
          if (condition === "failed")
            return Response.json({ error: { message: "Recheck unavailable" } }, { status: 500 });
          return Response.json({
            data:
              condition === "missing"
                ? []
                : [
                    {
                      ...reportCase(condition === "foreign" ? 52 : 51),
                      status: condition === "running" ? "running" : "resolved",
                      revision: condition === "changed" ? 8 : 7,
                    },
                  ],
            page: { next: null },
          });
        }
        return Response.json({ data: [reportCase(51)], page: { next: null } });
      }
      if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    showReportEditor();
    const user = await chooseCompletedCase();
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await screen.findByText(
      condition === "failed"
        ? "Recheck unavailable"
        : i18n.t(condition === "changed" ? "cases.stateChanged" : "reports.caseUnavailable"),
    );
    expect(posted).toEqual([]);
  },
);

test("generation sends nothing when its request identity cannot be saved", async () => {
  await i18n.changeLanguage("en");
  const posted: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posted.push(url.pathname);
      return Response.json({ data: summary });
    }
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new DOMException("Storage unavailable", "QuotaExceededError");
  });
  try {
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await screen.findByText("Could not save the request. No generation was submitted.");
    expect(posted).toEqual([]);
  } finally {
    saving.mockRestore();
  }
});

test.each(["closing", "changing accounts"])(
  "%s during a generation recheck aborts the read and cannot post afterward",
  async (interruption) => {
    await i18n.changeLanguage("en");
    let checking: Request | undefined;
    let finishCheck: ((response: Response) => void) | undefined;
    const posted: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        posted.push(url.pathname);
        return Response.json({ data: summary });
      }
      if (url.pathname === "/api/v1/cases/summaries") {
        if (url.searchParams.has("ids")) {
          checking = request;
          return new Promise<Response>((resolve) => {
            finishCheck = resolve;
          });
        }
        return Response.json({ data: [reportCase(51)], page: { next: null } });
      }
      if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    const view = showReportEditor();
    const user = await chooseCompletedCase();
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await waitFor(() => expect(checking).toBeDefined());
    if (interruption === "closing")
      await user.click(screen.getByRole("button", { name: "Cancel" }));
    else view.rerender(reportEditor("operator-2"));
    expect(checking?.signal.aborted).toBe(true);
    await act(async () => {
      finishCheck?.(Response.json({ data: [reportCase(51)], page: { next: null } }));
    });
    expect(posted).toEqual([]);
  },
);

test("a rejected generation reports its error and does not retain a pending receipt or retry automatically", async () => {
  await i18n.changeLanguage("en");
  const requests: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    if (request.method === "POST")
      return Response.json({ error: { message: "Generation rejected" } }, { status: 409 });
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await screen.findByText("Generation rejected");
  expect(
    (screen.getByRole("button", { name: "Generate report" }) as HTMLButtonElement).disabled,
  ).toBe(false);
  expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(0);
});

test("a rejection arriving after the form closes releases only its own saved generation request", async () => {
  await i18n.changeLanguage("en");
  let finishPost: ((response: Response) => void) | undefined;
  const posted: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posted.push(url.pathname);
      return new Promise<Response>((resolve) => {
        finishPost = resolve;
      });
    }
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await waitFor(() => expect(finishPost).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  await act(async () => {
    finishPost?.(Response.json({ error: { message: "Generation rejected" } }, { status: 409 }));
  });
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await screen.findByRole("group", { name: "Completed Case" });
  expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
  expect(posted).toHaveLength(1);
});

test("accepted generation keeps its receipt when the list refresh fails and checks it without reposting", async () => {
  await i18n.changeLanguage("en");
  const requests: string[] = [];
  let reportReads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    const receipt = { ...summary, case_id: reportCase(51).id, case_revision: 7 };
    if (request.method === "POST") return Response.json({ data: receipt }, { status: 201 });
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname.endsWith("/reports/7")) return Response.json({ data: receipt });
    if (url.pathname === "/api/v1/reports") {
      reportReads++;
      if (reportReads === 2)
        return Response.json({ error: { message: "Accepted refresh failed" } }, { status: 500 });
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await screen.findByText("Could not confirm report generation. Check the result.");
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(0);
  await user.click(screen.getByRole("button", { name: "Check result" }));
  await waitFor(() => expect(screen.queryByRole("group", { name: "Completed Case" })).toBeNull());
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(1);
});

test.each(["foreign", "failed"])(
  "a %s generation receipt stays unknown and cannot enable another POST",
  async (condition) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      requests.push(`${request.method} ${url.pathname}`);
      if (request.method === "POST")
        return Response.json({ error: { message: "Lost generation response" } }, { status: 503 });
      if (url.pathname === "/api/v1/cases/summaries")
        return Response.json({ data: [reportCase(51)], page: { next: null } });
      if (url.pathname.endsWith("/reports/7"))
        return condition === "foreign"
          ? Response.json({ data: { ...summary, case_id: reportCase(52).id, case_revision: 7 } })
          : Response.json({ error: { message: "Receipt storage unavailable" } }, { status: 500 });
      if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    showReportEditor();
    const user = await chooseCompletedCase();
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await screen.findByText("Could not confirm report generation. Check the result.");
    await user.click(screen.getByRole("button", { name: "Check result" }));
    await waitFor(() =>
      expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(2),
    );
    await waitFor(() =>
      expect(
        (screen.getByRole("button", { name: "Check result" }) as HTMLButtonElement).disabled,
      ).toBe(false),
    );
    expect(
      (screen.getByRole("button", { name: "Generate report" }) as HTMLButtonElement).disabled,
    ).toBe(true);
    expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  },
);

afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("an unconfirmed automatic setting change survives reload and is checked without another PUT", async () => {
  await i18n.changeLanguage("en");
  let current = setting;
  const writes: unknown[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/report-setting") {
      if (request.method === "PUT") {
        writes.push(await request.json());
        current = { ...setting, revision: 2, automatic_case_reports_enabled: true };
        return Response.json({ error: { message: "Setting response lost" } }, { status: 503 });
      }
      return Response.json({ data: current });
    }
    return Response.json({ data: [], page: { next: null } });
  });
  const editor = () => (
    <AuthenticationContext.Provider
      value={{ account: { id: "admin-1", role: "admin" } } as Authentication}
    >
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
  const view = render(editor());
  const user = userEvent.setup();
  const toggle = await screen.findByRole("switch", { name: "Off" });
  await waitFor(() => expect(toggle.getAttribute("aria-disabled")).not.toBe("true"));
  await user.click(toggle);
  await screen.findByText("Could not confirm the setting change. Check the current state.");
  expect(writes).toEqual([
    { report_setting: { expected_revision: 1, automatic_case_reports_enabled: true } },
  ]);
  view.unmount();
  render(editor());
  const currentToggle = await screen.findByRole("switch", { name: "On" });
  expect(currentToggle.getAttribute("aria-disabled")).toBe("true");
  await user.click(screen.getByRole("button", { name: "Check result" }));
  await waitFor(() => expect(currentToggle.getAttribute("aria-disabled")).not.toBe("true"));
  expect(writes).toHaveLength(1);
  expect(currentToggle.getAttribute("aria-checked")).toBe("true");
});

test("a failed referenced Case read keeps the last complete Report window and aborts its sibling read before retry", async () => {
  await i18n.changeLanguage("en");
  let tailFails = true;
  let caseReads = 0;
  let sibling: Request | undefined;
  let finishSibling: ((response: Response) => void) | undefined;
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/reports")
      return Response.json({
        data: [{ ...summary, id: url.searchParams.has("after") ? olderId : reportId }],
        page: { next: url.searchParams.has("after") ? null : "older-reports" },
      });
    if (url.pathname === "/api/v1/cases/summaries") {
      caseReads++;
      if (caseReads > 1 && tailFails)
        return Response.json(
          { error: { message: "Case references unavailable" } },
          { status: 500 },
        );
      return Response.json({
        data: [{ ...reportCase(1), id: caseId, title: "Complete window Case" }],
        page: { next: null },
      });
    }
    if (
      url.pathname === "/api/v1/deliveries/latest" &&
      url.searchParams.get("report_ids") === olderId &&
      tailFails
    ) {
      sibling = request;
      return new Promise<Response>((resolve) => {
        finishSibling = resolve;
      });
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const history = await screen.findByRole("region", { name: "Report history" });
  const user = userEvent.setup();
  await user.click(within(history).getByRole("button", { name: "Next" }));
  await screen.findByText("Case references unavailable");
  expect(sibling?.signal.aborted).toBe(true);
  expect(within(history).getByText("Page 1")).toBeTruthy();
  expect(document.getElementById(`report-${reportId}`)).not.toBeNull();
  expect(document.getElementById(`report-${olderId}`)).toBeNull();
  tailFails = false;
  await user.click(screen.getAllByRole("button", { name: "Refresh" })[0]);
  await within(history).findByText("Page 2");
  await act(async () => {
    finishSibling?.(
      Response.json({ data: [{ report_id: olderId, status: "failed", attempt_count: 99 }] }),
    );
  });
  expect(screen.queryByText("×99")).toBeNull();
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
  expect(document.getElementById(`report-${olderId}`)).not.toBeNull();
});

test.each(["unchanged", "opposite", "foreign", "unavailable"])(
  "an automatic setting read with %s evidence keeps the original request blocked",
  async (condition) => {
    await i18n.changeLanguage("en");
    let puts = 0;
    let gets = 0;
    let receipt = false;
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (url.pathname === "/api/v1/report-setting") {
        if (request.method === "PUT") {
          puts++;
          receipt = true;
          return Response.json({ error: { message: "Response lost" } }, { status: 503 });
        }
        gets++;
        if (receipt && condition === "unavailable")
          return Response.json(
            { error: { message: "Setting storage unavailable" } },
            { status: 500 },
          );
        return Response.json({
          data: !receipt
            ? setting
            : {
                ...setting,
                id: condition === "foreign" ? olderId : setting.id,
                revision: condition === "unchanged" ? 1 : 2,
                automatic_case_reports_enabled: condition !== "opposite",
              },
        });
      }
      return Response.json({ data: [], page: { next: null } });
    });
    render(
      <AuthenticationContext.Provider
        value={{ account: { id: "admin-1", role: "admin" } } as Authentication}
      >
        <MemoryRouter>
          <ReportPage />
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    const user = userEvent.setup();
    const toggle = await screen.findByRole("switch", { name: "Off" });
    await user.click(toggle);
    const panel = screen.getByRole("region", { name: "Automatic Case reports" });
    const check = await within(panel).findByRole("button", { name: "Check result" });
    await waitFor(() => expect((check as HTMLButtonElement).disabled).toBe(false));
    await user.click(check);
    await waitFor(() =>
      expect(
        (within(panel).getByRole("button", { name: "Check result" }) as HTMLButtonElement).disabled,
      ).toBe(false),
    );
    expect(within(panel).getByRole("switch").getAttribute("aria-disabled")).toBe("true");
    expect(puts).toBe(1);
    expect(gets).toBe(2);
  },
);

test("automatic setting sends nothing when its original revision cannot be saved", async () => {
  await i18n.changeLanguage("en");
  let puts = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "PUT") puts++;
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "admin-1", role: "admin" } } as Authentication}
    >
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const toggle = await screen.findByRole("switch", { name: "Off" });
  const storage = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new Error("Storage unavailable");
  });
  try {
    await userEvent.setup().click(toggle);
    await screen.findByText(
      "The setting request could not be saved or read. No change will be sent.",
    );
    expect(puts).toBe(0);
  } finally {
    storage.mockRestore();
  }
});

test("an accepted setting response cancels an older overlapping refresh instead of reverting the displayed value", async () => {
  await i18n.changeLanguage("en");
  let accept: ((response: Response) => void) | undefined;
  let finishOldRead: ((response: Response) => void) | undefined;
  let oldRead: Request | undefined;
  let reads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/report-setting") {
      if (request.method === "PUT")
        return new Promise<Response>((resolve) => {
          accept = resolve;
        });
      reads++;
      if (reads === 2) {
        oldRead = request;
        return new Promise<Response>((resolve) => {
          finishOldRead = resolve;
        });
      }
      return Response.json({ data: setting });
    }
    return Response.json({ data: [], page: { next: null } });
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "admin-1", role: "admin" } } as Authentication}
    >
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole("switch", { name: "Off" }));
  await waitFor(() => expect(accept).toBeDefined());
  await user.click(screen.getAllByRole("button", { name: "Refresh" })[0]);
  await waitFor(() => expect(oldRead).toBeDefined());
  await act(async () => {
    accept?.(
      Response.json({ data: { ...setting, revision: 2, automatic_case_reports_enabled: true } }),
    );
  });
  await screen.findByRole("switch", { name: "On" });
  expect(oldRead?.signal.aborted).toBe(true);
  await act(async () => {
    finishOldRead?.(Response.json({ data: setting }));
  });
  expect(screen.getByRole("switch", { name: "On" }).getAttribute("aria-checked")).toBe("true");
  expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
});

test("changing accounts aborts pending Report references, selected body and setting reads and ignores their late responses", async () => {
  await i18n.changeLanguage("en");
  let changed = false;
  let caseReads = 0;
  const oldReads: Request[] = [];
  const finish: Array<() => void> = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/reports")
      return Response.json({
        data: [{ ...summary, id: changed ? olderId : reportId }],
        page: { next: null },
      });
    if (url.pathname === "/api/v1/cases/summaries") {
      caseReads++;
      if (!changed && caseReads === 2) {
        oldReads.push(request);
        return new Promise<Response>((resolve) => {
          finish.push(() =>
            resolve(
              Response.json({
                data: [{ ...reportCase(1), id: caseId, title: "Old private Case" }],
                page: { next: null },
              }),
            ),
          );
        });
      }
      return Response.json({
        data: [
          {
            ...reportCase(1),
            id: caseId,
            title: changed ? "New account Case" : "Old private Case",
          },
        ],
        page: { next: null },
      });
    }
    if (
      (!changed && url.pathname === "/api/v1/report-setting") ||
      url.pathname === `/api/v1/reports/${reportId}`
    ) {
      oldReads.push(request);
      return new Promise<Response>((resolve) => {
        finish.push(() =>
          resolve(
            Response.json({
              data:
                url.pathname === "/api/v1/report-setting"
                  ? { ...setting, automatic_case_reports_enabled: true }
                  : full,
            }),
          ),
        );
      });
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  const view = showReportEditor();
  const user = userEvent.setup();
  await screen.findByRole("link", { name: "Old private Case" });
  await user.click(screen.getByRole("button", { name: "Details" }));
  await user.click(screen.getAllByRole("button", { name: "Refresh" })[0]);
  await waitFor(() => expect(oldReads).toHaveLength(3));
  changed = true;
  view.rerender(reportEditor("operator-2"));
  await screen.findByRole("link", { name: "New account Case" });
  expect(oldReads.every((request) => request.signal.aborted)).toBe(true);
  await act(async () => {
    finish.forEach((resolve) => resolve());
  });
  expect(screen.queryByText("Old private Case")).toBeNull();
  expect(screen.queryByText("The selected recovery was verified.")).toBeNull();
  expect(screen.getByRole("switch", { name: "Off" }).getAttribute("aria-checked")).toBe("false");
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
});

test.each([409, 503])(
  "a late setting response with status %s preserves the correct request when accounts change",
  async (status) => {
    await i18n.changeLanguage("en");
    let finish: ((response: Response) => void) | undefined;
    let puts = 0;
    wire.mockImplementation(async (request: Request) => {
      if (request.method === "PUT") {
        puts++;
        return new Promise<Response>((resolve) => {
          finish = resolve;
        });
      }
      if (new URL(request.url).pathname === "/api/v1/report-setting")
        return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    const editor = (id: string) => (
      <AuthenticationContext.Provider value={{ account: { id, role: "admin" } } as Authentication}>
        <MemoryRouter>
          <ReportPage />
        </MemoryRouter>
      </AuthenticationContext.Provider>
    );
    const view = render(editor("admin-1"));
    const user = userEvent.setup();
    await user.click(await screen.findByRole("switch", { name: "Off" }));
    await waitFor(() => expect(finish).toBeDefined());
    view.rerender(editor("admin-2"));
    await screen.findByRole("switch", { name: "Off" });
    await act(async () => {
      finish?.(Response.json({ error: { message: "Old account response" } }, { status }));
    });
    expect(screen.queryByText("Old account response")).toBeNull();
    expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
    view.rerender(editor("admin-1"));
    const toggle = await screen.findByRole("switch", { name: "Off" });
    if (status === 503) {
      expect(screen.getByRole("button", { name: "Check result" })).toBeTruthy();
      expect(toggle.getAttribute("aria-disabled")).toBe("true");
    } else {
      expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
      expect(toggle.getAttribute("aria-disabled")).not.toBe("true");
    }
    expect(puts).toBe(1);
  },
);

test("report history reads one metadata page and loads only the selected body", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("skopos.session", "fixture-token");
  const requests: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const url = new URL(request.url, "http://localhost");
    requests.push(url.pathname + url.search);
    if (url.pathname === "/api/v1/reports") {
      const older = url.searchParams.has("after");
      return new Response(
        JSON.stringify({
          data: [older ? { ...summary, id: olderId, case_revision: 1 } : summary],
          page: { next: older ? null : "older-reports" },
        }),
      );
    }
    if (url.pathname === `/api/v1/reports/${reportId}`)
      return new Response(JSON.stringify({ data: full }));
    if (url.pathname === "/api/v1/report-setting")
      return new Response(JSON.stringify({ data: setting }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  expect(await screen.findByText("3 operations · 2 checks")).toBeDefined();
  expect(requests.filter((url) => url.startsWith("/api/v1/reports"))).toEqual([
    "/api/v1/reports?limit=50",
  ]);
  expect(document.querySelector("pre")).toBeNull();
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Details" }));
  expect(await screen.findByText("The selected recovery was verified.")).toBeDefined();
  expect(screen.getByText("Print or save as PDF").closest("a")?.getAttribute("href")).toBe(
    `/reports/${reportId}/print`,
  );
  expect(document.querySelector("pre")).toBeNull();
  await user.click(screen.getByText("Technical details"));
  await waitFor(() =>
    expect(document.querySelector("pre")?.textContent).toContain(full.content.padding),
  );
  await user.click(screen.getByRole("button", { name: "Hide details" }));
  expect(screen.queryByText("The selected recovery was verified.")).toBeNull();
  expect(document.querySelector("pre")).toBeNull();
  await user.click(
    within(screen.getByRole("region", { name: "Report history" })).getByRole("button", {
      name: "Next",
    }),
  );
  expect(
    await within(screen.getByRole("region", { name: "Report history" })).findByText("Page 2"),
  ).toBeDefined();
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
  expect(document.getElementById(`report-${olderId}`)).not.toBeNull();
  expect(
    (
      within(screen.getByRole("region", { name: "Report history" })).getByRole("button", {
        name: "Next",
      }) as HTMLButtonElement
    ).disabled,
  ).toBe(true);
  await user.click(
    within(screen.getByRole("region", { name: "Report history" })).getByRole("button", {
      name: "Previous",
    }),
  );
  expect(
    await within(screen.getByRole("region", { name: "Report history" })).findByText("Page 1"),
  ).toBeDefined();
  expect(document.getElementById(`report-${olderId}`)).toBeNull();
  expect(requests.filter((url) => url.startsWith("/api/v1/reports"))).toEqual([
    "/api/v1/reports?limit=50",
    `/api/v1/reports/${reportId}`,
    "/api/v1/reports?limit=50&after=older-reports",
    "/api/v1/reports?limit=50",
  ]);
});

test("generation accepted after navigating refreshes the current Report window without returning to the submission page", async () => {
  await i18n.changeLanguage("en");
  let accept: ((response: Response) => void) | undefined;
  const reportReads: Array<string | null> = [];
  let posts = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts++;
      return new Promise<Response>((resolve) => {
        accept = resolve;
      });
    }
    if (url.pathname === "/api/v1/reports") {
      const cursor = url.searchParams.get("after");
      reportReads.push(cursor);
      return Response.json({
        data: [{ ...summary, id: cursor ? olderId : reportId }],
        page: { next: cursor ? null : "older-reports" },
      });
    }
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await waitFor(() => expect(accept).toBeDefined());
  const history = screen.getByRole("region", { name: "Report history" });
  await user.click(within(history).getByRole("button", { name: "Next" }));
  await within(history).findByText("Page 2");
  await act(async () => {
    accept?.(
      Response.json(
        {
          data: { ...summary, case_id: reportCase(51).id, case_revision: 7 },
        },
        { status: 201 },
      ),
    );
  });
  await waitFor(() => expect(screen.queryByRole("group", { name: "Completed Case" })).toBeNull());
  expect(within(history).getByText("Page 2")).toBeTruthy();
  expect(reportReads).toEqual([null, "older-reports", "older-reports"]);
  expect(posts).toBe(1);
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
  expect(document.getElementById(`report-${olderId}`)).not.toBeNull();
});

test("a refresh started on the first report page cannot replace a newly selected page", async () => {
  await i18n.changeLanguage("en");
  let firstPageReads = 0;
  let finishRefresh: ((response: Response) => void) | undefined;
  const firstPage = { data: [summary], page: { next: "older-reports" } };
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/api/v1/reports") {
      if (url.searchParams.has("after"))
        return new Response(
          JSON.stringify({ data: [{ ...summary, id: olderId }], page: { next: null } }),
        );
      firstPageReads++;
      if (firstPageReads === 2)
        return new Promise<Response>((resolve) => {
          finishRefresh = resolve;
        });
      return new Response(JSON.stringify(firstPage));
    }
    if (url.pathname === "/api/v1/report-setting")
      return new Response(JSON.stringify({ data: setting }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("3 operations · 2 checks");
  const user = userEvent.setup();
  await user.click(screen.getAllByRole("button", { name: "Refresh" })[0]);
  await waitFor(() => expect(finishRefresh).toBeDefined());
  await user.click(
    within(screen.getByRole("region", { name: "Report history" })).getByRole("button", {
      name: "Next",
    }),
  );
  expect(
    await within(screen.getByRole("region", { name: "Report history" })).findByText("Page 2"),
  ).toBeDefined();
  await act(async () => {
    finishRefresh?.(new Response(JSON.stringify(firstPage)));
  });
  expect(
    within(screen.getByRole("region", { name: "Report history" })).getByText("Page 2"),
  ).toBeDefined();
  expect(document.getElementById(`report-${olderId}`)).not.toBeNull();
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
});
