// A stand-in for the console HTTP API. Every request is logged; every default
// answer echoes the path and the auth headers back, so a test can prove a
// credential was sent AND that the server scrubbed it from what it returned.
import http from 'node:http';

export function startStub(opts = {}) {
  const requests = [];
  const fails = new Map(Object.entries(opts.fail ?? {}));
  const routes = opts.routes ?? {};
  const hits = new Map();

  const send = (res, status, json, headers = {}) => {
    const text = typeof json === 'string' ? json : JSON.stringify(json);
    res.writeHead(status, { 'content-type': 'application/json', ...headers });
    res.end(text);
  };

  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      let body = null;
      if (raw) { try { body = JSON.parse(raw); } catch { body = raw; } }
      const path = req.url;
      const authorization = req.headers.authorization ?? null;
      const cookie = req.headers.cookie ?? null;
      requests.push({ method: req.method, path, authorization, cookie, body });
      hits.set(path, (hits.get(path) ?? 0) + 1);

      const login = /^\/login\/([^/?]+)$/.exec(path);
      if (req.method === 'GET' && login) {
        const value = opts.cookie ?? 'ck-' + login[1];
        res.writeHead(302, { 'set-cookie': `dash=${value}; Path=/; HttpOnly`, location: '/' });
        return res.end();
      }

      const mode = fails.get(path);
      if (mode === 404) return send(res, 404, { error: 'not_found' });
      if (mode === 500) return send(res, 500, { error: 'boom', path, headers: req.headers });
      if (mode === '401-once' && hits.get(path) === 1) return send(res, 401, { error: 'unauthorized' });

      const route = routes[path];
      if (route) return send(res, route.status ?? 200, route.json);

      send(res, 200, { ok: true, method: req.method, path, authorization, cookie, body });
    });
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}`,
        requests,
        fail: (path, mode) => { fails.set(path, mode); hits.delete(path); },
        close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }),
      });
    });
  });
}
