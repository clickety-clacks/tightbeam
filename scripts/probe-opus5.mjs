#!/usr/bin/env node
// Opus-5 entitlement probe — the claude.ex:55-65 documented procedure.
// Boots the real adapter with the real home, reads the offered model set from
// session/new configOptions, then confirms claude-opus-5 via set_config_option.
// Exit 0 + "ACCEPTED" when the grant serves opus-5; exit 1 + refusal otherwise.
// Run on gibson: CLAUDE_CONFIG_DIR=/home/mike/.tightbeam/homes/gibson/claude \
//   node probe-opus5.mjs
import { spawn } from "node:child_process";

const adapter = spawn("node", ["/home/mike/.tightbeam/adapters/node_modules/.bin/claude-agent-acp"], {
  stdio: ["pipe", "pipe", "inherit"],
  env: { ...process.env },
});
let buf = "";
let id = 0;
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
try {
  await rpc("initialize", { protocolVersion: 1, clientCapabilities: {} });
  const sess = await rpc("session/new", { cwd: "/tmp", mcpServers: [] });
  const modelOpt = (sess.configOptions ?? []).find((o) => o.id === "model" || o.name === "model");
  const offered = (modelOpt?.options ?? []).map((o) => o.value ?? o.id ?? o);
  console.log("offered:", JSON.stringify(offered));
  try {
    await rpc("session/set_config_option", { sessionId: sess.sessionId, configId: "model", value: "claude-opus-5" });
    console.log("ACCEPTED: claude-opus-5");
    process.exit(0);
  } catch (e) {
    console.log("REFUSED: claude-opus-5 ->", e.message);
    process.exit(1);
  }
} catch (e) {
  console.error("probe error:", e.message);
  process.exit(2);
} finally {
  adapter.kill();
}
