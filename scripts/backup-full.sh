#!/usr/bin/env bash
# openclaw-backup-full: 黑名单全卷备份 ~/.openclaw
# 用法: backup-full.sh [output-dir] [--exclude-file <path>]
#
# 与 backup.sh 的区别：
#   backup.sh    = 白名单精筛（逐目录挑选）
#   backup-full.sh = 黑名单全卷（整体打包，排除已知垃圾）
#
# 排除规则从 backup-exclude.conf 读取（每行一条 glob），
# 后续新增排除项只需编辑配置文件，无需改动本脚本。

set -euo pipefail

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="${1:-/tmp/openclaw-backups}"

# 解析可选参数
EXCLUDE_FILE=""
shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --exclude-file)
      EXCLUDE_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

OPENCLAW_HOME="${HOME}/.openclaw"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 默认排除规则文件：与本脚本同级目录下的 backup-exclude.conf
[ -z "$EXCLUDE_FILE" ] && EXCLUDE_FILE="${SCRIPT_DIR}/backup-exclude.conf"

# 使用 hostname 作为标识符，配合时间戳保证唯一性
HOST_NAME=$(hostname | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
BACKUP_NAME="openclaw-full-backup_${HOST_NAME}_${TIMESTAMP}"

# ── 颜色输出 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── 前置校验 ────────────────────────────────────────────────────────────────
[ ! -d "$OPENCLAW_HOME" ] && error "OpenClaw 主目录不存在: $OPENCLAW_HOME"

echo ""
echo "🦞 OpenClaw Full Backup — ${TIMESTAMP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$OUTPUT_DIR"

# ── 构建排除规则 ────────────────────────────────────────────────────────────
EXCLUDE_TMPFILE=$(mktemp /tmp/oc-exclude.XXXXXX)
trap "rm -f $EXCLUDE_TMPFILE" EXIT

if [ -f "$EXCLUDE_FILE" ]; then
  # 过滤注释行和空行
  grep -v '^\s*#' "$EXCLUDE_FILE" | grep -v '^\s*$' > "$EXCLUDE_TMPFILE"
  RULE_COUNT=$(wc -l < "$EXCLUDE_TMPFILE" | tr -d ' ')
  info "已加载排除规则: ${EXCLUDE_FILE} (${RULE_COUNT} 条)"
else
  warn "排除规则文件不存在: ${EXCLUDE_FILE}，将打包全部内容"
  touch "$EXCLUDE_TMPFILE"
fi

# ── 显示排除规则摘要 ────────────────────────────────────────────────────────
if [ -s "$EXCLUDE_TMPFILE" ]; then
  echo "   排除项: $(head -5 "$EXCLUDE_TMPFILE" | tr '\n' ' ')"
  TOTAL=$(wc -l < "$EXCLUDE_TMPFILE" | tr -d ' ')
  [ "$TOTAL" -gt 5 ] && echo "   ... 及其他 $((TOTAL - 5)) 条规则"
fi
echo ""

# ── 写入 MANIFEST.json 到临时位置 ──────────────────────────────────────────
MANIFEST_TMP=$(mktemp /tmp/oc-manifest.XXXXXX)
trap "rm -f $EXCLUDE_TMPFILE $MANIFEST_TMP" EXIT

OC_VERSION=$(openclaw --version 2>/dev/null | head -1 || true)
OC_VERSION="${OC_VERSION:-unknown}"

cat > "$MANIFEST_TMP" <<EOF
{
  "backup_name": "${BACKUP_NAME}",
  "backup_mode": "full",
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "openclaw_home": "${OPENCLAW_HOME}",
  "openclaw_version": "${OC_VERSION}",
  "created_by": "openclaw-backup skill (full mode) v1.0",
  "exclude_file": "$(basename "$EXCLUDE_FILE")",
  "exclude_rules_count": ${RULE_COUNT:-0},
  "notes": "Full-volume backup. Restore with restore-full.sh. Contains credentials and API keys — keep secure."
}
EOF

# 临时拷贝 MANIFEST 到 openclaw 目录（打包后删除）
MANIFEST_DEST="${OPENCLAW_HOME}/.backup-manifest.json"
cp "$MANIFEST_TMP" "$MANIFEST_DEST"

# ── 执行全卷打包 ────────────────────────────────────────────────────────────
info "正在打包 ${OPENCLAW_HOME} ..."
ARCHIVE="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"

tar -czf "$ARCHIVE" \
  --exclude-from="$EXCLUDE_TMPFILE" \
  -C "$(dirname "$OPENCLAW_HOME")" \
  "$(basename "$OPENCLAW_HOME")"

# 清理临时 manifest
rm -f "$MANIFEST_DEST"

# 设置安全权限（归档包含敏感凭证）
chmod 600 "$ARCHIVE"

ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
info "打包完成: ${ARCHIVE}"
info "归档大小: ${ARCHIVE_SIZE}"

# ── 对比统计 ────────────────────────────────────────────────────────────────
ORIGINAL_SIZE=$(du -sh "$OPENCLAW_HOME" 2>/dev/null | cut -f1 || echo "unknown")
info "原始目录: ${ORIGINAL_SIZE} → 压缩后: ${ARCHIVE_SIZE}"
warn "归档包含凭证 — 请妥善保管 (chmod 600 已应用)"

# ── 清理旧备份（保留最近 7 个） ──────────────────────────────────────────────
BACKUP_COUNT=$(ls "${OUTPUT_DIR}"/openclaw-full-backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt 7 ]; then
  info "清理旧的全卷备份 (保留最近 7 个)..."
  ls -t "${OUTPUT_DIR}"/openclaw-full-backup_*.tar.gz | tail -n +8 | xargs rm -f
  info "  已删除 $((BACKUP_COUNT - 7)) 个旧备份"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 全卷备份完成: ${BACKUP_NAME}.tar.gz"
echo "   恢复命令: restore-full.sh ${ARCHIVE}"
echo ""
