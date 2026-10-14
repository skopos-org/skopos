defmodule SkoposWeb.Router do
  use SkoposWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SkoposWeb.ApiSpec
  end

  pipeline :oidc_browser do
    plug :accepts, ["html"]
    plug :fetch_session
  end

  pipeline :authenticated_api do
    plug SkoposWeb.API.Auth
  end

  pipeline :request_body do
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      body_reader: {SkoposWeb.CacheBodyReader, :read_body, []}
  end

  pipeline :binary_api do
    plug :accepts, ["json", "bin"]
    plug :fetch_query_params
    plug OpenApiSpex.Plug.PutApiSpec, module: SkoposWeb.ApiSpec
  end

  scope "/api/v1", SkoposWeb.API.V1 do
    pipe_through [:binary_api, :authenticated_api]
    put "/targets/:target_id/files/:id/chunks/:offset", TargetFileController, :append_chunk
    get "/targets/:target_id/files/:id/chunks/:offset", TargetFileController, :download_chunk
  end

  scope "/api/v1", SkoposWeb.API.V1 do
    pipe_through [:api, :request_body]

    get "/openapi.json", OpenAPIController, :show
    post "/accounts/bootstrap", AccountController, :bootstrap
    post "/sessions", SessionController, :create
    get "/oidc", OIDCController, :status
    post "/cli/session-requests", CLISessionController, :create
    post "/cli/session-requests/:id/exchange", CLISessionController, :exchange
  end

  scope "/api/v1", SkoposWeb.API.V1 do
    pipe_through [:api, :authenticated_api, :request_body]

    get "/session", SessionController, :show
    delete "/session", SessionController, :delete
    get "/accounts", AccountController, :index
    post "/accounts", AccountController, :create
    patch "/accounts/:id/role", AccountController, :update_role
    patch "/account/language", AccountController, :update_language
    get "/oidc/provider", OIDCController, :show_provider
    put "/oidc/provider", OIDCController, :configure_provider
    post "/oidc/link-requests", OIDCController, :create_link_request
    post "/cli/session-requests/:id/approve", CLISessionController, :approve
    post "/cli/session-requests/:id/deny", CLISessionController, :deny

    get "/providers", ProviderController, :index
    get "/providers/references", ProviderController, :references
    get "/providers/summaries", ProviderController, :summaries
    get "/ai-services", ProviderController, :services
    post "/providers", ProviderController, :create
    get "/providers/:id", ProviderController, :show
    patch "/providers/:id", ProviderController, :update
    delete "/providers/:id", ProviderController, :delete
    put "/providers/:id/ai-usage", ProviderController, :configure_ai_usage
    post "/providers/:id/check", ProviderController, :check
    post "/providers/:id/target-capabilities", ProviderController, :target_capabilities
    post "/providers/:id/enable", ProviderController, :enable
    post "/providers/:id/disable", ProviderController, :disable

    get "/ai-usage-role-assignments", AIUsageRoleAssignmentController, :index

    get "/management-boundaries", TargetSetupController, :boundaries_index
    get "/management-boundaries/:id", TargetSetupController, :boundaries_show
    post "/management-boundaries", TargetSetupController, :boundaries_create
    patch "/management-boundaries/:id", TargetSetupController, :boundaries_update
    post "/management-boundaries/:id/deactivate", TargetSetupController, :boundaries_deactivate

    get "/target-types", TargetSetupController, :target_types
    get "/targets", TargetSetupController, :targets_index
    get "/targets/references", TargetSetupController, :target_references
    get "/targets/summaries", TargetSetupController, :target_summaries
    post "/targets", TargetSetupController, :targets_create
    get "/targets/:id", TargetSetupController, :targets_show
    patch "/targets/:id", TargetSetupController, :targets_update
    post "/targets/:id/deactivate", TargetSetupController, :targets_deactivate
    post "/targets/:target_id/files", TargetFileController, :create
    get "/targets/:target_id/files", TargetFileController, :index
    get "/targets/:target_id/files/:id", TargetFileController, :show
    post "/targets/:target_id/files/:id/complete", TargetFileController, :complete
    delete "/targets/:target_id/files/:id", TargetFileController, :revoke
    get "/target-file-limits", TargetFileController, :limits

    get "/external-identities", TargetSetupController, :identities_index
    post "/external-identities", TargetSetupController, :identities_create
    patch "/external-identities/:id", TargetSetupController, :identities_update
    post "/external-identities/:id/deactivate", TargetSetupController, :identities_deactivate

    get "/access-methods", TargetSetupController, :access_methods_index
    get "/access-methods/:id", TargetSetupController, :access_methods_show
    post "/access-methods", TargetSetupController, :access_methods_create
    patch "/access-methods/:id", TargetSetupController, :access_methods_update
    post "/access-methods/:id/check", TargetSetupController, :access_methods_check
    post "/access-methods/:id/deactivate", TargetSetupController, :access_methods_deactivate

    get "/target-relationships", TargetSetupController, :relationships_index
    post "/target-relationships", TargetSetupController, :relationships_create
    patch "/target-relationships/:id", TargetSetupController, :relationships_update
    post "/target-relationships/:id/deactivate", TargetSetupController, :relationships_deactivate

    get "/inventory-imports", InventoryImportController, :index
    post "/inventory-imports/manual-preview", InventoryImportController, :preview_manual
    post "/inventory-imports/provider-preview", InventoryImportController, :preview_provider
    get "/inventory-imports/:id", InventoryImportController, :show
    get "/inventory-imports/:id/rows", InventoryImportController, :rows
    get "/inventory-imports/:id/rows/summaries", InventoryImportController, :row_summaries
    post "/inventory-imports/:id/apply", InventoryImportController, :apply_import

    get "/authority-settings", AuthoritySettingController, :index
    get "/authority-setting", AuthoritySettingController, :show
    get "/authority-setting/readiness", AuthoritySettingController, :readiness
    put "/authority-setting", AuthoritySettingController, :update

    get "/cases", CaseController, :index
    get "/cases/summaries", CaseController, :summaries
    post "/cases", CaseController, :create
    get "/cases/:id", CaseController, :show
    get "/cases/:id/timeline", CaseController, :timeline
    get "/cases/:id/turns", CaseController, :turns
    get "/turns/:id", CaseController, :show_turn
    get "/cases/:id/proposals", CaseController, :proposals
    get "/cases/:id/condition-history", CaseController, :condition_history
    get "/cases/:id/operations", CaseController, :operations
    get "/cases/:id/verification-attempts", CaseController, :verifications
    get "/cases/:id/ai-invocations", CaseController, :ai_invocations
    get "/cases/:id/evidence", CaseController, :evidence
    get "/evidence/:id", CaseController, :show_evidence
    get "/cases/:id/approvals", CaseController, :approvals
    get "/cases/:id/review-decisions", CaseController, :review_decisions
    post "/cases/:id/claim", CaseController, :claim
    post "/cases/:id/split", CaseController, :split
    post "/cases/:id/handoff", CaseController, :handoff
    post "/cases/:id/cancel", CaseController, :cancel
    post "/cases/:id/resume", CaseController, :resume

    get "/proposals/:id", ProposalController, :show
    post "/proposals/:id/decision", ProposalController, :decide
    get "/operations/:id", OperationController, :show
    get "/verification-attempts/:id", OperationController, :show_verification

    get "/signal-receipts", SignalReceiptController, :index
    get "/signal-receipts/:id", SignalReceiptController, :show
    get "/signal-receipts/:id/events", SignalReceiptController, :events

    get "/audit-schedules", AuditController, :schedules
    get "/audit-schedules/summaries", AuditController, :schedule_summaries
    post "/audit-schedules", AuditController, :schedule
    get "/audit-schedules/:id", AuditController, :show_schedule
    post "/audit-schedules/:id/deactivate", AuditController, :deactivate
    get "/audit-runs", AuditController, :runs
    get "/audit-runs/summaries", AuditController, :run_summaries
    get "/audit-runs/:id", AuditController, :show_run

    get "/reports", ReportController, :index
    get "/report-setting", ReportSettingController, :show
    put "/report-setting", ReportSettingController, :update
    get "/reports/operations-summary", ReportController, :summary
    get "/reports/:id", ReportController, :show
    post "/cases/:case_id/reports", ReportController, :generate
    get "/cases/:case_id/reports/:case_revision", ReportController, :revision

    get "/deliveries", DeliveryController, :index
    get "/deliveries/summaries", DeliveryController, :summaries
    get "/deliveries/latest", DeliveryController, :latest
    get "/deliveries/receipt", DeliveryController, :receipt
    post "/deliveries", DeliveryController, :create
    get "/deliveries/:id", DeliveryController, :show
  end

  scope "/api/v1", SkoposWeb do
    pipe_through [:api, :request_body]

    post "/signals/alertmanager/:provider_id", SignalWebhookController, :alertmanager
    post "/signals/generic/:provider_id", SignalWebhookController, :generic
    post "/signals/zabbix/:provider_id", SignalWebhookController, :zabbix
  end

  scope "/api/v1", SkoposWeb do
    pipe_through :api

    match :*, "/*path", APIErrorController, :not_found
  end

  scope "/auth", SkoposWeb do
    pipe_through [:oidc_browser, :request_body]

    get "/user/oidc", OIDCController, :start
    get "/user/oidc/callback", OIDCController, :callback
    get "/oidc/start/:id", OIDCController, :start_link
  end

  scope "/", SkoposWeb do
    get "/*path", SPAController, :index
  end
end
