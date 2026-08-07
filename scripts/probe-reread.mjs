#!/usr/bin/env node
// Re-read probe — establishes the mechanism the home-pin durable fix relies on
// (wi_263814d3): a LIVE, long-lived claude-agent-acp adapter RE-READS its home's
// model pin at every session/new, so re-pinning the shared home to a session's
// resolved model BEFORE that session's session/new (or session/load) makes the
// adapter offer and accept it — without an adapter restart. This is WHY
// Gateway.pin_home_to_session_model re-pins on the create/resume branches.
//
// Sequence on ONE adapter process (no restart between phases):
//   1. home pins sonnet     -> session/new A -> read offered set, try opus-5 (expect REFUSE)
//   2. rewrite home to opus-5 pin (SAME process)
//   3. session/new B        -> read offered set, try opus-5 (ACCEPT iff re-read happens)
//
// Run on a claude host with a warmed, credentialed home to COPY (the pin file is
// rewritten in place, so point PROBE_HOME at a throwaway copy, never a live home):
//   cp -a <base>/homes/<host>/claude ./probe-home
//   PROBE_HOME="$PWD/probe-home" node scripts/probe-reread.mjs
// Prints "re-read-per-session-new = YES" when phase B accepts what phase A refused.
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";

const HOME = process.env.PROBE_HOME;
if (!HOME) {
  console.error("set PROBE_HOME to a throwaway copy of a claude home");
  process.exit(2);
}
const SETTINGS = `${HOME}/settings.json`;
// Minimal rails; the hook set is irrelevant to the model offer, only the pin is.
const pin = (model) => writeFileSync(SETTINGS, JSON.stringify({ hooks: {}, model }));

pin("claude-sonnet-5");

const adapter = spawn(
  "node",
  ["/home/mike/.tightbeam/adapters/node_modules/.bin/claude-agent-acp"],
  { stdio: ["pipe", "pipe", "inherit"], env: { ...process.env, CLAUDE_CONFIG_DIR: HOME } }
);
let buf = "", id = 0;
const pending = new Map();
function rpc(method, params) {
  return new Promise((res, rej) => {
    const msgId = ++id;
    pending.set(msgId, { res, rej });
    adapter.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: msgId, method, params }) + "\n");
    setTimeout(() => { if (pending.has(msgId)) { pending.delete(msgId); rej(new Error(`timeout: ${method}`)); } }, 30000);
  });
}
adapter.stdout.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id && pending.has(msg.id)) {
      const p = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? p.rej(Object.assign(new Error(JSON.stringify(msg.error)), { rpc: msg.error })) : p.res(msg.result);
    }
  }
});
async function offerAndTry(label) {
  const sess = await rpc("session/new", { cwd: "/tmp", mcpServers: [] });
  const modelOpt = (sess.configOptions ?? []).find((o) => o.id === "model" || o.name === "model");
  const offered = (modelOpt?.options ?? []).map((o) => o.value ?? o.id ?? o);
  console.log(`[${label}] offered:`, JSON.stringify(offered));
  try {
    await rpc("session/set_config_option", { sessionId: sess.sessionId, configId: "model", value: "claude-opus-5" });
    console.log(`[${label}] opus-5: ACCEPTED`);
    return true;
  } catch (e) {
    console.log(`[${label}] opus-5: REFUSED ->`, e.message);
    return false;
  }
}
try {
  await rpc("initialize", { protocolVersion: 1, clientCapabilities: {} });
  const a = await offerAndTry("A/sonnet-pin");
  pin("claude-opus-5");
  const b = await offerAndTry("B/opus5-pin-same-process");
  console.log(
    "\nRESULT: re-read-per-session-new =",
    (!a && b) ? "YES (pin B accepted without restart)"
      : (a ? "INCONCLUSIVE (A already accepted)" : "NO (B still refused after re-pin)")
  );
  process.exit(0);
} catch (e) {
  console.error("probe error:", e.message);
  process.exit(2);
} finally {
  adapter.kill();
}
