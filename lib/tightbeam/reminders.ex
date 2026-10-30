defmodule Tightbeam.Reminders do
  @moduledoc "Reminder wording from the published identity, with shipped defaults."
  alias Tightbeam.DB.Txn

  @fields %{
    "holder-reminder" => ~w(assignment_id subject holder last_activity),
    "climb-copy" => ~w(assignment_id subject holder last_activity),
    "terminal-action" =>
      ~w(child_assignment_id source_kind source_token notice_id child_session child_session_state your_last_activity child_finished),
    "work-item-routing" => ~w(work_item_id title),
    "work-item-slate" => ~w(work_item_id),
    "critical-lease-retire" => ~w(reason hard_deadline),
    "identity-staleness" => ~w(late_count revision),
    "remedy-pending" => ~w(rule subject)
  }

  def render(%Txn{} = txn, kind, values) do
    base =
      Enum.find_value(Txn.q(txn, "PRAGMA database_list"), fn
        [_, "main", path] when is_binary(path) and path != "" -> Path.dirname(path)
        _ -> nil
      end)

    render(base, kind, values)
  end

  def render(base, kind, values) do
    allowed = Map.fetch!(@fields, kind)
    values = Map.new(values, fn {key, value} -> {to_string(key), to_string(value)} end)
    template = published(base, kind) || default(kind)

    Regex.replace(~r/\{([^{}]+)\}/u, template, fn original, name ->
      if name in allowed, do: Map.get(values, name, original), else: original
    end)
  end

  def render_db(db, kind, values) do
    {:ok, text} = Tightbeam.DB.transaction(db, &render(&1, kind, values))
    text
  end

  def default(kind) do
    Map.fetch!(@fields, kind)

    :tightbeam
    |> :code.priv_dir()
    |> Path.join("kungfu/agentic-engineering/reminders/#{kind}.md")
    |> File.read!()
  end

  defp published(nil, _kind), do: nil

  defp published(base, kind) do
    bytes = Tightbeam.Identity.published_file_bytes!(base, "reminders/#{kind}.md")
    if String.valid?(bytes) and String.trim(bytes) != "", do: bytes
  rescue
    _ -> nil
  end

  def activity(nil, _now), do: "none recorded"

  def activity(at, now) do
    stamp = at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    minutes = div(max(now - at, 0), 60_000)
    "#{stamp} (#{minutes} #{if minutes == 1, do: "minute", else: "minutes"} ago)"
  end
end
