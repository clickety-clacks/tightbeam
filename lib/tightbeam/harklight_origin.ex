defmodule Tightbeam.HarklightOrigin do
  @moduledoc false

  alias Tightbeam.{DB, HarklightWakes, Placement}
  alias Tightbeam.DB.Txn

  # A move is opt-in for one owned handle. Coverage confirmation is separate
  # from completion: offers can arrive before the first cover receipt, and the
  # second cover must still settle declarations made by the old listener.
  @ddl """
  CREATE TABLE IF NOT EXISTS harklight_origin_moves (
    handle TEXT PRIMARY KEY REFERENCES harklight_wake_handles(handle),
    state TEXT NOT NULL CHECK(state IN ('moving','covered')),
    confirmed INTEGER NOT NULL DEFAULT 0 CHECK(confirmed IN (0,1)),
    createdAt INTEGER NOT NULL,
    updatedAt INTEGER NOT NULL,
    CHECK(state != 'covered' OR confirmed = 1)
  );
  CREATE TABLE IF NOT EXISTS harklight_origin_offers (
    handle TEXT NOT NULL REFERENCES harklight_origin_moves(handle),
    eventId TEXT NOT NULL,
    feedCursor INTEGER NOT NULL,
    rawLine TEXT NOT NULL,
    PRIMARY KEY(handle,eventId)
  );
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)

  # The caller durably begins the move and starts the origin receiver first.
  # stop must return only after observing the old child exit; on restore it
  # must also account for a child left by the previous gateway process.
  def migrate(db, handle, opts) do
    runner = Keyword.fetch!(opts, :runner)
    stop = Keyword.fetch!(opts, :stop)

    first_cover =
      if Keyword.get(opts, :restore, false) do
        :ok
      else
        with :ok <- settle_cover(runner, handle),
             {:ok, _} <- confirmed(db, handle),
             :ok <- drain(db, handle),
             :ok <- Tightbeam.HarklightLifecycle.acknowledge_pending(db, runner: runner),
             do: :ok
      end

    with :ok <- first_cover,
         :ok <- stop.(handle),
         :ok <- settle_cover(runner, handle),
         {:ok, _} <- confirmed(db, handle, true),
         :ok <- drain(db, handle),
         :ok <- Tightbeam.HarklightLifecycle.acknowledge_pending(db, runner: runner),
         do: :ok
  end

  # The CLI owns the support-operation journal. Never replace an unresolved
  # declaration with a new request: settle its exact key, then cover again.
  def settle_cover(runner, handle) do
    {output, status} = runner.(["cover", "--session", handle])
    lines = json_lines(output)

    cond do
      status == 0 and
          Enum.any?(lines, fn line ->
            line["kind"] == "covered" and line["session_handle"] == handle and
                get_in(line, ["listening_support", "origin_listener"]) == true
          end) ->
        :ok

      status == 7 ->
        case unresolved_support(output, lines) do
          nil -> {:error, "coverage_outcome_unknown"}
          op_id -> settle_support(runner, handle, op_id)
        end

      true ->
        {:error, "coverage_unconfirmed"}
    end
  end

  defp settle_support(runner, handle, op_id) do
    {output, status} = runner.(["retry", "--op-id", op_id])

    settled? =
      Enum.any?(json_lines(output), fn line ->
        line["op_id"] == op_id and
          ((status == 0 and line["kind"] == "committed") or
             (status == 2 and line["kind"] == "refused"))
      end)

    if settled?, do: settle_cover(runner, handle), else: {:pending, op_id}
  end

  defp unresolved_support(output, lines) do
    Enum.find_value(lines, fn
      %{"kind" => "outcome_unknown", "operation" => "support", "op_id" => id}
      when is_binary(id) ->
        id

      _ ->
        nil
    end) ||
      case Regex.run(
             ~r/^support operation ([0-9a-fA-F-]{36}) is unresolved; retry that exact operation before changing its fields$/m,
             output
           ) do
        [_, id] -> id
        _ -> nil
      end
  end

  defp json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, value} when is_map(value) -> [value]
        _ -> []
      end
    end)
  end

  def managed?(db, handle) do
    case DB.query(db, "SELECT 1 FROM harklight_origin_moves WHERE handle=?1", [handle]) do
      {:ok, []} -> false
      {:ok, [[1]]} -> true
      {:error, reason} -> raise "Harklight coverage lookup failed: #{inspect(reason)}"
    end
  end

  # Called under the legacy listener manager so the durable marker and its
  # decision to admit another per-handle attach cannot cross each other.
  def begin_move(db, handle, session_key) do
    DB.transaction(db, fn txn ->
      case Txn.q(
             txn,
             """
             SELECT 1 FROM harklight_send_operations s
             JOIN harklight_wake_handles h ON h.handle=s.handle
             WHERE s.handle=?1 AND s.sessionKey=?2 AND s.state='bound'
               AND h.host=?3 AND h.state IN ('active','unavailable') LIMIT 1
             """,
             [handle, session_key, Placement.local_host_name()]
           ) do
        [[1]] ->
          prior = Txn.q(txn, "SELECT state FROM harklight_origin_moves WHERE handle=?1", [handle])
          now = System.system_time(:millisecond)

          Txn.q(
            txn,
            """
            INSERT OR IGNORE INTO harklight_origin_moves(handle,state,createdAt,updatedAt)
            VALUES(?1,'moving',?2,?2)
            """,
            [handle, now]
          )

          case prior do
            [] -> :started
            [["moving"]] -> :moving
            [["covered"]] -> :covered
          end

        [] ->
          {:error, "harklight_owned_handle_required"}
      end
    end)
  end

  def confirmed(db, handle, complete? \\ false) do
    DB.query(
      db,
      """
      UPDATE harklight_origin_moves SET confirmed=1,
        state=CASE WHEN ?2 THEN 'covered' ELSE state END,updatedAt=?3 WHERE handle=?1
      """,
      [handle, if(complete?, do: 1, else: 0), System.system_time(:millisecond)]
    )
  end

  # The ownership lookup is in the capture transaction. An arbitrary handle on
  # the enrollment's stream cannot acquire coverage or a wake as a side effect.
  def admission(txn, handle) do
    case Txn.q(
           txn,
           """
           SELECT m.confirmed FROM harklight_origin_moves m
           JOIN harklight_wake_handles h ON h.handle=m.handle
           WHERE m.handle=?1 AND h.host=?2 AND EXISTS (
             SELECT 1 FROM harklight_send_operations s
             WHERE s.handle=m.handle AND s.state='bound'
           )
           """,
           [handle, Placement.local_host_name()]
         ) do
      [[1]] -> :confirmed
      [[0]] -> :moving
      [] -> :ignored
    end
  end

  def stage(txn, handle, event_id, cursor, line) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO harklight_origin_offers(handle,eventId,feedCursor,rawLine)
      VALUES(?1,?2,?3,?4)
      """,
      [handle, event_id, cursor, line]
    )

    :captured
  end

  def captured(txn, handle, event_id) do
    Txn.q(txn, "DELETE FROM harklight_origin_offers WHERE handle=?1 AND eventId=?2", [
      handle,
      event_id
    ])

    :ok
  end

  def drain(db, handle) do
    with {:ok, rows} <-
           DB.query(
             db,
             """
             SELECT rawLine FROM harklight_origin_offers WHERE handle=?1 ORDER BY feedCursor
             """,
             [handle]
           ) do
      Enum.reduce_while(rows, :ok, fn [line], :ok ->
        case HarklightWakes.capture_origin_line(db, line) do
          result when result in [:ok, :captured] -> {:cont, :ok}
          other -> {:halt, other}
        end
      end)
    end
  end
end
