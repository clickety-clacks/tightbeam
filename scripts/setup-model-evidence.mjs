import http from 'node:http';
const MODEL = 'compat-fixture';
const REPLY = 'setup fixture reply';
const provider = http.createServer(async (request, response) => {
  if (request.method === 'GET' && request.url === '/v1/models') {
    response.writeHead(200, { 'content-type': 'application/json' });
    return response.end(JSON.stringify({ object: 'list',
      data: [{ object: 'model', id: MODEL, owned_by: 'scratch', context_window: 32768 }] }));
  }
  if (request.method !== 'POST' || request.url !== '/v1/chat/completions') return response.writeHead(404).end();
  let raw = '';
  for await (const chunk of request) raw += chunk;
  const payload = JSON.parse(raw);
  const welcome = raw.match(/installer[.]first-run-project-ready[.][a-f0-9]{64}/)?.[0];
  const shouldCreate = process.env.SETUP_PROJECT_TOOL && welcome && payload.messages.at(-1)?.role === 'user';
  const envelope = { id: 'fixture', object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model: MODEL };
  const send = body => response.write(`data: ${JSON.stringify({ ...envelope, ...body })}\n\n`);
  response.writeHead(200, { 'content-type': 'text/event-stream' });
  if (shouldCreate) {
    const command = `project=$(tightbeam spawn --display "Setup fixture project" --name project:fixture --archetype default --harness pi --model local/compat-fixture --effort off --key fixture-project | jq -er .sessionKey) && tightbeam condition --kind ${welcome} --scope "$project"`;
    send({ choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'setup_fixture_tool',
      type: 'function', function: { name: 'bash', arguments: JSON.stringify({ command }) } }] }, finish_reason: null }] });
    send({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
    return response.end('data: [DONE]\n\n');
  }
  send({ choices: [{ index: 0, delta: { role: 'assistant', content: REPLY }, finish_reason: null }] });
  send({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } });
  return response.end('data: [DONE]\n\n');
});
provider.listen(25502, '127.0.0.1');
