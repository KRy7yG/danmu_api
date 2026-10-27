/**
 * danmu_api 万能反代 —— Cloudflare Worker 版
 * =============================================
 * 用途：Vercel 的出口 IP 打不通中国境内弹幕源（api.so.360kan.com / api.douban.com /
 * api.xiawen.tv 等一律超时）。把本 Worker 部署到 Cloudflare（免费），再把
 * danmu_api 的 PROXY_URL 指向它，请求就会改由 Cloudflare 出口发出。
 *
 * 部署（网页版，2 分钟）：
 *   1. Cloudflare Dashboard → Workers & Pages → Create → Worker → 命名（例如 danmu-proxy）→ Deploy
 *   2. Edit code → 全选删除 → 粘贴本文件全部内容 → Deploy
 *   3. Settings → Variables → 添加 SECRET（类型选 Secret），值随便一串长随机字符
 *   4. 记下地址 https://<worker名>.<你的子域>.workers.dev
 *
 * 然后在 danmu_api 侧设置：
 *   PROXY_URL = @https://<worker名>.<你的子域>.workers.dev/<SECRET>
 *
 * 工作方式：danmu_api 会把请求改写成
 *   https://<worker>/<SECRET>/https://api.so.360kan.com/index?kw=xxx
 * 本 Worker 剥掉 <SECRET>/ 前缀，取回原 URL（含 query），转发并原样返回。
 *
 * 环境变量：
 *   SECRET      必填，路径里的口令；不匹配直接 403
 *   ALLOW_HOSTS 可选，逗号分隔的域名白名单；留空=允许所有（靠 SECRET 保护）
 *   UA          可选，覆盖出来的 User-Agent
 */

const DEFAULT_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const HOP_BY_HOP = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'host',
  'cf-connecting-ip',
  'cf-ray',
  'cf-visitor',
  'x-forwarded-for',
  'x-forwarded-proto',
];

export default {
  async fetch(request, env) {
    const secret = (env.SECRET || '').trim();
    if (!secret) {
      return json({ error: 'proxy misconfigured: SECRET is not set' }, 500);
    }

    const url = new URL(request.url);
    const prefix = `/${secret}/`;

    if (!url.pathname.startsWith(prefix)) {
      // 健康检查：GET / 返回一句说明，避免被人当成开放代理
      if (url.pathname === '/' || url.pathname === '') {
        return json({ ok: true, proxy: 'danmu-api universal reverse proxy', usage: `/{SECRET}/https://target/path` }, 200);
      }
      return json({ error: 'forbidden' }, 403);
    }

    // 取出目标 URL：路径去掉 /<SECRET>/ 后剩下的部分 + 原 query
    let target = url.pathname.slice(prefix.length);
    if (url.search) target += url.search;

    let targetUrl;
    try {
      targetUrl = new URL(target);
    } catch {
      return json({ error: `bad target: ${target}` }, 400);
    }
    if (targetUrl.protocol !== 'http:' && targetUrl.protocol !== 'https:') {
      return json({ error: 'only http/https targets allowed' }, 400);
    }

    const allow = (env.ALLOW_HOSTS || '')
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean);
    if (allow.length) {
      const host = targetUrl.hostname.toLowerCase();
      const ok = allow.some((a) => host === a || host.endsWith(`.${a}`));
      if (!ok) return json({ error: `host not allowed: ${host}` }, 403);
    }

    // 组装转发头：保留客户端的 Content-Type/Accept 等，剔除逐跳头
    const headers = new Headers();
    for (const [k, v] of request.headers) {
      const key = k.toLowerCase();
      if (HOP_BY_HOP.includes(key)) continue;
      if (key === 'user-agent' && env.UA) continue;
      headers.set(k, v);
    }
    if (!headers.has('user-agent')) headers.set('user-agent', env.UA || DEFAULT_UA);
    // 部分中国源校验 Referer，按目标站点自动补一个
    if (!headers.has('referer')) {
      headers.set('referer', `${targetUrl.protocol}//${targetUrl.host}/`);
    }

    const init = {
      method: request.method,
      headers,
      redirect: 'follow',
      signal: AbortSignal.timeout(20000),
    };
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      init.body = await request.arrayBuffer();
    }

    let resp;
    try {
      resp = await fetch(targetUrl.toString(), init);
    } catch (e) {
      return json({ error: `upstream fetch failed: ${e.name}: ${e.message}`, target: targetUrl.toString() }, 502);
    }

    // 原样回传，但去掉会导致客户端解压失败的头，并放开 CORS
    const outHeaders = new Headers();
    for (const [k, v] of resp.headers) {
      const key = k.toLowerCase();
      if (key === 'content-encoding' || key === 'content-length') continue;
      if (key === 'set-cookie') continue;
      outHeaders.set(k, v);
    }
    outHeaders.set('access-control-allow-origin', '*');
    outHeaders.set('x-proxy-target', targetUrl.host);

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
          'access-control-allow-headers': '*',
        },
      });
    }

    return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: outHeaders });
  },
};

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' },
  });
}
