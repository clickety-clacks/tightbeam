import { setTimeout as pause } from 'node:timers/promises';

const endpoint = 'http://127.0.0.1:9222/json/list';
async function find(check, label) {
  for (let i = 0; i < 120; i++) {
    try {
      const result = await check();
      if (result) return result;
    } catch {}
    await pause(500);
  }
  throw new Error(`Timed out waiting for ${label}`);
}
const tabs = async () => (await (await fetch(endpoint)).json()).filter((tab) => tab.type === 'page');
const mainTab = await find(async () => (await tabs()).find(({ url }) => {
  const target = new URL(url);
  return target.origin === 'http://127.0.0.1:4178' && target.searchParams.get('session')?.startsWith('agent:main:');
}), 'the full installer to open Main in Chat');
console.log('Main opened in Chromium');
const socket = new WebSocket(mainTab.webSocketDebuggerUrl);
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
async function type(text) {
  await find(() => evaluate("Boolean(document.querySelector('textarea'))"), 'the Chat composer');
  await evaluate("document.querySelector('textarea').focus()");
  await call('Input.insertText', { text });
  for (const type of ['rawKeyDown', 'char', 'keyUp']) {
    await call('Input.dispatchKeyEvent', { type, key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
  }
}
try {
  await find(async () => (await evaluate('document.body.innerText')).includes('I recommend Uncle Enzo'), 'the welcome turn recommending Enzo');
  await type('Skip Enzo for now');
  await find(async () => (await evaluate('document.body.innerText')).includes('Would you like to set up a project?'), 'the project offer');
  await type('Please create my fixture project');
  await find(async () => (await tabs()).find(({ url, id }) => {
    const target = new URL(url);
    return id !== mainTab.id && target.origin === 'http://127.0.0.1:4178' &&
      target.searchParams.get('session') && !target.searchParams.get('session').startsWith('agent:main:');
  }), 'an independently addressed project tab');
  console.log('Declined Enzo, accepted the project offer, and observed a new project tab.');
} finally {
  socket.close();
}
