import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as pause } from 'node:timers/promises';

let injected = false;
async function injectTourFailure() {
  if (!process.env.SETUP_PROJECT_TOOL || injected) return;
  const file = path.join(process.env.TIGHTBEAM_BASE_DIR, 'state.db');
  for (let i = 0; i < 40; i++) {
    try {
      const db = new DatabaseSync(file, { open: fs.existsSync(file) });
      try {
        db.exec("PRAGMA busy_timeout=1500");
        const receipt = db.prepare("SELECT value FROM org_settings WHERE key='first-run-tour'").get();
        if (receipt?.value !== 'pending') throw new Error('pending fixture not ready');
        db.exec(`CREATE TRIGGER IF NOT EXISTS fixture_block_guide BEFORE INSERT ON roles
          WHEN NEW.name='tour-guide' BEGIN SELECT RAISE(ABORT,'fixture Tour Guide failure'); END`);
        injected = true;
        console.log('Installed the isolated role-write failure fixture.');
        return;
      } finally {
        db.close();
      }
    } catch {}
    await pause(100);
  }
}

const MODEL = 'compat-fixture';
const REPLY = 'setup fixture reply';
const provider = http.createServer(async (request, response) => {
  if (request.method === 'GET' && request.url === '/v1/models') {
    await injectTourFailure();
    response.writeHead(200, { 'content-type': 'application/json' });
    return response.end(JSON.stringify({ object: 'list',
      data: [{ object: 'model', id: MODEL, owned_by: 'scratch', context_window: 32768 }] }));
  }
  if (request.method !== 'POST' || request.url !== '/v1/chat/completions') return response.writeHead(404).end();
  let raw = '';
  for await (const chunk of request) raw += chunk;
  const payload = JSON.parse(raw);
  const messages = payload.messages;
  const last = messages.at(-1);
  const latest = JSON.stringify(last);
  const welcome = raw.match(/installer[.]first-run-project-ready[.][a-f0-9]{64}/)?.[0];
  let text = REPLY;
  let command;
  let toolId;
  if (process.env.SETUP_PROJECT_TOOL && welcome) {
    if (last.role === 'tool' && latest.includes('factId')) {
      text = 'Your project is ready in a separate tab.';
    } else if (last.role === 'tool' && latest.includes('sessionKey')) {
      const key = JSON.parse(last.content.match(/\{[\s\S]*\}/)[0]).sessionKey;
      if (!/^[a-zA-Z0-9:._-]+ s_[a-zA-Z0-9_-]+$/.test(key)) throw new Error('Unexpected project session key');
      toolId = 'call_fixture_condition';
      command = `tightbeam condition --kind ${welcome} --scope '${key}'`;
    } else if (latest.includes('Please create my fixture project')) {
      toolId = 'call_fixture_spawn';
      command = 'tightbeam spawn --display "Fixture project" --name exec:fixture --archetype default --harness pi --model local/compat-fixture --effort off --key fixture-project';
    } else if (latest.includes('Skip Enzo for now')) {
      text = 'Would you like to set up a project?';
    } else if (raw.includes('Recommend Uncle Enzo as the kungfu to start with')) {
      text = 'I recommend Uncle Enzo as your first kungfu. Would you like me to install it?';
    }
  }
  const envelope = { id: 'fixture', object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model: MODEL };
  const send = body => response.write(`data: ${JSON.stringify({ ...envelope, ...body })}\n\n`);
  response.writeHead(200, { 'content-type': 'text/event-stream' });
  if (command) {
    send({ choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: toolId,
      type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } }] }, finish_reason: null }] });
    send({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
    return response.end('data: [DONE]\n\n');
  }
  send({ choices: [{ index: 0, delta: { role: 'assistant', content: text }, finish_reason: null }] });
  send({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } });
  return response.end('data: [DONE]\n\n');
});
provider.listen(25502, '127.0.0.1');
