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
  `check` selects one of the two checks carried by a TOML statute:
  `github-auth` and `spawn-probe`.

  Loading is boot-time and fail-closed: substrate files under
  `<base_dir>/identity/rails/*.toml` and receipt-owned kungfu files under
  `<base_dir>/identity/kungfu/*/rails/*.toml` are loaded in path order. Every
  statute is validated before the set is stored in
  `:persistent_term`; a malformed statute is logged and replaced by a
  catch-all refusal. Statute changes ride the home's `extra_files` into the
  manifest hash: a law change is an identity change and regenerates homes.

  Hook settings stay self-contained: commands embed no home paths and need no
  gateway connection. During per-session workdir provisioning, this module
  compiles the session's active statute names with the shared
  `Tightbeam.RailScope` matcher and writes them beside the qualified archetype
  in a non-secret sidecar. Hook wrappers consult that compiled name set only
  after their statute pattern or action matches. This keeps calls outside a
  statute's pattern on the 0.1.16 pass path and avoids starting a BEAM runtime
  per tool call. Pattern statutes match their POSIX ERE against the RAW
  tool-call JSON on stdin, so no jq is required on satellites; patterns should
  not rely on matching bare `"` characters, which arrive JSON-escaped. Closed
  action statutes parse `tool_input.command` and classify executable argv
  instead, so quoted prose cannot impersonate an action.
  """

  @persist_key __MODULE__
  @session_scope_filename ".tightbeam-rail-scope.json"
  @statute_keys MapSet.new([
                  "name",
                  "on",
                  "mode",
                  "text",
                  "check",
                  "archetypes",
                  "tool",
                  "pattern",
                  "action"
                ])
  @actions ~w(git-stash git-reset-hard git-clean-force git-checkout-discard git-restore)
  # Deliberately loose on what sits between the two words — the agent may write
  # `tightbeam  artifact-record`, or reach the binary by path. Loose is the right
  # direction here: a false match opens a window the record then binds, which is
  # the same turn it would have bound anyway, while a miss silently downgrades a
  # correct agent's evidence.
  @observation_pattern "tightbeam[^\"]*artifact-record"
  @checks ~w(github-auth spawn-probe)

  @typedoc "A validated gate statute."
  @type statute :: %{
          name: String.t(),
          on: :tool_call,
          mode: :gate,
          tool: String.t(),
          pattern: String.t() | nil,
          action: String.t() | nil,
          check: String.t() | nil,
          archetypes: [String.t()],
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
      statute_paths(base_dir)
      |> Enum.flat_map(fn path ->
        try do
          manifest = path |> File.read!() |> Toml.decode!()

          case Map.get(manifest, "statute") do
            statutes when is_list(statutes) and statutes != [] ->
              statutes
              |> Enum.with_index(1)
              |> Enum.map(fn {raw, ordinal} ->
                try do
                  validate!(raw, base_dir, path)
                rescue
                  error ->
                    require Logger

                    Logger.warning(
                      "rail #{path} entry #{ordinal} unavailable: #{Exception.message(error)}"
                    )

                    tool = if is_map(raw), do: Map.get(raw, "tool"), else: nil

                    %{
                      name:
                        qualified_name(
                          base_dir,
                          path,
                          "unavailable-#{Path.basename(path, ".toml")}-#{ordinal}"
                        ),
                      on: :tool_call,
                      mode: :gate,
                      tool: if(is_binary(tool) and String.trim(tool) != "", do: tool, else: ".*"),
                      pattern: ".*",
                      action: nil,
                      check: nil,
                      archetypes: fallback_archetypes(base_dir, path),
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
                name:
                  qualified_name(base_dir, path, "unavailable-" <> Path.basename(path, ".toml")),
                on: :tool_call,
                mode: :gate,
                tool: ".*",
                pattern: ".*",
                action: nil,
                check: nil,
                archetypes: fallback_archetypes(base_dir, path),
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
              check: nil,
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
  @spec hook_settings(atom() | String.t()) :: map()
  def hook_settings(harness) do
    statutes = :persistent_term.get(@persist_key, [])
    statutes = Enum.filter(statutes, &enabled_for_harness?(&1, harness))

    %{
      "hooks" => %{
        "PreToolUse" => Enum.map(statutes, &pre_tool_use_entry/1) ++ [observation_entry()]
      }
    }
  end

  @doc "The non-secret session scope sidecar filename."
  @spec session_scope_filename() :: String.t()
  def session_scope_filename, do: @session_scope_filename

  @doc "Compile the active statute names for the current qualified archetype into a session workdir sidecar."
  @spec session_scope_content(String.t()) :: String.t()
  def session_scope_content(archetype) when is_binary(archetype) do
    statutes =
      :persistent_term.get(@persist_key, [])
      |> Enum.filter(fn statute ->
        Tightbeam.RailScope.matches_agents?(statute.archetypes, [archetype])
      end)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()

    JSON.encode!(%{"archetype" => archetype, "statutes" => statutes})
  end

  @doc """
  Whether any org LAW is loaded.

  Distinct from `hook_settings/1` being present, which it now always is. Only law
  can deny, so only law justifies the codex spawn wiring-check and its
  fail-closed boot: the reserved observation entry must never be able to block
  anything, a boot included.
  """
  @spec statutes?() :: boolean()
  def statutes? do
    Enum.any?(:persistent_term.get(@persist_key, []), &is_nil(&1.check))
  end

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

  defp validate!(statute, base_dir, path) when is_map(statute) do
    keys = Map.keys(statute) |> MapSet.new()

    unknown = keys |> MapSet.difference(@statute_keys) |> MapSet.to_list() |> Enum.sort()

    if unknown != [] do
      raise ArgumentError, "unknown statute keys: #{Enum.join(unknown, ", ")}"
    end

    name = Map.get(statute, "name")

    check = Map.get(statute, "check")

    if MapSet.member?(keys, "check") and check not in @checks do
      raise ArgumentError,
            "statute #{inspect(name)} in #{path} has unsupported check value #{inspect(check)}; " <>
              "allowed values: #{Enum.join(@checks, ", ")}"
    end

    action = Map.get(statute, "action")

    if not is_nil(check) and MapSet.member?(keys, "action") do
      raise ArgumentError,
            "statute #{inspect(name)} in #{path} cannot combine check value #{inspect(check)} " <>
              "with action #{inspect(action)}; allowed check values: #{Enum.join(@checks, ", ")}"
    end

    archetypes =
      case Map.fetch(statute, "archetypes") do
        :error ->
          []

        {:ok, names} when is_list(names) ->
          unless Enum.all?(names, &is_binary/1) do
            raise ArgumentError,
                  "statute #{inspect(name)} in #{path} archetypes must be a list of strings"
          end

          names

        {:ok, other} ->
          raise ArgumentError,
                "statute #{inspect(name)} in #{path} archetypes must be a list of strings, " <>
                  "got #{inspect(other)}"
      end

    owner =
      Tightbeam.Identity.Provenance.owner_for_path(base_dir, Path.relative_to(path, base_dir))

    validate_archetypes!(name, path, base_dir, owner, archetypes)

    # An org-written statute without `archetypes` names no agent and never fires.
    if owner == :substrate and not Map.has_key?(statute, "archetypes") do
      require Logger

      Logger.warning(
        "#{path}: statute #{inspect(name)} omits archetypes and applies to no agent; " <>
          ~s(add archetypes = ["*"] to apply it to every agent)
      )
    end

    cond do
      is_nil(name) ->
        raise ArgumentError, ~s(statute is missing "name")

      not (is_binary(name) and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name)) ->
        raise ArgumentError, "invalid statute name: #{inspect(name)}"

      true ->
        :ok
    end

    qualified_name = Tightbeam.Identity.Provenance.qualify(owner, name)

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
      name: qualified_name,
      on: on,
      mode: mode,
      tool: String.trim(tool),
      pattern: pattern,
      action: action,
      check: check,
      archetypes: archetypes,
      text: String.trim(text)
    }
  end

  defp validate_archetypes!(_name, _path, _base_dir, :substrate, _archetypes), do: :ok

  defp validate_archetypes!(name, path, base_dir, {:kungfu, kungfu}, archetypes) do
    allowed =
      base_dir
      |> Tightbeam.Identity.Provenance.archetype_names(kungfu)
      |> Enum.map(&Tightbeam.Identity.Provenance.qualify({:kungfu, kungfu}, &1))

    invalid = Enum.reject(archetypes, &(&1 in allowed))

    if invalid != [] do
      raise ArgumentError,
            "statute #{inspect(name)} in #{path} has out-of-scope archetypes " <>
              "#{inspect(invalid)}; allowed names for #{kungfu}: #{Enum.join(allowed, ", ")}"
    end
  end

  defp fallback_archetypes(base_dir, path) do
    case Tightbeam.Identity.Provenance.owner_for_path(base_dir, Path.relative_to(path, base_dir)) do
      :substrate ->
        ["*"]

      {:kungfu, kungfu} ->
        base_dir
        |> Tightbeam.Identity.Provenance.archetype_names(kungfu)
        |> Enum.map(&Tightbeam.Identity.Provenance.qualify({:kungfu, kungfu}, &1))
    end
  end

  defp qualified_name(base_dir, path, name) do
    relative_path = Path.relative_to(path, base_dir)
    owner = Tightbeam.Identity.Provenance.owner_for_path(base_dir, relative_path)
    Tightbeam.Identity.Provenance.qualify(owner, name)
  end

  defp statute_paths(base_dir) do
    identity = Path.join(base_dir, "identity")

    (Path.wildcard(Path.join(identity, "rails/*.toml")) ++
       Path.wildcard(Path.join(identity, "kungfu/*/rails/*.toml")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pre_tool_use_entry(statute) do
    action = Map.get(statute, :action)
    check = Map.get(statute, :check)

    payload =
      case check do
        "github-auth" ->
          github_auth_check_payload(statute)

        "spawn-probe" ->
          pattern_gate_payload(statute)

        nil when not is_nil(action) ->
          action_gate_payload(statute)

        nil ->
          pattern_gate_payload(statute)
      end

    %{
      "matcher" => statute.tool,
      "hooks" => [
        %{"type" => "command", "command" => "sh -c '" <> escape_single_quotes(payload) <> "'"}
      ]
    }
  end

  defp action_gate_payload(statute) do
    action = Map.get(statute, :action)
    scope = scope_check(statute)

    "input=$(cat); printf '%s' \"$input\" | tightbeam rail-action #{action}; status=$?; " <>
      "if [ \"$status\" -eq 1 ]; then exit 0; fi; " <>
      "if [ \"$status\" -ne 0 ]; then " <>
      "echo \"[gate: #{statute.name}] action classifier failed closed (status $status).\" >&2; exit 2; fi; " <>
      scope <> generic_refusal(statute)
  end

  defp pattern_gate_payload(statute) do
    scope = scope_check(statute)

    "input=$(cat); printf '%s' \"$input\" | grep -qE \"#{escape_double_quoted(statute.pattern)}\" - || exit 0; " <>
      scope <> generic_refusal(statute)
  end

  defp github_auth_check_payload(statute) do
    "input=$(cat); " <>
      "printf '%s' \"$input\" | " <>
      "grep -qE \"#{escape_double_quoted(statute.pattern)}\" - || exit 0; " <>
      scope_check(statute) <>
      "printf '%s' \"$input\" | tightbeam github-auth-check --text-template " <>
      "'#{escape_single_quotes(one_line(statute.text))}' || exit 2; exit 0"
  end

  defp scope_check(%{archetypes: ["*"]}), do: ""

  defp scope_check(statute) do
    "tightbeam rail-scope-check --statute " <>
      "'#{escape_single_quotes(statute.name)}' >/dev/null 2>&1; status=$?; " <>
      "if [ \"$status\" -eq 1 ]; then exit 0; fi; " <>
      "if [ \"$status\" -ne 0 ]; then " <>
      "echo \"[gate: #{statute.name}] archetype scope check failed (status $status).\" >&2; exit 2; fi; "
  end

  defp enabled_for_harness?(%{check: "spawn-probe"}, harness)
       when harness in [:codex, :pi, "codex", "pi"],
       do: true

  defp enabled_for_harness?(%{check: "spawn-probe"}, _harness), do: false

  defp enabled_for_harness?(_statute, _harness), do: true

  defp generic_refusal(statute) do
    "echo \"[gate: #{statute.name}] #{escape_double_quoted(one_line(statute.text))}\" >&2; exit 2"
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
