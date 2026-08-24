defmodule Tightbeam.AssignmentCommitRefCorrections do
  @moduledoc """
  Append-only canonical commit-ref corrections for closed historical assignments.

  A correction is not an attest and never changes assignment lifecycle state. It
  records who supplied a replacement canonical reference, why, the immutable
  evidence row supporting it, and the exact branch or tag that contained the
  commit when Tightbeam verified it.
  """

  alias Tightbeam.{DB, Placement}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Harness.Support

  @cause "historical_canonical_commitref_correction"

  @ddl """
  CREATE TABLE IF NOT EXISTS assignment_commit_ref_corrections (
    id                 TEXT PRIMARY KEY,
    assignmentId       TEXT NOT NULL UNIQUE REFERENCES assignments(id),
    commitRefs         TEXT NOT NULL CHECK (json_valid(commitRefs) AND json_type(commitRefs) = 'array'),
    reason             TEXT NOT NULL CHECK (length(trim(reason)) BETWEEN 1 AND 4000),
    evidenceArtifactId TEXT NOT NULL REFERENCES artifacts(artifactId),
    actorKind          TEXT NOT NULL CHECK (actorKind IN ('user','session')),
    actorRef           TEXT NOT NULL,
    cause              TEXT NOT NULL CHECK (cause = '#{@cause}'),
    idempotencyKey     TEXT NOT NULL CHECK (length(trim(idempotencyKey)) BETWEEN 1 AND 200),
    requestFingerprint TEXT NOT NULL CHECK (length(requestFingerprint) = 64),
    verifiedAt         INTEGER NOT NULL,
    createdAt          INTEGER NOT NULL,
    UNIQUE (actorKind, actorRef, idempotencyKey)
  );
  CREATE INDEX IF NOT EXISTS assignment_commit_ref_corrections_assignment
    ON assignment_commit_ref_corrections (assignmentId, createdAt, id);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  def __handle__(db, "assignment-commitref-correct", call), do: correct(db, call)

  @doc "List immutable corrections for one assignment in deterministic order."
  def list(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, commitRefs, reason, evidenceArtifactId,
               actorKind, actorRef, cause, idempotencyKey, verifiedAt, createdAt
        FROM assignment_commit_ref_corrections
        WHERE assignmentId = ?1
        ORDER BY createdAt, id
        """,
        [assignment_id]
      )

    Enum.map(rows, &correction/1)
  end

  defp correct(db, call) do
    params = Map.get(call, :params, %{})

    result =
      with {:ok, actor} <- actor(Map.get(call, :principal)),
           :ok <- valid_key(params[:idempotency_key]),
           :ok <- valid_reason(params[:reason]),
           :ok <- valid_artifact_id(params[:evidence_artifact_id]),
           {:ok, requested_refs} <- normalize_requested_refs(params[:commit_refs]),
           {:ok, prepared} <- prepare(db, call, actor, requested_refs) do
        case prepared do
          {:replay, row} ->
            %{correction: row}

          {:new, context} ->
            with {:ok, verified_refs} <- verify_refs(db, requested_refs) do
              verified_at = System.system_time(:millisecond)
              maybe_after_verify(call, db)
              commit(db, call, actor, context, verified_refs, verified_at)
            end
        end
      end

    case result do
      {:error, error} -> error
      result -> result
    end
  end

  defp prepare(db, call, actor, refs) do
    transaction(db, fn txn ->
      with {:ok, assignment_id} <- resolve_visible_assignment(txn, call, actor),
           {:ok, artifact_id} <- resolve_artifact(txn, call.params[:evidence_artifact_id]),
           {:ok, context} <- authorize_context(txn, actor, assignment_id, artifact_id),
           :ok <- require_closed(context) do
        fingerprint =
          fingerprint(%{
            assignmentId: assignment_id,
            commitRefs: refs,
            evidenceArtifactId: artifact_id,
            reason: call.params[:reason]
          })

        case replay(txn, actor, call.params[:idempotency_key], fingerprint) do
          {:ok, row} ->
            {:ok, {:replay, row}}

          :conflict ->
            {:error,
             error(
               "idempotency_conflict",
               "idempotency key conflicts with a prior correction request"
             )}

          :new ->
            {:ok, {:new, Map.merge(context, %{fingerprint: fingerprint})}}
        end
      end
    end)
  end

  defp commit(db, call, actor, context, verified_refs, verified_at) do
    transaction(db, fn txn ->
      with {:ok, current} <-
             authorize_context(
               txn,
               actor,
               context.assignment_id,
               context.evidence_artifact_id
             ) do
        case replay(txn, actor, call.params[:idempotency_key], context.fingerprint) do
          {:ok, row} ->
            %{correction: row}

          :conflict ->
            error(
              "idempotency_conflict",
              "idempotency key conflicts with a prior correction request"
            )

          :new ->
            cond do
              current.state != "closed" ->
                error(
                  "assignment_open",
                  "canonical commitRef corrections require a closed assignment"
                )

              correction_exists?(txn, context.assignment_id) ->
                error(
                  "correction_exists",
                  "assignment already has a canonical commitRef correction"
                )

              true ->
                id = "crc_" <> Tightbeam.Id.uuid4()
                created_at = System.system_time(:millisecond)

                Txn.q(
                  txn,
                  """
                  INSERT INTO assignment_commit_ref_corrections
                    (id, assignmentId, commitRefs, reason, evidenceArtifactId,
                     actorKind, actorRef, cause, idempotencyKey, requestFingerprint,
                     verifiedAt, createdAt)
                  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                  """,
                  [
                    id,
                    context.assignment_id,
                    JSON.encode!(verified_refs),
                    call.params[:reason],
                    context.evidence_artifact_id,
                    actor.kind,
                    actor.ref,
                    @cause,
                    call.params[:idempotency_key],
                    context.fingerprint,
                    verified_at,
                    created_at
                  ]
                )

                %{correction: fetch!(txn, id)}
            end
        end
      end
    end)
  end

  # Corrections are deliberately exact-id only. A caller outside the target's
  # product lane gets the same unknown result for an existing and absent id.
  defp resolve_visible_assignment(txn, call, actor) do
    supplied = call.params[:assignment_id]

    authorize_assignment(txn, actor, supplied)
    |> case do
      {:ok, _context} -> {:ok, supplied}
      {:error, _error} -> {:error, error("unknown_assignment", "unknown assignment: #{supplied}")}
    end
  end

  defp resolve_artifact(txn, supplied) do
    case Txn.q(txn, "SELECT artifactId FROM artifacts WHERE artifactId = ?1", [supplied]) do
      [[^supplied]] -> {:ok, supplied}
      [] -> {:error, error("invalid_evidence", "evidence artifact is unknown")}
    end
  end

  defp authorize_context(txn, actor, assignment_id, artifact_id) do
    with {:ok, context} <- authorize_assignment(txn, actor, assignment_id),
         :ok <- evidence_is_immutable(txn, artifact_id) do
      {:ok, Map.put(context, :evidence_artifact_id, artifact_id)}
    end
  end

  defp authorize_assignment(txn, actor, assignment_id) do
    case Txn.q(
           txn,
           """
           SELECT a.state, a.holderKey, a.workItemId, w.ownerUserId
           FROM assignments AS a
           LEFT JOIN work_items AS w ON w.id = a.workItemId
           WHERE a.id = ?1
           """,
           [assignment_id]
         ) do
      [] ->
        {:error, error("unknown_assignment", "unknown assignment: #{assignment_id}")}

      [[state, holder, work_item_id, owner_user_id]] ->
        context = %{
          assignment_id: assignment_id,
          state: state,
          holder: holder,
          work_item_id: work_item_id,
          owner_user_id: owner_user_id
        }

        if authorized?(txn, actor, context),
          do: {:ok, context},
          else: {:error, error("unknown_assignment", "unknown assignment: #{assignment_id}")}
    end
  end

  defp authorized?(_txn, _actor, %{work_item_id: nil}), do: false

  defp authorized?(_txn, %{kind: "user", ref: user}, %{owner_user_id: owner}),
    do: user == owner

  defp authorized?(txn, %{kind: "session", ref: caller}, %{holder: holder}) do
    case {product_owner_lane(txn, caller), product_owner_lane(txn, holder)} do
      {lane, lane} when is_binary(lane) -> true
      _ -> false
    end
  end

  defp product_owner_lane(txn, session_key) do
    case Txn.q(
           txn,
           """
           WITH RECURSIVE lineage(sessionKey, operationalParent, archetype, depth) AS (
             SELECT sessionKey, operationalParent, archetype, 0
             FROM sessions WHERE sessionKey = ?1
             UNION ALL
             SELECT parent.sessionKey, parent.operationalParent, parent.archetype, lineage.depth + 1
             FROM sessions AS parent
             JOIN lineage ON parent.sessionKey = lineage.operationalParent
             WHERE lineage.operationalParent != lineage.sessionKey AND lineage.depth < 100
           )
           SELECT sessionKey FROM lineage
           WHERE archetype = 'product-owner'
           ORDER BY depth ASC LIMIT 1
           """,
           [session_key]
         ) do
      [[lane]] -> lane
      _ -> nil
    end
  end

  # Historical backfill evidence can describe assignments across several work
  # items. The correction keeps the exact artifact id and its immutable hash as
  # provenance; it does not require synthetic copies on every target item.
  defp evidence_is_immutable(txn, artifact_id) do
    case Txn.q(
           txn,
           "SELECT contentSha256 FROM artifacts WHERE artifactId = ?1",
           [artifact_id]
         ) do
      [[sha]] when is_binary(sha) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
          do: :ok,
          else:
            {:error,
             error(
               "invalid_evidence",
               "evidence must be SHA-bound"
             )}

      _ ->
        {:error, error("invalid_evidence", "evidence must be SHA-bound")}
    end
  end

  defp require_closed(%{state: "closed"}), do: :ok

  defp require_closed(_context),
    do:
      {:error,
       error("assignment_open", "canonical commitRef corrections require a closed assignment")}

  defp replay(txn, actor, key, fingerprint) do
    case Txn.q(
           txn,
           """
           SELECT id, requestFingerprint
           FROM assignment_commit_ref_corrections
           WHERE actorKind = ?1 AND actorRef = ?2 AND idempotencyKey = ?3
           """,
           [actor.kind, actor.ref, key]
         ) do
      [] -> :new
      [[id, ^fingerprint]] -> {:ok, fetch!(txn, id)}
      [[_id, _other]] -> :conflict
    end
  end

  defp correction_exists?(txn, assignment_id) do
    Txn.q(txn, "SELECT 1 FROM assignment_commit_ref_corrections WHERE assignmentId = ?1", [
      assignment_id
    ]) == [[1]]
  end

  defp fetch!(txn, id) do
    [row] =
      Txn.q(
        txn,
        """
        SELECT id, assignmentId, commitRefs, reason, evidenceArtifactId,
               actorKind, actorRef, cause, idempotencyKey, verifiedAt, createdAt
        FROM assignment_commit_ref_corrections WHERE id = ?1
        """,
        [id]
      )

    correction(row)
  end

  defp correction([
         id,
         assignment_id,
         commit_refs,
         reason,
         evidence_artifact_id,
         actor_kind,
         actor_ref,
         cause,
         idempotency_key,
         verified_at,
         created_at
       ]) do
    %{
      id: id,
      assignmentId: assignment_id,
      commitRefs: JSON.decode!(commit_refs),
      reason: reason,
      evidenceArtifactId: evidence_artifact_id,
      actorKind: actor_kind,
      actorRef: actor_ref,
      cause: cause,
      idempotencyKey: idempotency_key,
      verifiedAt: verified_at,
      createdAt: created_at
    }
  end

  defp normalize_requested_refs(refs) when is_list(refs) and refs != [] do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case normalize_requested_ref(ref) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        sorted = Enum.sort_by(normalized, &{&1["repo"], &1["remote"], &1["ref"], &1["commit"]})

        if length(Enum.uniq(sorted)) == length(sorted),
          do: {:ok, sorted},
          else: {:error, error("invalid_commit_refs", "commitRefs must not contain duplicates")}

      error ->
        error
    end
  end

  defp normalize_requested_refs(_),
    do: {:error, error("invalid_commit_refs", "commitRefs must be a non-empty array")}

  defp normalize_requested_ref(ref) when is_map(ref) do
    normalized = Map.new(ref, fn {key, value} -> {to_string(key), value} end)

    with ["commit", "ref", "remote", "repo"] <- normalized |> Map.keys() |> Enum.sort(),
         commit when is_binary(commit) <- normalized["commit"],
         true <- Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit),
         ref_name when is_binary(ref_name) <- normalized["ref"],
         true <- Regex.match?(~r/\Arefs\/(?:heads|tags)\/[A-Za-z0-9._\/-]+\z/, ref_name),
         repo when is_binary(repo) <- normalized["repo"],
         [host, path] <- String.split(repo, ":", parts: 2),
         true <- host != "" and Path.type(path) == :absolute,
         remote when is_binary(remote) <- normalized["remote"],
         true <- String.trim(remote) != "" and byte_size(remote) <= 2000 do
      {:ok, normalized}
    else
      _ ->
        {:error,
         error(
           "invalid_commit_refs",
           "each commitRef requires exact repo, remote, ref, and commit fields"
         )}
    end
  end

  defp normalize_requested_ref(_),
    do: {:error, error("invalid_commit_refs", "each commitRef must be an object")}

  defp verify_refs(db, refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case verify_ref(db, ref) do
        {:ok, verified} -> {:cont, {:ok, [verified | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, Enum.reverse(verified)}
      error -> error
    end
  end

  defp verify_ref(db, ref) do
    [host, path] = String.split(ref["repo"], ":", parts: 2)

    with {:ok, remote} <- git_output(db, host, path, ["remote", "get-url", "origin"]),
         true <- remote == ref["remote"],
         {:ok, commit} <-
           git_output(db, host, path, ["rev-parse", "--verify", "#{ref["commit"]}^{commit}"]),
         true <- commit == ref["commit"],
         {:ok, ref_commit} <-
           git_output(db, host, path, ["rev-parse", "--verify", "#{ref["ref"]}^{commit}"]),
         {:ok, remote_ref_commit} <- remote_ref_commit(db, host, path, ref["remote"], ref["ref"]),
         true <- remote_ref_commit == ref_commit,
         :ok <- git_status(db, host, path, ["merge-base", "--is-ancestor", commit, ref_commit]) do
      {:ok, Map.put(ref, "verifiedRefCommit", ref_commit)}
    else
      _ ->
        {:error,
         error(
           "unverifiable_commit_ref",
           "commitRefs contains a commit without the declared canonical remote/ref proof"
         )}
    end
  end

  defp remote_ref_commit(db, host, path, remote, ref_name) do
    args = ["ls-remote", "--exit-code", remote, ref_name, "#{ref_name}^{}"]

    with {:ok, output} <- git_output(db, host, path, args),
         lines when lines != [] <- String.split(output, "\n", trim: true),
         parsed <- Map.new(lines, &parse_remote_ref_line/1),
         commit when is_binary(commit) <- parsed["#{ref_name}^{}"] || parsed[ref_name],
         true <- Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit) do
      {:ok, commit}
    else
      _ -> :error
    end
  end

  defp parse_remote_ref_line(line) do
    case String.split(line, "\t", parts: 2) do
      [commit, ref_name] -> {ref_name, commit}
      _ -> {"", ""}
    end
  end

  defp maybe_after_verify(call, db) do
    case Map.get(call, :on_refs_verified) do
      fun when is_function(fun, 1) -> fun.(db)
      _ -> :ok
    end
  end

  defp git_output(db, host, path, args) do
    case run_git(db, host, path, args) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  end

  defp git_status(db, host, path, args) do
    case run_git(db, host, path, args) do
      {_output, 0} -> :ok
      _ -> :error
    end
  end

  defp run_git(db, host, path, args) do
    base_dir =
      Application.get_env(:tightbeam, :base_dir, Path.join(System.user_home!(), ".tightbeam"))

    case Placement.hosts(base_dir, db)[host] do
      %{ssh: nil} ->
        command("git", ["-C", path | args])

      %{ssh: destination} when is_binary(destination) ->
        remote_command = ["git", "-C", path | args] |> Enum.map_join(" ", &shell_quote/1)

        command(
          "ssh",
          Support.ssh_opts() ++ [destination, "sh", "-c", shell_quote(remote_command)]
        )

      nil ->
        {:error, :unknown_host}
    end
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_failed}
  end

  defp command(executable, args) do
    runner = Application.get_env(:tightbeam, :commit_ref_command, &System.cmd/3)
    runner.(executable, args, stderr_to_stdout: true)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp actor({:user, ref}) when is_binary(ref), do: {:ok, %{kind: "user", ref: ref}}
  defp actor({:session, ref}) when is_binary(ref), do: {:ok, %{kind: "session", ref: ref}}

  defp actor({:process, _}),
    do: {:error, error("process_denied", "process principals cannot correct commitRefs")}

  defp actor(_),
    do:
      {:error,
       error(
         "principal_required",
         "commitRef correction requires a user credential or session token"
       )}

  defp valid_key(key) when is_binary(key) do
    if String.trim(key) != "" and String.length(key) <= 200,
      do: :ok,
      else:
        {:error,
         error("invalid_idempotency_key", "idempotencyKey must be 1..200 non-blank characters")}
  end

  defp valid_key(_), do: {:error, error("invalid_idempotency_key", "idempotencyKey is required")}

  defp valid_reason(reason) when is_binary(reason) do
    if String.trim(reason) != "" and length(String.to_charlist(reason)) <= 4000,
      do: :ok,
      else: {:error, error("invalid_reason", "reason must be 1..4000 non-blank characters")}
  end

  defp valid_reason(_), do: {:error, error("invalid_reason", "reason is required")}

  defp valid_artifact_id(id) when is_binary(id) and id != "", do: :ok

  defp valid_artifact_id(_),
    do: {:error, error("invalid_evidence", "evidenceArtifactId is required")}

  defp fingerprint(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, minor_version: 2))
    |> Base.encode16(case: :lower)
  end

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, error}} -> {:error, error}
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  defp error(code, message), do: %{code: code, message: message}
end
