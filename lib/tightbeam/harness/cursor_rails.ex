defmodule Tightbeam.Harness.CursorRails do
  @moduledoc """
  Compile Tightbeam rails into Cursor's hooks config.

  Tightbeam rails are authored once, in the Claude/codex `PreToolUse` shape that
  `Tightbeam.Rails.hook_settings/0` and `Tightbeam.Rails.probe_entry/0` emit:

      %{"hooks" => %{"PreToolUse" => [
        %{"matcher" => "Bash",
          "hooks" => [%{"type" => "command", "command" => "sh -c '...'"}]},
        ...
      ]}}

  Cursor's gate is a DIFFERENT config with a DIFFERENT deny PROTOCOL. This module
  is the pure transform between them; `Tightbeam.Harness.Cursor.reconcile_home/3`
  calls it to write `~/.cursor/hooks.json`.

  ## Two things this transform reconciles

  1. **Shape.** Cursor keys hooks by lifecycle event, not by a `matcher` field:

         %{"hooks" => %{"beforeShellExecution" => [%{"command" => "..."}], ...}}

     The Tightbeam `matcher` selects the Cursor event (see `event_for/1`).

  2. **Deny protocol (the load-bearing part).** A Tightbeam rail BLOCKS by
     `exit 2` and writes its `[gate: ...]` reason to stderr. Cursor ignores that:
     its `beforeShellExecution`/`beforeMCPExecution` hook gates by writing a JSON
     verdict to STDOUT and exiting 0 —

         {"permission":"allow"|"ask"|"deny","user_message":"..."}

     — where `deny` blocks the tool call. A nonzero exit is Cursor's hook-FAILURE
     path (blocks only when the hook is separately marked fail-closed), NOT the
     intentional-gate path. So copying a Tightbeam command verbatim into a Cursor
     hook would be silently ignored — a gate bypass. Each command is therefore
     WRAPPED (`wrap/1`): run the original command against Cursor's stdin, then map
     its `exit 2`+stderr to `{"permission":"deny","user_message":<stderr>}` and any
     other exit to `{"permission":"allow"}`. The original command is carried
     base64-encoded so its own quoting survives the wrap untouched, and it stays
     the exact byte-for-byte gate logic — no pattern or message is re-derived.

  Contract captured from the real `cursor-agent` binary (v2026.08.11-e8db854); the
  deny/allow behaviour is exercised against real command execution in the tests,
  not asserted against a hand-written fixture.

  ## Rails floor — no silent drops

  Every command-block rail MUST land on an enforcing Cursor *before-execution*
  hook. A `matcher` with no such analog (e.g. `Edit`/`Write`: Cursor exposes only
  `afterFileEdit`, which fires too late to gate) is REFUSED: `event_for/1` raises
  `UnmappableRailError` rather than route it to a non-gating event or drop it. An
  unmapped rail cannot pass silently; it fails the compile loudly for adjudication.
  """

  defmodule UnmappableRailError do
    @moduledoc """
    Raised when a Tightbeam rail's `matcher` has no enforcing Cursor
    before-execution hook. Fail-closed: never silently dropped or mis-routed.
    """
    defexception [:matcher]

    @impl true
    def message(%{matcher: matcher}) do
      "no enforcing Cursor before-execution hook for Tightbeam rail matcher " <>
        "#{inspect(matcher)} — refusing to silently drop or mis-route a gate " <>
        "(rails floor). Add a mapping to Tightbeam.Harness.CursorRails.event_for/1 " <>
        "only once the enforcing Cursor event is confirmed, or adjudicate the gap."
    end
  end

  # Tightbeam PreToolUse `matcher` -> Cursor before-execution hook event.
  #
  # ONLY matchers with a genuine, MATCHER-FAITHFUL BEFORE-execution gate belong
  # here. Today that is exactly "Bash" -> beforeShellExecution: the reserved
  # Tightbeam entries (probe, observation, github-auth) and every shipped statute
  # use "Bash".
  #
  # MCP is deliberately NOT mapped. A Tightbeam "mcp__<server>__<tool>" matcher
  # gates ONE specific tool, but Cursor's beforeMCPExecution fires for EVERY MCP
  # call and this compiler cannot re-derive a per-tool guard from the opaque
  # wrapped command — routing an mcp__ rail there would gate unrelated MCP tools
  # (matcher parity violation / false positives, wisdom 4). No shipped statute
  # targets MCP, so refusing it costs nothing today; it raises (see
  # UnmappableRailError) until a tool-faithful Cursor contract exists.
  @shell_event "beforeShellExecution"

  @doc """
  Compile a Tightbeam PreToolUse hook map into a Cursor hooks config.

  `nil` (no rails) and an empty PreToolUse list compile to an empty hooks config.
  Raises `UnmappableRailError` on any rail whose matcher has no enforcing Cursor
  before-execution hook.

  ## Options

    * `:path` — the PATH the wrapped command runs with. Reserved Tightbeam
      rails (`github-auth-check`, `tool-call-observed`) invoke the `tightbeam`
      helper by bare name, and `github-auth-check` in turn needs `gh`; both rely
      on the harness PATH. Claude and codex inherit it from `common_env`; Cursor
      runs under the dedicated execution identity whose launcher sets a FIXED
      system PATH (deliberately — an inherited PATH was a code-execution hole
      into uid 503). So the Cursor wrapper itself sets PATH before running the
      carried command, to the SAME value `common_env` gives the other harnesses
      (`cli_bin` + the gateway's PATH: operator-side config, hashed into the
      projected hooks and re-verified by the launcher), never anything from the
      launched process's env. Proven live 2026-08-29: without it the GitHub-auth
      rail failed closed (`sh: tightbeam: command not found`) and refused git.
  """
  @spec compile(map() | nil, keyword()) :: map()
  def compile(settings, opts \\ [])

  def compile(nil, _opts), do: %{"version" => 1, "hooks" => %{}}

  def compile(%{"hooks" => %{"PreToolUse" => entries}}, opts) when is_list(entries) do
    path = Keyword.get(opts, :path)

    hooks =
      Enum.reduce(entries, %{}, fn %{"matcher" => matcher, "hooks" => cmds}, acc ->
        event = event_for(matcher)
        cursor_cmds = Enum.map(cmds, &to_cursor_command(&1, path))
        Map.update(acc, event, cursor_cmds, &(&1 ++ cursor_cmds))
      end)

    %{"version" => 1, "hooks" => hooks}
  end

  @doc """
  The Cursor before-execution hook event that enforces a Tightbeam `matcher`.

  Raises `UnmappableRailError` for any matcher without an enforcing analog, so a
  gate can never be silently dropped or routed to a non-gating (after-*) event.
  """
  @spec event_for(String.t()) :: String.t()
  def event_for("Bash"), do: @shell_event
  def event_for(matcher), do: raise(UnmappableRailError, matcher: matcher)

  # Wrap one Tightbeam command entry into a Cursor command entry that speaks
  # Cursor's stdout permission protocol.
  defp to_cursor_command(%{"type" => "command", "command" => tb_command}, path) do
    %{"command" => wrap(tb_command, path)}
  end

  # JSON-string encoding of the captured stderr reason, pure POSIX (no jq/python
  # dependency for the rare deny path). `tr '\000-\037' ' '` first maps EVERY JSON
  # control byte (0x00-0x1F: newline, CR, tab, and the rest) to a space, so a
  # multi-line or control-byte reason cannot break out of the JSON string; sed
  # then escapes backslash and quote. Result: always well-formed JSON — a deny is
  # never downgraded to a hook-failure (which Cursor would treat as a non-deny,
  # i.e. a bypass). The reason is flattened to one line, not dropped. Kept as a
  # raw sigil so the shell sees the escapes verbatim.
  @json_encode_reason ~S(tr '\000-\037' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')

  # Adapt a Tightbeam gate command (block = exit 2 + stderr reason; allow = exit 0)
  # to Cursor's protocol (stdout JSON verdict, exit 0). Cursor runs this string in
  # a shell with the hook payload on stdin; we feed that stdin to the original
  # command (carried base64 so its quoting is inert), capture its stderr as the
  # deny reason, and translate its exit code. Only Tightbeam's defined block code
  # (2) denies; every other exit allows, preserving PreToolUse parity exactly.
  defp wrap(tb_command, path) do
    b64 = Base.encode64(tb_command)

    path_prefix(path) <>
      "in=$(cat); " <>
      "msg=$(printf '%s' \"$in\" | sh -c \"$(printf '%s' '#{b64}' | base64 -d)\" 2>&1 1>/dev/null); " <>
      "rc=$?; " <>
      "if [ \"$rc\" = 2 ]; then " <>
      "esc=$(printf '%s' \"$msg\" | #{@json_encode_reason}); " <>
      "printf '{\"permission\":\"deny\",\"user_message\":\"%s\"}' \"$esc\"; " <>
      "else printf '{\"permission\":\"allow\"}'; fi"
  end

  # Set the operator-configured PATH for the wrapped command only (the fixed
  # launcher PATH is kept as a suffix). Single-quoted so the value is inert to
  # the shell; a value containing a single quote is refused rather than
  # mis-quoted.
  defp path_prefix(nil), do: ""

  defp path_prefix(path) when is_binary(path) do
    if String.contains?(path, "'") do
      raise ArgumentError, "Cursor rails :path must not contain a single quote: #{inspect(path)}"
    end

    "PATH='" <> path <> "':\"$PATH\"; export PATH; "
  end
end
