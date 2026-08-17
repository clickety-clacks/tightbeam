// Tightbeam gate plugin for OpenCode (@opencode-ai/plugin).
//
// Tightbeam-owned, materialized out-of-tree (a dir the agent cannot edit) and referenced by
// absolute path from a Tightbeam-owned opencode config, which `prepare_launch/3` points at via
// OPENCODE_CONFIG. It is the OpenCode analog of the codex/claude PreToolUse gate: `tool.execute.
// before` runs BEFORE the tool executes, and a throw aborts the call (verified against the
// installed opencode 1.18.18 binary control-flow — the tool wrapper `yield*`s this hook
// immediately before `u.execute(...)` with no swallowing catch). The thrown message carries the
// same `[gate: <name>] <text>` marker the adapter watches for (`acp/adapter.ex` @gate_marker).
//
// This build enforces the substrate-reserved wiring-check probe (the same statute codex drives
// at boot). Full operator-statute parity — executing the compiled PreToolUse set for every
// authored statute — is the tracked follow-on (rails-parity / HB-05); it slots in here by
// reading a Tightbeam-written rails artifact and matching each statute's pattern the same way.

const RESERVED_PROBE = {
  name: "tightbeam-probe",
  pattern: "tightbeam-gate-probe",
  text: "Spawn wiring-check probe command; always refused by design.",
};

export const TightbeamGate = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      // Match against a JSON serialization of the proposed call, mirroring the raw tool-call
      // JSON the PreToolUse hooks grep on stdin: the tool name plus its arguments (which carry
      // the shell command for a Bash tool).
      const callJson = JSON.stringify({
        tool: input && input.tool,
        args: output && output.args,
      });

      for (const statute of [RESERVED_PROBE]) {
        let re;
        try {
          re = new RegExp(statute.pattern);
        } catch (e) {
          // FAIL-CLOSED: a malformed statute pattern is a broken gate, not an absent one. Deny
          // the call rather than skip the statute — a skipped rule is a silent hole, exactly the
          // failure a rails gate must never have.
          throw new Error(`[gate: ${statute.name}] malformed statute pattern; denied fail-closed`);
        }
        if (re.test(callJson)) {
          // Same refusal contract as the codex/claude gate: abort the call before it runs and
          // deliver the statute text as the denial reason, prefixed with the recognizable marker.
          throw new Error(`[gate: ${statute.name}] ${statute.text}`);
        }
      }
    },
  };
};
