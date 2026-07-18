defmodule Tightbeam.Rails do
  @moduledoc """
  Loads the org's operator-authored statutes and compiles their remind-tier
  delivery surfaces. Statutes bind the whole org: every home receives the
  same standing law, while Claude homes also receive event hooks that
  re-present each obligation at its moment.

  Loading is boot-time and fail-closed. Files under
  `<base_dir>/identity/rails/*.toml` are read in filename order, every
  statute is validated before the set is stored in `:persistent_term`, and
  reserved predicate, gate, and block behavior is refused rather than
  silently weakened into reminders.

  `work-received` compiles to a self-contained Claude `UserPromptSubmit`
  command whose stdout is injected into model context. `turn-end` compiles
  to a Claude `Stop` command whose stderr and exit 2 bounce the model once;
  the vendor's `stop_hook_active` input guard then exits 0 so the next stop
  ends the turn. Commands contain no home paths or environment dependencies.

  Standing law is part of projected guidance. Adding, removing, or changing
  a statute therefore changes the home manifest hash and regenerates the
  home; an empty statute set contributes no bytes or files and preserves the
  pre-rails manifest exactly.
  """

  @persist_key __MODULE__
  @statute_keys MapSet.new(["name", "on", "mode", "text", "check"])

  @typedoc "A validated remind-tier statute."
  @type statute :: %{
          name: String.t(),
          on: :work_received | :turn_end,
          mode: :remind,
          text: String.t()
        }

  @doc """
  Loads, validates, and persists every statute under the base directory.
  Missing rails directories and directories containing no TOML files are an
  empty, valid statute set.
  """
  @spec load!(String.t()) :: [statute()]
  def load!(base_dir) do
    statutes =
      base_dir
      |> Path.join("identity/rails/*.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        manifest = path |> File.read!() |> Toml.decode!()

        case Map.get(manifest, "statute") do
          statutes when is_list(statutes) and statutes != [] ->
            Enum.map(statutes, &validate!/1)

          _ ->
            raise ArgumentError, "#{path} must contain one or more [[statute]] tables"
        end
      end)

    duplicate =
      statutes
      |> Enum.frequencies_by(& &1.name)
      |> Enum.find_value(fn {name, count} -> if count > 1, do: name end)

    if duplicate, do: raise(ArgumentError, "duplicate statute name: #{duplicate}")

    :persistent_term.put(@persist_key, statutes)
    statutes
  end

  @doc "The standing-law guidance section, or nil for an empty statute set."
  @spec standing_law() :: String.t() | nil
  def standing_law do
    case :persistent_term.get(@persist_key) do
      [] ->
        nil

      statutes ->
        bullets = Enum.map_join(statutes, "\n", &standing_bullet/1)

        """
        ## Standing law

        Deterministic law of this org, delivered by rail. Each statute is also
        re-presented at its moment; these are the same obligations, standing.

        #{bullets}
        """
        |> String.trim_trailing()
    end
  end

  @doc "The Claude settings hook map, or nil for an empty statute set."
  @spec claude_settings() :: map() | nil
  def claude_settings do
    case :persistent_term.get(@persist_key) do
      [] ->
        nil

      statutes ->
        hooks =
          statutes
          |> Enum.reduce(%{"UserPromptSubmit" => [], "Stop" => []}, fn statute, hooks ->
            {event, entry} = claude_hook(statute)
            Map.update!(hooks, event, &(&1 ++ [entry]))
          end)
          |> Enum.reject(fn {_event, entries} -> entries == [] end)
          |> Map.new()

        %{"hooks" => hooks}
    end
  end

  defp validate!(statute) when is_map(statute) do
    keys = Map.keys(statute) |> MapSet.new()

    if MapSet.member?(keys, "check") do
      raise ArgumentError, ~s|"check" (predicate statutes) is reserved for a later stage|
    end

    unknown = keys |> MapSet.difference(@statute_keys) |> MapSet.to_list() |> Enum.sort()

    if unknown != [] do
      raise ArgumentError, "unknown statute keys: #{Enum.join(unknown, ", ")}"
    end

    name = Map.get(statute, "name")

    cond do
      is_nil(name) ->
        raise ArgumentError, ~s(statute is missing "name")

      not (is_binary(name) and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name)) ->
        raise ArgumentError, "invalid statute name: #{inspect(name)}"

      true ->
        :ok
    end

    on =
      case Map.fetch(statute, "on") do
        :error -> raise ArgumentError, ~s(statute #{name} is missing "on")
        {:ok, "work-received"} -> :work_received
        {:ok, "turn-end"} -> :turn_end
        {:ok, event} -> raise ArgumentError, "unknown statute event: #{inspect(event)}"
      end

    mode =
      case Map.get(statute, "mode", "remind") do
        "remind" -> :remind
        "gate" -> raise ArgumentError, ~s(mode "gate" is reserved for a later stage)
        "block" -> raise ArgumentError, ~s(mode "block" is reserved for a later stage)
        value -> raise ArgumentError, "unknown statute mode: #{inspect(value)}"
      end

    text = Map.get(statute, "text")

    unless is_binary(text) and String.trim(text) != "" do
      raise ArgumentError, ~s(statute #{name} is missing "text")
    end

    %{name: name, on: on, mode: mode, text: String.trim(text)}
  end

  defp standing_bullet(statute) do
    event = event_name(statute.on)
    prefix = "- #{statute.name} (on #{event}): "
    [first | rest] = String.split(one_line(statute.text))

    rest
    |> Enum.reduce({[], prefix <> first}, fn word, {lines, line} ->
      if String.length(line) + String.length(word) + 1 < 76 do
        {lines, line <> " " <> word}
      else
        {[line | lines], "  " <> word}
      end
    end)
    |> then(fn {lines, line} -> Enum.reverse([line | lines]) end)
    |> Enum.join("\n")
  end

  defp claude_hook(%{on: :work_received} = statute) do
    command = "echo '" <> (statute |> hook_message() |> escape_single_quotes()) <> "'"
    {"UserPromptSubmit", %{"hooks" => [%{"type" => "command", "command" => command}]}}
  end

  defp claude_hook(%{on: :turn_end} = statute) do
    message = statute |> hook_message() |> escape_double_quoted()

    payload =
      "if grep -q \"\\\"stop_hook_active\\\"[[:space:]]*:[[:space:]]*true\" -; then exit 0; fi; " <>
        "echo \"#{message}\" >&2; exit 2"

    command = "sh -c '" <> escape_single_quotes(payload) <> "'"
    {"Stop", %{"hooks" => [%{"type" => "command", "command" => command}]}}
  end

  defp hook_message(statute), do: "[standing law: #{statute.name}] #{one_line(statute.text)}"

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  defp event_name(:work_received), do: "work-received"
  defp event_name(:turn_end), do: "turn-end"

  defp escape_single_quotes(text), do: String.replace(text, "'", "'\\''")

  defp escape_double_quoted(text) do
    text
    |> String.replace("\"", "\\\"")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
  end
end
