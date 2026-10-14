defmodule Skopos.Reports.Report.Actions.PeriodSummary do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Audits, Cases, Repo}

  @max_window_seconds 366 * 24 * 60 * 60
  @source_limit 100

  @impl true
  def run(input, _opts, context) do
    %{from: from, to: to, target_id: target_id} = input.arguments

    with :ok <- validate_window(from, to) do
      # Sandbox tests own an outer transaction before this action starts.
      # The HTTP path starts a fresh transaction and sets a stable read snapshot.
      nested_transaction? =
        Repo.in_transaction?() or Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox

      case Repo.transaction(fn ->
             unless nested_transaction? do
               Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
             end

             build(from, to, target_id, context.actor)
           end) do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end
  end

  defp validate_window(from, to) do
    seconds = DateTime.diff(to, from, :second)

    if seconds > 0 and seconds <= @max_window_seconds do
      :ok
    else
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :to,
         message: "period must be after from and no longer than 366 days"
       )}
    end
  end

  defp build(from, to, target_id, actor) do
    with {:ok, case_page} <-
           Cases.report_cases(from, to, target_id, page: [limit: 100], actor: actor),
         {:ok, case_state} <- fold_pages(case_page, empty_cases(), &add_case/2),
         {:ok, audit_page} <-
           Audits.report_audit_runs(from, to, target_id, page: [limit: 100], actor: actor),
         {:ok, audit_state} <- fold_pages(audit_page, empty_audits(), &add_audit/2) do
      daily =
        Map.keys(case_state.daily)
        |> Kernel.++(Map.keys(audit_state.daily))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(fn day ->
          %{
            "date" => day,
            "cases" => Map.get(case_state.daily, day, 0),
            "audits" => Map.get(audit_state.daily, day, 0)
          }
        end)

      {:ok,
       %{
         "from" => DateTime.to_iso8601(from),
         "to" => DateTime.to_iso8601(to),
         "as_of" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "target_id" => target_id,
         "case_count" => case_state.total,
         "case_status" => case_state.status,
         "case_trigger" => case_state.trigger,
         "recovery" => %{
           "measured_cases" => case_state.recovery_count,
           "unmeasured_resolved_cases" =>
             Map.get(case_state.status, "resolved", 0) - case_state.recovery_count,
           "average_seconds" =>
             if(case_state.recovery_count > 0,
               do: div(case_state.recovery_sum, case_state.recovery_count),
               else: nil
             )
         },
         "audit_count" => audit_state.total,
         "audit_status" => audit_state.status,
         "daily" => daily,
         "cases" => Enum.reverse(case_state.items),
         "audits" => Enum.reverse(audit_state.items),
         "case_sources_truncated" => case_state.total > @source_limit,
         "audit_sources_truncated" => audit_state.total > @source_limit
       }}
    end
  end

  defp fold_pages(page, state, add) do
    next = Enum.reduce(page.results, state, add)

    if page.more? do
      case Ash.page(page, :next) do
        {:ok, following} -> fold_pages(following, next, add)
        {:error, error} -> {:error, error}
      end
    else
      {:ok, next}
    end
  end

  defp empty_cases do
    %{
      total: 0,
      status: %{"running" => 0, "needs_attention" => 0, "resolved" => 0, "cancelled" => 0},
      trigger: %{"manual" => 0, "signal" => 0, "audit" => 0},
      daily: %{},
      recovery_count: 0,
      recovery_sum: 0,
      items: []
    }
  end

  defp empty_audits do
    %{
      total: 0,
      status: %{
        "queued" => 0,
        "running" => 0,
        "case_opened" => 0,
        "skipped" => 0,
        "cancelled" => 0,
        "failed" => 0
      },
      daily: %{},
      items: []
    }
  end

  defp add_case(item, state) do
    status = Atom.to_string(item.status)
    trigger = Atom.to_string(item.trigger_kind)
    date = item.inserted_at |> DateTime.to_date() |> Date.to_iso8601()
    elapsed = recovery_seconds(item)

    record = %{
      "id" => item.id,
      "title" => item.title,
      "status" => status,
      "trigger_kind" => trigger,
      "opened_at" => DateTime.to_iso8601(item.inserted_at),
      "target_id" => item.selected_target_id || item.initial_target_id
    }

    %{
      state
      | total: state.total + 1,
        status: Map.update!(state.status, status, &(&1 + 1)),
        trigger: Map.update!(state.trigger, trigger, &(&1 + 1)),
        daily: Map.update(state.daily, date, 1, &(&1 + 1)),
        recovery_count: state.recovery_count + if(elapsed, do: 1, else: 0),
        recovery_sum: state.recovery_sum + (elapsed || 0),
        items: if(state.total < @source_limit, do: [record | state.items], else: state.items)
    }
  end

  defp recovery_seconds(%{status: :resolved, resolved_at: %DateTime{} = resolved} = item) do
    seconds = DateTime.diff(resolved, item.inserted_at, :second)
    if seconds >= 0, do: seconds
  end

  defp recovery_seconds(_item), do: nil

  defp add_audit(item, state) do
    status = Atom.to_string(item.status)
    date = item.scheduled_for |> DateTime.to_date() |> Date.to_iso8601()

    record = %{
      "id" => item.id,
      "status" => status,
      "scheduled_for" => DateTime.to_iso8601(item.scheduled_for),
      "target_id" => item.target_id,
      "case_id" => item.case_id,
      "reason" => item.reason
    }

    %{
      state
      | total: state.total + 1,
        status: Map.update!(state.status, status, &(&1 + 1)),
        daily: Map.update(state.daily, date, 1, &(&1 + 1)),
        items: if(state.total < @source_limit, do: [record | state.items], else: state.items)
    }
  end
end
