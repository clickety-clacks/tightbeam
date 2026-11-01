// Runs the real PiAcpSession and PiRpcProcess classes from a pi-acp@0.0.33
// dist/index.js (pristine or Tightbeam-patched) against synthetic Pi RPC event
// streams. No Pi process, model or provider is involved.
//
// Event shapes follow the Pi sources the adapter runs against:
//   Pi 0.84.1 dist/core/agent-session.js (sha256 91e72d54...): agent_end carries
//     messages and willRetry (:353); auto_retry_start (:2134); auto_retry_end
//     success:true on a recovered message_end (:392), success:false with
//     finalError on exhaustion (:769-772) and "Retry cancelled" on abort
//     (:2155-2158); agent_settled has no fields (:330-331).
//   Pi 1.4.0 dist/core/agent-session.js (sha256 436e8be3...): the same events,
//     exhaustion at :1552-1555, cancellation at :3080, and
//     agent_settled { aborted } (:689-690).
// Both versions emit agent_end before the post-run handling that reports a
// failed retry chain, because agent-core awaits listeners per event.

import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Verbatim subset of @agentclientprotocol/sdk@0.26.0 dist/acp.js RequestError,
// the class pi-acp@0.0.33 imports. Its connection serializes a thrown
// RequestError as the JSON-RPC error { code, message, data }.
const sdkStub = `
class RequestError extends Error {
  code;
  data;
  constructor(code, message, data) {
    super(message);
    this.code = code;
    this.name = "RequestError";
    this.data = data;
  }
  static internalError(data, additionalMessage) {
    return new RequestError(-32603, \`Internal error\${additionalMessage ? \`: \${additionalMessage}\` : ""}\`, data);
  }
  static authRequired(data, additionalMessage) {
    return new RequestError(-32000, \`Authentication required\${additionalMessage ? \`: \${additionalMessage}\` : ""}\`, data);
  }
}
`;

function extractClass(source, name) {
  const start = source.indexOf(`var ${name} = class`);
  if (start === -1) throw new Error(`bundle has no class ${name}`);
  const end = source.indexOf("\n};\n", start);
  return source.slice(start, end + 4);
}

function extractFunction(source, name, { optional = false } = {}) {
  const start = source.indexOf(`\nfunction ${name}(`);
  if (start === -1) {
    if (optional) return "";
    throw new Error(`bundle has no function ${name}`);
  }
  const end = source.indexOf("\n}\n", start);
  return source.slice(start + 1, end + 3);
}

function extractConstant(source, name) {
  const start = source.indexOf(`\nvar ${name} = `);
  if (start === -1) throw new Error(`bundle has no constant ${name}`);
  return source.slice(start + 1, source.indexOf(";\n", start) + 2);
}

async function loadBundle(source) {
  const module = [
    sdkStub,
    extractConstant(source, "PI_SETUP_METHOD_ID"),
    ...["getAuthMethods", "terminalAuthLaunchSpec", "maybeAuthRequiredError", "expandSlashCommand",
      "formatAutoRetryMessage"].map((name) => extractFunction(source, name)),
    // Present only in the Tightbeam-patched bundle.
    extractFunction(source, "tightbeamPiMaskValue", { optional: true }),
    extractFunction(source, "tightbeamPiRedact", { optional: true }),
    extractFunction(source, "tightbeamPiSafeError", { optional: true }),
    extractFunction(source, "tightbeamPiTurnError", { optional: true }),
    extractClass(source, "PiRpcProcess"),
    extractClass(source, "PiAcpSession"),
    "export { PiAcpSession, PiRpcProcess };",
    source.includes("\nfunction tightbeamPiRedact(") ? "export { tightbeamPiRedact };" : ""
  ].join("\n");
  const path = join(tmpdir(), `pi-acp-turn-contract-${process.pid}-${Date.now()}.mjs`);
  writeFileSync(path, module);
  return import(path);
}

const user = { role: "user", content: [{ type: "text", text: "hi" }] };
const failed = (errorMessage) => ({ role: "assistant", content: [], stopReason: "error", errorMessage });
const answered = { role: "assistant", content: [{ type: "text", text: "done" }], stopReason: "stop" };

function settled(version, aborted = false) {
  return version === "1.4.0" ? { type: "agent_settled", aborted } : { type: "agent_settled" };
}

function failedRun(errorMessage, willRetry) {
  return [
    { type: "agent_start" },
    { type: "message_end", message: failed(errorMessage) },
    { type: "agent_end", messages: [user, failed(errorMessage)], willRetry }
  ];
}

function retryStart(attempt, errorMessage, delayMs = 2000) {
  return { type: "auto_retry_start", attempt, maxAttempts: 3, delayMs, errorMessage };
}

