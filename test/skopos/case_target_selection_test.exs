defmodule Skopos.CaseTargetSelectionTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Targets}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("selection-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("selection-operator@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("selection-viewer@example.com", @password, :viewer, actor: admin)

    linux =
      Targets.create_target!("linux-01", "host", "linux", %{"site" => "tokyo"}, nil, actor: admin)

    switch =
      Targets.create_target!("switch-01", "network_device", "cisco_ios_xe", %{}, nil,
        actor: admin
      )

    %{admin: admin, operator: operator, viewer: viewer, linux: linux, switch: switch}
  end

  test "catalog evidence and exact Case selection survive reload and retry once", context do
    {incident, run} = open!("selection", context.operator)

    searched = search!(incident, run, "search-1", "linux-01", context.operator)
    assert searched.status == :charged
    assert searched.run.target_request_count == 1
    assert searched.value.kind == "target_candidates"

    assert [%{"id" => target_id, "revision" => target_revision}] =
             searched.value.content["targets"]

    assert target_id == context.linux.id
    assert target_revision == context.linux.revision

    retried = search!(incident, run, "search-1", "linux-01", context.operator)
    assert retried.status == :duplicate
    assert retried.value.id == searched.value.id
    assert retried.run.target_request_count == 1

    assert {:error, _error} =
             search(incident, run, "search-1", "switch-01", context.operator)

    signal_evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "selection-signal",
        "signal",
        "zabbix",
        "event-1",
        %{"host" => "linux-01", "site" => "tokyo"},
        DateTime.utc_now(),
        authorize?: false
      )

    evidence_ids = [searched.value.id, signal_evidence.id]

    selected =
      Cases.select_case_target!(
        incident.id,
        incident.revision,
        run.id,
        evidence_ids,
        context.linux.id,
        context.linux.revision,
        "Alert host name and site match the registered Target",
        "select-1",
        actor: context.operator
      )

    assert selected.selected_target_id == context.linux.id
    assert selected.selected_target_revision == context.linux.revision
    assert selected.revision == incident.revision + 1

    replayed =
      Cases.select_case_target!(
        incident.id,
        incident.revision,
        run.id,
        evidence_ids,
        context.linux.id,
        context.linux.revision,
        "Alert host name and site match the registered Target",
        "select-1",
        actor: context.operator
      )

    assert replayed.revision == selected.revision

    assert {:error, _error} =
             Cases.select_case_target(
               incident.id,
               incident.revision,
               run.id,
               evidence_ids,
               context.linux.id,
               context.linux.revision,
               "Different retry input",
               "select-1",
               actor: context.operator
             )

    reloaded = Cases.get_case!(incident.id, actor: context.viewer)
    assert reloaded.selected_target_id == context.linux.id
    assert reloaded.selected_target_revision == context.linux.revision
    assert length(Cases.list_evidence!(actor: context.viewer)) == 2

    selection_events =
      Cases.list_case_events!(actor: context.viewer)
      |> Enum.filter(&(&1.event_type == "case_target_selected"))

    assert [event] = selection_events
    assert event.data["prior_target_id"] == nil
    assert event.data["evidence_ids"] == evidence_ids

    assert Targets.list_external_identities!(actor: context.viewer) == []
  end

  test "initial Target snapshots its revision and a later current candidate can replace it",
       context do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        "initial-target",
        "Initial Target",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        context.linux.id,
        :en,
        actor: context.operator
      )

    assert incident.initial_target_id == context.linux.id
    assert incident.selected_target_id == context.linux.id
    assert incident.selected_target_revision == context.linux.revision

    opened = Cases.list_case_events!(actor: context.viewer) |> List.first()
    assert opened.data["selected_target_id"] == context.linux.id
    assert opened.data["selected_target_revision"] == context.linux.revision

    Targets.deactivate_target!(context.linux, context.linux.revision, actor: context.admin)

    replayed_open =
      Cases.open_case!(
        :manual,
        "test",
        "initial-target",
        "Initial Target",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        context.linux.id,
        :en,
        actor: context.operator
      )

    assert replayed_open.id == incident.id
    assert replayed_open.selected_target_revision == context.linux.revision

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    searched = search!(incident, run, "search-switch", "switch-01", context.operator)

    replaced =
      Cases.select_case_target!(
        incident.id,
        incident.revision,
        run.id,
        [searched.value.id],
        context.switch.id,
        context.switch.revision,
        "Fresh evidence points to the network layer",
        "select-switch",
        actor: context.operator
      )

    assert replaced.initial_target_id == context.linux.id
    assert replaced.selected_target_id == context.switch.id

    event = Cases.list_case_events!(actor: context.viewer) |> List.last()
    assert event.data["prior_target_id"] == context.linux.id
    assert event.data["target_id"] == context.switch.id
  end

  test "invented and stale candidates fail without changing the Case", context do
    {incident, run} = open!("invalid-selection", context.operator)
    searched = search!(incident, run, "search-invalid", "linux-01", context.operator)

    assert {:error,
            %Ash.Error.Invalid{
              errors: [%Skopos.Cases.Case.Actions.TargetSelection.CandidateNotOffered{}]
            }} =
             Cases.select_case_target(
               incident.id,
               incident.revision,
               run.id,
               [searched.value.id],
               context.switch.id,
               context.switch.revision,
               "Invented candidate",
               "select-invented",
               actor: context.operator
             )

    updated_linux =
      Targets.update_target!(
        context.linux,
        context.linux.revision,
        %{facts: %{"site" => "osaka"}},
        actor: context.admin
      )

    assert updated_linux.revision == context.linux.revision + 1

    assert {:error, _error} =
             Cases.select_case_target(
               incident.id,
               incident.revision,
               run.id,
               [searched.value.id],
               context.linux.id,
               context.linux.revision,
               "Stale candidate",
               "select-stale",
               actor: context.operator
             )

    reloaded = Cases.get_case!(incident.id, actor: context.viewer)
    assert is_nil(reloaded.selected_target_id)
    assert reloaded.revision == incident.revision
  end

  test "viewer and cancelled Case cannot search or select", context do
    {incident, run} = open!("forbidden-selection", context.operator)

    assert {:error, %Ash.Error.Forbidden{}} =
             search(incident, run, "viewer-search", "linux-01", context.viewer)

    searched = search!(incident, run, "allowed-search", "linux-01", context.operator)

    cancelled =
      Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert {:error, _error} =
             search(cancelled, run, "cancelled-search", "linux-01", context.operator)

    assert {:error, _error} =
             Cases.select_case_target(
               cancelled.id,
               cancelled.revision,
               run.id,
               [searched.value.id],
               context.linux.id,
               context.linux.revision,
               "Do not select after cancellation",
               "cancelled-select",
               actor: context.operator
             )
  end

  defp open!(source_ref, actor) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: actor
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp search!(incident, run, key, query, actor) do
    search(incident, run, key, query, actor) |> then(fn {:ok, result} -> result end)
  end

  defp search(incident, run, key, query, actor) do
    Cases.search_case_targets(
      incident.id,
      run.id,
      key,
      query,
      20,
      %{"action" => "search_targets", "query" => query},
      "Refine the Target query or select a Target manually",
      actor: actor
    )
  end
end
