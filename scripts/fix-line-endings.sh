#!/usr/bin/env bash
# ============================================================
# fix-line-endings.sh
# 在 Linux 服务器上对导入的脚本和配置文件做行尾修复（CRLF → LF）。
# 通常在 Windows 完成离线打包、传输到内网 Linux 后、首次执行前运行一次。
#
# 用法：
#   bash scripts/fix-line-endings.sh          # 直接修复
#   bash scripts/fix-line-endings.sh --dry-run # 仅列出含 CRLF 的文件
# ============================================================

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[dry-run] 仅检查，不修改文件"
fi

# 脚本自身目录的上级即项目根目录
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "项目根目录: $ROOT"
echo ""

FIXED=0
SKIPPED=0

# 需要处理的文件扩展名
EXTS=("sh" "yml" "yaml" "conf" "env" "py" "rc")

# 构造 find 的 -name 条件
FIND_ARGS=()
for ext in "${EXTS[@]}"; do
    FIND_ARGS+=(-o -name "*.${ext}")
done
# 去掉第一个多余的 -o
FIND_ARGS=("${FIND_ARGS[@]:1}")

while IFS= read -r -d '' file; do
    has_crlf=false
    has_bom=false

    grep -qP '\r' "$file" 2>/dev/null && has_crlf=true
    grep -qP '^\xEF\xBB\xBF' "$file" 2>/dev/null && has_bom=true

    if ! $has_crlf && ! $has_bom; then
        ((SKIPPED++)) || true
        continue
    fi

    rel="${file#"$ROOT/"}"
    issues=""
    $has_crlf && issues+="CRLF"
    $has_bom  && { [[ -n "$issues" ]] && issues+="+"; issues+="BOM"; }

    if $DRY_RUN; then
        echo "[检测到 ${issues}] $rel"
    else
        # 移除 BOM（文件首行开头的 UTF-8 BOM：EF BB BF）
        $has_bom  && sed -i '1s/^\xEF\xBB\xBF//' "$file"
        # 移除 CRLF（不依赖 dos2unix）
        $has_crlf && sed -i 's/\r$//' "$file"
        echo "[已修复 ${issues}] $rel"
    fi
    ((FIXED++)) || true
done < <(find "$ROOT" \( "${FIND_ARGS[@]}" \) -type f -print0)

echo ""
if $DRY_RUN; then
    echo "检测完成：${FIXED} 个文件含 CRLF/BOM，${SKIPPED} 个文件无需处理。"
else
    echo "完成：已修复 ${FIXED} 个文件，跳过 ${SKIPPED} 个文件（无需处理）。"
fi
