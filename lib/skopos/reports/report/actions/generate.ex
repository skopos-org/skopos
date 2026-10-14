defmodule Skopos.Reports.Report.Actions.Generate do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.{Cases, Reports, Signals}

  alias Skopos.Cases.{
    Approval,
    Case,
    CaseConditionMembership,
    CaseEvent,
    Evidence,
    Operation,
    Proposal,
    ResolutionRun,
    ReviewDecision,
    Turn,
    VerificationAttempt
  }

  alias Skopos.Reports.Report
  alias Skopos.Reports.Report.Content

  @resources [
    Report,
    Case,
    CaseConditionMembership,
    Signals.Condition,
    ResolutionRun,
    CaseEvent,
    Turn,
    Evidence,
    Proposal,
    ReviewDecision,
    Approval,
    Operation,
    VerificationAttempt
  ]

  @impl true
  def run(input, _opts, _context) do
    %{case_id: case_id, expected_case_revision: case_revision} = input.arguments

    Ash.transact(@resources, fn ->
      with {:ok, incident} <- locked_case(case_id),
           {:ok, existing} <- existing_report(case_id, case_revision) do
        existing || generate(incident, case_revision)
      end
    end)
  end

  defp generate(incident, expected_revision) do
    with :ok <- reportable?(incident, expected_revision),
         {:ok, records} <- records(incident.id) do
      content = Content.build(incident, records)

      case Reports.create_report_record(
             %{
               case_id: incident.id,
               case_revision: incident.revision,
               language: incident.report_language,
               outcome: incident.status,
               content: content,
               content_digest: Content.digest(content),
               generated_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
        {:ok, report} -> report
        {:error, error} -> {:error, error}
      end
    end
  end

  defp locked_case(id) do
    Case
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Case{} = incident} ->
        {:ok, incident}

      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: Case, primary_key: %{id: id})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp existing_report(case_id, case_revision) do
    Report
    |> Ash.Query.filter(case_id: case_id, case_revision: case_revision)
    |> Ash.read_one(authorize?: false)
  end

  defp reportable?(%Case{revision: revision}, expected) when revision != expected,
    do: {:error, Ash.Error.Changes.StaleRecord.exception(resource: Case, field: :revision)}

  defp reportable?(%Case{status: :running}, _expected),
    do:
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :status,
         message: "running Case cannot be reported"
       )}

  defp reportable?(%Case{status: status}, _expected)
       when status in [:resolved, :needs_attention, :cancelled],
       do: :ok

  defp records(case_id) do
    with {:ok, memberships} <- Cases.active_conditions_for_case(case_id, authorize?: false),
         {:ok, conditions} <- conditions(memberships),
         {:ok, runs} <- read(ResolutionRun, case_id, generation: :asc, id: :asc),
         {:ok, events} <- read(CaseEvent, case_id, inserted_at: :asc, id: :asc),
         {:ok, turns} <- read(Turn, case_id, started_at: :asc, id: :asc),
         {:ok, evidence} <- read(Evidence, case_id, observed_at: :asc, id: :asc),
         {:ok, proposals} <- read(Proposal, case_id, inserted_at: :asc, id: :asc),
         {:ok, reviews} <- read(ReviewDecision, case_id, decided_at: :asc, id: :asc),
         {:ok, approvals} <- read(Approval, case_id, decided_at: :asc, id: :asc),
         {:ok, operations} <- read(Operation, case_id, accepted_at: :asc, id: :asc),
         {:ok, verifications} <-
           read(VerificationAttempt, case_id, accepted_at: :asc, id: :asc) do
      {:ok,
       %{
         conditions: conditions,
         runs: runs,
         events: events,
         turns: turns,
         evidence: evidence,
         proposals: proposals,
         reviews: reviews,
         approvals: approvals,
         operations: operations,
         verifications: verifications
       }}
    end
  end

  defp conditions(memberships) do
    Enum.reduce_while(memberships, {:ok, []}, fn membership, {:ok, items} ->
      case Signals.get_condition(membership.condition_id, authorize?: false) do
        {:ok, condition} -> {:cont, {:ok, [condition | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, conditions} -> {:ok, Enum.reverse(conditions)}
      error -> error
    end
  end

  defp read(resource, case_id, sort) do
    resource
    |> Ash.Query.filter(case_id: case_id)
    |> Ash.Query.sort(sort)
    |> Ash.read(authorize?: false)
  end
end