const scripts = {
  success: (version) => [
    { type: "agent_start" },
    { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "hello" } },
    { type: "message_end", message: answered },
    { type: "agent_end", messages: [user, answered], willRetry: false },
    settled(version)
  ],
  // Turn 38756: the initial request and three auto-retries all timed out.
  exhausted: (version, finalError = "Request timed out.") => [
    ...failedRun(finalError, true),
    retryStart(1, finalError),
    ...failedRun(finalError, true),
    retryStart(2, finalError, 4000),
    ...failedRun(finalError, true),
    retryStart(3, finalError, 8000),
    ...failedRun(finalError, false),
    { type: "auto_retry_end", success: false, attempt: 3, finalError },
    settled(version)
  ],
  recovered: (version) => [
    ...failedRun("overloaded", true),
    retryStart(1, "overloaded"),
    { type: "agent_start" },
    { type: "message_update", assistantMessageEvent: { type: "text_delta", delta: "recovered" } },
    { type: "message_end", message: answered },
    { type: "auto_retry_end", success: true, attempt: 1 },
    { type: "agent_end", messages: [user, answered], willRetry: false },
    settled(version)
  ],
  // A failed retry chain followed by automatic compaction and a successful run.
  supersededByLaterRun: (version) => [
    ...failedRun("context_length_exceeded", true),
    retryStart(1, "context_length_exceeded"),
    ...failedRun("context_length_exceeded", false),
    { type: "auto_retry_end", success: false, attempt: 1, finalError: "context_length_exceeded" },
    { type: "agent_start" },
    { type: "message_end", message: answered },
    { type: "agent_end", messages: [user, answered], willRetry: false },
    settled(version)
  ],
  assistantError: (version) => [
    ...failedRun("400 invalid_request_error: bad schema", false),
    settled(version)
  ],
  unsafeError: (version) =>
    scripts.exhausted(
      version,
      "401 echoed sk-proj-ABCDEFGHIJKLMNOP\nAuthorization: Bearer sk-live-abcdefghijklmnop api_key=SECRETVALUE " +
        "Authorization: Basic dXNlcjpwYXNzd29yZA== Cookie: session=topsecret " +
        "https://alice:hunter2@example.test/fail ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456 " +
        'password="secret phrase with spaces" ' +
        "x".repeat(5000)
    )
};

class Turns {
  constructor(PiAcpSession, PiRpcProcess, sessionId) {
    this.updates = [];
    this.requests = [];
    this.steps = [];
    this.onAbort = null;
    // The real PiRpcProcess prompt/abort/onEvent methods over a scripted
    // request transport; events reach handlers the way its stdout reader does.
    const proc = Object.create(PiRpcProcess.prototype);
    proc.eventHandlers = [];
    proc.pending = new Map();
    proc.request = async (message) => {
      this.requests.push(message.type);
      if (message.type === "abort") {
        const abort = this.onAbort;
        this.onAbort = null;
        if (abort) setTimeout(abort, 0);
        return { success: true };
      }
      const step = this.steps.shift();
      if (step.rejection) return { success: false, error: step.rejection };
      setTimeout(() => {
        for (const event of step.events) for (const handler of proc.eventHandlers) handler(event);
        if (step.onCancel) this.onAbort = () => {
          for (const event of step.onCancel) for (const handler of proc.eventHandlers) handler(event);
        };
      }, 0);
      return { success: true };
    };
    this.proc = proc;
    this.session = new PiAcpSession({
      sessionId,
      cwd: "/synthetic",
      mcpServers: [],
      proc,
      conn: { sessionUpdate: async (notification) => this.updates.push(notification.update) },
      fileCommands: []
    });
  }

  prompt(step) {
    this.steps.push(step);
    return this.session.prompt("hi").then(
      (stopReason) => ({ stopReason }),
      (error) => ({ error: { code: error.code, message: error.message, data: error.data ?? null } })
    );
  }

  text() {
    return this.updates
      .filter((update) => update.sessionUpdate === "agent_message_chunk")
      .map((update) => update.content.text);
  }
}

// The adapter's redaction applied to each text, for parity with ErrorDiagnostic.
export async function runRedaction(source, texts) {
  const { tightbeamPiRedact } = await loadBundle(source);
  return texts.map((text) => tightbeamPiRedact(text));
}

export async function runTurnContract(source, version) {
  const { PiAcpSession, PiRpcProcess } = await loadBundle(source);
  const turns = (id) => new Turns(PiAcpSession, PiRpcProcess, id);
  const single = async (step) => {
    const t = turns("single");
    const result = await t.prompt(step);
    return { ...result, text: t.text(), requests: t.requests };
  };

  const results = {};
  for (const name of Object.keys(scripts)) results[name] = await single({ events: scripts[name](version) });

  results.rpcRejected = await single({ rejection: "No model selected" });
  results.rpcAuthRejected = await single({ rejection: "No API key found for provider" });

  {
    const t = turns("cancelled");
    const pending = t.prompt({
      events: [...failedRun("Request timed out.", true), retryStart(1, "Request timed out.", 60000)],
      onCancel: [
        { type: "auto_retry_end", success: false, attempt: 1, finalError: "Retry cancelled" },
        settled(version, true)
      ]
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    await t.session.cancel();
    results.cancelled = { ...(await pending), text: t.text(), requests: t.requests };
  }

  {
    // A prompt rejected by Pi while a cancel is in flight stays cancelled.
    const t = turns("cancelled-rejection");
    t.steps.push({ rejection: "aborted" });
    const original = t.proc.request;
    t.proc.request = async (message) => {
      if (message.type === "prompt") t.session.cancelRequested = true;
      return original(message);
    };
    const result = await t.session.prompt("hi").then(
      (stopReason) => ({ stopReason }),
      (error) => ({ error: { code: error.code, message: error.message, data: error.data ?? null } })
    );
    results.cancelledRejection = result;
  }

  {
    // Consecutive prompts on one session: the second is queued behind the
    // failing first and must not inherit its failure.
    const t = turns("consecutive");
    const first = t.prompt({ events: scripts.exhausted(version) });
    const second = t.prompt({ events: scripts.success(version) });
    const third = Promise.all([first, second]).then(() => t.prompt({ events: scripts.assistantError(version) }));
    results.consecutive = [await first, await second, await third];
  }

  {
    // Two sessions with separate Pi processes fail and succeed independently.
    const a = turns("isolated-a");
    const b = turns("isolated-b");
    const [failedTurn, deliveredTurn] = await Promise.all([
      a.prompt({ events: scripts.exhausted(version) }),
      b.prompt({ events: scripts.success(version) })
    ]);
    results.isolated = { failed: failedTurn, delivered: deliveredTurn };
  }

  return results;
}
