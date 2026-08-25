defmodule Tightbeam.ColdStart do
  @moduledoc """
  Owns the gateway-serialized transition from an empty identity graph to its
  first canonical user, credential, and personal Main.

  Every decision and write in a claim runs on the `Tightbeam.DB` owner.  The
  socket and CLI are transports only.
  """

  require Logger

  alias Tightbeam.{DB, Devices, EventLog, Org}
  alias Tightbeam.DB.Txn

  @recovery "Recover an unusable fresh database"
  @principal "process:tightbeam"
  @replay_domain "tightbeam-cold-start-replay-v1"
  @token_domain "tightbeam-cold-start-token-v1"

  defmodule ClaimError do
    @moduledoc false
    defexception [:code, :message, :counts]
  end

  @ddl """
  CREATE TABLE IF NOT EXISTS cold_start_receipts (
    id                 INTEGER PRIMARY KEY CHECK (id = 1),
    userId             TEXT NOT NULL REFERENCES users(userId),
    deviceId           TEXT REFERENCES devices(deviceId),
    rootSessionKey     TEXT NOT NULL REFERENCES sessions(sessionKey),
    cause              TEXT NOT NULL CHECK (cause IN (
      'first_device_pair','gateway_local_bootstrap','v5_observed'
    )),
    phase              TEXT NOT NULL CHECK (phase IN ('reserved','complete')),
    principal          TEXT NOT NULL CHECK (principal = 'process:tightbeam'),
    requestFingerprint BLOB,
    replaySecretHash   BLOB,
    claimTokenHash     BLOB,
    claimEventId       INTEGER REFERENCES events(id),
    deviceEventId      INTEGER REFERENCES events(id),
    createdAt          INTEGER NOT NULL CHECK (createdAt >= 0),
    activatedAt        INTEGER CHECK (activatedAt >= 0),
    CHECK (replaySecretHash IS NULL OR length(replaySecretHash) = 32),
    CHECK (claimTokenHash IS NULL OR length(claimTokenHash) = 32),
    CHECK (
      (cause = 'gateway_local_bootstrap' AND phase = 'reserved' AND
       deviceId IS NULL AND requestFingerprint IS NULL AND replaySecretHash IS NULL AND
       claimTokenHash IS NULL AND claimEventId IS NOT NULL AND deviceEventId IS NULL AND
       activatedAt IS NULL)
      OR
      (cause = 'gateway_local_bootstrap' AND phase = 'complete' AND
       deviceId IS NOT NULL AND requestFingerprint IS NOT NULL AND
       claimTokenHash IS NOT NULL AND claimEventId IS NOT NULL AND deviceEventId IS NOT NULL)
      OR
      (cause = 'first_device_pair' AND phase = 'complete' AND
       deviceId IS NOT NULL AND requestFingerprint IS NOT NULL AND
       claimTokenHash IS NOT NULL AND claimEventId IS NOT NULL AND deviceEventId IS NULL)
      OR
      (cause = 'v5_observed' AND phase = 'complete' AND deviceId IS NOT NULL AND
       requestFingerprint IS NULL AND replaySecretHash IS NULL AND claimTokenHash IS NULL AND
       claimEventId IS NULL AND deviceEventId IS NULL AND activatedAt IS NOT NULL)
    )
  );
  """

  @doc false
  def receipt_ddl, do: @ddl

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Decode the optional replay proof before opening a claim transaction."
  @spec decode_replay_secret(nil | String.t()) ::
          {:ok, nil | binary()} | {:error, :invalid_message}
  def decode_replay_secret(nil), do: {:ok, nil}

  def decode_replay_secret(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, secret} when byte_size(secret) == 32 -> {:ok, secret}
      _ -> {:error, :invalid_message}
    end
  end

  def decode_replay_secret(_), do: {:error, :invalid_message}

  @doc "Pair through the single cold-start coordinator transaction."
  @spec pair(DB.server(), map(), map()) ::
          Devices.pair_outcome() | {:error, String.t()}
  def pair(db \\ Tightbeam.DB, input, defaults) do
    defaults = Org.resolve_personal_main_defaults(defaults)

    case DB.transaction(db, fn txn -> pair_in_txn(txn, input, defaults) end) do
      {:ok, result} ->
        result

      {:error, %ClaimError{code: code, counts: counts}} ->
        log_claim_failure(code, input, counts, "rolled_back")
        {:error, code}

      {:error, error} ->
        log_claim_failure("bootstrap_failed", input, counts(db), "rolled_back")
        Logger.debug("cold-start failure class=#{inspect(error_class(error))}")
        {:error, "bootstrap_failed"}
    end
  end

  @doc false
  def pair_in_txn(%Txn{} = txn, input, defaults) do
    case classify_in_txn(txn) do
      %{state: "open"} ->
        first_pair_in_txn(txn, input, defaults)

      %{state: "reserved", receipt: receipt} ->
        complete_reserved_in_txn(txn, receipt, input)

      %{state: "claimed", receipt: receipt} ->
        pair_claimed_in_txn(txn, receipt, input)

      %{state: "incomplete", counts: graph_counts} ->
        claim_error!("bootstrap_incomplete", graph_counts)
    end
  end

  @doc "Reserve the first canonical user and Main for a loopback CLI request."
  @spec bootstrap_user(DB.server(), String.t(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def bootstrap_user(db \\ Tightbeam.DB, user_id, defaults) do
    defaults = Org.resolve_personal_main_defaults(defaults)

    case DB.transaction(db, fn txn -> bootstrap_user_in_txn(txn, user_id, defaults) end) do
      {:ok, result} ->
        {:ok, result}

      {:error, %ClaimError{code: code, counts: graph_counts}} ->
        log_claim_failure(code, %{device_id: nil}, graph_counts, "rolled_back")
        {:error, code}

      {:error, error} ->
        log_claim_failure("bootstrap_failed", %{device_id: nil}, counts(db), "rolled_back")
        Logger.debug("cold-start failure class=#{inspect(error_class(error))}")
        {:error, "bootstrap_failed"}
    end
  end

  @doc false
  def bootstrap_user_in_txn(%Txn{} = txn, user_id, defaults) do
    user_id = validate_user_id!(user_id)

    case classify_in_txn(txn) do
      %{state: "open"} ->
        reserve_user_in_txn(txn, user_id, defaults)

      %{state: "reserved", receipt: %{user_id: ^user_id} = receipt} ->
        bootstrap_result(receipt)

      %{state: "reserved"} ->
        claim_error!("bootstrap_closed")

      %{state: "claimed"} ->
        claim_error!("bootstrap_closed")

      %{state: "incomplete", counts: graph_counts} ->
        claim_error!("bootstrap_incomplete", graph_counts)
    end
  end

  @doc "Return the secret-free compatible cold-start state."
  @spec state(DB.server()) :: map()
  def state(db \\ Tightbeam.DB) do
    case DB.transaction(db, &classify_in_txn/1) do
      {:ok, %{state: "open"}} ->
        %{"state" => "open", "action" => "choose pair-first or host-local bootstrap"}

      {:ok, %{state: "reserved", receipt: receipt}} ->
        %{
          "state" => "reserved",
          "cause" => receipt.cause,
          "userId" => receipt.user_id,
          "rootSessionKey" => receipt.root_session_key,
          "action" => "pair the first client with the reserved user"
        }

      {:ok, %{state: "claimed", receipt: receipt}} ->
        %{
          "state" => "claimed",
          "cause" => receipt.cause,
          "userId" => receipt.user_id,
          "deviceId" => receipt.device_id,
          "rootSessionKey" => receipt.root_session_key,
          "activated" => not is_nil(receipt.activated_at)
        }

      {:ok, %{state: "incomplete", invariant: invariant}} ->
        raise Tightbeam.Schema.ShapeError,
          message: "incompatible_cold_start_v1: #{invariant}; recovery: #{@recovery}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def validate!(db \\ Tightbeam.DB) do
    case DB.transaction(db, &classify_in_txn/1) do
      {:ok, %{state: state}} when state in ["open", "reserved", "claimed"] ->
        :ok

      {:ok, %{state: "incomplete", invariant: invariant}} ->
        raise Tightbeam.Schema.ShapeError,
          message: "incompatible_cold_start_v1: #{invariant}; recovery: #{@recovery}"

      {:error, %Tightbeam.Schema.ShapeError{} = error} ->
        raise error

      {:error, error} ->
        raise error
    end
  end

  @doc "Authenticate and mark the first credential activated in the same transaction."
  def authenticate(db \\ Tightbeam.DB, token) do
    case DB.transaction(db, fn txn ->
           case Devices.get_device_by_token_in_txn(txn, token) do
             nil ->
               nil

             device ->
               Txn.q(
                 txn,
                 "UPDATE cold_start_receipts SET activatedAt = COALESCE(activatedAt, ?2) WHERE id = 1 AND deviceId = ?1",
                 [device.device_id, now()]
               )

               device
           end
         end) do
      {:ok, device} -> device
      {:error, error} -> raise error
    end
  end

  @doc false
  def classify_in_txn(%Txn{} = txn) do
    graph_counts = counts_in_txn(txn)
    receipts = receipt_rows(txn)

    cond do
      orphan_identity?(txn) ->
        %{state: "incomplete", counts: graph_counts, invariant: "orphan_identity_row"}

      graph_counts.users == 0 and receipts == [] ->
        %{state: "open", counts: graph_counts}

      receipts == [] ->
        %{state: "incomplete", counts: graph_counts, invariant: "receiptless_nonempty_users"}

      length(receipts) != 1 ->
        %{state: "incomplete", counts: graph_counts, invariant: "receipt_phase_invalid"}

      true ->
        classify_receipt(txn, hd(receipts), graph_counts)
    end
  end

  defp first_pair_in_txn(txn, input, defaults) do
    [[0]] = Txn.q(txn, "SELECT COUNT(*) FROM users")
    user_id = Devices.slug_user_id(Map.fetch!(input, :claimed_name))
    Devices.insert_user_in_txn(txn, user_id, true, "cold_start")
    maybe_fail!(input, 1)
    token = Devices.mint_token()

    device =
      Devices.insert_device_in_txn(txn, Map.put(input, :user_id, user_id), "allowlisted", token)

    maybe_fail!(input, 2)
    root = Org.ensure_personal_main_in_txn(txn, user_id, Map.put(defaults, :origin, @principal))
    maybe_fail!(input, 3)
    ts = now()
    fingerprint = fingerprint(device.device_id, user_id)

    event_id =
      cold_start_event(
        txn,
        "cold-start",
        "first_device_pair",
        "complete",
        user_id,
        device,
        root,
        ts
      )

    maybe_fail!(input, 4)

    Txn.q(
      txn,
      """
      INSERT INTO cold_start_receipts
        (id,userId,deviceId,rootSessionKey,cause,phase,principal,requestFingerprint,
         replaySecretHash,claimTokenHash,claimEventId,deviceEventId,createdAt,activatedAt)
      VALUES (1,?1,?2,?3,'first_device_pair','complete',?4,?5,?6,?7,?8,NULL,?9,NULL)
      """,
      [
        user_id,
        device.device_id,
        root.session_key,
        @principal,
        blob(fingerprint),
        blob(replay_hash(input[:replay_secret])),
        blob(token_hash(token)),
        event_id,
        ts
      ]
    )

    maybe_fail!(input, 5)
    assert_complete!(txn, user_id, device.device_id, root.session_key)
    {:paired, device}
  end

  defp reserve_user_in_txn(txn, user_id, defaults) do
    [[0]] = Txn.q(txn, "SELECT COUNT(*) FROM users")
    Devices.insert_user_in_txn(txn, user_id, true, "gateway_local_bootstrap")
    root = Org.ensure_personal_main_in_txn(txn, user_id, Map.put(defaults, :origin, @principal))
    ts = now()

    event_id =
      cold_start_event(
        txn,
        "cold-start",
        "gateway_local_bootstrap",
        "reserved",
        user_id,
        nil,
        root,
        ts
      )

    Txn.q(
      txn,
      """
      INSERT INTO cold_start_receipts
        (id,userId,deviceId,rootSessionKey,cause,phase,principal,requestFingerprint,
         replaySecretHash,claimTokenHash,claimEventId,deviceEventId,createdAt,activatedAt)
      VALUES (1,?1,NULL,?2,'gateway_local_bootstrap','reserved',?3,NULL,NULL,NULL,?4,NULL,?5,NULL)
      """,
      [user_id, root.session_key, @principal, event_id, ts]
    )

    bootstrap_result(receipt_in_txn(txn))
  end

  defp complete_reserved_in_txn(txn, receipt, input) do
    user_id = Devices.slug_user_id(Map.fetch!(input, :claimed_name))
    if user_id != receipt.user_id, do: claim_error!("bootstrap_closed")

    token = Devices.mint_token()

    device =
      Devices.insert_device_in_txn(txn, Map.put(input, :user_id, user_id), "allowlisted", token)

    root = Org.get_in_txn(txn, receipt.root_session_key)
    ts = now()

    event_id =
      cold_start_event(
        txn,
        "cold-start-device",
        receipt.cause,
        "complete",
        user_id,
        device,
        root,
        ts
      )

    Txn.q(
      txn,
      """
      UPDATE cold_start_receipts SET phase='complete', deviceId=?1, requestFingerprint=?2,
        replaySecretHash=?3, claimTokenHash=?4, deviceEventId=?5
      WHERE id=1 AND phase='reserved'
      """,
      [
        device.device_id,
        blob(fingerprint(device.device_id, user_id)),
        blob(replay_hash(input[:replay_secret])),
        blob(token_hash(token)),
        event_id
      ]
    )

    if Txn.changes(txn) != 1, do: claim_error!("bootstrap_closed")
    assert_complete!(txn, user_id, device.device_id, receipt.root_session_key)
    {:paired, device}
  end

  defp pair_claimed_in_txn(txn, receipt, input) do
    device_id = Map.fetch!(input, :device_id)
    user_id = Devices.slug_user_id(Map.fetch!(input, :claimed_name))

    cond do
      is_nil(receipt.activated_at) and device_id == receipt.device_id ->
        if fingerprint(device_id, user_id) == receipt.request_fingerprint do
          replay_or_refuse(txn, receipt, input[:replay_secret])
        else
          {:error, "bootstrap_closed"}
        end

      true ->
        Devices.pair_in_txn(txn, input)
    end
  end

  defp replay_or_refuse(txn, receipt, secret) do
    case Devices.get_device_in_txn(txn, receipt.device_id) do
      %{status: "denied"} ->
        :denied

      %{status: "allowlisted", token: token} = device when is_binary(token) ->
        proof = replay_hash(secret)

        if is_binary(proof) and is_binary(receipt.replay_secret_hash) and
             Plug.Crypto.secure_compare(proof, receipt.replay_secret_hash) and
             Plug.Crypto.secure_compare(token_hash(token), receipt.claim_token_hash) do
          {:paired, device}
        else
          {:error, "bootstrap_closed"}
        end

      _ ->
        {:error, "bootstrap_closed"}
    end
  end

  defp cold_start_event(txn, verb, cause, phase, user_id, device, root, ts) do
    EventLog.append_event_in_txn(
      txn,
      "verb",
      verb,
      @principal,
      root.session_key,
      %{
        "receiptId" => 1,
        "cause" => cause,
        "phase" => phase,
        "userId" => user_id,
        "deviceId" => device && device.device_id,
        "rootSessionKey" => root.session_key,
        "isAdmin" => true,
        "deviceStatus" => device && device.status,
        "rootKind" => root.kind,
        "operationalParent" => root.operational_parent
      },
      {:process, "tightbeam"},
      ts
    )
  end

  defp classify_receipt(txn, receipt, graph_counts) do
    user = Devices.get_user_in_txn(txn, receipt.user_id)
    root = Org.get_in_txn(txn, receipt.root_session_key)
    device = receipt.device_id && Devices.get_device_in_txn(txn, receipt.device_id)

    invariant =
      cond do
        receipt.cause not in ~w(first_device_pair gateway_local_bootstrap v5_observed) ->
          "receipt_cause_invalid"

        receipt.phase not in ~w(reserved complete) ->
          "receipt_phase_invalid"

        is_nil(user) ->
          "receipt_missing_user"

        is_nil(root) ->
          "receipt_missing_root"

        receipt.phase == "complete" and is_nil(device) ->
          "receipt_missing_device"

        device && device.user_id != receipt.user_id ->
          "receipt_owner_mismatch"

        not personal_main?(root, receipt.user_id) ->
          "root_not_personal_main"

        not event_referents_valid?(txn, receipt) ->
          "receipt_event_shape_invalid"

        not replay_shape_valid?(receipt) ->
          "receipt_replay_shape_invalid"

        true ->
          nil
      end

    if invariant do
      %{state: "incomplete", counts: graph_counts, invariant: invariant}
    else
      %{
        state: (receipt.phase == "reserved" && "reserved") || "claimed",
        receipt: receipt,
        counts: graph_counts
      }
    end
  end

  defp receipt_rows(txn) do
    Txn.q(txn, """
    SELECT id,userId,deviceId,rootSessionKey,cause,phase,principal,requestFingerprint,
           replaySecretHash,claimTokenHash,claimEventId,deviceEventId,createdAt,activatedAt
    FROM cold_start_receipts ORDER BY id
    """)
    |> Enum.map(&to_receipt/1)
  end

  defp receipt_in_txn(txn), do: receipt_rows(txn) |> List.first()

  defp to_receipt([
         id,
         user_id,
         device_id,
         root,
         cause,
         phase,
         principal,
         fingerprint,
         replay_hash,
         claim_hash,
         claim_event,
         device_event,
         created_at,
         activated_at
       ]) do
    %{
      id: id,
      user_id: user_id,
      device_id: device_id,
      root_session_key: root,
      cause: cause,
      phase: phase,
      principal: principal,
      request_fingerprint: fingerprint,
      replay_secret_hash: replay_hash,
      claim_token_hash: claim_hash,
      claim_event_id: claim_event,
      device_event_id: device_event,
      created_at: created_at,
      activated_at: activated_at
    }
  end

  defp counts(db) do
    case DB.transaction(db, &counts_in_txn/1) do
      {:ok, result} -> result
      _ -> %{users: -1, devices: -1, sessions: -1, receipts: -1}
    end
  end

  defp counts_in_txn(txn) do
    [[users, devices, sessions, receipts]] =
      Txn.q(txn, """
      SELECT (SELECT COUNT(*) FROM users), (SELECT COUNT(*) FROM devices),
             (SELECT COUNT(*) FROM sessions), (SELECT COUNT(*) FROM cold_start_receipts)
      """)

    %{users: users, devices: devices, sessions: sessions, receipts: receipts}
  end

  defp orphan_identity?(txn) do
    Txn.q(txn, """
    SELECT 1 FROM devices d LEFT JOIN users u ON u.userId=d.userId WHERE u.userId IS NULL
    UNION ALL
    SELECT 1 FROM sessions s LEFT JOIN users u ON u.userId=s.ownerUserId WHERE u.userId IS NULL
    LIMIT 1
    """) != []
  end

  defp personal_main?(root, user_id) do
    root.owner_user_id == user_id and root.session_key == Org.personal_session_key(user_id) and
      root.kind == "main" and root.is_built_in and root.operational_parent == root.session_key
  end

  defp event_referents_valid?(_txn, %{
         cause: "v5_observed",
         claim_event_id: nil,
         device_event_id: nil
       }),
       do: true

  defp event_referents_valid?(
         txn,
         %{
           cause: "first_device_pair",
           claim_event_id: id,
           device_event_id: nil
         } = receipt
       ) do
    accepted_event_valid?(
      txn,
      id,
      "cold-start",
      {:exact, receipt.created_at},
      event_payload(receipt, "complete", receipt.device_id)
    )
  end

  defp event_referents_valid?(
         txn,
         %{
           cause: "gateway_local_bootstrap",
           phase: "reserved",
           claim_event_id: id,
           device_event_id: nil
         } = receipt
       ) do
    accepted_event_valid?(
      txn,
      id,
      "cold-start",
      {:exact, receipt.created_at},
      event_payload(receipt, "reserved", nil)
    )
  end

  defp event_referents_valid?(
         txn,
         %{
           cause: "gateway_local_bootstrap",
           phase: "complete",
           claim_event_id: claim,
           device_event_id: device
         } = receipt
       ) do
    accepted_event_valid?(
      txn,
      claim,
      "cold-start",
      {:exact, receipt.created_at},
      event_payload(receipt, "reserved", nil)
    ) and
      accepted_event_valid?(
        txn,
        device,
        "cold-start-device",
        {:at_or_after, receipt.created_at},
        event_payload(receipt, "complete", receipt.device_id)
      )
  end

  defp event_referents_valid?(_txn, _receipt), do: false

  defp accepted_event_valid?(txn, id, verb, timestamp, expected_payload)
       when is_integer(id) do
    case Txn.q(
           txn,
           "SELECT ts,kind,verb,origin,principal,sessionKey,payload FROM events WHERE id=?1",
           [id]
         ) do
      [[ts, kind, actual_verb, origin, principal, session_key, payload]] ->
        valid_event_timestamp?(ts, timestamp) and kind == "verb" and actual_verb == verb and
          origin == @principal and principal == @principal and
          session_key == expected_payload["rootSessionKey"] and
          payload == inspect(expected_payload)

      _ ->
        false
    end
  end

  defp accepted_event_valid?(_txn, _id, _verb, _timestamp, _payload), do: false

  defp valid_event_timestamp?(ts, {:exact, expected}), do: ts == expected

  defp valid_event_timestamp?(ts, {:at_or_after, minimum}),
    do: is_integer(ts) and ts >= minimum

  defp event_payload(receipt, phase, device_id) do
    %{
      "receiptId" => 1,
      "cause" => receipt.cause,
      "phase" => phase,
      "userId" => receipt.user_id,
      "deviceId" => device_id,
      "rootSessionKey" => receipt.root_session_key,
      "isAdmin" => true,
      "deviceStatus" => device_id && "allowlisted",
      "rootKind" => "main",
      "operationalParent" => receipt.root_session_key
    }
  end

  defp replay_shape_valid?(%{
         cause: "v5_observed",
         request_fingerprint: nil,
         replay_secret_hash: nil,
         claim_token_hash: nil,
         activated_at: activated
       }),
       do: is_integer(activated)

  defp replay_shape_valid?(%{
         phase: "reserved",
         request_fingerprint: nil,
         replay_secret_hash: nil,
         claim_token_hash: nil,
         activated_at: nil
       }),
       do: true

  defp replay_shape_valid?(%{
         phase: "complete",
         request_fingerprint: fp,
         replay_secret_hash: replay,
         claim_token_hash: token
       }) do
    is_binary(fp) and byte_size(fp) == 32 and
      (is_nil(replay) or (is_binary(replay) and byte_size(replay) == 32)) and
      is_binary(token) and byte_size(token) == 32
  end

  defp replay_shape_valid?(_), do: false

  defp assert_complete!(txn, user_id, device_id, root_key) do
    user = Devices.get_user_in_txn(txn, user_id)
    device = Devices.get_device_in_txn(txn, device_id)
    root = Org.get_in_txn(txn, root_key)
    receipt = receipt_in_txn(txn)

    unless user && user.is_admin && device && device.status == "allowlisted" &&
             is_binary(device.token) && device.user_id == user_id && personal_main?(root, user_id) &&
             root.state == "active" && receipt && receipt.phase == "complete" &&
             receipt.device_id == device_id do
      claim_error!("bootstrap_failed")
    end
  end

  defp bootstrap_result(receipt) do
    %{
      receiptId: receipt.id,
      phase: receipt.phase,
      cause: receipt.cause,
      userId: receipt.user_id,
      rootSessionKey: receipt.root_session_key,
      isAdmin: true
    }
  end

  defp validate_user_id!(user_id) when is_binary(user_id) do
    normalized = String.trim(user_id)

    if normalized != "" and normalized == user_id,
      do: normalized,
      else: claim_error!("bootstrap_failed")
  end

  defp validate_user_id!(_), do: claim_error!("bootstrap_failed")

  defp fingerprint(device_id, user_id) do
    :crypto.hash(
      :sha256,
      ~s({"deviceId":#{JSON.encode!(device_id)},"userId":#{JSON.encode!(user_id)}})
    )
  end

  defp replay_hash(nil), do: nil
  defp replay_hash(secret) when is_binary(secret), do: domain_hash(@replay_domain, secret)
  defp token_hash(token), do: domain_hash(@token_domain, token)
  defp domain_hash(domain, value), do: :crypto.hash(:sha256, domain <> <<0>> <> value)
  defp blob(nil), do: nil
  defp blob(value) when is_binary(value), do: {:blob, value}

  defp claim_error!(code, counts \\ nil),
    do: raise(ClaimError, code: code, message: code, counts: counts)

  defp maybe_fail!(input, step),
    do: if(input[:fail_after] == step, do: raise("forced cold-start interruption"), else: :ok)

  defp now, do: System.system_time(:millisecond)

  defp error_class(%{__struct__: module}) when is_atom(module), do: module
  defp error_class(_error), do: :non_exception

  defp log_claim_failure(code, input, graph_counts, rollback) do
    Logger.error("cold-start claim failed",
      code: code,
      deviceId: input[:device_id],
      counts: inspect(graph_counts),
      rollback: rollback
    )
  end
end
