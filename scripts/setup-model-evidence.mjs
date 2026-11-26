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
  for await (const chunk of request) void chunk;
  const envelope = { id: 'fixture', object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model: MODEL };
  const send = body => response.write(`data: ${JSON.stringify({ ...envelope, ...body })}\n\n`);
  response.writeHead(200, { 'content-type': 'text/event-stream' });
  send({ choices: [{ index: 0, delta: { role: 'assistant', content: REPLY }, finish_reason: null }] });
  send({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } });
  return response.end('data: [DONE]\n\n');
});
provider.listen(25502, '127.0.0.1');
