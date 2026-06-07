#!/bin/bash
# ============================================================
# workspace 启动脚本（在 workspace 容器内执行）
# 由 Coder agent 的 startup_script 调用
#
# 功能：
#   1. 配置 Claude Code API（从环境变量读取）
#   2. 合并内置 VS Code 扩展（seed → extensions 目录）
#   3. 后台启动 code-server（--auth none，Coder 负责认证）
# ============================================================
set -e

# ---- 1. 配置 Claude Code ----
# 容器以 root 运行，Claude Code 读取 /root/.claude/settings.json
CLAUDE_DIR="${HOME}/.claude"
mkdir -p "$CLAUDE_DIR"

if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    cat > "$CLAUDE_DIR/settings.json" <<CONFIG_EOF
{
  "env": {
    "ANTHROPIC_API_KEY": "${ANTHROPIC_API_KEY:-}",
    "ANTHROPIC_BASE_URL": "${ANTHROPIC_BASE_URL:-}",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8192"
  }
}
CONFIG_EOF

    # 标记已完成新手引导，这是独立在根目录的 .claude.json，强制覆盖旧状态
    rm -f "${HOME}/.claude.json"
    cat > "${HOME}/.claude.json" <<ONBOARDING_EOF
{
  "hasCompletedOnboarding": true
}
ONBOARDING_EOF

    echo "[startup] Claude Code configured: ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-<default Anthropic>}"
else
    echo "[startup] WARNING: No API config found."
    echo "[startup]   In offline/intranet deployments, Claude Code requires either:"
    echo "[startup]     A) ANTHROPIC_BASE_URL pointing to an internal LiteLLM gateway"
    echo "[startup]     B) ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL pointing to an internal model server"
    echo "[startup]   Interactive login (OAuth) requires external internet access and WILL fail offline."
    echo "[startup]   Configure the workspace template vars via: manage.sh init + manage.sh setup-coder"
fi

# ---- 验证 claude CLI ----
if command -v claude >/dev/null 2>&1; then
    echo "[startup] claude CLI found at: $(which claude)"
else
    echo "[startup] WARNING: claude CLI not found in PATH"
fi

if [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${OPENAI_BASE_URL:-}" ]; then
    echo "[startup] OpenAI-compatible config present: OPENAI_BASE_URL=${OPENAI_BASE_URL:-<default OpenAI>}"
else
    echo "[startup] INFO: OPENAI_* not configured; Codex and Kilo can be configured interactively."
fi

if command -v codex >/dev/null 2>&1; then
    echo "[startup] codex CLI found at: $(which codex)"
else
    echo "[startup] WARNING: codex CLI not found in PATH"
fi

if command -v kilo >/dev/null 2>&1; then
    echo "[startup] kilo CLI found at: $(which kilo)"
else
    echo "[startup] WARNING: kilo CLI not found in PATH"
fi

# ---- 2. 合并内置扩展 seed 到 extensions 目录 ----
# seed 目录随镜像构建，volume 挂载不会覆盖它
# -n (no-clobber) 保证不覆盖用户手动安装的同名扩展
SEED_DIR="${CODE_SERVER_EXTENSIONS_SEED:-/opt/code-server-extensions-seed}"
EXT_DIR="/home/coder/.local/share/code-server/extensions"

if [ -d "$SEED_DIR" ] && [ "$(ls -A "$SEED_DIR" 2>/dev/null)" ]; then
    mkdir -p "$EXT_DIR"
    cp -rn "$SEED_DIR"/. "$EXT_DIR"/
    # 确保 coder 用户对扩展目录有读取权限
    chown -R coder:coder "$EXT_DIR" 2>/dev/null || true
    echo "[startup] Built-in extensions merged from $SEED_DIR"
fi

# ---- 3. 后台启动 code-server ----
# --auth none: Coder 已负责认证，无需 code-server 再要密码
# --bind-addr 0.0.0.0:8080: 监听容器内的 8080 端口
# Coder agent 的 coder_app.healthcheck 会检查 /healthz 确认就绪
echo "[startup] Starting code-server on :8080 (auth=none)..."

nohup dumb-init /usr/bin/code-server \
    --bind-addr 0.0.0.0:8080 \
    --extensions-dir /home/coder/.local/share/code-server/extensions \
    --user-data-dir /home/coder/.local/share/code-server \
    --disable-telemetry \
    --disable-update-check \
    --auth none \
    > /tmp/code-server.log 2>&1 &

CODE_SERVER_PID=$!
echo "[startup] code-server started (PID: $CODE_SERVER_PID)"

# 等待 code-server 就绪（最多 30 秒）
for i in $(seq 1 30); do
    if curl -sf http://localhost:8080/healthz >/dev/null 2>&1; then
        echo "[startup] code-server is ready"
        break
    fi
    sleep 1
done

# ---- 4. Skill Hub 集成（SKILLHUB_ENABLED=true 时）----
if [ "${SKILLHUB_ENABLED:-false}" = "true" ]; then
    # 配置 pip 使用内网 PyPI Mirror（通过 Docker DNS 直达，无 TLS 开销）
    mkdir -p "${HOME}/.pip"
    cat > "${HOME}/.pip/pip.conf" <<PIP_EOF
[global]
index-url = http://pypi-mirror:8080/simple/
trusted-host = pypi-mirror
PIP_EOF
    echo "[startup] pip configured to use internal PyPI mirror (http://pypi-mirror:8080/simple/)"

    # 从 Gitea 克隆 Claude Code slash commands 到 ~/.claude/commands/
    # Gitea 内部 URL 通过 Docker DNS 访问（http://gitea:3000）
    COMMANDS_DIR="${HOME}/.claude/commands"
    GITEA_URL="http://gitea:3000"

    if [ -d "${COMMANDS_DIR}/.git" ]; then
        echo "[startup] Updating commands from Gitea..."
        git -C "$COMMANDS_DIR" pull --quiet 2>/dev/null \
            || echo "[startup] WARNING: git pull commands failed (non-fatal)"
    else
        echo "[startup] Cloning commands from Gitea..."
        mkdir -p "$(dirname "$COMMANDS_DIR")"
        git clone --quiet "${GITEA_URL}/admin/commands" "$COMMANDS_DIR" 2>/dev/null \
            && echo "[startup] Commands installed to ~/.claude/commands/" \
            || echo "[startup] WARNING: failed to clone commands from Gitea (skill hub may not be running)"
    fi

    # 添加 skill-sync alias 到 ~/.bashrc（方便手动重新同步）
    if ! grep -q 'skill-sync' "${HOME}/.bashrc" 2>/dev/null; then
        cat >> "${HOME}/.bashrc" <<'BASHRC_EOF'

# Claude Code commands sync from Gitea Skill Hub (added by workspace-startup.sh)
alias skill-sync='git -C "${HOME}/.claude/commands" pull && echo "Commands updated."'
BASHRC_EOF
    fi
fi

echo "[startup] Workspace ready!"
echo "[startup] Access via Coder dashboard: /@${CODER_WORKSPACE_OWNER_NAME:-user}/${CODER_WORKSPACE_NAME:-workspace}.main/apps/code-server"
