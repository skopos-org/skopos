defmodule Skopos.Providers.Provider.Actions.Inventory do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.{Inventory, Redactor, Registry}

  @failures [:retryable, :failed, :cancelled]
  @max_pages 100
  @max_scope_fields 100
  @max_scope_bytes 65_536
  @max_page_records 1_000
  @max_page_bytes 1_048_576
  @max_identity_bytes 1_024

  @impl true
  def run(input, _opts, _context) do
    %{provider_id: provider_id, request: request, invocation: invocation} = input.arguments

    with :ok <- validate_request(request),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             provider_id,
             request.provider_revision,
             :inventory,
             authorize?: false
           ),
         {:ok, adapter} <- fetch_inventory_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider) do
      fetch(
        adapter,
        state,
        request,
        invocation,
        provider.credentials,
        nil,
        nil,
        request.max_pages,
        []
      )
    end
  rescue
    _error -> {:error, inventory_error(:failed, "Inventory provider failed")}
  catch
    _kind, _reason -> {:error, inventory_error(:failed, "Inventory provider failed")}
  end

  defp validate_request(%Inventory.Request{
         provider_revision: revision,
         scope: scope,
         max_pages: pages
       })
       when is_integer(revision) and revision > 0 and is_map(scope) and is_integer(pages) and
              pages > 0 and pages <= @max_pages do
    if map_size(scope) <= @max_scope_fields and
         :erlang.external_size(scope) <= @max_scope_bytes do
      :ok
    else
      {:error, inventory_error(:failed, "Inventory request is invalid")}
    end
  end

  defp validate_request(_request),
    do: {:error, inventory_error(:failed, "Inventory request is invalid")}

  defp fetch_inventory_adapter(adapter_type) do
    case Registry.fetch(adapter_type, Inventory) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _reason} -> {:error, inventory_error(:failed, "Inventory adapter is unavailable")}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        {:error, inventory_error(:failed, "Inventory configuration is invalid")}
    end
  end

  defp fetch(
         adapter,
         state,
         request,
         invocation,
         credentials,
         cursor,
         source_version,
         pages_left,
         records
       ) do
    case fetch_page(adapter, state, request, cursor, invocation, credentials) do
      {:ok, %Inventory.Page{} = page} when is_nil(source_version) ->
        continue(
          adapter,
          state,
          request,
          invocation,
          credentials,
          page,
          page.source_version,
          pages_left,
          records
        )

      {:ok, %Inventory.Page{source_version: ^source_version} = page} ->
        continue(
          adapter,
          state,
          request,
          invocation,
          credentials,
          page,
          source_version,
          pages_left,
          records
        )

      {:ok, %Inventory.Page{} = page} ->
        {:ok,
         partial(records, source_version, cursor, {
           :source_changed,
           %{expected: source_version, received: page.source_version}
         })
         |> Redactor.value(credentials)}

      {:error, %Inventory.Error{category: category, message: message}} ->
        {:ok,
         partial(records, source_version, cursor, {category, message})
         |> Redactor.value(credentials)}
    end
  end

  defp fetch_page(adapter, state, request, cursor, invocation, credentials) do
    with :ok <- ensure_not_cancelled(invocation) do
      safe_call(fn -> adapter.fetch_page(state, request, cursor, invocation) end, credentials)
      |> validate_page(credentials)
    end
  end

  defp continue(
         adapter,
         state,
         request,
         invocation,
         credentials,
         page,
         source_version,
         pages_left,
         records
       ) do
    records = Enum.reverse(page.records, records)

    cond do
      is_nil(page.next_cursor) ->
        {:ok,
         %Inventory.Snapshot{
           status: :complete,
           records: Enum.reverse(records),
           source_version: source_version
         }
         |> Redactor.value(credentials)}

      pages_left == 1 ->
        {:ok,
         partial(records, source_version, page.next_cursor, {
           :page_limit,
           "Inventory page limit reached"
         })
         |> Redactor.value(credentials)}

      true ->
        fetch(
          adapter,
          state,
          request,
          invocation,
          credentials,
          page.next_cursor,
          source_version,
          pages_left - 1,
          records
        )
    end
  end

  defp validate_page({:ok, %Inventory.Page{} = page}, _credentials) do
    if valid_page?(page) do
      {:ok, page}
    else
      {:error, inventory_error(:failed, "Invalid inventory page")}
    end
  end

  defp validate_page({:error, category, message}, credentials)
       when category in @failures and is_binary(message),
       do: {:error, inventory_error(category, Redactor.message(message, credentials))}

  defp validate_page(_result, _credentials),
    do: {:error, inventory_error(:failed, "Invalid inventory page")}

  defp valid_page?(%Inventory.Page{
         records: records,
         source_version: source_version,
         next_cursor: cursor
       })
       when is_list(records) and is_binary(source_version) and byte_size(source_version) > 0 and
              byte_size(source_version) <= @max_identity_bytes and
              (is_nil(cursor) or (is_binary(cursor) and byte_size(cursor) > 0)),
       do:
         length(records) <= @max_page_records and
           :erlang.external_size(records) <= @max_page_bytes and
           (is_nil(cursor) or byte_size(cursor) <= @max_identity_bytes) and
           Enum.all?(records, &valid_record?/1)

  defp valid_page?(_page), do: false

  defp valid_record?(%Inventory.Record{
         external_id: external_id,
         kind: kind,
         source_ref: source_ref,
         attributes: attributes
       }),
       do:
         is_binary(external_id) and byte_size(external_id) > 0 and is_atom(kind) and
           byte_size(external_id) <= @max_identity_bytes and is_binary(source_ref) and
           byte_size(source_ref) > 0 and byte_size(source_ref) <= @max_identity_bytes and
           is_map(attributes)

  defp valid_record?(_record), do: false

  defp partial(records, source_version, cursor, error) do
    %Inventory.Snapshot{
      status: :partial,
      records: Enum.reverse(records),
      source_version: source_version,
      next_cursor: cursor,
      error: error
    }
  end

  defp ensure_not_cancelled(%{cancelled?: cancelled?}) when is_function(cancelled?, 0) do
    if cancelled?.() do
      {:error, inventory_error(:cancelled, "Inventory snapshot was cancelled")}
    else
      :ok
    end
  end

  defp ensure_not_cancelled(_invocation), do: :ok

  defp safe_call(callback, credentials) do
    callback.()
  rescue
    error -> {:error, :failed, Redactor.message(Exception.message(error), credentials)}
  catch
    _kind, _reason -> {:error, :failed, "Inventory provider failed"}
  end

  defp inventory_error(category, message),
    do: Inventory.Error.exception(category: category, message: message)
end
