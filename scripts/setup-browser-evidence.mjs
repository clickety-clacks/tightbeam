import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as pause } from 'node:timers/promises';

const endpoint = `http://127.0.0.1:${process.env.BROWSER_DEBUG_PORT}/json/list`;
async function find(check, label) {
  for (let i = 0; i < 120; i++) {
    try {
      const result = await check();
      if (result) return result;
    } catch {}
    await pause(500);
  }
  console.error('Browser targets at timeout:', await (await fetch(endpoint)).text());
  throw new Error(`Timed out waiting for ${label}`);
}
const tabs = async () => (await (await fetch(endpoint)).json()).filter((tab) => tab.type === 'page');
const mainKey = await find(async () => (await (await fetch('http://127.0.0.1:4178/chat-config.json')).json()).sessionKey, 'the configured Main session');
const base = process.env.TIGHTBEAM_BASE_DIR;
const setup = JSON.parse(fs.readFileSync(path.join(base, 'setup.json'), 'utf8'));
const token = fs.readFileSync(path.join(base, 'setup-device-token'), 'utf8');
const tourKey = await find(async () => {
  const response = await fetch('http://127.0.0.1:11373/api/streams', {
    headers: { authorization: `Bearer ${token}` },
  });
  const { streams } = await response.json();
  return streams?.find(({ displayName }) => displayName === 'Tour Guide')?.sessionKey;
}, 'the durable Tour Guide session');
if (tourKey === mainKey) throw new Error('The Guide was bound to Main');
const tourTab = await find(async () => (await tabs()).find(({ url }) => {
  const target = new URL(url);
  return target.origin === 'http://127.0.0.1:4178' && target.searchParams.get('session') === tourKey;
}), 'the installer to open Tour Guide in Chat');
console.log('Tour Guide opened in Chromium while Chat default still points to Main');
const socket = new WebSocket(tourTab.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let id = 0;
const replies = new Map();
socket.onmessage = ({ data }) => {
  const result = JSON.parse(data);
  replies.get(result.id)?.(result);
  replies.delete(result.id);
};
const call = (method, params) => new Promise((resolve) => {
  replies.set(++id, resolve);
  socket.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expression) => (await call('Runtime.evaluate', { expression, returnByValue: true })).result?.result?.value;
async function sendUserReply(content) {
  const gateway = new WebSocket('ws://127.0.0.1:11373/ws');
  const messageId = `c_${randomUUID()}`;
  try {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('User test reply was not accepted')), 10000);
      gateway.onopen = () => gateway.send(JSON.stringify({
        type: 'auth', protocolVersion: 1, deviceId: setup.deviceId, token, subscriptions: ['chat'],
      }));
      gateway.onmessage = ({ data }) => {
        const frame = JSON.parse(data);
        if (frame.type === 'auth_result' && frame.success) {
          gateway.send(JSON.stringify({ type: 'message', id: messageId, sessionKey: tourKey, content }));
        } else if (frame.type === 'ack' && frame.id === messageId) {
          clearTimeout(timeout);
          resolve();
        }
      };
    });
  } finally {
    gateway.close();
  }
}

try {
  await find(async () => (await evaluate('document.body.innerText')).includes('I recommend Uncle Enzo'), 'the welcome turn recommending Enzo');
  const tourScreenshot = await call('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'tour-guide.png'), Buffer.from(tourScreenshot.result.data, 'base64'));
  await sendUserReply('Skip Enzo for now');
  await find(async () => (await evaluate('document.body.innerText')).includes('Would you like to set up a project?'), 'the project offer');
  await sendUserReply('Please create my fixture project');
  const project = await find(async () => (await tabs()).find(({ url, id }) => {
    const target = new URL(url);
    return id !== tourTab.id && target.origin === 'http://127.0.0.1:4178' &&
      target.searchParams.get('session') && target.searchParams.get('session') !== mainKey && target.searchParams.get('session') !== tourKey;
  }), 'an independently addressed project tab');
  const projectSocket = new WebSocket(project.webSocketDebuggerUrl);
  try {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Project screenshot timed out')), 10000);
      projectSocket.onopen = () => projectSocket.send(JSON.stringify({ id: 1, method: 'Page.captureScreenshot', params: { format: 'png' } }));
      projectSocket.onerror = reject;
      projectSocket.onmessage = ({ data }) => {
        const result = JSON.parse(data);
        if (result.id !== 1) return;
        fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'project-exec.png'), Buffer.from(result.result.data, 'base64'));
        clearTimeout(timeout);
        resolve();
      };
    });
  } finally {
    projectSocket.close();
  }
  fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'browser-targets.log'), JSON.stringify((await tabs()).map(({ id, url }) => ({ id, url })), null, 2));
  console.log('Declined Enzo, accepted the project offer, and observed a new project tab.');
} finally {
  socket.close();
}
