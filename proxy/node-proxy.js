/**
 * danmu_api 万能反代 —— Node 版（自架 VPS / 家宽小主机 / Docker）
 * ==============================================================
 * 和 cloudflare-worker.js 等价的实现，用在你能控制的机器上。
 * 放在香港/大陆的 VPS 上效果最好（Vercel 的出口 IP 打不通中国境内源）。
 *
 * 启动：
 *   SECRET=my-long-random-secret PORT=8787 node proxy/node-proxy.js
 *
 * 然后 danmu_api 侧：
 *   PROXY_URL=@http://<你的主机>:8787/<SECRET>
 *
 * Docker：
 *   docker run -d --restart=always -p 8787:8787 \
 *     -e SECRET=my-long-random-secret -e ALLOW_HOSTS= \
 *     -v $PWD/proxy/node-proxy.js:/app/node-proxy.js \
 *     node:22-alpine node /app/node-proxy.js
 *
 * 环境变量：
 *   SECRET      必填，路径口令
 *   PORT        默认 8787
 *   ALLOW_HOSTS 可选，逗号分隔白名单；空=允许所有（靠 SECRET 保护）
 *   UA          可选，覆盖 User-Agent
 *   TIMEOUT_MS  可选，默认 20000
 */

import http from 'node:http';
import { URL } from 'node:url';

const SECRET = (process.env.SECRET || '').trim();
const PORT = Number.parseInt(process.env.PORT || '8787', 10);
const TIMEOUT_MS = Number.parseInt(process.env.TIMEOUT_MS || '20000', 10);
const DEFAULT_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const ALLOW_HOSTS = (process.env.ALLOW_HOSTS || '')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

if (!SECRET) {
  console.error('[proxy] 必须设置 SECRET 环境变量');
  process.exit(1);
}

const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'host',
  'content-length',
]);

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': '*',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const incoming = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const prefix = `/${SECRET}/`;

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
      'access-control-allow-headers': '*',
    });
    return res.end();
  }

  if (!incoming.pathname.startsWith(prefix)) {
    if (incoming.pathname === '/' || incoming.pathname === '') {
      return sendJson(res, 200, { ok: true, usage: '/{SECRET}/https://target/path' });
    }
    return sendJson(res, 403, { error: 'forbidden' });
  }

  let target = incoming.pathname.slice(prefix.length);
  if (incoming.search) target += incoming.search;

  let targetUrl;
  try {
    targetUrl = new URL(target);
  } catch {
    return sendJson(res, 400, { error: `bad target: ${target}` });
  }
  if (!/^https?:$/.test(targetUrl.protocol)) {
    return sendJson(res, 400, { error: 'only http/https' });
  }
  if (ALLOW_HOSTS.length) {
    const host = targetUrl.hostname.toLowerCase();
    if (!ALLOW_HOSTS.some((a) => host === a || host.endsWith(`.${a}`))) {
      return sendJson(res, 403, { error: `host not allowed: ${host}` });
    }
  }

  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    const key = k.toLowerCase();
    if (HOP_BY_HOP.has(key)) continue;
    if (key === 'user-agent' && process.env.UA) continue;
    headers[key] = v;
  }
  if (!headers['user-agent']) headers['user-agent'] = process.env.UA || DEFAULT_UA;
  if (!headers.referer) headers.referer = `${targetUrl.protocol}//${targetUrl.host}/`;

  let body;
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    body = Buffer.concat(chunks);
  }

  try {
    const upstream = await fetch(targetUrl, {
      method: req.method,
      headers,
      body,
      redirect: 'follow',
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });

    const outHeaders = {};
    upstream.headers.forEach((v, k) => {
      const key = k.toLowerCase();
      if (key === 'content-encoding' || key === 'content-length' || key === 'set-cookie') return;
      outHeaders[key] = v;
    });
    outHeaders['access-control-allow-origin'] = '*';
    outHeaders['x-proxy-target'] = targetUrl.host;

    const buf = Buffer.from(await upstream.arrayBuffer());
    outHeaders['content-length'] = String(buf.length);
    res.writeHead(upstream.status, outHeaders);
    res.end(buf);
  } catch (e) {
    sendJson(res, 502, { error: `upstream fetch failed: ${e.name}: ${e.message}`, target: targetUrl.toString() });
  }
});

server.listen(PORT, () => {
  console.log(`[proxy] listening on :${PORT}  (path prefix /${SECRET}/)`);
  console.log(`[proxy] ALLOW_HOSTS=${ALLOW_HOSTS.length ? ALLOW_HOSTS.join(',') : '(all)'}`);
});
