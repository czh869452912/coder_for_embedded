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

echo "[startup] Workspace ready!"
echo "[startup] Access via Coder dashboard: /@${CODER_WORKSPACE_OWNER_NAME:-user}/${CODER_WORKSPACE_NAME:-workspace}.main/apps/code-server"
