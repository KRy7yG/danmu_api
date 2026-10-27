#!/usr/bin/env bash
# 小盘 VPS 专用：不装 Docker、不装 Node，只用系统自带 python3 跑反代
#   sudo bash install-proxy-python.sh
#   sudo SECRET=my-secret PORT=8787 bash install-proxy-python.sh
#
# 会做：下载 proxy/python-proxy.py → 装 systemd 服务 → 装 10 分钟自动更新 timer
set -euo pipefail

RAW="${RAW:-https://raw.githubusercontent.com/KRy7yG/danmu_api/main}"
DIR="${DIR:-/opt/danmu-proxy}"
PORT="${PORT:-8787}"
SECRET="${SECRET:-$(openssl rand -hex 24)}"

log() { printf '[install] %s\n' "$*"; }

[ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 运行" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  log "安装 python3"
  apt-get update -qq
  apt-get install -y -qq python3
fi
command -v openssl >/dev/null 2>&1 || apt-get install -y -qq openssl

mkdir -p "$DIR"
log "下载 python-proxy.py"
curl -fsSL "$RAW/proxy/python-proxy.py" -o "$DIR/python-proxy.py"
chmod 644 "$DIR/python-proxy.py"

cat >/etc/systemd/system/danmu-proxy.service <<UNIT
[Unit]
Description=danmu_api universal reverse proxy (python)
After=network-online.target
Wants=network-online.target

[Service]
Environment=SECRET=$SECRET
Environment=PORT=$PORT
Environment=ALLOW_HOSTS=${ALLOW_HOSTS:-}
Environment=TIMEOUT_MS=${TIMEOUT_MS:-20000}
ExecStart=/usr/bin/python3 $DIR/python-proxy.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

# 每 10 分钟对比 GitHub 上的文件，有变就换掉并重启（等价于跟随仓库更新）
cat >/etc/systemd/system/danmu-proxy-update.service <<UNIT
[Unit]
Description=danmu-proxy 跟随 GitHub 更新
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsSL $RAW/proxy/python-proxy.py -o /tmp/danmu-proxy.new || exit 0; if ! cmp -s /tmp/danmu-proxy.new $DIR/python-proxy.py; then install -m 644 /tmp/danmu-proxy.new $DIR/python-proxy.py && systemctl restart danmu-proxy; fi'
UNIT

cat >/etc/systemd/system/danmu-proxy-update.timer <<UNIT
[Unit]
Description=每 10 分钟检查 danmu-proxy 更新

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Unit=danmu-proxy-update.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now danmu-proxy.service
systemctl enable --now danmu-proxy-update.timer
sleep 1
systemctl is-active danmu-proxy.service | sed 's/^/danmu-proxy.service: /'

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
  log "已放行 ufw $PORT/tcp"
fi

IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || echo '<VPS_IP>')"

cat <<EOF

================ 完成 ================
反代地址：http://$IP:$PORT/$SECRET

Vercel → danmu-api 项目 → Environment Variables：
  PROXY_URL = @http://$IP:$PORT/$SECRET
存盘后 Redeploy。

自检（在 VPS 上）：
  curl -s -m 20 "http://127.0.0.1:$PORT/$SECRET/https://api.so.360kan.com/index?force_v=1&kw=%E7%B9%81%E8%8A%B1&pageno=1&v_ap=1&tab=all" | head -c 200

维护：
  systemctl status danmu-proxy
  journalctl -u danmu-proxy -n 30
  systemctl list-timers danmu-proxy-update.timer
======================================
EOF
