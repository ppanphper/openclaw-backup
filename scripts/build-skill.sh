#!/usr/bin/env bash
# build-skill.sh: 将当前仓库打包为 .skill 文件（ZIP 格式）
# 用法: build-skill.sh [output-path]
#   output-path: 输出文件路径（默认: 仓库根目录下的 openclaw-backup.skill）
#
# .skill 文件本质是 ZIP 压缩包，根目录必须是技能名（如 openclaw-backup/），
# 内含 SKILL.md（必需）和 scripts/ 等资源目录。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL_NAME="openclaw-backup"
OUTPUT="${1:-${REPO_ROOT}/${SKILL_NAME}.skill}"

# ── 颜色输出 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── 前置校验 ────────────────────────────────────────────────────────────────
[ ! -f "${REPO_ROOT}/SKILL.md" ] && error "SKILL.md 不存在于 ${REPO_ROOT}，无法打包"
command -v zip >/dev/null 2>&1 || error "需要 zip 命令。请先安装: brew install zip"

echo ""
echo "📦 构建 OpenClaw Skill 包"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 构建临时目录（确保根目录为技能名） ──────────────────────────────────────
BUILD_DIR=$(mktemp -d /tmp/skill-build.XXXXXX)
trap "rm -rf $BUILD_DIR" EXIT

SKILL_DIR="${BUILD_DIR}/${SKILL_NAME}"
mkdir -p "$SKILL_DIR"

# ── 拷贝需要打包的文件 ────────────────────────────────────────────────────
# 核心文件
cp "${REPO_ROOT}/SKILL.md" "${SKILL_DIR}/"

# scripts 目录
if [ -d "${REPO_ROOT}/scripts" ]; then
  mkdir -p "${SKILL_DIR}/scripts"
  cp "${REPO_ROOT}/scripts/"*.sh "${SKILL_DIR}/scripts/" 2>/dev/null || true
  cp "${REPO_ROOT}/scripts/"*.js "${SKILL_DIR}/scripts/" 2>/dev/null || true
  cp "${REPO_ROOT}/scripts/"*.html "${SKILL_DIR}/scripts/" 2>/dev/null || true
  cp "${REPO_ROOT}/scripts/"*.conf "${SKILL_DIR}/scripts/" 2>/dev/null || true
  # 确保脚本拥有可执行权限
  chmod +x "${SKILL_DIR}/scripts/"*.sh 2>/dev/null || true
  info "scripts/ → $(ls "${SKILL_DIR}/scripts/" | wc -l | tr -d ' ') 个文件"
fi

# references 目录
if [ -d "${REPO_ROOT}/references" ]; then
  mkdir -p "${SKILL_DIR}/references"
  cp -r "${REPO_ROOT}/references/"* "${SKILL_DIR}/references/"
  info "references/ → $(ls "${SKILL_DIR}/references/" | wc -l | tr -d ' ') 个文件"
fi

# ── 执行 ZIP 打包 ──────────────────────────────────────────────────────────
rm -f "$OUTPUT"
(cd "$BUILD_DIR" && zip -r "$OUTPUT" "$SKILL_NAME/" -x "*/.git/*" "*/node_modules/*" "*/.DS_Store")

SKILL_SIZE=$(du -sh "$OUTPUT" | cut -f1)
FILE_COUNT=$(unzip -l "$OUTPUT" | tail -1 | awk '{print $2}')

echo ""
info "构建完成: ${OUTPUT}"
info "文件大小: ${SKILL_SIZE}"
info "包含文件: ${FILE_COUNT} 个"
echo ""

# ── 显示包内容清单 ──────────────────────────────────────────────────────────
echo "📋 包内容:"
unzip -l "$OUTPUT" | grep -v "^Archive\|^  Length\|^-\|files$" | sed 's/^/   /'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 技能包已就绪: $(basename "$OUTPUT")"
echo "   安装: 将此文件拷贝到 ~/.openclaw/skills/ 并解压"
echo "   或通过 OpenClaw Dashboard 上传安装"
echo ""
