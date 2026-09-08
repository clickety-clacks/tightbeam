#!/usr/bin/env node
"use strict";
// fixture-patched: the existing Fixture adapter's pinned package patch marker.
// Deterministic test double for OUR ACP client and durable recovery boundary.
// This is not a real provider, a model, or proof of provider availability.
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const arenaInput = process.env.RECOVERY_FIXTURE_ARENA;
if (!arenaInput || !path.isAbsolute(arenaInput)) {
  throw new Error("RECOVERY_FIXTURE_ARENA must name the marked isolated arena");
}
const arena = fs.realpathSync(arenaInput);
if (fs.readFileSync(path.join(arena, ".soak-arena"), "utf8") !==
    "tightbeam recovery acceptance arena v1\n") {
  throw new Error("not a recovery acceptance arena");
}
if (fs.readFileSync(path.join(arena, "auth/fixture/fixture.json"), "utf8") !==
    "fixture-provider-credential") {
  throw new Error("fixture accepts only its synthetic arena credential");
}
const transcript = path.join(arena, "recovery-acp.jsonl");
const record = (direction, frame) => fs.appendFileSync(transcript,
  JSON.stringify({ pid: process.pid, direction, frame }) + "\n");
const send = (frame) => {
  frame = { jsonrpc: "2.0", ...frame };
  record("reply", frame);
  process.stdout.write(JSON.stringify(frame) + "\n");
};
const reply = (id, result) => send({ id, result });
const reject = (id, message, code = -32602) => send({ id, error: { code, message } });
const sessions = new Map();
let nextSession = 0;
const options = () => ({ configOptions: [
  { id: "model", name: "Model", type: "select", currentValue: "fixture-model",
    options: [{ value: "fixture-model", name: "Fixture Model" }] },
  { id: "effort", name: "Effort", type: "select", currentValue: "medium",
    options: [{ value: "medium", name: "Medium" }] }
] });
const pending = new Map();
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const frame = JSON.parse(line);
  record("request", frame);
  const p = frame.params || {};
  switch (frame.method) {
    case "initialize":
      if (p.protocolVersion !== 1) return reject(frame.id, "only protocolVersion 1 is supported");
      return reply(frame.id, { protocolVersion: 1,
        agentCapabilities: { loadSession: true },
        agentInfo: { name: "recovery-test-fixture", version: "1.0.0" } });
    case "session/new": {
      if (typeof p.cwd !== "string" || !Array.isArray(p.mcpServers)) {
        return reject(frame.id, "session/new requires cwd and mcpServers");
      }
      const id = `recovery-${process.pid}-${++nextSession}`;
      sessions.set(id, true);
      return reply(frame.id, { sessionId: id, ...options() });
    }
    case "session/load":
      if (typeof p.sessionId !== "string") return reject(frame.id, "missing sessionId");
      sessions.set(p.sessionId, true);
      return reply(frame.id, options());
    case "session/set_config_option":
      if (!sessions.has(p.sessionId)) return reject(frame.id, "unknown session");
      if (!((p.configId === "model" && p.value === "fixture-model") ||
            (p.configId === "effort" && p.value === "medium"))) {
        return reject(frame.id, "unsupported fixture selection");
      }
      return reply(frame.id, options());
    case "session/set_mode":
      if (!sessions.has(p.sessionId)) return reject(frame.id, "unknown session");
      if (p.modeId !== "full") return reject(frame.id, "unsupported fixture mode");
      return reply(frame.id, {});
    case "session/prompt": {
      if (!sessions.has(p.sessionId) || !Array.isArray(p.prompt) ||
          p.prompt.some((part) => part.type !== "text" || typeof part.text !== "string")) {
        return reject(frame.id, "fixture requires a known session and text prompt");
      }
      const text = p.prompt.map((part) => part.text).join("\n");
      // The controller uses this explicit arena barrier to observe A running.
      // It never completes A; restart must mark that turn failed_unknown.
      if (text.includes("RECOVERY_HOLD_A")) {
        pending.set(p.sessionId, frame.id);
        return;
      }
      send({ method: "session/update", params: { sessionId: p.sessionId,
        update: { sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "recovery fixture delivered" } } } });
      return reply(frame.id, { stopReason: "end_turn" });
    }
    case "session/cancel": {
      if (pending.has(p.sessionId)) {
        reply(pending.get(p.sessionId), { stopReason: "cancelled" });
        pending.delete(p.sessionId);
      }
      return;
    }
    case "session/close":
      sessions.delete(p.sessionId);
      return reply(frame.id, {});
    default:
      if (frame.id !== undefined) return reject(frame.id, "unsupported fixture method", -32601);
  }
});
