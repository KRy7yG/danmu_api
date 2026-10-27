#!/usr/bin/env bash
# 拉取 GitHub 上最新的 proxy/python-proxy.py，有变化就替换并重启 danmu-proxy。
# 由 danmu-proxy-update.timer 每 10 分钟调用；也可手动执行。
#
# 多个下载源依次尝试：raw.githubusercontent.com 在部分网络下不可达，
# 会退到 jsDelivr（Cloudflare CDN）和 ghproxy 镜像。
set -uo pipefail

DEST="${DEST:-/opt/danmu-proxy/python-proxy.py}"
REPO_PATH="KRy7yG/danmu_api/main/proxy/python-proxy.py"
SOURCES=(
  "https://raw.githubusercontent.com/${REPO_PATH}"
  "https://cdn.jsdelivr.net/gh/KRy7yG/danmu_api@main/proxy/python-proxy.py"
  "https://gcore.jsdelivr.net/gh/KRy7yG/danmu_api@main/proxy/python-proxy.py"
  "https://ghproxy.net/https://raw.githubusercontent.com/${REPO_PATH}"
)

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ok=0
for url in "${SOURCES[@]}"; do
  if curl -fsSL --connect-timeout 8 --max-time 25 "$url" -o "$TMP" 2>/dev/null; then
    if head -1 "$TMP" | grep -q "python3"; then
      ok=1
      echo "[update] fetched from ${url}"
      break
    fi
    echo "[update] bad content from ${url}" >&2
  else
    echo "[update] unreachable: ${url}" >&2
  fi
done

if [ "$ok" = 0 ]; then
  echo "[update] $(date -u +%Y-%m-%dT%H:%M:%SZ) 所有下载源都失败，保持现状" >&2
  exit 0
fi

if cmp -s "$TMP" "$DEST"; then
  echo "[update] $(date -u +%Y-%m-%dT%H:%M:%SZ) 已是最新"
  exit 0
fi

install -m 644 "$TMP" "$DEST"
systemctl restart danmu-proxy
echo "[update] $(date -u +%Y-%m-%dT%H:%M:%SZ) 已更新并重启 danmu-proxy"
