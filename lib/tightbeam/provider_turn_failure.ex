defmodule Tightbeam.ProviderTurnFailure do
  @moduledoc """
  Immutable, redacted evidence for an ordinary failed provider turn.

  The row is keyed by the durable turn sequence. It adds observation to the
  existing turn state machine and never changes health, recovery, retry, or
  credential behavior. Raw provider errors and credential bytes never cross
  this boundary.
  """

  alias Tightbeam.{Credentials, DB, Harness, HarnessProcess}
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS provider_turn_failures (
    turnSeq                    INTEGER PRIMARY KEY REFERENCES turns(seq),
    capturedAt                 INTEGER NOT NULL CHECK(capturedAt >= 0),
    stage                      TEXT NOT NULL CHECK(stage IN ('checkout','session','prompt')),
    acpRequestId               INTEGER,
    launchId                   TEXT REFERENCES harness_processes(launchId),
    launchSequence             INTEGER,
    upstreamHttpStatus         INTEGER CHECK(upstreamHttpStatus BETWEEN 100 AND 599),
    upstreamErrorClass         TEXT CHECK(upstreamErrorClass IS NULL OR length(upstreamErrorClass) BETWEEN 1 AND 96),
    upstreamRequestId          TEXT CHECK(upstreamRequestId IS NULL OR length(upstreamRequestId) BETWEEN 1 AND 128),
    credentialCapturedAt       INTEGER NOT NULL CHECK(credentialCapturedAt >= 0),
    credentialProvider         TEXT NOT NULL CHECK(length(credentialProvider) BETWEEN 1 AND 32),
    credentialProvenance       TEXT NOT NULL CHECK(credentialProvenance IN ('credential-metadata','credential-metadata-unavailable')),
    credentialAvailable        INTEGER NOT NULL CHECK(credentialAvailable IN (0,1)),
    credentialTerminal         INTEGER CHECK(credentialTerminal IN (0,1)),
    credentialLastHealth       TEXT CHECK(credentialLastHealth IS NULL OR length(credentialLastHealth) <= 64),
    credentialInitialAuthNoneIgnored INTEGER CHECK(credentialInitialAuthNoneIgnored IN (0,1)),
    buildCapturedAt            INTEGER,
    buildProvenance            TEXT,
    buildJson                  TEXT CHECK(buildJson IS NULL OR length(buildJson) BETWEEN 2 AND 4096)
  );
  CREATE TRIGGER IF NOT EXISTS provider_turn_failure_immutable_update
  BEFORE UPDATE ON provider_turn_failures
  BEGIN
    SELECT RAISE(ABORT, 'provider turn failure evidence is immutable');
  END;
  CREATE TRIGGER IF NOT EXISTS provider_turn_failure_immutable_delete
  BEFORE DELETE ON provider_turn_failures
  BEGIN
    SELECT RAISE(ABORT, 'provider turn failure evidence is immutable');
  END;
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Capture fixed, non-secret values at the failure boundary, before terminal commit."
  @spec capture(map(), atom(), term()) :: map()
  def capture(session, stage, reason) when stage in [:checkout, :session, :prompt] do
    captured_at = System.system_time(:millisecond)
    module = harness_module!(session.harness)
    provider = module.credential_provider()
    health = credential_health(provider, session.host)

    %{
      captured_at: captured_at,
      stage: Atom.to_string(stage),
      harness: to_string(session.harness),
      host: session.host,
      upstream: safe_upstream(reason),
      credential: %{
        captured_at: captured_at,
        provider: Atom.to_string(provider),
        available: Map.get(health, :available, false) == true,
        terminal: redacted_boolean(Map.get(health, :terminal)),
        last_health: redacted_last_health(Map.get(health, :last_health)),
        initial_auth_none_ignored: redacted_boolean(Map.get(health, :initial_auth_none_ignored))
      }
    }
  end

  @doc "Insert one failure snapshot in the same transaction as the terminal turn."
  @spec record_in_txn(Txn.t(), pos_integer(), map()) :: :ok
  def record_in_txn(%Txn{} = txn, turn_seq, snapshot) do
    launch = HarnessProcess.failure_launch_in_txn(txn, snapshot.harness, snapshot.host)
    request_id = acp_request_id(txn, turn_seq)
    upstream = snapshot.upstream
    credential = snapshot.credential

    Txn.q(
      txn,
      """
      INSERT INTO provider_turn_failures
        (turnSeq,capturedAt,stage,acpRequestId,launchId,launchSequence,
         upstreamHttpStatus,upstreamErrorClass,upstreamRequestId,
         credentialCapturedAt,credentialProvider,credentialProvenance,
         credentialAvailable,credentialTerminal,credentialLastHealth,
         credentialInitialAuthNoneIgnored,buildCapturedAt,buildProvenance,buildJson)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)
      """,
      [
        turn_seq,
        snapshot.captured_at,
        snapshot.stage,
        request_id,
        launch && launch.launch_id,
        launch && launch.launch_sequence,
        upstream.http_status,
        upstream.error_class,
        upstream.request_id,
        credential.captured_at,
        credential.provider,
        if(credential.available,
          do: "credential-metadata",
          else: "credential-metadata-unavailable"
        ),
        boolean_column(credential.available),
        boolean_column(credential.terminal),
        credential.last_health,
        boolean_column(credential.initial_auth_none_ignored),
        launch && launch.build_captured_at,
        launch && launch.build_provenance,
        launch && launch.build && JSON.encode!(launch.build)
      ]
    )

    :ok
  end

  @doc "Read the redacted snapshot for one already-authorized turn."
  @spec read(DB.server(), pos_integer()) :: map() | nil
  def read(db, turn_seq) do
    case DB.query(
           db,
           """
           SELECT capturedAt,stage,acpRequestId,launchId,launchSequence,
                  upstreamHttpStatus,upstreamErrorClass,upstreamRequestId,
                  credentialCapturedAt,credentialProvider,credentialProvenance,
                  credentialAvailable,credentialTerminal,credentialLastHealth,
                  credentialInitialAuthNoneIgnored,buildCapturedAt,buildProvenance,buildJson
           FROM provider_turn_failures WHERE turnSeq=?1
           """,
           [turn_seq]
         ) do
      {:ok,
       [
         [
           captured_at,
           stage,
           acp_request_id,
           launch_id,
           launch_sequence,
           http_status,
           error_class,
           request_id,
           credential_captured_at,
           credential_provider,
           credential_provenance,
           credential_available,
           credential_terminal,
           credential_last_health,
           credential_initial_none,
           build_captured_at,
           build_provenance,
           build_json
         ]
       ]} ->
        %{
          captured_at: captured_at,
          stage: stage,
          correlation: %{
            turn_seq: turn_seq,
            acp_request_id: acp_request_id,
            launch_id: launch_id,
            launch_sequence: launch_sequence
          },
          upstream: %{
            http_status: http_status,
            error_class: error_class,
            request_id: request_id
          },
          credential_health: %{
            captured_at: credential_captured_at,
            provider: credential_provider,
            provenance: credential_provenance,
            available: credential_available == 1,
            terminal: decode_boolean(credential_terminal),
            last_health: credential_last_health,
            initial_auth_none_ignored: decode_boolean(credential_initial_none)
          },
          loaded_build: %{
            captured_at: build_captured_at,
            provenance: build_provenance,
            identity: decode_json(build_json)
          }
        }

      {:ok, []} ->
        nil
    end
  end

  defp harness_module!(harness) when is_binary(harness), do: Harness.parse!(harness)
  defp harness_module!(harness), do: Harness.module!(harness)

  defp credential_health(provider, host) do
    Credentials.health_snapshot(provider, Credentials.server(host))
  catch
    :exit, _reason ->
      %{available: false, terminal: nil, last_health: nil, initial_auth_none_ignored: nil}
  end

  defp safe_upstream(reason) do
    %{
      http_status:
        find_integer(reason, ~w(httpStatus http_status statusCode status_code), 100..599),
      error_class: upstream_error_class(reason),
      request_id: find_safe_string(reason, ~w(requestId request_id request-id x-request-id), 128)
    }
  end

  defp upstream_error_class(reason) do
    cond do
      status = find_integer(reason, ~w(httpStatus http_status statusCode status_code), 100..599) ->
        "http:#{status}"

      code = find_integer(reason, ~w(code), -99_999..99_999) ->
        "acp_code:#{code}"

      kind = find_safe_string(reason, ~w(errorKind error_kind), 64) ->
        "provider:#{kind}"

      true ->
        "provider_error"
    end
  end

  defp find_integer(value, keys, range) when is_map(value) do
    direct =
      Enum.find_value(keys, fn key ->
        candidate = Map.get(value, key) || Map.get(value, safe_existing_atom(key))
        if is_integer(candidate) and candidate in range, do: candidate
      end)

    direct || Enum.find_value(Map.values(value), &find_integer(&1, keys, range))
  end

  defp find_integer(value, keys, range) when is_tuple(value),
    do: value |> Tuple.to_list() |> find_integer(keys, range)

  defp find_integer(value, keys, range) when is_list(value),
    do: Enum.find_value(value, &find_integer(&1, keys, range))

  defp find_integer(_value, _keys, _range), do: nil

  defp find_safe_string(value, keys, max) when is_map(value) do
    direct =
      Enum.find_value(keys, fn key ->
        candidate = Map.get(value, key) || Map.get(value, safe_existing_atom(key))
        if safe_identity?(candidate, max), do: candidate
      end)

    direct || Enum.find_value(Map.values(value), &find_safe_string(&1, keys, max))
  end

  defp find_safe_string(value, keys, max) when is_tuple(value),
    do: value |> Tuple.to_list() |> find_safe_string(keys, max)

  defp find_safe_string(value, keys, max) when is_list(value),
    do: Enum.find_value(value, &find_safe_string(&1, keys, max))

  defp find_safe_string(_value, _keys, _max), do: nil

  defp safe_identity?(value, max) when is_binary(value) and byte_size(value) <= max,
    do: Regex.match?(~r/\A[A-Za-z0-9._:\/-]+\z/, value)

  defp safe_identity?(_value, _max), do: false

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__provider_failure_missing_key__
  end

  defp acp_request_id(txn, turn_seq) do
    case Txn.q(
           txn,
           """
           SELECT acpRequestId FROM turn_lifecycle_events
           WHERE turnSeq=?1 AND kind='prompt_dispatched'
           ORDER BY ordinal DESC LIMIT 1
           """,
           [turn_seq]
         ) do
      [[request_id]] -> request_id
      [] -> nil
    end
  end

  defp redacted_boolean(value) when is_boolean(value), do: value
  defp redacted_boolean(_value), do: nil

  defp redacted_last_health(value)
       when value in ["onboarded", "revoked", "no_subscription", "present_but_unverified"],
       do: value

  defp redacted_last_health(nil), do: nil
  defp redacted_last_health(_value), do: "other"
  defp boolean_column(true), do: 1
  defp boolean_column(false), do: 0
  defp boolean_column(nil), do: nil
  defp decode_boolean(1), do: true
  defp decode_boolean(0), do: false
  defp decode_boolean(nil), do: nil
  defp decode_json(nil), do: nil
  defp decode_json(value), do: JSON.decode!(value)
end
