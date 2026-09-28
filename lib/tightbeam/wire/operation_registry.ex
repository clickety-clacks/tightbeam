defmodule Tightbeam.Wire.OperationRegistry do
  @moduledoc """
  Finite HTTP method/template operations for the current 0.1.9 router.

  The source check compares declared routes and rows in both directions. The
  PO's att_32a752d1 retains semantic names while adding agent/terminal and the
  current work-items parameter spelling. Concrete URLs never become labels.
  CLI command identity and allowed paths are implemented separately in Rust.
  """

  # The same form `Tightbeam.DB` requires of a DB operation: dotted lowercase
  # segments, so a registry cannot smuggle free text into an operator's record.
  @operation_form ~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/

  # Module-level route macros only. A deeper indent is a route built inside a
  # function or a test, which is not the wire contract.
  @route_declaration ~r/^  (get|post|patch|put|delete|head|options) "([^"]+)"/m

  @http_rows [
    {{"GET", "/"}, "http.root"},
    {{"GET", "/ws"}, "http.ws"},
    {{"GET", "/ws/changes"}, "http.ws_changes"},
    {{"GET", "/version"}, "http.version"},
    {{"GET", "/harnesses"}, "http.harnesses"},
    {{"POST", "/agent/dispatch"}, "http.agent_dispatch"},
    {{"POST", "/agent/terminal"}, "http.agent_terminal"},
    {{"POST", "/agent/tool-call-observed"}, "http.agent_tool_call_observed"},
    {{"GET", "/api/streams"}, "http.api_streams.list"},
    {{"GET", "/api/org-options"}, "http.api_org_options.get"},
    {{"GET", "/api/trackable-sessions"}, "http.api_trackable_sessions.list"},
    {{"GET", "/api/config"}, "http.api_config.list"},
    {{"GET", "/api/config/:key"}, "http.api_config.get"},
    {{"GET", "/api/host-env"}, "http.api_host_env.list"},
    {{"GET", "/api/hosts"}, "http.api_hosts.list"},
    {{"GET", "/api/hosts/:host"}, "http.api_hosts.get"},
    {{"GET", "/api/users"}, "http.api_users.list"},
    {{"GET", "/api/users/:user_id"}, "http.api_users.get"},
    {{"GET", "/api/identity"}, "http.api_identity.list"},
    {{"GET", "/api/identity/:name"}, "http.api_identity.get"},
    {{"GET", "/api/kungfu"}, "http.api_kungfu.list"},
    {{"GET", "/api/kungfu/:name"}, "http.api_kungfu.get"},
    {{"GET", "/api/assignments/:assignment_id"}, "http.api_assignments.get"},
    {{"GET", "/api/wakes/:wake_id"}, "http.api_wakes.get"},
    {{"GET", "/api/turns/:turn_seq"}, "http.api_turns.get"},
    {{"GET", "/api/decision-requests/:decision_request_id"}, "http.api_decision_requests.get"},
    {{"GET", "/api/sessions/:session_key"}, "http.api_sessions.get"},
    {{"GET", "/api/sessions/:session_key/messages"}, "http.api_sessions.messages.list"},
    {{"GET", "/api/sessions/:session_key/turns"}, "http.api_sessions.turns.list"},
    {{"GET", "/api/sessions/:session_key/wakes"}, "http.api_sessions.wakes.list"},
    {{"GET", "/api/devices/:device_id"}, "http.api_devices.get"},
    {{"GET", "/api/artifacts/:artifact_id"}, "http.api_artifacts.get"},
    {{"GET", "/api/read-markers/:scope_key"}, "http.api_read_markers.get"},
    {{"POST", "/api/streams"}, "http.api_streams.create"},
    {{"PATCH", "/api/streams/:key"}, "http.api_streams.update"},
    {{"DELETE", "/api/streams/:key"}, "http.api_streams.delete"},
    {{"GET", "/api/session-status"}, "http.api_session_status.get"},
    {{"GET", "/api/work"}, "http.api_work.list"},
    {{"GET", "/api/work/:id"}, "http.api_work.get"},
    {{"GET", "/api/work-items"}, "http.api_work_items.list"},
    {{"GET", "/api/work-items/:id"}, "http.api_work_items.get"},
    {{"POST", "/api/session-control"}, "http.api_session_control"},
    {{"POST", "/upload"}, "http.upload"},
    {{"GET", "/download/:asset_id"}, "http.download_asset"},
    {:unmatched, "http.not_found"}
  ]

  @type key :: {String.t(), String.t()}
  @type row :: {key() | :unmatched, String.t()}
  @type finding ::
          {:unmapped_source, key()}
          | {:orphan_row, key()}
          | {:duplicate_row, key()}
          | {:malformed_operation, key() | :unmatched, term()}

  @doc "The closed HTTP rows."
  @spec rows(:http) :: {:ok, [row()]}
  def rows(:http), do: {:ok, @http_rows}

  @http_lookup Map.new(@http_rows)
  def http(method, template) do
    Map.get(@http_lookup, {method, template}, Map.fetch!(@http_lookup, :unmatched))
  end

  @doc """
  Compare a registry against the keys measured from source.

  Returns `:ok` only when every measured key maps to exactly one row and every
  row except `:unmatched` maps to a measured key.
  """
  @spec check([row()], [key()]) :: :ok | {:error, [finding()]}
  def check(rows, observed) when is_list(rows) and is_list(observed) do
    keys = Enum.map(rows, fn {key, _operation} -> key end)
    mapped = MapSet.new(keys)
    measured = MapSet.new(observed)

    duplicates =
      keys
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(fn {key, _count} -> {:duplicate_row, key} end)

    unmapped =
      observed
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(mapped, &1))
      |> Enum.map(&{:unmapped_source, &1})

    # `:unmatched` is the row for a request that matched no route, so it has no
    # template in source and cannot be an orphan. Every other row must answer
    # for a route that exists.
    orphans =
      keys
      |> Enum.uniq()
      |> Enum.reject(&(&1 == :unmatched or MapSet.member?(measured, &1)))
      |> Enum.map(&{:orphan_row, &1})

    malformed =
      for {key, operation} <- rows,
          not (is_binary(operation) and Regex.match?(@operation_form, operation)),
          do: {:malformed_operation, key, operation}

    case duplicates ++ unmapped ++ orphans ++ malformed do
      [] -> :ok
      findings -> {:error, Enum.sort(findings)}
    end
  end

  @doc """
  Run one registry's check against the keys measured from its source.

  """
  @spec check_source(:http, [key()]) :: :ok | {:error, [finding()]}
  def check_source(:http, observed) when is_list(observed), do: check(@http_rows, observed)

  @doc """
  Measure the method/template pairs the router declares.

  Measures the declarations, independently of runtime lookup through Plug's
  matched template. A scan that measures nothing is an error: an empty list
  would make every row an orphan and read as a registry problem.
  """
  @spec router_routes(Path.t()) :: {:ok, [key()]} | {:error, term()}
  def router_routes(source \\ Path.expand("router.ex", __DIR__)) do
    with {:ok, text} <- read(source),
         {:ok, routes} <- scan_routes(text, source) do
      {:ok, routes}
    end
  end

  defp read(source) do
    case File.read(source) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:unreadable_source, source, reason}}
    end
  end

  defp scan_routes(text, source) do
    case Regex.scan(@route_declaration, text) do
      [] ->
        {:error, {:no_routes_measured, source}}

      matches ->
        {:ok,
         Enum.map(matches, fn [_all, method, template] -> {String.upcase(method), template} end)}
    end
  end
end
