// Execute the pinned package's real runtime against synthetic SDK task facts.
// This verifies package behavior; it does not authenticate or call a model.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';

const pkg = process.argv[2];
assert.ok(pkg, 'Usage: node scripts/capture_claude_native.mjs /path/to/claude-agent-acp');
const { version } = JSON.parse(readFileSync(`${pkg}/package.json`));
assert.equal(version, '0.73.0');
const { clientSupportsSubagents } = await import(pathToFileURL(`${pkg}/dist/acp-subagents.js`));
const { NativeSubagentRuntime } = await import(pathToFileURL(`${pkg}/dist/native-subagents.js`));

assert.equal(clientSupportsSubagents({ subagents: {} }), true);
for (const caps of [undefined, {}, { subagents: null }, { subagents: [] }, { subagents: false }]) {
  assert.equal(clientSupportsSubagents(caps), false);
}

const frames = [];
const runtime = new NativeSubagentRuntime(true, 'root-1', {}, async n => frames.push(n), { log() {} });
const deliver = async notification => {
  const routed = await runtime.route(notification, deliver);
  if (routed) frames.push(routed);
};
const control = (id, parent) => ({
  sessionId: 'root-1',
  update: {
    sessionUpdate: 'tool_call',
    toolCallId: id,
    status: 'pending',
    _meta: { claudeCode: { toolName: 'Agent', ...(parent ? { parentToolUseId: parent } : {}) } },
    rawInput: { name: `Agent ${id}`, prompt: `Task ${id}` },
  },
});

await deliver(control('call-1'));
await runtime.taskStarted({
  taskId: 'child-1', toolUseId: 'call-1', subagentType: 'general-purpose', description: 'Review',
}, deliver);
await deliver({
  sessionId: 'root-1',
  update: {
    sessionUpdate: 'agent_message_chunk',
    content: { type: 'text', text: 'child text' },
    _meta: { claudeCode: { parentToolUseId: 'call-1' } },
  },
});
await deliver(control('call-2', 'call-1'));
await runtime.taskStarted({
  taskId: 'child-2', toolUseId: 'call-2', subagentType: 'general-purpose', description: 'Nested review',
}, deliver);
await runtime.finishTask('child-2', 'completed', deliver, 'call-2');
await runtime.finishTask('child-1', 'completed', deliver, 'call-1');
assert.deepEqual(frames.map(n => [n.sessionId, n.update.sessionUpdate]), [
  ['root-1', 'subagent_spawned'],
  ['child-1', 'agent_message_chunk'],
  ['child-1', 'subagent_spawned'],
  ['child-1', 'subagent_state_update'],
  ['root-1', 'subagent_state_update'],
]);
const before = frames.length;
await runtime.finishTask('child-1', 'completed', deliver, 'call-1');
assert.equal(frames.length, before);

const terminals = {};
for (const status of ['completed', 'failed', 'cancelled', 'disconnected', 'killed', 'stopped']) {
  const emitted = [];
  const childRuntime = new NativeSubagentRuntime(true, 'root', {}, async n => emitted.push(n), { log() {} });
  await childRuntime.taskStarted({ taskId: `task-${status}`, subagentType: 'general-purpose' }, async () => {});
  await childRuntime.finishTask(`task-${status}`, status, async () => {});
  terminals[status] = emitted.at(-1).update.state;
  assert.equal(terminals[status], ['killed', 'stopped'].includes(status) ? 'cancelled' : status);
}

console.log(JSON.stringify({
  adapter: '@agentclientprotocol/claude-agent-acp',
  version,
  provenance: 'Captured from execution of actual installed package NativeSubagentRuntime; SDK task facts supplied synthetically; no authentication/model request. Not a live harness smoke.',
  frames,
  terminals,
}, null, 2));
