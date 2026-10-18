defmodule Tightbeam.RowReactionFixtures do
  @moduledoc false

  def elect_handoff(valid_verbs) do
    base = Path.join(System.tmp_dir!(), "handoff-rails-#{System.unique_integer([:positive])}")
    rules = Path.join(base, "identity/rules")
    File.mkdir_p!(rules)
    names = ~w(row-reaction-handoff.toml row-reaction-terminal-action.toml)

    Enum.each(names, fn name ->
      File.cp!(Path.join("priv/kungfu/agentic-engineering/rules", name), Path.join(rules, name))
    end)

    receipt = Path.join(base, "identity/kungfu/agentic-engineering/installed.toml")
    File.mkdir_p!(Path.dirname(receipt))
    paths = Enum.map_join(names, ",", &"'rules/#{&1}'")
    File.write!(receipt, "name='agentic-engineering'\npaths=[#{paths}]\n")
    Tightbeam.Rules.load!(base, valid_verbs)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  alias Tightbeam.{DB.Txn, RowReactions, Rules, Wakes}

  def source_in_txn(txn, id, token \\ nil) do
    source =
      if token do
        %{"kind" => "assignment_revocation", "id" => token}
      else
        case Txn.q(txn, "SELECT closingAttestId FROM assignments WHERE id=?1", [id]) do
          [[value]] when is_binary(value) -> %{"kind" => "attest", "id" => value}
          _ -> %{"kind" => "assignment_revocation", "id" => nil}
        end
      end

    Wakes.terminal_source_in_txn(txn, id, source)
  end

  # Replay the recorded observation rather than invoke a removed policy producer.
  def replay_terminal_in_txn(txn, id, token \\ nil) do
    with {:ok, source} <- source_in_txn(txn, id, token),
         {:ok, notice} <- Wakes.terminal_notification(source) do
      [[event, facts]] =
        Txn.q(
          txn,
          "SELECT event,facts FROM row_reaction_events WHERE json_extract(event,'$.source.kind')=?1 AND json_extract(event,'$.source.id')=?2 AND json_extract(event,'$.after.id')=?3",
          [source.source_kind, source.source_token, id]
        )

      event = JSON.decode!(event)
      RowReactions.admit_in_txn(txn, event, JSON.decode!(facts), Rules.reactions(), event["at"])
      {:ok, Wakes.get_in_txn(txn, notice.wake_id)}
    end
  end

  # Construct one explicit pre-upgrade output, with the fixture's known address.
  # This never chooses production policy or runs the current reaction observer.
  def legacy_notice_in_txn(txn, id, address, token \\ nil) do
    {:ok, source} = source_in_txn(txn, id, token)
    {:ok, notice} = Wakes.terminal_notification(source)

    Wakes.schedule_in_txn(
      txn,
      Map.merge(notice, %{
        session_key: address,
        origin: "process:tightbeam",
        consumer: "prompt",
        creator_session_key: source.child_session_key,
        assignment_id: id,
        work_item_id: source.work_item_id,
        owner_user_id: source.owner_user_id,
        obligation_ref: "terminal-child-owner-notification:" <> id,
        due_at: source.terminal_at
      })
    )
  end
end
