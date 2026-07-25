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
  seeds the harness trust override whenever statutes exist; the adapter
  spreads that request override into every thread config and arms the
  substrate-projected home's rails artifact. The seed is
  `CODEX_CONFIG={"bypass_hook_trust":true}`. Because either seed or file can
  fail silently, the adapter drives the reserved probe at boot and fails
  closed unless it observes the refusal.

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
  satellites) and match the statute's POSIX ERE against the RAW tool-call
  JSON on stdin, so no jq is required on satellites; patterns should not
  rely on matching bare `"` characters, which arrive JSON-escaped.
  """

  @persist_key __MODULE__
  @statute_keys MapSet.new(["name", "on", "mode", "text", "check", "tool", "pattern"])
  @probe_statute %{
    name: "tightbeam-probe",
    on: :tool_call,
    mode: :gate,
    tool: "Bash",
    pattern: "tightbeam-gate-probe",
    text: "Spawn wiring-check probe command; always refused by design."
  }

  @typedoc "A validated gate statute."
  @type statute :: %{
          name: String.t(),
          on: :tool_call,
          mode: :gate,
          tool: String.t(),
          pattern: String.t(),
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

  @doc "The compiled PreToolUse hook map embedded in each harness's rails artifact, or nil for an empty statute set."
  @spec hook_settings() :: map() | nil
  def hook_settings do
    case :persistent_term.get(@persist_key, []) do
      [] ->
        nil

      statutes ->
        %{"hooks" => %{"PreToolUse" => Enum.map(statutes, &pre_tool_use_entry/1)}}
    end
  end

  @doc "The compiled PreToolUse entry for the substrate-reserved codex spawn wiring-check."
  @spec probe_entry() :: map()
  def probe_entry, do: pre_tool_use_entry(@probe_statute)

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

    unless is_binary(pattern) and String.trim(pattern) != "" do
      raise ArgumentError, ~s(statute #{name} is missing "pattern")
    end

    case Regex.compile(pattern) do
      {:ok, _} -> :ok
      {:error, _} -> raise ArgumentError, "invalid gate pattern: #{inspect(pattern)}"
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
      text: String.trim(text)
    }
  end

  defp pre_tool_use_entry(statute) do
    payload =
      "grep -qE \"#{escape_double_quoted(statute.pattern)}\" - || exit 0; " <>
        "echo \"[gate: #{statute.name}] #{escape_double_quoted(one_line(statute.text))}\" >&2; exit 2"

    %{
      "matcher" => statute.tool,
      "hooks" => [
        %{"type" => "command", "command" => "sh -c '" <> escape_single_quotes(payload) <> "'"}
      ]
    }
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
