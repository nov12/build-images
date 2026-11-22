import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { request, Agent } from 'node:http';
import { networkInterfaces } from 'node:os';
import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { test } from 'node:test';

const root = resolve(process.argv[2] || '/opt/dsh');
const helper = process.argv[3] ? resolve(process.argv[3]) : fileURLToPath(new URL('./web-compat.mjs', import.meta.url));
const { originalRequest, prepareWebRuntime } = await import(pathToFileURL(helper));
const require = createRequire(join(root, 'package.json'));
prepareWebRuntime(root);
const files = ['@deepseek-ai/dsh-host-webserver', '@deepseek-ai/dsh-client-connection'].map(name => require.resolve(name));
const installed = files.map(filename => readFileSync(filename, 'utf8'));
prepareWebRuntime(root);
assert.deepEqual(files.map(filename => readFileSync(filename, 'utf8')), installed, 'patch is idempotent');
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
const { WebServer } = await import(pathToFileURL(files[0]));
const Connection = await import(pathToFileURL(files[1]));
const nativeAdmission = typeof Connection.ConnectionAuthentication === 'function';

await test('image-owned DSH web compatibility', { timeout: 20000 }, async t => {
  const ctx = new Context();
  const bindHost = Object.values(networkInterfaces()).flat().find(address => address.family === 'IPv4' && !address.internal)?.address || '127.0.0.1';
  const records = new Map();
  ctx.provide('credentials', { async modifyRecord(key, update) {
    const change = await update(records.get(key));
    if (change !== undefined) records.set(key, change);
    return records.get(key);
  } });
  await ctx.plugin(WebServer, { host: bindHost, port: 0, compression: 'gzip', compressionThresholdBytes: 1 }).await();
  const web = ctx.get('webServer');
  const agent = new Agent({ keepAlive: true, maxSockets: 1 });
  let connection;
  let cookie;
  let attempts = 0;
  let saves = 0;
  let lastBody;
  let lastSocket;
  const send = (path, { method = 'GET', headers = {}, body, keepAlive = false } = {}) => new Promise((resolve, reject) => {
    const req = request({ host: bindHost, port: web.port, path, method, agent: keepAlive ? agent : false,
      headers: { host: 'dsh.example', ...headers } }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('error', reject);
      res.on('end', () => {
        const bytes = Buffer.concat(chunks);
        resolve({ status: res.statusCode, headers: res.headers,
          body: (res.headers['content-encoding'] === 'gzip' ? gunzipSync(bytes) : bytes).toString() });
      });
    });
    req.setTimeout(5000, () => req.destroy(new Error('test request timed out')));
    req.on('error', reject);
    req.end(body);
  });
  const json = (res, status, value) => {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(value));
  };
  const legacy = async (req, res, peer) => {
    attempts++;
    const local = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress);
    const host = new URL(`http://${req.headers.host}`).hostname;
    const origin = req.headers.origin;
    if (!local || host !== '127.0.0.1' || (origin && new URL(origin).host !== new URL(`http://${req.headers.host}`).host)) {
      res.setHeader('x-early-refusal', 'discard-on-retry');
      const body = JSON.stringify({ error: 'forbidden: loopback-only' });
      res.writeHead(403, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
      res.end(body);
      return;
    }
    if (nativeAdmission) {
      assert.equal(peer?.principal.kind, 'owner', 'legacy handlers retain the admitted Peer');
      assert.equal(connection.admit(originalRequest(req)).peer, peer);
    } else {
      assert.equal(connection.requestRejection(req), undefined, 'native authentication still sees the external Host');
    }
    assert.ok(req.rawHeaders.includes(req.headers.host), 'raw and parsed compatibility headers agree');
    assert.deepEqual(req.headersDistinct.host, [req.headers.host]);
    if (req.method === 'POST') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      lastBody = Buffer.concat(chunks).toString();
      saves++;
    }
    json(res, 200, { ok: true });
  };
  web.register({ kind: 'exact', path: '/api/legacy', handler: legacy });

  try {
    await t.test('incomplete patches fail validation', () => {
      const filename = nativeAdmission ? files[0] : files[1];
      const integration = nativeAdmission
        ? 'await handleRoute(req, res, responder, admission.peer);'
        : 'request = originalRequest(request);';
      const source = readFileSync(filename, 'utf8');
      const timestamp = statSync(files[0], { bigint: true }).mtimeNs;
      try {
        writeFileSync(filename, source.replace(integration, '/* missing integration */'));
        assert.throws(() => prepareWebRuntime(root), /Incomplete DSH web compatibility patch/);
        if (!nativeAdmission) assert.equal(statSync(files[0], { bigint: true }).mtimeNs, timestamp);
      } finally { writeFileSync(filename, source); }
    });
    await t.test('missing authentication service fails closed', async () => {
      assert.equal((await send('/api/legacy')).status, 503);
      assert.equal(attempts, 0);
    });
    const connectionFiber = ctx.plugin(Connection, { trustedHosts: ['dsh.example', 'second.example'] });
    await connectionFiber.await();
    connection = ctx.get('connection');
    const browserUrl = 'https://dsh.example/';
    let loginUrl;
    if (nativeAdmission) {
      const TokenAuth = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-host-authentication-token')));
      await ctx.plugin(TokenAuth, { cookieMaxAgeDays: 30 }).await();
      web.registerFallback({
        auth: req => req.url.pathname === '/asset.js' ? 'anonymous' : 'required',
        handler(req, res) {
          res.end(req.url === '/asset.js' ? 'public static asset' : 'native authenticated index');
        },
      });
      const entries = [];
      ctx.emit('webserver/entry-url', browserUrl, entries);
      loginUrl = new URL(entries[0].url);
    } else {
      web.registerFallback((req, res) => {
        if (req.url === '/asset.js') { res.end('public static asset'); return; }
        if (connection.authorizeIndex(req, res)) res.end('native authenticated index');
      });
      loginUrl = new URL(connection.authenticatedUrl(browserUrl));
    }
    await t.test('anonymous requests and query tokens cannot reach raw plugin routes', async () => {
      assert.equal((await send('/api/legacy')).status, 401);
      assert.equal((await send(`/api/legacy${loginUrl.search}`)).status, 401);
      assert.equal(attempts, 0);
    });
    await t.test('native browser login and public static assets are retained', async () => {
      assert.equal((await send('/')).status, 401);
      assert.equal((await send('/?token=wrong')).status, 401);
      const login = await send(loginUrl.pathname + loginUrl.search);
      assert.equal(login.status, 303);
      assert.equal(login.headers.location, './');
      cookie = login.headers['set-cookie'][0].split(';', 1)[0];
      assert.equal((await send('/', { headers: { cookie } })).status, 200);
      assert.equal((await send('/asset.js')).status, 200);
    });
    await t.test('an authenticated early loopback refusal is adapted once', async () => {
      const response = await send('/api/legacy', { headers: { cookie, origin: 'https://dsh.example' } });
      assert.equal(response.status, 200);
      assert.deepEqual(JSON.parse(response.body), { ok: true });
      assert.equal(response.headers['x-early-refusal'], undefined);
      assert.equal(attempts, 2);
    });
    if (nativeAdmission) {
      await t.test('an explicit route auth policy preserves its loopback restriction', async () => {
        const before = attempts;
        web.register({ kind: 'exact', path: '/api/explicit-auth', auth: 'required', handler: legacy });
        assert.equal((await send('/api/explicit-auth', { headers: { cookie } })).status, 403);
        assert.equal(attempts, before + 1);
      });
    }
    await t.test('POST bytes reach the operation once after its early refusal', async () => {
      const body = JSON.stringify({ value: 'one operation' });
      const response = await send('/api/legacy', { method: 'POST', headers: {
        cookie, origin: 'https://dsh.example', 'content-type': 'application/json', 'content-length': Buffer.byteLength(body),
      }, body });
      assert.equal(response.status, 200);
      assert.equal(lastBody, body);
      assert.equal(saves, 1);
    });
    await t.test('chunked POST bytes are retained for the compatible invocation', async () => {
      const before = saves;
      const body = 'chunked body';
      assert.equal((await send('/api/legacy', { method: 'POST', headers: { cookie, 'transfer-encoding': 'chunked' }, body })).status, 200);
      assert.equal(lastBody, body);
      assert.equal(saves, before + 1);
    });
    await t.test('foreign Host, Origin, and cross-site metadata are rejected before a handler', async () => {
      const before = attempts;
      for (const headers of [
        { host: 'attacker.example' }, { origin: 'https://attacker.example' }, { 'sec-fetch-site': 'cross-site' },
      ]) assert.equal((await send('/api/legacy', { headers: { cookie, ...headers } })).status, 403);
      assert.equal(attempts, before);
    });
    await t.test('cookies retain their external Host audience', async () => {
      assert.equal((await send('/api/legacy', { headers: { cookie, host: 'second.example' } })).status, 401);
      assert.equal((await send('/api/legacy', { headers: { 'x-container-authenticated': 'true' } })).status, 401);
    });
    web.register({ kind: 'exact', path: '/plugin/callback', handler(req, res) {
      assert.equal(this.path, '/plugin/callback', 'handler receiver is preserved');
      lastSocket = req.socket;
      assert.equal(req.headers.host, 'dsh.example');
      assert.equal(req.socket.remoteAddress, bindHost);
      assert.equal(req.headers.origin, 'https://dsh.example');
      res.writeHead(302, { location: `https://${req.headers.host}/callback` });
      res.end();
    } });
    await t.test('new routes outside /api are protected and normal callback Hosts stay intact', async () => {
      assert.equal((await send('/plugin/callback')).status, 401);
      const response = await send('/plugin/callback', { headers: { cookie, origin: 'https://dsh.example' } });
      assert.equal(response.status, 302);
      assert.equal(response.headers.location, 'https://dsh.example/callback');
      assert.equal(lastSocket.remoteAddress, bindHost);
    });
    await t.test('normal responses still support gzip compression', async () => {
      const response = await send('/api/legacy', { headers: { cookie, 'accept-encoding': 'gzip' } });
      assert.equal(response.status, 200);
      assert.equal(response.headers['content-encoding'], 'gzip');
      assert.deepEqual(JSON.parse(response.body), { ok: true });
    });
    await t.test('explicit plain-text loopback refusals are also supported', async () => {
      web.register({ kind: 'exact', path: '/api/plain-refusal', handler(req, res) {
        if (!req.headers.host.startsWith('127.0.0.1:')) {
          res.writeHead(403); res.end('forbidden: loopback-only'); return;
        }
        res.end('local view');
      } });
      assert.equal((await send('/api/plain-refusal', { headers: { cookie } })).body, 'local view');
    });
    await t.test('callback-based early refusals finish even after the handler returns', async () => {
      let calls = 0;
      web.register({ kind: 'exact', path: '/api/deferred-refusal', handler(req, res) {
        calls++;
        setImmediate(() => {
          if (!req.headers.host.startsWith('127.0.0.1:')) {
            json(res, 403, { error: 'forbidden: loopback-only' }); return;
          }
          res.end('deferred local view');
        });
      } });
      const response = await send('/api/deferred-refusal', { headers: { cookie } });
      assert.equal(response.status, 200);
      assert.equal(response.body, 'deferred local view');
      assert.equal(calls, 2);
    });
    for (const style of ['status-code', 'buffer', 'status-message', 'raw-headers']) {
      await t.test(`${style} response writers support an early loopback refusal`, async () => {
        let calls = 0;
        web.register({ kind: 'exact', path: `/api/writer-${style}`, handler(req, res) {
          calls++;
          if (req.headers.host.startsWith('127.0.0.1:')) { res.end('compatible'); return; }
          const body = JSON.stringify({ error: 'forbidden: loopback-only' });
          if (style === 'status-code') res.statusCode = 403;
          else if (style === 'status-message') res.writeHead(403, 'Local access required', { 'x-refusal': 'discard' });
          else if (style === 'raw-headers') res.writeHead(403, ['x-refusal', 'discard']);
          else res.writeHead(403);
          res.end(style === 'buffer' ? Buffer.from(body) : body);
        } });
        const response = await send(`/api/writer-${style}`, { headers: { cookie } });
        assert.equal(response.status, 200);
        assert.equal(response.body, 'compatible');
        assert.equal(response.headers['x-refusal'], undefined);
        assert.equal(calls, 2);
      });
    }
    await t.test('prefix handlers receive the same loopback compatibility', async () => {
      web.register({ kind: 'prefix', path: '/legacy-prefix', handler: legacy });
      assert.equal((await send('/legacy-prefix/item', { headers: { cookie } })).status, 200);
    });
    for (const mode of ['permission', 'different-wording', 'body-read', 'late-body-read', 'streamed', 'callback', 'finish-before', 'finish-after']) {
      let calls = 0;
      web.register({ kind: 'exact', path: `/api/refusal-${mode}`, async handler(req, res) {
        calls++;
        const completed = mode === 'finish-before' ? new Promise(resolve => res.once('finish', resolve)) : undefined;
        if (mode === 'body-read') for await (const _ of req) { /* consume before refusal */ }
        const error = mode === 'permission' ? 'forbidden: permission-required'
          : mode === 'different-wording' ? 'forbidden: localhost required' : 'forbidden: loopback-only';
        const body = JSON.stringify({ error });
        res.writeHead(403, { 'x-retained': mode });
        if (mode === 'streamed') { res.write(body); res.end(); }
        else if (mode === 'callback') res.end(body, () => {});
        else res.end(body);
        if (mode === 'late-body-read') for await (const _ of req) { /* a completed refusal is no longer eligible */ }
        if (completed) await completed;
        if (mode === 'finish-after') await new Promise(resolve => res.once('finish', resolve));
      } });
      await t.test(`${mode} refusals are not replayed`, async () => {
        const response = await send(`/api/refusal-${mode}`, { method: 'POST', headers: { cookie }, body: 'payload' });
        assert.equal(response.status, 403);
        assert.equal(response.headers['x-retained'], mode);
        assert.equal(calls, 1);
      });
    }
    web.register({ kind: 'prefix', path: '/plugin-prefix', handler(req, res) { res.end(req.headers.host); } });
    web.register({ kind: 'exact', path: '/private-resource', resource: async req => new Response(req.headers.get('host')) });
    await t.test('prefix and resource routes use the same admission gate', async () => {
      for (const path of ['/plugin-prefix/item', '/private-resource']) {
        assert.equal((await send(path)).status, 401);
        const response = await send(path, { headers: { cookie } });
        assert.equal(response.status, 200);
        assert.equal(response.body, 'dsh.example');
      }
    });
    await t.test('native shared API and independent API cookies continue to work', async () => {
      assert.equal((await send('/api')).status, 401);
      assert.equal((await send('/api', { headers: { cookie } })).status, 404);
      assert.equal((await send('/connect?token=wrong')).status, 401);
      assert.equal((await send(`/connect${loginUrl.search}`, { headers: { origin: 'https://attacker.example' } })).status, 403);
      const connected = await send(`/connect${loginUrl.search}`);
      assert.equal(connected.status, 302);
      const apiCookie = connected.headers['set-cookie'][0].split(';', 1)[0];
      assert.equal((await send('/api', { headers: { cookie: apiCookie } })).status, 404);
    });
    web.registerUpgrade({ path: '/api/socket', handler(req, socket, _head, peer) {
      assert.equal(req.headers.host, 'dsh.example');
      if (nativeAdmission) assert.equal(peer?.principal.kind, 'owner');
      else assert.equal(connection.requestRejection(req), undefined);
      socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
    } });
    const upgrade = headers => new Promise((resolve, reject) => {
      const req = request({ host: bindHost, port: web.port, path: '/api/socket', agent: false,
        headers: { host: 'dsh.example', connection: 'Upgrade', upgrade: 'websocket', ...headers } });
      req.on('upgrade', (res, socket) => { resolve(res.statusCode); socket.destroy(); });
      req.on('response', res => { resolve(res.statusCode); res.resume(); });
      req.on('error', reject);
      req.setTimeout(5000, () => req.destroy(new Error('upgrade test timed out')));
      req.end();
    });
    await t.test('upgrade admission protects WebSockets without changing their Host', async () => {
      assert.equal(await upgrade({ cookie }), 101);
      assert.equal(await upgrade({}), 401);
      assert.equal(await upgrade({ cookie, origin: 'https://attacker.example' }), 403);
    });
    await t.test('keep-alive sockets keep their real address across requests', async () => {
      for (let index = 0; index < 2; index++) {
        assert.equal((await send('/api/legacy', { headers: { cookie }, keepAlive: true })).status, 200);
        assert.equal((await send('/plugin/callback', { headers: { cookie, origin: 'https://dsh.example' }, keepAlive: true })).status, 302);
        assert.equal(lastSocket.remoteAddress, bindHost);
      }
    });
    await t.test('unloading authentication fails closed for already mounted plugins', async () => {
      await connectionFiber.dispose();
      assert.equal((await send('/api/legacy', { headers: { cookie } })).status, 503);
    });
  } finally {
    agent.destroy();
    await ctx.fiber.dispose();
  }
});
