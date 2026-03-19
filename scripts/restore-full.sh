#!/usr/bin/env bash
# openclaw-restore-full: 从全卷备份恢复 OpenClaw
# 用法: restore-full.sh <backup.tar.gz> [--dry-run] [--overwrite-gateway-token]
#
# ⚠️  警告: 此操作将覆盖 ~/.openclaw/ 下的现有文件。请先使用 --dry-run 预览。
#
# 与 restore.sh 的区别：
#   restore.sh      = 配合白名单备份，按目录逐一 rsync 恢复
#   restore-full.sh = 配合全卷备份，单次 tar 解压直接覆盖
#
# 默认行为：保留当前服务器的 Gateway Token（防止 Dashboard 断连）。
# 使用 --overwrite-gateway-token 覆盖此行为（全机灾难恢复场景）。

set -euo pipefail

ARCHIVE="${1:-}"
DRY_RUN=false
OVERWRITE_GATEWAY_TOKEN=false

for arg in "${@:2}"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --overwrite-gateway-token) OVERWRITE_GATEWAY_TOKEN=true ;;
  esac
done

OPENCLAW_HOME="${HOME}/.openclaw"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 颜色输出 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
dryrun(){ echo -e "${CYAN}[DRY]${NC} $*"; }

# ── 前置校验 ────────────────────────────────────────────────────────────────
[ -z "$ARCHIVE" ] && error "用法: restore-full.sh <backup.tar.gz> [--dry-run] [--overwrite-gateway-token]"
[ ! -f "$ARCHIVE" ] && error "归档文件不存在: $ARCHIVE"
command -v python3 >/dev/null 2>&1 || error "需要 python3 来解析配置文件。请先安装。"

# ── 自动解密逻辑 ────────────────────────────────────────────────────────────
IS_ENCRYPTED=false
REAL_ARCHIVE="$ARCHIVE"
if [[ "$ARCHIVE" == *.enc ]]; then
    IS_ENCRYPTED=true
    info "检测到加密归档，正在准备解密..."
    
    OC_BACKUP_PASS="${OC_BACKUP_PASS:-}"
    if [ -z "$OC_BACKUP_PASS" ]; then
        echo -n "   请输入备份加密密码: "
        read -rs OC_BACKUP_PASS
        echo ""
    fi
    
    DECRYPTED_TMP=$(mktemp /tmp/oc-decrypt.XXXXXX.tar.gz)
    # 确保解密临时文件能被清理
    trap "rm -f $DECRYPTED_TMP" EXIT
    
    if ! openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$ARCHIVE" -out "$DECRYPTED_TMP" -pass "pass:${OC_BACKUP_PASS}" 2>/dev/null; then
        error "解密失败：密码错误或归档已损坏。"
    fi
    info "解密成功"
    REAL_ARCHIVE="$DECRYPTED_TMP"
fi

echo ""
echo "🦞 OpenClaw Full Restore"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
$DRY_RUN && echo -e "${CYAN}[DRY RUN 模式 — 不会做任何修改]${NC}\n"

# ── 探测归档内部结构 ────────────────────────────────────────────────────────
# 全卷备份的根目录是 .openclaw/，检测是否符合预期
info "正在检测归档结构..."
ARCHIVE_ROOT=$(tar -tzf "$REAL_ARCHIVE" | head -1 | cut -d'/' -f1)

if [ "$ARCHIVE_ROOT" != ".openclaw" ]; then
  error "归档结构异常：根目录为 '${ARCHIVE_ROOT}'，预期为 '.openclaw'。这不是全卷备份生成的归档文件。请使用 restore.sh 恢复白名单备份。"
fi
info "归档结构验证通过 (根目录: ${ARCHIVE_ROOT})"

# ── 显示 Manifest ───────────────────────────────────────────────────────────
MANIFEST_EXISTS=$(tar -tzf "$REAL_ARCHIVE" 2>/dev/null | grep '.backup-manifest.json' || true)
if [ -n "$MANIFEST_EXISTS" ]; then
  echo ""
  echo "📋 Manifest:"
  tar -xzf "$REAL_ARCHIVE" -C /tmp --include='*/.backup-manifest.json' 2>/dev/null || true
  MANIFEST_FILE=$(find /tmp -name '.backup-manifest.json' -newer "$REAL_ARCHIVE" 2>/dev/null | head -1 || true)
  if [ -n "$MANIFEST_FILE" ] && [ -f "$MANIFEST_FILE" ]; then
    python3 -c "
