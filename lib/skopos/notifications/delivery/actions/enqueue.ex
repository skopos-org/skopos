defmodule Skopos.Notifications.Delivery.Actions.Enqueue do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Notifications
  alias Skopos.Reports.Report
  alias Skopos.Notifications.Delivery
  alias Skopos.Providers.Provider

  @impl true
  def run(input, _opts, _context) do
    arguments = input.arguments

    with {:ok, existing} <- existing(arguments.idempotency_key) do
      if existing do
        exact_replay(existing, arguments)
      else
        create_or_replay(arguments)
      end
    end
  end

  defp create_or_replay(arguments) do
    result =
      Ash.transact([Delivery, Report, Provider], fn ->
        with {:ok, existing} <- existing(arguments.idempotency_key) do
          if existing do
            case exact_replay(existing, arguments) do
              {:ok, delivery} -> delivery
              {:error, error} -> {:error, error}
            end
          else
            create(arguments)
          end
        end
      end)

    case result do
      {:error, _error} = failed ->
        case existing(arguments.idempotency_key) do
          {:ok, %Delivery{} = delivery} -> exact_replay(delivery, arguments)
          _missing -> failed
        end

      success ->
        success
    end
  end

  defp create(arguments) do
    with {:ok, report} <- lock(Report, arguments.report_id),
         :ok <- exact_report(report, arguments.report_revision),
         {:ok, provider} <- lock(Provider, arguments.provider_id),
         :ok <- eligible_provider(provider, arguments.provider_revision),
         {:ok, delivery} <-
           Notifications.create_delivery_record(
             %{
               report_id: report.id,
               report_revision: report.revision,
               provider_id: provider.id,
               provider_revision: provider.revision,
               destination_id: provider.id,
               destination_revision: provider.revision,
               idempotency_key: arguments.idempotency_key,
               status: :queued,
               details: %{},
               enqueued_at: DateTime.utc_now()
             },
             authorize?: false
           ),
         {:ok, _job} <- enqueue(delivery.id) do
      delivery
    end
  end

  defp exact_replay(delivery, arguments) do
    if delivery.report_id == arguments.report_id and
         delivery.report_revision == arguments.report_revision and
         delivery.provider_id == arguments.provider_id and
         delivery.provider_revision == arguments.provider_revision do
      {:ok, delivery}
    else
      stale(Delivery, :idempotency_key)
    end
  end

  defp exact_report(%Report{revision: revision}, revision), do: :ok

  defp exact_report(_report, _revision),
    do: stale(Report, :revision)

  defp eligible_provider(provider, expected_revision) do
    cond do
      provider.revision != expected_revision ->
        stale(Provider, :revision)

      provider.kind == :notification and provider.enabled and provider.check_status == :passed and
          provider.checked_revision == provider.revision ->
        :ok

      true ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :provider_id,
           message: "Notification Provider is not enabled"
         )}
    end
  end

  defp existing(idempotency_key) do
    Notifications.delivery_by_idempotency(idempotency_key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: resource, primary_key: %{id: id})}

      result ->
        result
    end
  end

  defp stale(resource, field) do
    {:error, Ash.Error.Changes.StaleRecord.exception(resource: resource, field: field)}
  end

  defp enqueue(id) do
    id
    |> then(&Skopos.Notifications.Delivery.DispatchWorker.new(%{"delivery_id" => &1}))
    |> Oban.insert()
  end
end
