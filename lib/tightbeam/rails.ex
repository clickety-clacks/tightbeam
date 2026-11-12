defmodule Tightbeam.Rails do
  @moduledoc """
  Statutes: operator-authored TOML law compiled into deterministic
  guardrails (spec §rails; tenets T1, T4).

  THE INVARIANT — rails never add guidance. A rail contributes ZERO bytes
  to any model's context: no standing sections, no reminders, no injected
  obligations. Inference is nondeterministic and finite-attention; feeding
  it more prose both pollutes the context and changes behavior it cannot
  guarantee — the exact failure this system replaces. The ONLY text a rail
  ever emits is the refusal reason at the moment it fires, delivered by
  the enforcing mechanism itself: the agent learns the law by hitting it,
  never by reading it. `mode = "remind"` is refused at load for this
  reason, not treated as unknown.

  V1 is the GATE tier: a statute compiles to a `PreToolUse` hook. The harness
  presents every proposed tool call to the hook BEFORE execution; on pattern
  match the hook exits 2 and the call is REFUSED — the action never happens,
  no inference in the loop, and the statute's text reaches the model as the
  denial reason. Honest limit: pattern matching over command strings is
  accident-grade enforcement — a determined agent can evade patterns;
  adversarial containment belongs to sandboxes and credentials. Gates stop
  mistakes deterministically.

  Codex has supported hooks since 0.124.0; 0.144.x is the tested floor for
  whichever executable codex-acp selects (its bundled executable, or a
  `CODEX_PATH` override). Codex receives the identical PreToolUse map in
  harness-owned rails artifact. Both implementations use the same
  stdin wire, report shell calls as tool_name "Bash", and refuse by exit 2;
  parity is scoped to Bash-tool statutes. Hooks fire under permission bypass
  on both harnesses: codex `agent-full-access` and claude `bypassPermissions`.

  DISTINCT from permission bypass, codex adds a hook-TRUST layer with no
  claude analog. Untrusted hooks are silently skipped headless, so placement
  seeds `CODEX_CONFIG={"bypass_hook_trust":true}` on EVERY codex spawn; the
  adapter spreads that request override into every thread config and arms the
  substrate-projected home's rails artifact. Unconditional because the
  projected map is unconditional: the reserved observation entry rides in it
  whether or not the org has authored law, and on codex a hook that is not
  trusted does not arm at all. Seeding an env var costs nothing and can fail
  nothing.

  The boot-time PROBE is the part that stays gated on law. Because either seed
  or file can fail silently, the adapter drives the reserved probe at spawn and
  fails CLOSED unless it observes the refusal — and only a DENIAL is worth
  refusing to boot over. An observation that does not arm degrades to a weaker
  evidence class and nothing else, so a law-free org must not lose its adapter
  to a hook-trust regression. `statutes?/0`, not the presence of the map, is
  what the probe follows.

  Rails-tier denial on both harnesses is for a cooperative agent — enumerated
  call denial, wired proven at boot for codex, not a sandbox or tamper-proof.
  Malicious/config-hostile actors are out of scope equally for both harnesses.
  Reserved for later stages, refused by name at load: `mode = "block"` and
  `check` predicates.

  Loading is boot-time and fail-closed: `<base_dir>/identity/rails/*.toml`
  in filename order, every statute validated before the set is stored in
  `:persistent_term`; a malformed statute fails the boot (bad law stops
  the boot). Statute changes ride the home's extra_files into the manifest
  hash: a law change is an identity change and regenerates homes.

  Hook commands are self-contained (no file paths, no environment
  dependencies — homes live at different paths on gateway, staging, and
  satellites). Statute patterns match their POSIX ERE against the raw
  tool-call JSON on stdin, so no jq is required on satellites; patterns
  should not rely on matching bare `"` characters, which arrive
  JSON-escaped. Closed action statutes parse `tool_input.command` and classify
  executable argv instead, so quoted prose cannot impersonate an action.
  """

  @persist_key __MODULE__
  # Each hook command is passed as one `sh -c` argument. Keep room below the
  # per-argument exec limit; this bounds packaging, not statute semantics.
  @bash_hook_command_arg_bytes 90_000
  @statute_keys MapSet.new([
                  "name",
                  "on",
                  "mode",
                  "text",
                  "check",
                  "tool",
                  "pattern",
                  "action"
                ])
  @actions ~w(git-stash git-reset-hard git-clean-force git-checkout-discard git-restore)
  @probe_statute %{
    name: "tightbeam-probe",
    on: :tool_call,
    mode: :gate,
    tool: "Bash",
    pattern: "tightbeam-gate-probe",
    text: "Spawn wiring-check probe command; always refused by design."
  }
  # Deliberately loose on what sits between the two words — the agent may write
  # `tightbeam  artifact-record`, or reach the binary by path. Loose is the right
  # direction here: a false match opens a window the record then binds, which is
  # the same turn it would have bound anyway, while a miss silently downgrades a
  # correct agent's evidence.
  @observation_pattern "tightbeam[^\"]*artifact-record"
  # A cheap prefilter only — it may over-match freely (the CLI judges
  # operations vs mentions), but it must never exclude an operation the CLI
  # would gate. Every network-capable `git` verb reaches the checker because a
  # named remote has no github.com literal. Local-only git commands still exit
  # at the prefilter and never pay for a CLI process.
  @github_auth_pattern "(github\\.com|gh[[:space:]]+(repo|pr|issue|api)|git[[:space:]]+(clone|fetch|pull|push|ls-remote|remote|submodule))"

  @typedoc "A validated gate statute."
  @type statute :: %{
          name: String.t(),
          on: :tool_call,
          mode: :gate,
          tool: String.t(),
          pattern: String.t() | nil,
          action: String.t() | nil,
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
        try do
          manifest = path |> File.read!() |> Toml.decode!()

          case Map.get(manifest, "statute") do
            statutes when is_list(statutes) and statutes != [] ->
              statutes
              |> Enum.with_index(1)
              |> Enum.map(fn {raw, ordinal} ->
                try do
                  validate!(raw)
                rescue
                  error ->
                    require Logger

                    Logger.warning(
                      "rail #{path} entry #{ordinal} unavailable: #{Exception.message(error)}"
                    )

                    tool = if is_map(raw), do: Map.get(raw, "tool"), else: nil

                    %{
                      name: "unavailable-#{Path.basename(path, ".toml")}-#{ordinal}",
                      on: :tool_call,
                      mode: :gate,
                      tool: if(is_binary(tool) and String.trim(tool) != "", do: tool, else: ".*"),
                      pattern: ".*",
                      action: nil,
                      text: "Rail #{Path.basename(path)} entry #{ordinal} requires repair"
                    }
                end
              end)

            _ ->
              raise ArgumentError, "#{path} must contain one or more [[statute]] tables"
          end
        rescue
          error ->
            require Logger
            Logger.warning("rail #{path} unavailable: #{Exception.message(error)}")

            [
              %{
                name: "unavailable-" <> Path.basename(path, ".toml"),
                on: :tool_call,
                mode: :gate,
                tool: ".*",
                pattern: ".*",
                action: nil,
                text: "Tool operations unavailable until rail #{Path.basename(path)} is repaired"
              }
            ]
        end
      end)

    duplicates = Enum.frequencies_by(statutes, & &1.name)

    Enum.each(duplicates, fn {name, count} ->
      if count > 1 do
        require Logger

        Logger.warning(
          "duplicate statute name: #{name} unavailable; affected tools remain closed"
        )
      end
    end)

    statutes =
      Enum.map(statutes, fn statute ->
        if duplicates[statute.name] > 1,
          do: %{
            statute
            | pattern: ".*",
              action: nil,
              text: "Duplicate statute #{statute.name} requires repair"
          },
          else: statute
      end)

    :persistent_term.put(@persist_key, statutes)
    statutes
  end

  @doc """
  The compiled PreToolUse hook map embedded in each harness's rails artifact.

  Never nil: the substrate-reserved observation entry is present whatever the
  statute set is. It is not law and is not gated on law — an org that has
  authored no statute still needs `artifact-record` to be observable, and the
  statute that makes artifacts load-bearing
  (`completion-requires-results-artifact`) lives in the DISPATCH tier, so gating
  the hook on the presence of GATE statutes would leave exactly the orgs that
  need the observation without one.
  """
  @spec hook_settings() :: map()
  def hook_settings do
    statutes = :persistent_term.get(@persist_key, [])

    statute_entries =
      statutes
      |> Enum.chunk_by(&(&1.tool == "Bash" and is_binary(&1.pattern)))
      |> Enum.flat_map(fn
        [%{tool: "Bash", pattern: pattern} | _] = bash_statutes when is_binary(pattern) ->
          bash_pre_tool_use_entries(bash_statutes)

        other_statutes ->
          Enum.map(other_statutes, &pre_tool_use_entry/1)
      end)

    %{
      "hooks" => %{
        "PreToolUse" => statute_entries ++ [github_auth_entry(), observation_entry()]
      }
    }
  end

  @doc """
  Whether any org LAW is loaded.

  Distinct from `hook_settings/0` being present, which it now always is. Only law
  can deny, so only law justifies the codex spawn wiring-check and its
  fail-closed boot: the reserved observation entry must never be able to block
  anything, a boot included.
  """
  @spec statutes?() :: boolean()
  def statutes?, do: :persistent_term.get(@persist_key, []) != []

  @doc "The compiled PreToolUse entry for the substrate-reserved codex spawn wiring-check."
  @spec probe_entry() :: map()
  def probe_entry, do: pre_tool_use_entry(@probe_statute)

  @doc """
  The compiled PreToolUse entry for the substrate-reserved artifact-record
  observation (artifact-carrier-proposal-v1 §4.1).

  Shaped like a gate and priced like one: `grep` the raw tool-call JSON on stdin
  and exit 0 immediately when the command is not an `artifact-record`, so every
  other Bash call pays one local grep and nothing else. Only the matching call
  pays the gateway round trip, which is what keeps a blocking pre-execution hop —
  over SSH from a satellite — rare by construction.

  It OBSERVES; it never refuses. Every path exits 0, including a failed call:
  `artifact-record` fails open, so a hook that could not reach the gateway must
  cost the agent nothing but the weaker evidence class it will get anyway. The
  CLI resolves url, token, and session from the workdir's `.tightbeam-session`
  exactly as the agent's own invocation does, so this stays self-contained — no
  paths, no environment beyond the `tightbeam` already on the agent's PATH.
  """
  @spec observation_entry() :: map()
  def observation_entry do
    payload =
      "grep -qE \"#{escape_double_quoted(@observation_pattern)}\" - || exit 0; " <>
        "tightbeam tool-call-observed >/dev/null 2>&1; exit 0"

    %{
      "matcher" => "Bash",
      "hooks" => [
        %{"type" => "command", "command" => "sh -c '" <> escape_single_quotes(payload) <> "'"}
      ]
    }
  end

  @doc """
  The reserved GitHub auth gate. It is not operator law; it is platform
  hygiene for a known credential seam. Non-GitHub commands exit immediately,
  while GitHub-dependent shell calls ask the local CLI to prove host auth before
  git can fall through to an interactive username/PAT prompt.
  """
  @spec github_auth_entry() :: map()
  def github_auth_entry do
    payload =
      "input=$(cat); printf '%s' \"$input\" | " <>
        "grep -qE \"#{escape_double_quoted(@github_auth_pattern)}\" - || exit 0; " <>
        "printf '%s' \"$input\" | tightbeam github-auth-check || exit 2; exit 0"

    %{
      "matcher" => "Bash",
      "hooks" => [
        %{"type" => "command", "command" => "sh -c '" <> escape_single_quotes(payload) <> "'"}
      ]
    }
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
        {:ok, "tool-call"} -> :tool_call
        {:ok, event} -> raise ArgumentError, "unknown statute event: #{inspect(event)}"
      end

    mode =
      case Map.get(statute, "mode", "gate") do
        "gate" ->
          :gate

        "remind" ->
          raise ArgumentError,
                "rails never add guidance; put prose in guidance or a skill"

        "block" ->
          raise ArgumentError, ~s(mode "block" is reserved for a later stage)

        value ->
          raise ArgumentError, "unknown statute mode: #{inspect(value)}"
      end

    tool = Map.get(statute, "tool")

    unless is_binary(tool) and String.trim(tool) != "" do
      raise ArgumentError, ~s(statute #{name} is missing "tool")
    end

    pattern = Map.get(statute, "pattern")
    action = Map.get(statute, "action")

    case {pattern, action} do
      {pattern, nil} when is_binary(pattern) ->
        if String.trim(pattern) == "" do
          raise ArgumentError,
                ~s(statute #{name} requires exactly one of "pattern" or "action")
        else
          case Regex.compile(pattern) do
            {:ok, _} ->
              :ok

            {:error, {reason, position}} ->
              raise ArgumentError,
                    "invalid gate pattern: #{inspect(pattern)}: #{reason} at byte #{position}"
          end
        end

      {nil, action} when action in @actions ->
        :ok

      {nil, nil} ->
        raise ArgumentError, ~s(statute #{name} requires exactly one of "pattern" or "action")

      {nil, action} ->
        raise ArgumentError, "unknown gate action: #{inspect(action)}"

      {_pattern, _action} ->
        raise ArgumentError, ~s(statute #{name} requires exactly one of "pattern" or "action")
    end

    text = Map.get(statute, "text")

    unless is_binary(text) and String.trim(text) != "" do
      raise ArgumentError, ~s(statute #{name} is missing "text")
    end

    %{
      name: name,
      on: on,
      mode: mode,
      tool: String.trim(tool),
      pattern: pattern,
      action: action,
      text: String.trim(text)
    }
  end

  defp pre_tool_use_entry(statute) do
    action = Map.get(statute, :action)

    predicate =
      if action do
        "tightbeam rail-action #{action}; status=$?; " <>
          "if [ \"$status\" -eq 1 ]; then exit 0; fi; " <>
          "if [ \"$status\" -ne 0 ]; then " <>
          "echo \"[gate: #{statute.name}] action classifier failed closed (status $status).\" >&2; exit 2; fi"
      else
        if statute.tool == "Bash" do
          bash_pre_tool_use_payload(statute)
        else
          "grep -qE \"#{escape_double_quoted(statute.pattern)}\" - || exit 0" <>
            "; echo \"[gate: #{statute.name}] #{escape_double_quoted(one_line(statute.text))}\" >&2; exit 2"
        end
      end

    payload =
      if action do
        predicate <>
          "; echo \"[gate: #{statute.name}] #{escape_double_quoted(one_line(statute.text))}\" >&2; exit 2"
      else
        predicate
      end

    %{
      "matcher" => statute.tool,
      "hooks" => [
        %{"type" => "command", "command" => "sh -c '" <> escape_single_quotes(payload) <> "'"}
      ]
    }
  end

  defp bash_pre_tool_use_entries(statutes) do
    statutes
    |> bash_pre_tool_use_reason_groups()
    |> Enum.reduce([], fn group, groups ->
      case groups do
        [current_group | earlier_groups] ->
          candidate = current_group ++ group

          if byte_size(bash_pre_tool_use_command(candidate)) <= @bash_hook_command_arg_bytes do
            [candidate | earlier_groups]
          else
            [group | groups]
          end

        [] ->
          [group]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      [statute] -> pre_tool_use_entry(statute)
      group -> bash_pre_tool_use_group_entry(group)
    end)
  end

  defp bash_pre_tool_use_reason_groups(statutes) do
    statutes
    |> Enum.reduce([], fn statute, groups ->
      reason_key = bash_pre_tool_use_reason_key(statute)

      case Enum.find_index(groups, fn {key, _members} -> key == reason_key end) do
        nil ->
          groups ++ [{reason_key, [statute]}]

        index ->
          List.update_at(groups, index, fn {key, members} ->
            {key, members ++ [statute]}
          end)
      end
    end)
    |> Enum.flat_map(fn {_reason_key, members} ->
      split_bash_pre_tool_use_group(members)
    end)
  end

  defp split_bash_pre_tool_use_group(statutes) do
    statutes
    |> Enum.reduce([], fn statute, groups ->
      case groups do
        [current_group | earlier_groups] ->
          candidate = current_group ++ [statute]

          if byte_size(bash_pre_tool_use_command(candidate)) <= @bash_hook_command_arg_bytes do
            [candidate | earlier_groups]
          else
            [[statute] | groups]
          end

        [] ->
          [[statute]]
      end
    end)
    |> Enum.reverse()
  end

  defp bash_pre_tool_use_group_entry(statutes) do
    %{
      "matcher" => "Bash",
      "hooks" => [%{"type" => "command", "command" => bash_pre_tool_use_command(statutes)}]
    }
  end

  defp bash_pre_tool_use_command(statutes) do
    "sh -c '" <> escape_single_quotes(grouped_bash_pre_tool_use_payload(statutes)) <> "'"
  end

  defp grouped_bash_pre_tool_use_payload(statutes) do
    # Check every statute, but report only the first matching gate for each
    # exact refusal text to avoid duplicate denial lines.
    failure_lines =
      Enum.map_join(statutes, "", fn statute ->
        "echo \"[gate: #{statute.name}] hook input check failed closed (status $status).\" >&2; "
      end)

    reason_ids =
      statutes
      |> Enum.map(&bash_pre_tool_use_reason_key/1)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    positional_values =
      Enum.map_join(statutes, " ", fn statute ->
        reason_id = Map.fetch!(reason_ids, bash_pre_tool_use_reason_key(statute))

        "\"#{escape_double_quoted(statute.pattern)}\" " <>
          "\"#{escape_double_quoted(statute.name)}\" " <>
          "\"#{escape_double_quoted(one_line(statute.text))}\" " <>
          "\"#{reason_id}\""
      end)

    pattern_arguments =
      statutes
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {_statute, index} -> "-e \"${#{1 + 4 * index}}\"" end)

    "input=$(cat); printf '%s' \"$input\" | tightbeam hook-command > /dev/null 2>/dev/null; status=$?; " <>
      "if [ \"$status\" -ne 0 ]; then " <>
      failure_lines <>
      "exit 2; fi; set -- " <>
      positional_values <>
      "; printf '%s' \"$input\" | grep -qE " <>
      pattern_arguments <>
      " >/dev/null 2>/dev/null; match_status=$?; " <>
      "if [ \"$match_status\" -eq 1 ]; then exit 0; fi; " <>
      "denied=0; reported_reasons=','; while [ \"$#\" -gt 0 ]; do " <>
      "pattern=$1; gate=$2; reason=$3; reason_id=$4; shift 4; " <>
      "printf '%s' \"$input\" | grep -qE \"$pattern\"; match_status=$?; " <>
      "if [ \"$match_status\" -eq 0 ]; then " <>
      "case \"$reported_reasons\" in *\",$reason_id,\"*) ;; " <>
      "*) echo \"[gate: $gate] $reason\" >&2; reported_reasons=\"$reported_reasons$reason_id,\";; esac; " <>
      "denied=1; " <>
      "elif [ \"$match_status\" -ne 1 ]; then " <>
      "echo \"[gate: $gate] hook input check failed closed (status $match_status).\" >&2; denied=1; fi; " <>
      "done; if [ \"$denied\" -eq 1 ]; then exit 2; fi; exit 0"
  end

  defp bash_pre_tool_use_reason_key(statute), do: one_line(statute.text)

  defp bash_pre_tool_use_payload(statute) do
    failure = "[gate: #{statute.name}] hook input check failed closed (status "
    refusal = "[gate: #{statute.name}] #{escape_double_quoted(one_line(statute.text))}"

    "input=$(cat); printf '%s' \"$input\" | tightbeam hook-command > /dev/null 2>/dev/null; status=$?; " <>
      "if [ \"$status\" -ne 0 ]; then echo \"#{failure}$status).\" >&2; exit 2; fi; " <>
      "printf '%s' \"$input\" | grep -qE \"#{escape_double_quoted(statute.pattern)}\" || exit 0; " <>
      "echo \"#{refusal}\" >&2; exit 2"
  end

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  defp escape_single_quotes(text), do: String.replace(text, "'", "'\\''")

  # Backslash FIRST: inside a shell double-quoted string a pattern's own
  # backslash would otherwise pair with a following escape and un-escape it
  # — `\$HOME` must reach grep as a literal-dollar regex, never expand.
  defp escape_double_quoted(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
  end
end
