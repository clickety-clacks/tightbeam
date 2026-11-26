defmodule Tightbeam.RowReactions.Reminder do
  @moduledoc """
  The readable `[[reminder]]` rule form.

  A reminder names an event to watch (`on`), what must hold about the work
  (`when`), what counts as answered (`satisfied_when_any`) and one or more
  `[[reminder.notify]]` entries saying whom to tell (`to`), after how long
  (`after`) and in what words (`text`).

  It is only a way of writing a reaction. `to_reaction!/1` translates the
  table into an ordinary event-mode `[[reaction]]` table, which then goes
  through the same compiler, timing, pre-delivery re-check and withdrawal as
  every other reaction. The reaction's condition is the event guard, every
  `when` entry and "none of `satisfied_when_any`". Because the engine re-checks
  a pending notice just before delivering it, a notice is dropped when an
  answer is on record or `when` no longer holds by then. Every notice is
  addressed with `on_unavailable = "skip"`: a recipient who is no longer
  active is skipped, never redirected.

  Tightbeam reads nothing about what a reminder is for. Its words, facts and
  values all come from the rule's author.
  """

  @required ~w(name on notify)
  @optional ~w(english when satisfied_when_any scope roles archetypes)
  @notify_keys ~w(to after text)
  @condition_keys ~w(fact op value)
  @operators ~w(eq ne gt gte lt lte in not_in contains)

  # Readable event names, each an existing reaction-engine event narrowed by an
  # optional guard. The engine's own event names are accepted as written.
  @events %{
    "assignment-completed" => {"assignment", :assignment, "completed"},
    "assignment-surrendered" => {"assignment", :assignment, "surrendered"},
    "assignment-revoked" => {"assignment", :assignment, "revoked"},
    "assignment-closed" => {"assignment", :assignment, nil},
    "assignment-started" => {"assignment_start", :assignment, nil},
    "assignment-attested" => {"assignment_attest", :assignment, nil},
    "work-item-created" => {"work_item_observation", :work_item, "created"},
    "assignment" => {"assignment", :assignment, nil},
    "assignment_start" => {"assignment_start", :assignment, nil},
    "assignment_attest" => {"assignment_attest", :assignment, nil},
    "work_item_observation" => {"work_item_observation", :work_item, nil}
  }

  # Facts a reminder may name, by the kind of work its event concerns. A fact
  # `x.y` is read from the event's snapshot at `facts.x.y`, both when the event
  # is admitted and again just before each notice is delivered.
  @work_item_facts ~w(work_item.title work_item.state work_item.artifact_titles work_item.artifact_kinds)
  @assignment_facts ~w(assignment.effect_kind assignment.is_review assignment.notes assignment.verdicts) ++
                      @work_item_facts
  @people_facts ~w(holder opener delivery_owner)

  @targets %{
    assignment: ~w(holder opener delivery_owner anchor),
    work_item: ~w(delivery_owner anchor)
  }

  @placeholders %{
    assignment:
      ~w(assignment_id work_item_id work_item_title holder_name opener_name delivery_owner_name anchor_name),
    work_item: ~w(work_item_id work_item_title delivery_owner_name anchor_name)
  }

  @doc "Event names a reminder may watch."
  def events, do: @events |> Map.keys() |> Enum.sort()

  @doc """
  Translates one `[[reminder]]` table into an event-mode `[[reaction]]` table.
  Raises `ArgumentError` naming the reminder and the problem.
  """
  def to_reaction!(reminder) when is_map(reminder) do
    name = Map.get(reminder, "name")

    unless is_binary(name) and name != "",
      do: raise(ArgumentError, "reminder requires a nonempty name")

    fail = fn message -> raise ArgumentError, "reminder #{inspect(name)}: #{message}" end
    fields!(reminder, @required, @optional, fail)

    english = Map.get(reminder, "english")

    unless is_nil(english) or (is_binary(english) and english != ""),
      do: fail.("english must be nonempty text")

    {event_kind, subject, guard} = event!(reminder["on"], fail)

    conditions =
      reminder
      |> Map.get("when", [])
      |> conditions!("when", subject, fail)

    answers =
      reminder
      |> Map.get("satisfied_when_any", [])
      |> conditions!("satisfied_when_any", subject, fail)

    notices = notices!(reminder["notify"], subject, fail)

    condition =
      [guard_expression(event_kind, guard)]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(conditions)
      |> Kernel.++(if answers == [], do: [], else: [op("not", [op("or", answers)])])
      |> case do
        [] -> true
        parts -> op("and", parts)
      end

    effects =
      notices
      |> Enum.with_index(1)
      |> Enum.map(fn {notice, index} -> effect(name, subject, event_kind, notice, index) end)

    %{
      "name" => name,
      "family" => "reminder:" <> name,
      "events" => [event_kind],
      "when" => condition,
      "effects" => effects
    }
    |> put_present("english", english)
    |> put_present("scope", Map.get(reminder, "scope"))
    |> put_present("roles", Map.get(reminder, "roles"))
    |> put_present("archetypes", Map.get(reminder, "archetypes"))
  end

  def to_reaction!(_), do: raise(ArgumentError, "reminder must be a table")

  @doc "Parses a duration such as `0m`, `90s`, `3h` or `2d` into milliseconds."
  def duration_ms(text) when is_binary(text) do
    case Regex.run(~r/\A(\d+)(s|m|h|d)\z/, text, capture: :all_but_first) do
      [count, unit] ->
        {:ok,
         String.to_integer(count) *
           %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}[unit]}

      _ ->
        :error
    end
  end

  def duration_ms(_), do: :error

  defp event!(on, fail) do
    case Map.fetch(@events, on) do
      {:ok, event} ->
        event

      :error ->
        fail.("unknown on #{inspect(on)}; known events: #{Enum.join(events(), ", ")}")
    end
  end

  defp guard_expression("assignment", nil), do: nil

  defp guard_expression("assignment", outcome),
    do: op("eq", [ref("event.terminal.outcome"), outcome])

  defp guard_expression("work_item_observation", nil), do: nil

  defp guard_expression("work_item_observation", operation),
    do: op("eq", [ref("event.operation"), operation])

  defp guard_expression(_kind, nil), do: nil

  defp conditions!(entries, label, subject, fail) do
    unless is_list(entries), do: fail.("#{label} must be an array of {fact, op, value} tables")

    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} -> condition!(entry, "#{label} ##{index}", subject, fail) end)
  end

  defp condition!(entry, label, subject, fail) do
    unless is_map(entry), do: fail.("#{label} must be a {fact, op, value} table")
    fields!(entry, @condition_keys, [], fn message -> fail.("#{label}: #{message}") end)

    fact = entry["fact"]
    operator = entry["op"]
    value = entry["value"]
    known = facts(subject)

    unless is_binary(fact) and fact in known,
      do:
        fail.(
          "#{label} has unknown fact #{inspect(fact)} for this event; known facts: " <>
            Enum.join(known, ", ")
        )

    unless operator in @operators,
      do:
        fail.(
          "#{label} has unknown op #{inspect(operator)}; known ops: " <>
            Enum.join(@operators, ", ")
        )

    static!(value, fn -> fail.("#{label} value must be a plain TOML value") end)
    subject_ref = ref("facts." <> fact)

    case operator do
      "in" ->
        unless is_list(value), do: fail.("#{label} op in needs a list value")
        op("in", [subject_ref, value])

      "not_in" ->
        unless is_list(value), do: fail.("#{label} op not_in needs a list value")
        op("not", [op("in", [subject_ref, value])])

      "contains" ->
        unless text_value?(value),
          do: fail.("#{label} op contains needs text or a nonempty list of text")

        op("contains", [subject_ref, value])

      other when other in ~w(gt gte lt lte) ->
        unless is_number(value), do: fail.("#{label} op #{other} needs a number")

        numeric(other, subject_ref, value)

      other ->
        op(other, [subject_ref, value])
    end
  end

  # The expression language has no type test; ordering on a missing fact must
  # read as false, not fail the whole evaluation. `coalesce` supplies a number
  # that cannot satisfy the comparison when the fact is absent.
  defp numeric(operator, subject_ref, value) do
    fallback = if operator in ~w(gt gte), do: value - 1, else: value + 1
    op(operator, [op("coalesce", [subject_ref, fallback]), value])
  end

  defp text_value?(value) when is_binary(value), do: value != ""

  defp text_value?(values) when is_list(values),
    do: values != [] and Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp text_value?(_), do: false

  defp notices!(entries, subject, fail) do
    unless is_list(entries) and entries != [],
      do: fail.("needs one or more [[reminder.notify]] tables")

    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} ->
      label = "notify ##{index}"
      unless is_map(entry), do: fail.("#{label} must be a table")
      fields!(entry, @notify_keys, [], fn message -> fail.("#{label}: #{message}") end)

      to = entry["to"]
      targets = @targets[subject]

      unless to in targets,
        do:
          fail.(
            "#{label} has unknown to #{inspect(to)} for this event; known recipients: " <>
              Enum.join(targets, ", ")
          )

      after_ms =
        case duration_ms(entry["after"]) do
          {:ok, ms} ->
            ms

          :error ->
            fail.(
              "#{label} after #{inspect(entry["after"])} is not a duration such as 0m, 90s, 3h or 2d"
            )
        end

      text = entry["text"]
      unless is_binary(text) and text != "", do: fail.("#{label} text must be nonempty text")

      %{to: to, after_ms: after_ms, parts: template!(text, subject, label, fail)}
    end)
  end

  # `{name}` is a placeholder when `name` is an identifier; any other brace is
  # literal text. An identifier that is not a known placeholder is an error, so
  # a misspelling fails at load time instead of reaching a recipient.
  defp template!(text, subject, label, fail) do
    known = @placeholders[subject]

    ~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case Regex.run(~r/\A\{([a-zA-Z_][a-zA-Z0-9_]*)\}\z/, part, capture: :all_but_first) do
        [name] ->
          unless name in known,
            do:
              fail.(
                "#{label} text uses unknown placeholder {#{name}} for this event; known " <>
                  "placeholders: " <> Enum.map_join(known, ", ", &"{#{&1}}")
              )

          {:placeholder, name}

        nil ->
          part
      end
    end)
  end

  defp effect(name, subject, event_kind, notice, index) do
    slot = "notify-#{index}"

    wake_id =
      op("concat", [
        "w_rem_",
        op("sha256", [op("json", [[name, ref("event.id"), slot]])])
      ])

    value =
      %{
        "wake_id" => wake_id,
        "session_key" => recipient(notice.to),
        "owner_user_id" => ref("event.org"),
        "origin" => "process:tightbeam",
        "work_item_id" => placeholder(subject, event_kind, "work_item_id"),
        "prompt" => prompt(subject, event_kind, notice.parts),
        "due_at" => op("add", [ref("event.at"), notice.after_ms]),
        "on_unavailable" => "skip"
      }
      |> then(fn value ->
        if subject == :assignment,
          do: Map.put(value, "assignment_id", placeholder(subject, event_kind, "assignment_id")),
          else: value
      end)

    %{"slot" => slot, "kind" => "notice", "when" => true, "value" => value}
  end

  defp prompt(subject, event_kind, parts) do
    args =
      Enum.map(parts, fn
        {:placeholder, name} ->
          op("coalesce", [placeholder(subject, event_kind, name), "(unknown)"])

        text ->
          text
      end)

    case args do
      [single] when is_binary(single) -> single
      args -> op("concat", args)
    end
  end

  # Ids come from the event itself, which every engine event carries today.
  defp placeholder(_subject, "assignment", "assignment_id"),
    do: ref("event.terminal.assignment_id")

  defp placeholder(_subject, "assignment", "work_item_id"), do: ref("event.terminal.work_item_id")
  defp placeholder(_subject, "work_item_observation", "work_item_id"), do: ref("event.workItemId")
  defp placeholder(_subject, _kind, "assignment_id"), do: ref("event.after.assignment.id")
  defp placeholder(_subject, _kind, "work_item_id"), do: ref("event.after.assignment.workItemId")
  defp placeholder(_subject, _kind, "work_item_title"), do: ref("facts.work_item.title")
  defp placeholder(_subject, _kind, "anchor_name"), do: ref("facts.names.anchor")

  defp placeholder(_subject, _kind, name) do
    who = String.replace_suffix(name, "_name", "")
    ref("facts.names.#{who}")
  end

  defp recipient("anchor"), do: ref("anchor.session_key")
  defp recipient(who) when who in @people_facts, do: ref("facts.people.#{who}.session_key")

  defp facts(:assignment), do: @assignment_facts
  defp facts(:work_item), do: @work_item_facts

  defp fields!(record, required, optional, fail) do
    keys = Map.keys(record)
    missing = required -- keys
    extra = keys -- (required ++ optional)
    if missing != [], do: fail.("missing #{Enum.join(missing, ", ")}")
    if extra != [], do: fail.("unknown keys #{Enum.join(Enum.sort(extra), ", ")}")
  end

  defp static!(value, _fail)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: :ok

  defp static!(values, fail) when is_list(values), do: Enum.each(values, &static!(&1, fail))
  defp static!(_value, fail), do: fail.()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp ref(path), do: %{"ref" => path}
  defp op(name, args), do: %{"op" => name, "args" => args}
end
