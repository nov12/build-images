import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Native transports already authenticate; retain their original response path.
export const nativeRoute = Symbol('dsh-container-native-route');
const originals = new WeakMap();
export const originalRequest = request => originals.get(request) ?? request;

function rejection(ctx, request) {
  const connection = ctx.get('connection');
  return typeof connection?.requestRejection === 'function'
    ? connection.requestRejection(originalRequest(request)) : 503;
}

export function authorizeRoute(ctx, request, response, route) {
  if (route[nativeRoute]) return true;
  const status = rejection(ctx, request);
  if (status === undefined) return true;
  response.writeHead(status, { 'cache-control': 'no-store' });
  response.end();
  return false;
}

export function authorizeUpgrade(ctx, request, socket) {
  const status = rejection(ctx, request);
  if (status === undefined) return true;
  socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\n\r\n`);
  return false;
}

function bound(target, key, receiver) {
  const value = Reflect.get(target, key, target);
  return typeof value !== 'function' ? value : (...args) => {
    const result = value.apply(target, args);
    return result === target ? receiver : result;
  };
}

function localRequest(request) {
  const authority = `127.0.0.1:${request.socket.localPort}`;
  const headers = { ...request.headers, host: authority };
  if (headers.origin !== undefined) {
    headers.origin = `${request.socket.encrypted ? 'https' : 'http'}://${authority}`;
  }
  const rawHeaders = [...request.rawHeaders];
  for (let index = 0; index < rawHeaders.length; index += 2) {
    const name = rawHeaders[index].toLowerCase();
    if (name === 'host' || name === 'origin') rawHeaders[index + 1] = headers[name];
  }
  const socket = new Proxy(request.socket, {
    get(target, key, receiver) {
      if (key === 'remoteAddress') return '127.0.0.1';
      if (key === 'remoteFamily') return 'IPv4';
      return bound(target, key, receiver);
    },
  });
  const view = new Proxy(request, {
    get(target, key, receiver) {
      if (key === 'headers') return headers;
      if (key === 'rawHeaders') return rawHeaders;
      if (key === 'headersDistinct') {
        return Object.fromEntries(Object.entries(headers).map(([name, value]) => [name, Array.isArray(value) ? value : [value]]));
      }
      if (key === 'socket' || key === 'connection' || key === 'client') return socket;
      return bound(target, key, receiver);
    },
  });
  originals.set(view, request);
  return view;
}

function loopbackRefusal(body) {
  if (typeof body !== 'string' && !Buffer.isBuffer(body)) return false;
  if (body.length > 1024) return false;
  const text = body.toString().trim();
  if (text === 'forbidden: loopback-only') return true;
  try { return JSON.parse(text)?.error === 'forbidden: loopback-only'; }
  catch { return false; }
}

/** A loopback-only refusal must precede side effects; do not replay other denials. */
export async function handleRoute(request, response, route, ...args) {
  if (route[nativeRoute]) return route.handler(request, response, ...args);
  const initialHeaders = response.getHeaders();
  const initialStatus = response.statusCode;
  const initialMessage = response.statusMessage;
  const events = ['data', 'readable', 'end'];
  const listeners = events.map(event => request.listenerCount(event));
  const finishListeners = response.listenerCount('finish');
  // Stage only a 403 head; successful and streaming responses pass through.
  let pendingHead;
  let refusedEnd;
  let wake;
  const untouched = () => !request.destroyed && request.readableDidRead === false
    && events.every((event, index) => request.listenerCount(event) === listeners[index]);
  const flush = () => {
    if (pendingHead === undefined) return;
    const args = pendingHead;
    pendingHead = undefined;
    response.writeHead(...args);
  };
  const endRefusal = () => {
    if (!response.headersSent) flush();
    if (refusedEnd && !response.writableEnded && !response.destroyed) response.end(...refusedEnd);
  };
  const probe = new Proxy(response, {
    get(target, key, receiver) {
      if (key === 'writeHead') return (...args) => {
        if (args[0] === 403 && !target.headersSent) {
          pendingHead = args;
          target.statusCode = 403;
        } else {
          pendingHead = undefined;
          target.writeHead(...args);
        }
        return receiver;
      };
      if (key === 'write' || key === 'flushHeaders') return (...args) => {
        flush();
        return target[key](...args);
      };
      if (key === 'end') return (...args) => {
        if (target.statusCode === 403 && !target.headersSent && !target.writableEnded && !target.destroyed
          && untouched() && target.listenerCount('finish') === finishListeners + (wake ? 1 : 0)
          && !args.some(arg => typeof arg === 'function') && loopbackRefusal(args[0])) {
          refusedEnd = args;
          wake?.();
          return receiver;
        }
        flush();
        target.end(...args);
        return receiver;
      };
      if (['on', 'once', 'addListener', 'prependListener', 'prependOnceListener'].includes(key)) return (...args) => {
        target[key](...args);
        // Awaiting response completion must not deadlock behind a held refusal.
        if (args[0] === 'finish' && refusedEnd) endRefusal();
        return receiver;
      };
      return bound(target, key, receiver);
    },
  });
  try {
    await route.handler(request, probe, ...args);
    // node:http also permits handlers that reply later without returning a Promise.
    if (!refusedEnd && !response.writableEnded && !response.destroyed) {
      await new Promise(resolve => {
        wake = resolve;
        response.once('finish', resolve);
        response.once('close', resolve);
      });
    }
  } catch (error) {
    endRefusal();
    throw error;
  } finally {
    if (wake) {
      response.off('finish', wake);
      response.off('close', wake);
    }
  }
  if (!refusedEnd) return;
  if (!untouched() || response.headersSent || response.writableEnded || response.destroyed) {
    endRefusal();
    return;
  }
  for (const name of response.getHeaderNames()) response.removeHeader(name);
  for (const [name, value] of Object.entries(initialHeaders)) response.setHeader(name, value);
  response.statusCode = initialStatus;
  response.statusMessage = initialMessage;
  await route.handler(localRequest(request), response, ...args);
}

