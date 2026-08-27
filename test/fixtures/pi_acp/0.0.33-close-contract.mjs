// Recorded from pi-acp@0.0.33 dist/index.js.
// npm integrity: sha512-vX9kY1tK14E72G4dBAx+RGCk/k7XPjTHls6dLUxA8WSkBav6B6JHuSBv3eusp50LCR/GTRsR2kIKsG0Z5jANzw==
// dist/index.js sha256: 24ff73fda6e3c76ddce2d359a79f5c4b8f292eb290e4d2ab85aac94676b2c2dc

export const release = {
  package: "pi-acp",
  version: "0.0.33",
  bundleSha256: "24ff73fda6e3c76ddce2d359a79f5c4b8f292eb290e4d2ab85aac94676b2c2dc",
};

class PiRpcProcess {
  constructor(trace) {
    this.trace = trace;
    this.requests = [];
  }

  async request(message) {
    this.requests.push(message);
    this.trace.push(`request:${message.type}`);
    return { success: true };
  }

  // Verbatim pi-acp@0.0.33 PiRpcProcess.abort contract.
  async abort() {
    const res = await this.request({ type: "abort" });
    if (!res.success) throw new Error(`pi abort failed: ${res.error ?? JSON.stringify(res.data)}`);
  }

  dispose() {
    this.trace.push("dispose");
  }
}

class PiAcpSession {
  constructor(proc, settlements) {
    this.cancelRequested = false;
    this.pendingTurn = null;
    this.turnQueue = [];
    this.inAgentLoop = false;
    this.proc = proc;
    this.settlements = settlements;
  }

  beginTurn() {
    return new Promise((resolve) => {
      this.pendingTurn = {
        resolve: (reason) => {
          this.settlements.push(reason);
          resolve(reason);
        },
      };
    });
  }

  // Verbatim pi-acp@0.0.33 PiAcpSession.cancel contract.
  async cancel() {
    this.cancelRequested = true;
    if (this.turnQueue.length) {
      const queued = this.turnQueue.splice(0, this.turnQueue.length);
      for (const t of queued) t.resolve("cancelled");
      this.emit({
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "Cleared queued prompts." }
      });
      this.emit({
        sessionUpdate: "session_info_update",
        _meta: { piAcp: { queueDepth: 0, running: Boolean(this.pendingTurn) } }
      });
    }
    await this.proc.abort();
  }

  emit() {}
  flushEmits() { return Promise.resolve(); }
  startTurn() { throw new Error("unexpected queued turn"); }

  handlePiEvent(ev) {
    switch (ev.type) {
      // Verbatim pi-acp@0.0.33 agent_settled contract.
      case "agent_settled": {
        void this.flushEmits().finally(() => {
          const reason = this.cancelRequested ? "cancelled" : "end_turn";
          this.pendingTurn?.resolve(reason);
          this.pendingTurn = null;
          this.inAgentLoop = false;
          const next = this.turnQueue.shift();
          if (next) {
            this.emit({
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: `Starting queued message. (${this.turnQueue.length} remaining)` }
            });
            this.startTurn(next);
          } else {
            this.emit({
              sessionUpdate: "session_info_update",
              _meta: { piAcp: { queueDepth: 0, running: false } }
            });
          }
        });
        break;
      }
      default:
        break;
    }
  }
}

class SessionManager {
  constructor() {
    this.sessions = new Map();
  }

  maybeGet(sessionId) {
    return this.sessions.get(sessionId);
  }

  close(sessionId) {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    session.proc.dispose?.();
    this.sessions.delete(sessionId);
  }
}

export async function runCloseContract(closeSessionSource) {
  const Agent = new Function(
    "SessionManager",
    `return class Agent {
      constructor() { this.sessions = new SessionManager(); }
      ${closeSessionSource}
    }`,
  )(SessionManager);

  const trace = [];
  const settlements = [];
  const proc = new PiRpcProcess(trace);
  const session = new PiAcpSession(proc, settlements);
  const agent = new Agent();
  agent.sessions.sessions.set("sess-1", session);

  const turn = session.beginTurn();
  await agent.closeSession({ sessionId: "sess-1" });

  // The released adapter can receive agent_settled after close has disposed and
  // removed the session. The first event must settle cancelled, and a later one
  // must not rewrite that result to end_turn.
  session.handlePiEvent({ type: "agent_settled" });
  const stopReason = await turn;
  session.handlePiEvent({ type: "agent_settled" });
  await Promise.resolve();

  return {
    release,
    abortRequests: proc.requests.filter((request) => request.type === "abort"),
    trace,
    settlements,
    stopReason,
    sessionClosed: !agent.sessions.sessions.has("sess-1"),
  };
}
