defmodule Skopos.Reports do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Reports.Report do
      define :list_reports, action: :read
      define :page_reports, action: :page
      define :get_report, action: :read, get_by: [:id]

      define :report_by_case_revision,
        action: :by_case_revision,
        args: [:case_id, :case_revision]

      define :report_summaries_for_case, action: :summaries_for_case, args: [:case_id]

      define :report_summary_by_case_revision,
        action: :summary_by_case_revision,
        args: [:case_id, :case_revision],
        get?: true

      define :create_report_record, action: :create_record
      define :generate_report, action: :generate, args: [:case_id, :expected_case_revision]
      define :period_summary, action: :period_summary, args: [:from, :to, :target_id]
    end

    resource Skopos.Reports.Setting do
      define :current_setting, action: :current
      define :bootstrap_setting, action: :bootstrap

      define :configure_setting,
        action: :configure,
        args: [:expected_revision, :automatic_case_reports_enabled]
    end
  end
end
