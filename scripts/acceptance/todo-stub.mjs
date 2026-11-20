import http from 'node:http';

export const writeTodos = {
  todos: [
    { title: 'Read AGENTS.md', status: 'in_progress' },
    { title: 'Write summary', status: 'pending' },
  ],
};
export const badTodos = { todos: [{ title: 'Broken', status: 'blocked' }] };
export const listing = 'Current todo list:\n  [in_progress] Read AGENTS.md\n  [pending] Write summary';
export const rejection = 'TodoList todos must be an array of {title: non-empty string, status: pending | in_progress | done} objects';

export function textOf(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((part) => (part && part.text) || '').join('');
  return '';
}

export function lastUserPrompt(messages) {
  const user = [...messages].reverse().find((m) => m.role === 'user');
  return user ? textOf(user.content) : '';
}

export function currentTurnToolCount(messages) {
  const lastUser = messages.map((m) => m.role).lastIndexOf('user');
  return messages.slice(lastUser + 1).filter((m) => m.role === 'tool').length;
}

export function toolContents(body) {
  return (body.messages || []).filter((m) => m.role === 'tool').map((m) => textOf(m.content));
}

export function planFor(toolName) {
  return (body) => {
    const messages = body.messages || [];
    const prompt = lastUserPrompt(messages);
    const step = currentTurnToolCount(messages);
    const call = (args) => ({ toolCall: { name: toolName, arguments: JSON.stringify(args) } });
    if (prompt.includes('[todo-cycle]')) {
      if (step === 0) return call(writeTodos);
      if (step === 1) return call({});
      if (step === 2) return call(badTodos);
      return { text: 'Finished the work.' };
    }
    if (prompt.includes('[todo-sub]')) {
      if (step === 0) return { toolCall: { name: 'Agent', arguments: JSON.stringify({ prompt: '[todo-child] plan the work', description: 'Plan the work', resume: 'helper' }) } };
      return { text: 'Subagent finished.' };
    }
    if (prompt.includes('[todo-child]')) return step === 0 ? call(writeTodos) : { text: 'Child finished.' };
    if (prompt.includes('[todo-write]')) return step === 0 ? call(writeTodos) : { text: 'Saved the plan.' };
    if (prompt.includes('[todo-read]')) return step === 0 ? call({}) : { text: 'Read the plan.' };
    return { text: 'Hello from the stub.' };
  };
}

function sse(res, model, step) {
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const base = { id: 'stub-1', object: 'chat.completion.chunk', created: 0, model };
  if (step.toolCall) {
    res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'call_stub_1', type: 'function', function: { name: step.toolCall.name, arguments: step.toolCall.arguments } }] }, finish_reason: null }] })}\n\n`);
    res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] })}\n\n`);
  } else {
    res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { role: 'assistant', content: step.text }, finish_reason: null }] })}\n\n`);
    res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
  }
  res.write(`data: ${JSON.stringify({ ...base, choices: [], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })}\n\n`);
  res.write('data: [DONE]\n\n');
  res.end();
}

function json(res, model, step) {
  const message = step.toolCall
    ? { role: 'assistant', content: null, tool_calls: [{ id: 'call_stub_1', type: 'function', function: step.toolCall }] }
    : { role: 'assistant', content: step.text };
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({
    id: 'stub-1',
    object: 'chat.completion',
    created: 0,
    model,
    choices: [{ index: 0, message, finish_reason: step.toolCall ? 'tool_calls' : 'stop' }],
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
  }));
}

export function startStub(toolName = 'TodoList') {
  const requests = [];
  const plan = planFor(toolName);
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      if (req.method === 'GET' && req.url.endsWith('/models')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ object: 'list', data: [{ id: 'stub-model', object: 'model' }] }));
        return;
      }
      let body = {};
      try { body = JSON.parse(raw || '{}'); } catch { body = {}; }
      requests.push(body);
      const step = plan(body);
      const model = body.model || 'stub-model';
      if (body.stream) sse(res, model, step);
      else json(res, model, step);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({
      port: server.address().port,
      requests,
      close: () => new Promise((done) => {
        server.closeAllConnections();
        server.close(done);
      }),
    }));
  });
}

export function providerSettings(port) {
  return {
    providers: {
      stub: {
        protocol: 'openai-chat-completions',
        base_url: `http://127.0.0.1:${port}/v1`,
        auth: { type: 'none' },
        tool_choice_mode: 'send',
        model_metadata: {
          'stub-model': { context_window: 100000, max_output_tokens: 4000, supports_tool_use: true, supports_vision: false },
        },
      },
    },
    models: { stub: 'stub-model' },
    provider: 'stub',
    permission_mode: 'full-access',
  };
}