import json
d = json.load(open('${MANIFEST_FILE}'))
print(f\"  备份名称  : {d.get('backup_name', 'unknown')}\")
print(f\"  备份模式  : {d.get('backup_mode', 'unknown')}\")
print(f\"  创建时间  : {d.get('timestamp', 'unknown')}\")
print(f\"  源主机    : {d.get('hostname', 'unknown')}\")
print(f\"  OC 版本   : {d.get('openclaw_version', 'unknown')}\")
print(f\"  排除规则数: {d.get('exclude_rules_count', 'unknown')}\")
" 2>/dev/null || warn "  无法解析 Manifest"
    rm -f "$MANIFEST_FILE"
  fi
  echo ""
fi

# ── 统计归档内容 ────────────────────────────────────────────────────────────
FILE_COUNT=$(tar -tzf "$REAL_ARCHIVE" | wc -l | tr -d ' ')
ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
info "归档文件: $(basename "$ARCHIVE")"
info "文件数量: ${FILE_COUNT} 个"
info "归档大小: ${ARCHIVE_SIZE}"
echo ""

# ── 读取当前 Gateway Token ──────────────────────────────────────────────────
CURRENT_GATEWAY_TOKEN=""
CURRENT_CONFIG="${OPENCLAW_HOME}/openclaw.json"
if [ -f "$CURRENT_CONFIG" ]; then
  CURRENT_GATEWAY_TOKEN=$(_OC_CONF="$CURRENT_CONFIG" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['_OC_CONF']))
    print(d.get('gateway', {}).get('auth', {}).get('token', ''))
except Exception:
    print('')
" 2>/dev/null || true)
fi

# ── 显示 Token 保护策略 ────────────────────────────────────────────────────
echo "🔑 Gateway Token 策略:"
if $OVERWRITE_GATEWAY_TOKEN; then
  warn "  --overwrite-gateway-token 已设置: 备份中的 Token 将覆盖当前 Token"
  warn "  你可能需要在 Control UI / Dashboard 中更新 Token"
else
  if [ -n "$CURRENT_GATEWAY_TOKEN" ]; then
    info "  当前服务器 Token 将被保留 (防止 Dashboard Token 不匹配)"
    echo "       Token: ${CURRENT_GATEWAY_TOKEN:0:8}...${CURRENT_GATEWAY_TOKEN: -4}"
  else
    warn "  未找到当前 Token — 将使用备份中的 Token"
  fi
fi
echo ""

# ── Dry Run 模式：输出预览后退出 ──────────────────────────────────────────
if $DRY_RUN; then
  echo ""
  dryrun "以下操作将在实际恢复时执行:"
  dryrun "  1. 自动备份当前 ~/.openclaw/ 到 /tmp/"
  dryrun "  2. 停止 OpenClaw Gateway"
  dryrun "  3. 解压归档到 ~/.openclaw/ (覆盖现有文件)"
  if [ -n "$CURRENT_GATEWAY_TOKEN" ] && ! $OVERWRITE_GATEWAY_TOKEN; then
    dryrun "  4. 恢复当前服务器的 Gateway Token"
  fi
  dryrun "  5. 重启 OpenClaw Gateway"
  dryrun "  6. 写入 .restore-complete.json 标志文件"
  echo ""
  echo "   文件将被覆盖的目录:"
  tar -tzf "$REAL_ARCHIVE" | cut -d'/' -f1-2 | sort -u | head -30 | sed 's/^/     /'
  TOTAL_DIRS=$(tar -tzf "$REAL_ARCHIVE" | cut -d'/' -f1-2 | sort -u | wc -l | tr -d ' ')
  [ "$TOTAL_DIRS" -gt 30 ] && echo "     ... 及其他 $((TOTAL_DIRS - 30)) 个路径"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Dry run 完成。去掉 --dry-run 参数以执行实际恢复。"
  echo ""
  exit 0
fi

# ── 交互式确认 ──────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}⚠️  警告: 此操作将用备份数据覆盖 ~/.openclaw/ 下的文件。${NC}"
echo "   归档: $(basename "$ARCHIVE")"
echo "   目标: ${OPENCLAW_HOME}"
if [ -n "$CURRENT_GATEWAY_TOKEN" ] && ! $OVERWRITE_GATEWAY_TOKEN; then
  echo -e "   ${GREEN}Gateway Token: 保留 (当前服务器的 Token 将被保持)${NC}"
fi
echo ""
echo -n "   输入 'yes' 以确认: "
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "已取消。"
  exit 0
fi
echo ""

# ── 恢复前自动快照 ──────────────────────────────────────────────────────────
# 逻辑重构：直接调用同级的 backup-full.sh 执行快照，确保规则一致
if [ -f "${SCRIPT_DIR}/backup-full.sh" ]; then
    warn "正在执行恢复前快照 (调用 backup-full.sh)..."
    # 强制禁用快照加密，避免在后台运行时弹密码
    OC_BACKUP_PASS="" bash "${SCRIPT_DIR}/backup-full.sh" /tmp > /tmp/oc-snapshot.log 2>&1 || warn "  快照生成遇到部分警告"
    
    # 从日志中提取生成的文件名
    AUTO_BACKUP=$(grep "✅ 全卷备份完成:" /tmp/oc-snapshot.log | awk '{print $NF}' | tr -d '\r')
    if [ -n "$AUTO_BACKUP" ]; then
        AUTO_BACKUP="/tmp/${AUTO_BACKUP}"
        info "  快照已保存: ${AUTO_BACKUP}"
    else
        warn "  未能自动识别快照文件名，请检查 /tmp/oc-snapshot.log"
    fi
else
    warn "未找到 backup-full.sh，跳过自动快照。"
fi

# ── 停止 Gateway ────────────────────────────────────────────────────────────
warn "正在停止 OpenClaw Gateway..."
openclaw gateway stop 2>/dev/null || kill $(pgrep -f "openclaw gateway" | head -1) 2>/dev/null || true
sleep 2

# ── 执行全卷解压覆盖 ────────────────────────────────────────────────────────
info "正在解压归档到 ${OPENCLAW_HOME} ..."
tar -xzf "$REAL_ARCHIVE" -C "$(dirname "$OPENCLAW_HOME")"
info "全卷解压完成"

# 清理打包时临时写入的 manifest 文件
rm -f "${OPENCLAW_HOME}/.backup-manifest.json"

# ── 恢复 Gateway Token ─────────────────────────────────────────────────────
if [ -n "$CURRENT_GATEWAY_TOKEN" ] && ! $OVERWRITE_GATEWAY_TOKEN; then
  info "正在恢复当前服务器的 Gateway Token..."
  _OC_PATH="${OPENCLAW_HOME}/openclaw.json" _OC_TOKEN="$CURRENT_GATEWAY_TOKEN" python3 -c "
import json, os
path = os.environ['_OC_PATH']
token = os.environ['_OC_TOKEN']
d = json.load(open(path))
if 'gateway' not in d:
    d['gateway'] = {}
if 'auth' not in d['gateway']:
    d['gateway']['auth'] = {}
d['gateway']['auth']['token'] = token
json.dump(d, open(path, 'w'), indent=2)
print('  Gateway Token 已恢复为当前服务器值')
"
  info "  openclaw.json 已恢复 (Gateway Token 保留: ${CURRENT_GATEWAY_TOKEN:0:8}...)"
else
  info "  openclaw.json 已恢复 (使用备份中的 Gateway Token)"
fi

# ── 重启 Gateway ────────────────────────────────────────────────────────────
echo ""
info "正在启动 OpenClaw Gateway..."
if [ -f "${OPENCLAW_HOME}/start-gateway.sh" ]; then
  bash "${OPENCLAW_HOME}/start-gateway.sh" &
  sleep 3
  info "  Gateway 已启动"
else
  warn "  start-gateway.sh 未找到 — 请手动启动: openclaw gateway start"
fi

# ── 写入恢复完成标志 ────────────────────────────────────────────────────────
RESTORED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 尝试从多个可能的 workspace 目录写入标志文件
RESTORE_FLAG_WRITTEN=false
for ws_candidate in "${OPENCLAW_HOME}"/workspace-* "${OPENCLAW_HOME}/workspace"; do
  if [ -d "$ws_candidate" ]; then
    RESTORE_FLAG="${ws_candidate}/.restore-complete.json"
    python3 -c "
import json
data = {
  'restored_at': '${RESTORED_AT}',
  'backup_file': '$(basename "$ARCHIVE")',
  'backup_mode': 'full',
  'pre_restore_snapshot': '${AUTO_BACKUP}',
  'restore_method': 'restore-full.sh'
}
with open('${RESTORE_FLAG}', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null && RESTORE_FLAG_WRITTEN=true && break
  fi
done

if $RESTORE_FLAG_WRITTEN; then
  info "  恢复标志已写入: .restore-complete.json"
else
  warn "  无法写入恢复标志 (非关键性问题)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 全卷恢复完成!"
echo ""
if [ -n "$CURRENT_GATEWAY_TOKEN" ] && ! $OVERWRITE_GATEWAY_TOKEN; then
  echo "🔑 Gateway Token: 已保留 (当前服务器的 Token 未被覆盖)"
  echo "   Control UI / Dashboard 无需任何调整。"
else
  echo "🔑 Gateway Token: 已从备份恢复"
  echo "   ⚠️  如果 Control UI 显示 'token mismatch'，请将以下 Token 写入 Dashboard 设置:"
  python3 -c "
import json
d = json.load(open('${OPENCLAW_HOME}/openclaw.json'))
print('   ' + d.get('gateway', {}).get('auth', {}).get('token', '(未找到)'))
" 2>/dev/null || true
fi
echo ""
echo "📋 所有 Channel 应会自动重新连接。"
echo "   如果 Telegram 30 秒后无响应，请向 Bot 发送 /start 重新触发连接。"
echo "   验证: openclaw gateway status"
echo ""
