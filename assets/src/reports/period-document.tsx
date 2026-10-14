import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import type { components } from "@/api/schema";
import "@/reports/report.css";

type Summary = components["schemas"]["PeriodSummary"];

export function PeriodReportDocument({
  summary,
  from,
  to,
  targetName,
}: {
  summary: Summary;
  from: string;
  to: string;
  targetName: string;
}) {
  const { t, i18n } = useTranslation();
  const ja = i18n.resolvedLanguage?.startsWith("ja");
  const maxCases = Math.max(1, ...summary.daily.map((day) => day.cases));
  const attention = summary.cases.filter((item) => item.status === "needs_attention").slice(0, 5);
  const sourceUrl = `/reports/operations?${new URLSearchParams({
    from,
    to,
    ...(summary.target_id ? { target: summary.target_id } : {}),
  })}`;
  const percentage = (count: number, total: number) =>
    total === 0 ? "—" : `${Math.round((count / total) * 100)}%`;
  const timestamp = (value: string) =>
    new Intl.DateTimeFormat(ja ? "ja-JP" : "en-US", {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      timeZone: "UTC",
      timeZoneName: "short",
    }).format(new Date(value));

  return (
    <article
      className="report-sheet report-period-sheet"
      lang={ja ? "ja" : "en"}
      aria-label={t("reports.periodTitle")}
    >
      <header className="report-masthead">
        <div className="report-brand">
          <span className="report-brand-mark" /> SKOPOS{" "}
          <span className="report-kind">/ {ja ? "運用集計" : "OPERATIONS"}</span>
        </div>
        <div className="report-issued">
          {t("reports.periodAsOf")} · {timestamp(summary.as_of)}
        </div>
      </header>

      <div className="report-heading">
        <p className="report-eyebrow">OPERATIONS REPORT</p>
        <h1>{t("reports.periodTitle")}</h1>
        <div className="report-period-range">
          <strong>
            {from} — {to}
          </strong>
          <span>UTC · {targetName}</span>
        </div>
      </div>

      <section className="report-period-highlights" aria-label={ja ? "主要指標" : "Key figures"}>
        <div>
          <span>{t("reports.periodCases")}</span>
          <strong>{summary.case_count}</strong>
        </div>
        <div>
          <span>{t("reports.periodResolved")}</span>
          <strong>
            {summary.case_status.resolved}
            <small>{percentage(summary.case_status.resolved, summary.case_count)}</small>
          </strong>
        </div>
        <div className="report-highlight-attention">
          <span>{t("reports.periodAttention")}</span>
          <strong>
            {summary.case_status.needs_attention}
            <small>{percentage(summary.case_status.needs_attention, summary.case_count)}</small>
          </strong>
        </div>
        <div>
          <span>{t("reports.periodAudits")}</span>
          <strong>{summary.audit_count}</strong>
        </div>
      </section>

      <div className="report-period-pair">
        <section className="report-section">
          <h2>
            <span>01</span>
            {t("reports.periodCaseBreakdown")}
          </h2>
          <dl className="report-period-counts">
            {Object.entries(summary.case_status).map(([status, count]) => (
              <div key={status}>
                <dt>{t(`cases.status.${status}`)}</dt>
                <dd>{count}</dd>
              </div>
            ))}
          </dl>
          <p className="report-period-note">
            {t("reports.periodTriggerBreakdown", summary.case_trigger)}
          </p>
        </section>
        <section className="report-section">
          <h2>
            <span>02</span>
            {t("reports.periodAuditBreakdown")}
          </h2>
          <dl className="report-period-counts">
            {Object.entries(summary.audit_status)
              .filter(([, count]) => count > 0)
              .map(([status, count]) => (
                <div key={status}>
                  <dt>{t(`audits.runStatus.${status}`)}</dt>
                  <dd>{count}</dd>
                </div>
              ))}
            {summary.audit_count === 0 && (
              <div>
                <dt>{t("reports.periodNoRecords")}</dt>
                <dd>0</dd>
              </div>
            )}
          </dl>
        </section>
      </div>

      <section className="report-section report-period-recovery">
        <h2>
          <span>03</span>
          {t("reports.periodRecovery")}
        </h2>
        <div className="report-period-recovery-content">
          <strong>
            {summary.recovery.average_seconds === null
              ? "—"
              : `${summary.recovery.average_seconds}${ja ? "秒" : " s"}`}
          </strong>
          <p className="report-period-note">
            {summary.recovery.average_seconds === null
              ? t("reports.periodNoRecoveryMeasurement")
              : t("reports.periodAverageRecovery", {
                  seconds: summary.recovery.average_seconds,
                  count: summary.recovery.measured_cases,
                })}
            <br />
            {t("reports.periodUnmeasured", { count: summary.recovery.unmeasured_resolved_cases })}
          </p>
        </div>
      </section>

      <section className="report-section report-period-daily">
        <h2>
          <span>04</span>
          {t("reports.periodDaily")}
        </h2>
        <p className="report-period-note">
          {ja
            ? "記録のある日を表示。棒はCase件数、右端は監査Run件数。日付はUTC。"
            : "Days with records only. Bars show Cases; the number at right is audit runs. Dates are UTC."}
        </p>
        {summary.daily.length ? (
          <div className="report-period-days">
            {summary.daily.map((day) => (
              <div className="report-period-day" key={day.date}>
                <time dateTime={day.date}>{day.date.slice(5)}</time>
                <div className="report-period-bar-track">
                  <span style={{ width: `${(day.cases / maxCases) * 100}%` }} />
                </div>
                <strong>{day.cases}</strong>
                <small>{day.audits}</small>
              </div>
            ))}
          </div>
        ) : (
          <p className="report-prose">{t("reports.periodNoRecords")}</p>
        )}
      </section>

      <section className="report-section report-period-attention">
        <h2>
          <span>05</span>
          {t("reports.periodAttention")}
        </h2>
        {summary.case_status.needs_attention > 0 ? (
          <>
            <p className="report-period-note">
              {ja
                ? `要対応は全${summary.case_status.needs_attention}件。${attention.length}件を掲載。${summary.case_sources_truncated ? "Web明細も先頭100件までです。" : "続きはWebの明細を参照してください。"}`
                : `${summary.case_status.needs_attention} Cases need attention; ${attention.length} are shown. ${summary.case_sources_truncated ? "Web details are limited to the first 100 source records." : "Open the Web detail for the rest."}`}
            </p>
            {attention.length > 0 && (
              <ol className="report-period-attention-list">
                {attention.map((item) => (
                  <li key={item.id}>
                    <Link to={`/cases/${item.id}`}>{item.title}</Link>
                    <span>{timestamp(item.opened_at)}</span>
                  </li>
                ))}
              </ol>
            )}
          </>
        ) : (
          <p className="report-prose">{t("reports.periodNoRecords")}</p>
        )}
      </section>

      <footer className="report-footer report-period-footer">
        <strong>{ja ? "集計条件と出典" : "Method and sources"}</strong>
        <span>{t("reports.periodSemantics")}</span>
        <span>{t("reports.periodRecoveryDefinition")}</span>
        <span>
          {ja
            ? "この値は取得時点の集計です。再取得時には変わる場合があります。"
            : "These figures reflect the retrieval time and may change when refreshed."}
        </span>
        <span>
          {ja
            ? `対象: Case ${summary.case_count}件・監査Run ${summary.audit_count}件。明細はWebで参照。`
            : `Sources: ${summary.case_count} Cases and ${summary.audit_count} audit runs. Open the Web detail for source records.`}{" "}
          <Link to={sourceUrl}>{ja ? "明細を開く" : "Open detail"}</Link>
        </span>
        {(summary.case_sources_truncated || summary.audit_sources_truncated) && (
          <span>{t("reports.periodSourceLimit")}</span>
        )}
      </footer>
    </article>
  );
}
