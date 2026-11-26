import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const local = 'http://127.0.0.1:11373';
const chat = await (await fetch('http://127.0.0.1:4178/chat-config.json')).json();
if (!chat.sessionKey || !chat.gateway) throw new Error('Chat did not target Main');
const directory = process.env.TIGHTBEAM_BASE_DIR;
const state = JSON.parse(fs.readFileSync(path.join(directory, 'setup.json')));
const token = fs.readFileSync(path.join(directory, 'setup-device-token'), 'utf8');
const id = `c_${randomUUID()}`;
const frame = new WebSocket(local.replace(/^http/, 'ws') + '/ws');
try {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Main did not accept the test message')), 10000);
    frame.onopen = () => frame.send(JSON.stringify({
      type: 'auth', protocolVersion: 1, deviceId: state.deviceId, token, subscriptions: ['chat'],
    }));
    frame.onmessage = ({ data }) => {
      const response = JSON.parse(data);
      if (response.type === 'auth_result' && response.success) {
        frame.send(JSON.stringify({ type: 'message', id, sessionKey: chat.sessionKey, content: 'Reply to verify this setup' }));
      } else if (response.type === 'ack' && response.id === id) {
        clearTimeout(timeout);
        resolve();
      }
    };
  });
  const url = `${local}/api/sessions/${encodeURIComponent(chat.sessionKey)}/messages?limit=30&tail=true`;
  for (let i = 0; i < 60; i++) {
    const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    const history = await response.json();
    if (history.items?.some(({ role, content }) => role === 'assistant' && content.includes('setup fixture reply'))) {
      console.log('Main delivered an assistant reply using the isolated model.');
      process.exitCode = 0;
      break;
    }
    if (i === 59) throw new Error(`No assistant reply arrived (history status ${response.status})`);
    await delay(1000);
  }
} finally {
  frame.close();
}
