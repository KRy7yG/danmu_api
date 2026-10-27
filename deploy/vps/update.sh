#!/usr/bin/env bash
# 拉取 GitHub 最新代码并重建容器。由 systemd timer 每 10 分钟调用一次，
# 也可以手动执行：/opt/danmu-api/deploy/vps/update.sh
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BRANCH="${BRANCH:-main}"
WITH_APP="${WITH_APP:-0}"
COMPOSE=(docker compose -f "$REPO_DIR/deploy/vps/docker-compose.yml")
if [ "$WITH_APP" = "1" ]; then
  COMPOSE+=(--profile app)
fi

cd "$REPO_DIR"

before="$(git rev-parse HEAD)"
git fetch --prune origin "$BRANCH" >/dev/null
# --ff-only：分叉就直接失败，不会偷偷 merge 出奇怪状态
git merge --ff-only "origin/$BRANCH"
after="$(git rev-parse HEAD)"

if [ "$before" = "$after" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 已是最新 ($after)"
  exit 0
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 发现更新 $before -> $after"
"${COMPOSE[@]}" up -d --build --force-recreate
docker image prune -f >/dev/null 2>&1 || true
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 重建完成"