/** Patch the image-owned host once; mounted plugins are never changed. */
export function prepareWebRuntime(root) {
  const require = createRequire(join(resolve(root), 'package.json'));
  const helper = pathToFileURL(fileURLToPath(import.meta.url)).href;
  const webserver = '@deepseek-ai/dsh-host-webserver';
  const connection = '@deepseek-ai/dsh-client-connection';
  const connectionSource = readFileSync(require.resolve(connection), 'utf8');
  const nativeAdmission = connectionSource.includes('ctx.on("webserver/authorize", (request, policy) =>');
  const launchToken = [
    'const created = encodeBase64Url(randomBytes(SECRET_BYTES));',
    'const created = process.env.DSH_TOKEN || encodeBase64Url(randomBytes(SECRET_BYTES));',
  ];
  // The native fallback keeps ownership of index login and public static assets.
  const patches = nativeAdmission ? [
    [webserver, 'handleRoute', [[
      '\t\t\t\telse await responder.handler(req, res, admission.peer);',
      // Legacy handlers have no explicit auth policy. Let only an admitted owner
      // retry those named routes, and keep the same Peer for both invocations.
      '\t\t\t\telse if (responder !== this.fallback && responder.auth === undefined && admission.peer?.principal.kind === "owner") await handleRoute(req, res, responder, admission.peer);\n\t\t\t\telse await responder.handler(req, res, admission.peer);',
    ]]],
    ['@deepseek-ai/dsh-host-authentication-token', '', [launchToken]],
  ] : [
    [webserver, 'authorizeRoute, authorizeUpgrade, handleRoute', [
      [
        '\t\t\tif (typeof responder === "function") await responder(req, res);',
        '\t\t\tif (responder !== this.fallback && !authorizeRoute(this.ctx, req, res, responder)) return;\n\t\t\tif (typeof responder === "function") await responder(req, res);',
      ],
      [
        '\t\t\telse await responder.handler(req, res);',
        '\t\t\telse await handleRoute(req, res, responder);',
      ],
      [
        '\t\t\t\tthis.upgradedSockets.add(socket);',
        '\t\t\t\tif (!authorizeUpgrade(this.ctx, req, socket)) return;\n\t\t\t\tthis.upgradedSockets.add(socket);',
      ],
    ]],
    [connection, 'originalRequest, nativeRoute', [
      launchToken,
      [
        '\tadmit(request) {\n\t\tif (!this.isTrusted(request))',
        '\tadmit(request) {\n\t\trequest = originalRequest(request);\n\t\tif (!this.isTrusted(request))',
      ],
      [
        '\t\t\tpath: API_PATH,\n\t\t\thandler:',
        '\t\t\tpath: API_PATH,\n\t\t\t[nativeRoute]: true,\n\t\t\thandler:',
      ],
      [
        '\t\t\tpath: CONNECT_PATH,\n\t\t\thandler:',
        '\t\t\tpath: CONNECT_PATH,\n\t\t\t[nativeRoute]: true,\n\t\t\thandler:',
      ],
    ]],
  ];
  // Validate every integration point before changing any installed package.
  const outputs = patches.map(([name, imports, replacements]) => {
    const filename = require.resolve(name);
    let source = readFileSync(filename, 'utf8');
    const preamble = imports ? `import { ${imports} } from ${JSON.stringify(helper)};\n` : '// DSH container launch token\n';
    if (source.startsWith(preamble)) {
      for (const [, after] of replacements) {
        if (source.split(after).length !== 2) throw new Error(`Incomplete DSH web compatibility patch: ${filename}`);
      }
      return [filename, source];
    }
    for (const [before, after] of replacements) {
      if (source.split(before).length !== 2) {
        throw new Error(`Unsupported DSH web runtime: ${filename}; integration point changed: ${before}`);
      }
      source = source.replace(before, after);
    }
    return [filename, preamble + source];
  });
  for (const [filename, source] of outputs) writeFileSync(filename, source);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error('Usage: web-compat.mjs <DSH installation prefix>');
  prepareWebRuntime(process.argv[2]);
}
