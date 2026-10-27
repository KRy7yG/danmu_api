#!/usr/bin/env bash
# VPS 磁盘清理（默认 dry-run，只报告不动手）
#
#   sudo bash cleanup-vps.sh          # 只列将删除什么
#   sudo bash cleanup-vps.sh --yes    # 真正执行
#
# 保护规则：名称/镜像里含 x-ui / xui 的容器、镜像、目录一律跳过（可用 KEEP_PATTERN 覆盖）。
# 永远不删：named volumes、数据库文件、/etc/x-ui、正在运行的容器。
set -uo pipefail

APPLY=0
[ "${1:-}" = "--yes" ] && APPLY=1
KEEP_PATTERN="${KEEP_PATTERN:-x-ui|xui|3x}"

log() { printf '%s\n' "$*"; }
hr() { printf '%s\n' "------------------------------------------------------------"; }

# 在 APPLY=1 时执行，否则只打印
run() {
  if [ "$APPLY" = 1 ]; then
    log "+ $*"
    "$@" || log "  (命令失败，已跳过)"
  else
    log "[dry-run] $*"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

hr; log "磁盘现状"; hr
df -h / 2>/dev/null | awk 'NR==1 || $NF=="/"'
if have docker; then
  log ""; log "Docker 占用："
  docker system df 2>/dev/null || true
fi

hr; log "3x-ui 相关对象（本脚本会跳过）"; hr
FOUND_KEEP=0
if have docker; then
  if docker ps -a --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | grep -Ei "$KEEP_PATTERN"; then
    FOUND_KEEP=1
  else
    log "(Docker 中没有匹配 $KEEP_PATTERN 的容器)"
  fi
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Ei "$KEEP_PATTERN" | sed 's/^/镜像: /' || true
fi
systemctl list-units --type=service --no-legend --plain 2>/dev/null | grep -Ei "$KEEP_PATTERN" | awk '{print "服务: "$1}' || true
[ -d /etc/x-ui ] && log "配置目录: /etc/x-ui (不会动)"
[ -d /usr/local/x-ui ] && log "程序目录: /usr/local/x-ui (不会动)"
[ "$FOUND_KEEP" = 0 ] && log "⚠️  未检测到 3x-ui 容器，若它是 systemd 安装请看上面的服务列表"

hr; log "1/7 Docker 构建缓存"; hr
if have docker; then
  run docker builder prune -af
else
  log "(未安装 docker，跳过)"
fi

hr; log "2/7 悬空镜像（dangling）"; hr
have docker && run docker image prune -f

hr; log "3/7 未被任何容器使用、且不匹配 $KEEP_PATTERN 的镜像"; hr
if have docker; then
  IN_USE="$(docker ps -a --format '{{.Image}}' 2>/dev/null | sort -u)"
  while read -r id name; do
    [ -z "${id:-}" ] && continue
    if printf '%s\n' "$IN_USE" | grep -qxF "$name"; then continue; fi
    if printf '%s\n' "$name" | grep -Eiq "$KEEP_PATTERN"; then log "保留(3x-ui): $name"; continue; fi
    run docker rmi "$id"
  done < <(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null)
else
  log "(未安装 docker，跳过)"
fi

hr; log "4/7 已停止的容器（不含 3x-ui）"; hr
if have docker; then
  while read -r cid cname; do
    [ -z "${cid:-}" ] && continue
    if printf '%s\n' "$cname" | grep -Eiq "$KEEP_PATTERN"; then log "保留(3x-ui): $cname"; continue; fi
    run docker rm "$cid"
  done < <(docker ps -a --filter status=exited --filter status=created --format '{{.ID}} {{.Names}}' 2>/dev/null)
  log "(named volumes 全部保留，不执行 docker volume prune)"
else
  log "(未安装 docker，跳过)"
fi

hr; log "5/7 systemd 日志"; hr
if have journalctl; then
  log "当前占用：$(journalctl --disk-usage 2>/dev/null | tail -1)"
  run journalctl --vacuum-size=200M
fi

hr; log "6/7 包管理器缓存 / 旧日志 / 临时文件"; hr
if have apt-get; then
  run apt-get clean
  run apt-get autoremove --purge -y
fi
if [ -d /var/log ]; then
  run find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete
fi
if [ -d /tmp ]; then
  run find /tmp -maxdepth 1 -type f -mtime +7 -delete
fi
# 容器 json 日志超过 100MB 的清零（只清日志，不动数据）
if have docker && [ "$APPLY" = 1 ]; then
  while read -r f; do
    [ -f "$f" ] || continue
    sz=$(du -m "$f" 2>/dev/null | cut -f1)
    if [ "${sz:-0}" -ge 100 ]; then
      log "+ truncate $f (${sz}MB)"
      : > "$f"
    fi
  done < <(find /var/lib/docker/containers -name '*-json.log' -size +100M 2>/dev/null)
fi

hr; log "7/7 npm 缓存（如果装了 node）"; hr
if have npm; then
  run npm cache clean --force
else
  log "(未安装 npm，跳过)"
fi

hr; log "清理后状态"; hr
df -h / 2>/dev/null | awk 'NR==1 || $NF=="/"'
have docker && docker system df 2>/dev/null || true

hr; log "3x-ui 存活检查"; hr
if have docker; then
  docker ps --format '{{.Names}}  {{.Status}}  {{.Ports}}' 2>/dev/null | grep -Ei "$KEEP_PATTERN" || log "(没有运行中的 3x-ui 容器)"
fi
systemctl is-active x-ui 2>/dev/null | sed 's/^/x-ui.service: /' || true

if [ "$APPLY" = 0 ]; then
  hr; log "以上为 dry-run。确认无误后执行：sudo bash $0 --yes"; hr
fi
