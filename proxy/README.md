# 万能反代（给 danmu_api 用）

## 为什么要它

Vercel 的出口 IP 打不通中国大陆的弹幕源。实测（region hkg1）：

```
api.so.360kan.com/index            10s timeout
api.douban.com/v2/movie/search     10s timeout
api.xiawen.tv/api/v1/aggregate/…   10s timeout ×2  → 20s 全部失败
```

所以 `douban / 360 / renren / hanjutv / tencent / youku / iqiyi / imgo / migu / sohu / leshi / xigua / hongguo`
这些源在 Vercel 上全部是「查询 20 秒 + 返回 0 条」。把请求先发到一台**能连回中国**的反代上，再由它去取，就能恢复这些源。

## 两种部署方式

### 1) Cloudflare Worker（免费、2 分钟，但不保证出口可通）

1. Cloudflare Dashboard → Workers & Pages → Create → Worker → 命名 `danmu-proxy` → Deploy
2. Edit code → 全选删掉 → 粘贴 `cloudflare-worker.js` 全文 → Deploy
3. Settings → Variables and Secrets → 添加 `SECRET`（类型 Secret），值用一串长随机字符
4. 记下地址：`https://danmu-proxy.<你的子域>.workers.dev`

然后在 danmu_api 侧设：

```
PROXY_URL=@https://danmu-proxy.<你的子域>.workers.dev/<SECRET>
```

> 注意：`@` 前缀 = 万能反代，**所有**源（含 dandan/bilibili 这些本来能通的）都会走它。
> 若 CF 出口同样被墙，这套方案不解决问题，改用方案 2。

### 2) 香港/大陆 VPS 上的 Node 反代（最稳）

```bash
# 机器上（Node 18+）
SECRET=<同一串随机值> PORT=8787 node proxy/node-proxy.js

# 或者 Docker
docker run -d --restart=always -p 8787:8787 \
  -e SECRET=<同一串随机值> \
  -v $PWD/node-proxy.js:/app/node-proxy.js \
  node:22-alpine node /app/node-proxy.js
```

danmu_api 侧：

```
PROXY_URL=@http://<VPS_IP>:8787/<SECRET>
```

反代机器只要能访问中国源即可；香港家宽实测可通（本机直连 360kan 正常返 33 条结果）。

## 只代理指定源（可选）

`PROXY_URL` 支持「专用反代」，只对某个源生效，其余源仍然直连。目前代码里写死了这几个键：
`bahamut` / `tmdb` / `bilibili` / `animeko` / `aiyifan`。

```
PROXY_URL=bilibili@https://your-bilibili-proxy,bahamut@https://your-bahamut-proxy
```

`douban / 360 / renren / hanjutv` **没有**专用键，只能靠 `@` 万能反代。

## 安全

- `SECRET` 是路径口令，务必够长；不带口令的请求一律 403。
- 需要更强的约束时设 `ALLOW_HOSTS`（逗号分隔），例如
  `ALLOW_HOSTS=360kan.com,douban.com,xiawen.tv`，其它 host 直接拒绝。
- 不要把反代完全公开成开放代理，Cloudflare/VPS 都可能因此被封。

## 验证

```bash
# 1. 反代自己通不通
curl -s -m 20 "https://<proxy>/<SECRET>/https://api.so.360kan.com/index?force_v=1&kw=%E7%B9%81%E8%8A%B1&pageno=1&v_ap=1&tab=all" | head -c 200

# 2. danmu_api 是否吃到了配置
curl -s "https://<你的实例>/api/config" | jq '.envs.PROXY_URL'

# 3. 恢复中国源后的实际效果（本机实测：33 条 / 9.5s）
curl -s "https://<你的实例>/<TOKEN>/api/v2/search/anime?keyword=%E7%B9%81%E8%8A%B1" | jq '[.animes[].source]|unique'
```
