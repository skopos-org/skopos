defmodule SkoposCLI.CLI do
  @moduledoc false

  alias SkoposCLI.{BrowserLogin, Client, Commands, Config, FileTransfer}
  alias SkoposCLI.Commands.Route

  @exit %{
    succeeded: 0,
    resolved: 0,
    accepted: 10,
    resolving: 10,
    approval_required: 11,
    needs_attention: 12,
    failed: 13,
    partial: 14,
    unknown: 15,
    cancel_requested: 16
  }
  @terminal ~w(succeeded resolved needs_attention failed partial unknown cancel_requested)a
  @switches [
    input: :string,
    limit: :integer,
    after: :string,
    from: :string,
    to: :string,
    target_id: :string,
    report_ids: :string,
    idempotency_key: :string,
    active: :boolean,
    ids: :string,
    roles: :string,
    query: :string,
    status: :string,
    sort: :string,
    kind: :string,
    kinds: :string,
    eligible: :boolean,
    enabled: :boolean,
    adapter_types: :string,
    exclude_id: :string,
    interval: :integer,
    timeout: :integer,
    server: :string,
    file: :string,
    upload_key: :string,
    media_type: :string,
    resume: :string,
    output: :string
  ]

  def run(args, runtime_options \\ [])

  def run(["--version"], _runtime_options) do
    IO.puts("skopos #{version()}")
    0
  end

  def run([], _runtime_options), do: help()
  def run(["--help"], _runtime_options), do: help()

  def run(["config", "set-server", server], runtime_options) do
    config_path = config_path(runtime_options)

    with {:ok, client} <- Client.new(server, nil),
         {:ok, config} <- Config.load(config_path),
         :ok <- Config.save(server_config(config, client.server), config_path) do
      print(%{"outcome" => "succeeded", "server" => client.server})
      0
    else
      {:error, message} -> local_error(message)
    end
  end

  def run(["config", "show"], runtime_options) do
    case Config.load(config_path(runtime_options)) do
      {:ok, config} ->
        print(%{
          "outcome" => "succeeded",
          "server" => config["server"],
          "authenticated" => is_binary(config["token"])
        })

        0

      {:error, message} ->
        local_error(message)
    end
  end

  def run(["auth", "login" | args], runtime_options), do: login(args, runtime_options)

  def run(args, runtime_options) do
    case Commands.lookup(args) do
      {:ok, route, ids, option_args, mode} ->
        execute(route, ids, option_args, mode, runtime_options)

      :error ->
        usage_error("Unknown or incomplete command")
    end
  end

  defp login(args, runtime_options) do
    with {:ok, options} <- parse_options(args),
         {:ok, config} <- Config.load(config_path(runtime_options)),
         server when is_binary(server) <- options[:server] || config["server"] do
      browser_login(server, options, runtime_options)
    else
      nil -> usage_error("auth login requires --server or saved server")
      {:error, message} -> local_error(message)
    end
  end

  defp browser_login(server, options, runtime_options) do
    timeout = max(options[:timeout] || 300, 1) * 1_000
    browser_login = Keyword.get(runtime_options, :browser_login, &BrowserLogin.run/4)

    with {:ok, client} <- Client.new(server, nil, request_options(runtime_options)),
         {:ok, token, account} <-
           browser_login.(
             client,
             timeout,
             Keyword.get(runtime_options, :open_browser, &BrowserLogin.open_browser/1),
             Keyword.get(runtime_options, :listen, &:gen_tcp.listen/2)
           ),
         :ok <-
           Config.save(
             %{"server" => client.server, "token" => token},
             config_path(runtime_options)
           ) do
      print(%{"outcome" => "succeeded", "account" => account})
      0
    else
      {:error, :http, status, body} -> http_error(status, body)
      {:error, :transport, message} -> transport_error(message)
      {:error, message} -> local_error(message)
      _other -> local_error("Browser login did not produce a session")
    end
  end

  defp execute(route, ids, args, mode, runtime_options) do
    with {:ok, options} <- parse_options(args),
         {:ok, config} <- Config.load(config_path(runtime_options)),
         :ok <- require_token(route, config),
         {:ok, client} <-
           Client.new(config["server"], config["token"], request_options(runtime_options)),
         {:ok, body} <- request_body(route, options, runtime_options) do
      if mode == :wait do
        wait(client, route, ids, options)
      else
        request_once(client, route, ids, body, options, runtime_options)
      end
    else
      {:error, message} -> local_error(message)
    end
  end

  defp request_once(
         client,
         %Route{outcome: :file_upload},
         [target_id],
         _body,
         options,
         _runtime_options
       ) do
    file_result(FileTransfer.upload(client, target_id, options))
  end

  defp request_once(
         client,
         %Route{outcome: :file_download},
         [target_id, id],
         _body,
         options,
         _runtime_options
       ) do
    file_result(FileTransfer.download(client, target_id, id, options))
  end

  defp request_once(client, route, ids, body, options, runtime_options) do
    receipt =
      case {route, ids, body} do
        {%Route{method: :post, path: "/providers"}, _ids,
         %{"provider" => %{"registration_id" => id}}} ->
          %{"registration_id" => id}

        {%Route{method: :post, path: "/audit-schedules"}, _ids,
         %{"audit_schedule" => %{"registration_id" => id}}} ->
          %{"registration_id" => id}

        {%Route{method: :post, path: "/audit-schedules/:id/deactivate"}, [id],
         %{"audit_schedule" => %{"expected_revision" => revision}}} ->
          %{"audit_schedule_id" => id, "expected_revision" => revision}

        _other ->
          %{}
      end

    with :ok <- emit_registration(receipt) do
      case Client.request(
             client,
             route.method,
             Commands.path(route, ids),
             body,
             query(route, options)
           ) do
        {:ok, _status, response} ->
          result = outcome(route.outcome, response)

          with :ok <- maybe_clear_logout(route, runtime_options) do
            print_response(route, response, result)
            Map.fetch!(@exit, result)
          else
            {:error, message} -> local_error(message)
          end

        {:error, :http, status, response} ->
          context =
            if status >= 500 and map_size(receipt) > 0,
              do: Map.put(receipt, "outcome", "unknown"),
              else: receipt

          http_error(status, response, context)

        {:error, :transport, message} ->
          transport_error(message, receipt)
      end
    else
      :error -> 4
    end
  end

  defp emit_registration(%{"registration_id" => id}) do
    with true <- Uniq.UUID.valid?(id) do
      IO.puts(
        :stderr,
        Jason.encode!(%{"event" => "registration_prepared", "registration_id" => id})
      )
    else
      false -> :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp emit_registration(_receipt), do: :ok

  defp file_result({:ok, response}) do
    print(with_outcome(response, :succeeded))
    0
  end

  defp file_result({:error, :local, message, context}), do: local_error(message, context)
  defp file_result({:error, :http, status, body, context}), do: http_error(status, body, context)
  defp file_result({:error, :transport, message, context}), do: transport_error(message, context)

  defp file_result({:error, :protocol, message, context}) do
    print_error(
      Map.merge(
        %{"outcome" => "unknown", "error" => %{"code" => "protocol_error", "message" => message}},
        context
      )
    )

    15
  end

  defp wait(client, route, ids, options) do
    interval = max(options[:interval] || 1_000, 50)
    timeout = max(options[:timeout] || 300, 0)
    deadline = System.monotonic_time(:millisecond) + timeout * 1_000
    poll(client, route, ids, interval, deadline)
  end

  defp poll(client, route, ids, interval, deadline) do
    case Client.request(client, route.method, Commands.path(route, ids)) do
      {:ok, _status, response} ->
        result = outcome(route.outcome, response)

        cond do
          result in @terminal or terminal_accepted?(route, response) ->
            print(with_outcome(response, result))
            Map.fetch!(@exit, result)

          System.monotonic_time(:millisecond) >= deadline ->
            print(with_outcome(response, result))
            Map.fetch!(@exit, result)

          true ->
            Process.sleep(interval)
            poll(client, route, ids, interval, deadline)
        end

      {:error, :http, status, body} ->
        http_error(status, body)

      {:error, :transport, message} ->
        transport_error(message)
    end
  end

  defp outcome(:case, %{"data" => %{"case" => incident} = snapshot}),
    do: case_outcome(incident, snapshot)

  defp outcome(:case_record, %{"data" => incident}), do: case_outcome(incident, %{})

  defp outcome(:operation, %{"data" => %{"status" => status}}),
    do:
      status_outcome(status, %{
        "queued" => :accepted,
        "dispatching" => :resolving,
        "applied" => :resolved
      })

  defp outcome(:verification, %{"data" => %{"status" => status}}),
    do:
      status_outcome(status, %{
        "queued" => :accepted,
        "dispatching" => :resolving,
        "verified" => :resolved,
        "not_verified" => :failed
      })

  defp outcome(:delivery, %{"data" => %{"status" => status}}),
    do:
      status_outcome(status, %{
        "queued" => :accepted,
        "dispatching" => :resolving,
        "accepted" => :accepted,
        "delivered" => :resolved
      })

  defp outcome(:proposal, %{"data" => %{"status" => "awaiting_human"}}),
    do: :approval_required

  defp outcome(:method_check, %{
         "data" => %{"check" => %{"status" => "passed", "current" => true}}
       }),
       do: :succeeded

  defp outcome(:method_check, %{"data" => %{"check" => %{"status" => "failed"}}}),
    do: :failed

  defp outcome(:method_check, _response), do: :unknown

  defp outcome(_kind, _response), do: :succeeded

  defp case_outcome(%{"cancel_requested" => true}, _snapshot), do: :cancel_requested
  defp case_outcome(%{"status" => "resolved"}, _snapshot), do: :resolved
  defp case_outcome(%{"status" => "needs_attention"}, _snapshot), do: :needs_attention
  defp case_outcome(%{"status" => "cancelled"}, _snapshot), do: :cancel_requested

  defp case_outcome(%{"status" => "running"} = incident, snapshot) do
    runs = Map.get(snapshot, "resolution_runs", [])

    cond do
      incident["operator_action"] == "decision_required" -> :approval_required
      runs == [] -> :accepted
      true -> :resolving
    end
  end

  defp case_outcome(_incident, _snapshot), do: :unknown

  defp status_outcome(status, aliases) do
    Map.get(aliases, status) ||
      case status do
        "failed" -> :failed
        "partial" -> :partial
        "unknown" -> :unknown
        _other -> :unknown
      end
  end

  defp request_body(%Route{root: nil}, _options, _runtime_options), do: {:ok, nil}

  defp request_body(%Route{root: root} = route, options, runtime_options) do
    with path when is_binary(path) <- options[:input],
         {:ok, encoded} <- read_input(path, runtime_options),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(encoded) do
      input =
        if route.method == :post and route.path in ["/providers", "/audit-schedules"],
          do: Map.put_new_lazy(decoded, "registration_id", &Uniq.UUID.uuid4/0),
          else: decoded

      {:ok, %{root => input}}
    else
      nil ->
        {:error, "This command requires --input FILE or --input -"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "Input is not valid JSON"}

      {:error, reason} when is_atom(reason) ->
        {:error, "Cannot read input: #{:file.format_error(reason)}"}

      _other ->
        {:error, "Input must be a JSON object"}
    end
  end

  defp read_input("-", runtime_options),
    do: {:ok, IO.read(runtime_options[:input] || :stdio, :eof)}

  defp read_input(path, _runtime_options), do: File.read(path)

  defp parse_options(args) do
    case OptionParser.parse(args, strict: @switches) do
      {options, [], []} ->
        {:ok, options}

      {_options, remaining, invalid} ->
        {:error, "Invalid options: #{inspect(invalid ++ remaining)}"}
    end
  end

  defp query(%Route{path: "/providers/references"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:kind, options[:kind])
    |> maybe_query(:enabled, options[:enabled])
    |> maybe_query(:adapter_types, options[:adapter_types])
  end

  defp query(%Route{path: "/providers/summaries"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:kinds, options[:kinds])
    |> maybe_query(:eligible, options[:eligible])
  end

  defp query(%Route{path: "/targets/references"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:active, options[:active])
    |> maybe_query(:exclude_id, options[:exclude_id])
  end

  defp query(%Route{path: "/targets/summaries"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:active, options[:active])
    |> maybe_query(:query, options[:query])
  end

  defp query(%Route{path: "/cases/summaries"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:query, options[:query])
    |> maybe_query(:status, options[:status])
    |> maybe_query(:sort, options[:sort])
  end

  defp query(%Route{path: path}, options)
       when path in ["/deliveries/summaries", "/deliveries/latest"] do
    query = maybe_query([], :report_ids, options[:report_ids])

    if path == "/deliveries/summaries" do
      query
      |> maybe_query(:limit, options[:limit])
      |> maybe_query(:after, options[:after])
    else
      query
    end
  end

  defp query(%Route{path: "/deliveries/receipt"}, options),
    do: maybe_query([], :idempotency_key, options[:idempotency_key])

  defp query(%Route{path: path}, options)
       when path in ["/reports", "/audit-schedules/summaries", "/audit-runs/summaries"] do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
  end

  defp query(%Route{path: "/management-boundaries"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:active, options[:active])
  end

  defp query(%Route{page?: true, path: "/accounts"}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, options[:ids])
    |> maybe_query(:roles, options[:roles])
  end

  defp query(%Route{page?: true, path: path}, options)
       when path in ["/access-methods", "/external-identities", "/target-relationships"] do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
    |> maybe_query(:ids, if(path == "/access-methods", do: options[:ids]))
    |> maybe_query(:target_id, options[:target_id])
    |> maybe_query(:active, options[:active])
  end

  defp query(%Route{page?: true}, options) do
    []
    |> maybe_query(:limit, options[:limit])
    |> maybe_query(:after, options[:after])
  end

  defp query(%Route{outcome: :period_summary}, options) do
    []
    |> maybe_query(:from, options[:from])
    |> maybe_query(:to, options[:to])
    |> maybe_query(:target_id, options[:target_id])
  end

  defp query(_route, _options), do: []
  defp maybe_query(query, _key, nil), do: query
  defp maybe_query(query, key, value), do: [{key, value} | query]

  defp require_token(%Route{auth?: false}, _config), do: :ok
  defp require_token(_route, %{"token" => token}) when is_binary(token), do: :ok
  defp require_token(_route, _config), do: {:error, "Not authenticated. Run skopos auth login"}

  defp maybe_clear_logout(%Route{path: "/session", method: :delete}, runtime_options),
    do: Config.clear_token(config_path(runtime_options))

  defp maybe_clear_logout(_route, _runtime_options), do: :ok

  defp terminal_accepted?(%Route{outcome: :delivery}, %{
         "data" => %{"status" => "accepted"}
       }),
       do: true

  defp terminal_accepted?(_route, _response), do: false

  defp server_config(%{"server" => server} = config, server), do: config

  defp server_config(config, server) do
    config
    |> Map.put("server", server)
    |> Map.delete("token")
  end

  defp with_outcome(response, result) when is_map(response),
    do: Map.put(response, "outcome", Atom.to_string(result))

  defp print(value), do: IO.puts(Jason.encode!(value, pretty: true))

  defp print_response(
         %Commands.Route{outcome: :report_read},
         %{
           "data" => %{"document" => %{"text" => text}}
         },
         _result
       )
       when is_binary(text),
       do: IO.puts(text)

  defp print_response(_route, response, result), do: print(with_outcome(response, result))

  defp http_error(status, body, context \\ %{}) do
    print_error(
      Map.merge(%{"outcome" => "failed", "http_status" => status}, map_body(body))
      |> Map.merge(context)
    )

    cond do
      context["outcome"] == "unknown" -> Map.fetch!(@exit, :unknown)
      status == 401 -> 3
      true -> 4
    end
  end

  defp transport_error(message, context \\ %{}) do
    print_error(
      %{
        "outcome" => "unknown",
        "error" => %{"code" => "transport_error", "message" => message}
      }
      |> Map.merge(context)
    )

    5
  end

  defp local_error(message, context \\ %{}) do
    print_error(
      %{
        "outcome" => "failed",
        "error" => %{"code" => "local_error", "message" => message}
      }
      |> Map.merge(context)
    )

    4
  end

  defp usage_error(message) do
    IO.puts(:stderr, message <> ". Run skopos --help for usage.")
    2
  end

  defp print_error(value), do: IO.puts(:stderr, Jason.encode!(value))
  defp map_body(body) when is_map(body), do: body
  defp map_body(body), do: %{"error" => %{"message" => inspect(body)}}

  defp help do
    IO.puts("""
    Usage:
      skopos config set-server URL
      skopos config show
      skopos auth login [--server URL] [--timeout SEC]
      skopos auth status | logout
      skopos provider services
      skopos RESOURCE ACTION [ID] [--input FILE|-] [--limit N] [--after CURSOR]
      skopos identity|relationship list [--target-id UUID] [--active|--no-active] [--limit N] [--after CURSOR]
      skopos access-method list [--ids UUID,UUID] [--target-id UUID] [--active|--no-active] [--limit N] [--after CURSOR]
      skopos boundary list [--ids UUID,UUID] [--active|--no-active] [--limit N] [--after CURSOR]
      skopos audit|audit-run summaries [--ids UUID,UUID] [--limit N] [--after CURSOR]
      skopos account list [--ids UUID,UUID] [--roles admin,operator,viewer] [--limit N] [--after CURSOR]
      skopos provider references [--ids UUID,UUID] [--kind KIND] [--enabled|--no-enabled] [--adapter-types TYPE,TYPE] [--limit N] [--after CURSOR]
      skopos target references [--ids UUID,UUID] [--active|--no-active] [--exclude-id UUID] [--limit N] [--after CURSOR]
      skopos target summaries [--ids UUID,UUID] [--active|--no-active] [--query TEXT] [--limit N] [--after CURSOR]
      skopos case|operation|verification|delivery wait ID [--interval MS] [--timeout SEC]
      skopos case ai-invocations ID [--limit N] [--after CURSOR]
      skopos case summaries [--ids UUID,UUID] [--query TEXT] [--status STATUS] [--sort SORT] [--limit N] [--after CURSOR]
      skopos delivery summaries [--report-ids UUID,UUID] [--limit N] [--after CURSOR]
      skopos delivery latest --report-ids UUID,UUID
      skopos delivery receipt --idempotency-key KEY
      skopos report summary --from ISO8601 --to ISO8601 [--target-id UUID]
      skopos report list [--ids UUID,UUID] [--limit N] [--after CURSOR]
      skopos report revision CASE_ID CASE_REVISION
      skopos report read ID
      skopos file list TARGET_ID
      skopos file show|revoke TARGET_ID FILE_ID
      skopos file upload TARGET_ID --file PATH (--upload-key KEY | --resume FILE_ID) [--media-type TYPE]
      skopos file download TARGET_ID FILE_ID --output PATH

    Resources:
      account provider ai-role boundary target-type target identity access-method relationship
      inventory authority case proposal operation verification signal audit audit-run report delivery file

    Input JSON contains the resource fields directly; the CLI adds the API envelope.
    Output is fixed-English JSON, except report read ID prints the Report language text.
    Registration IDs are emitted to stderr before dispatch; retain them to check the original result.
    Exit codes: 0 succeeded/resolved, 2 usage, 3 authentication,
    4 rejected, 5 transport, 10 accepted/resolving, 11 approval required, 12 needs attention,
    13 failed, 14 partial, 15 unknown, 16 cancellation requested.
    """)

    0
  end

  defp config_path(runtime_options), do: runtime_options[:config_path] || Config.path()
  defp request_options(runtime_options), do: runtime_options[:request_options] || []

  defp version do
    :skopos
    |> Application.spec(:vsn)
    |> to_string()
  end
end
