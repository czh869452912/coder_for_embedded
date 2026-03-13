#!/bin/bash
# ============================================================
# Coder 首次初始化脚本
# 在 manage.sh up 首次启动后自动执行（通过 .setup-done 标记防止重复）
#
# 功能：
#   1. 等待 Coder 服务就绪
#   2. 创建第一个管理员账户（通过 API）
#   3. 登录并获取 session token
#   4. 推送 workspace template（通过 docker exec 调用 coder CLI）
#   5. 写入 .setup-done 标记
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/docker"
ENV_FILE="$DOCKER_DIR/.env"
SETUP_DONE_FILE="$DOCKER_DIR/.setup-done"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 加载环境变量
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}[setup] 错误: $ENV_FILE 不存在，请先运行 manage.sh init${NC}"
    exit 1
fi
source "$ENV_FILE"

CODER_INTERNAL_URL="http://localhost:${CODER_INTERNAL_PORT:-7080}"

# ============================================================
# 等待 Coder 就绪
# ============================================================
wait_for_coder() {
    echo -e "${YELLOW}[setup] 等待 Coder 服务就绪...${NC}"
    local url="${CODER_INTERNAL_URL}/healthz"
    for i in $(seq 1 60); do
        if curl -sf "$url" >/dev/null 2>&1; then
            echo -e "${GREEN}[setup] Coder 已就绪${NC}"
            return 0
        fi
        echo -n "."
        sleep 3
    done
    echo ""
    echo -e "${RED}[setup] 错误: Coder 在 180 秒内未就绪${NC}"
    return 1
}

# ============================================================
# 检查是否已有第一个用户
# ============================================================
check_first_user() {
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        "${CODER_INTERNAL_URL}/api/v2/users/first" 2>/dev/null || echo "000")
    echo "$status"
}

# ============================================================
# 创建第一个管理员账户
# ============================================================
create_admin_user() {
    echo -e "${YELLOW}[setup] 创建管理员账户: ${CODER_ADMIN_EMAIL}${NC}"
    local result
    result=$(curl -sf -X POST \
        "${CODER_INTERNAL_URL}/api/v2/users/first" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"${CODER_ADMIN_EMAIL}\",
            \"username\": \"${CODER_ADMIN_USERNAME}\",
            \"password\": \"${CODER_ADMIN_PASSWORD}\",
            \"trial\": false
        }" 2>&1)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[setup] 管理员账户已创建${NC}"
    else
        echo -e "${RED}[setup] 创建管理员账户失败: $result${NC}"
        exit 1
    fi
}

# ============================================================
# 登录并获取 session token
# ============================================================
get_session_token() {
    local token
    token=$(curl -sf -X POST \
        "${CODER_INTERNAL_URL}/api/v2/users/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"${CODER_ADMIN_EMAIL}\",
            \"password\": \"${CODER_ADMIN_PASSWORD}\"
        }" | python3 -c "import sys, json; print(json.load(sys.stdin)['session_token'])" 2>/dev/null)

    if [ -z "$token" ]; then
        echo -e "${RED}[setup] 错误: 获取 session token 失败${NC}"
        exit 1
    fi
    echo "$token"
}

# ============================================================
# 检查模板是否已存在
# ============================================================
check_template_exists() {
    local token="$1"
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        "${CODER_INTERNAL_URL}/api/v2/organizations/default/templates/embedded-dev" \
        -H "Coder-Session-Token: $token" 2>/dev/null || echo "000")
    echo "$status"
}

# ============================================================
# 推送 workspace 模板（通过 docker exec 调用 coder CLI）
# ============================================================
push_template() {
    local token="$1"
    local template_dir="$PROJECT_ROOT/workspace-template"

    echo -e "${YELLOW}[setup] 推送 workspace 模板...${NC}"

    # 将模板目录打包并复制到 coder 容器
    local tmp_tar="/tmp/coder-workspace-template-$$.tar.gz"
    tar czf "$tmp_tar" -C "$template_dir" .
    docker cp "$tmp_tar" coder-server:/tmp/workspace-template.tar.gz
    rm "$tmp_tar"

    # 确定证书路径（宿主机上的路径，供 workspace 容器挂载）
    local ssl_cert_path="${PROJECT_ROOT}/configs/ssl/server.crt"

    # 在 coder 容器内执行模板推送
    docker exec coder-server sh -c "
        mkdir -p /tmp/template-push && \
        tar xzf /tmp/workspace-template.tar.gz -C /tmp/template-push && \
        CODER_URL=http://localhost:7080 \
        CODER_SESSION_TOKEN=${token} \
        /opt/coder templates push embedded-dev \
            --directory /tmp/template-push \
            --yes \
            --activate \
            --var 'workspace_image=${WORKSPACE_IMAGE:-workspace-embedded}' \
            --var 'workspace_image_tag=${WORKSPACE_IMAGE_TAG:-latest}' \
            --var 'anthropic_api_key=${ANTHROPIC_API_KEY:-}' \
            --var 'anthropic_base_url=${ANTHROPIC_BASE_URL:-}' && \
        rm -rf /tmp/template-push /tmp/workspace-template.tar.gz
    "

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[setup] workspace 模板推送成功${NC}"
    else
        echo -e "${RED}[setup] 模板推送失败${NC}"
        exit 1
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo -e "${BLUE}[setup] 开始 Coder 初始化配置...${NC}"

    wait_for_coder

    local first_user_status
    first_user_status=$(check_first_user)

    if [ "$first_user_status" = "404" ]; then
        create_admin_user
    elif [ "$first_user_status" = "200" ]; then
        echo -e "${YELLOW}[setup] 管理员账户已存在，跳过创建${NC}"
    else
        echo -e "${RED}[setup] 无法确认用户状态（HTTP $first_user_status），等待 Coder 完全就绪...${NC}"
        sleep 10
        first_user_status=$(check_first_user)
        if [ "$first_user_status" = "404" ]; then
            create_admin_user
        fi
    fi

    local session_token
    session_token=$(get_session_token)
    echo -e "${GREEN}[setup] 已登录，获取 session token${NC}"

    local template_status
    template_status=$(check_template_exists "$session_token")

    if [ "$template_status" = "200" ]; then
        echo -e "${YELLOW}[setup] 模板 embedded-dev 已存在，跳过推送${NC}"
        echo -e "${YELLOW}[setup] 如需更新模板：docker exec coder-server /opt/coder templates push embedded-dev ...${NC}"
    else
        push_template "$session_token"
    fi

    # 写入完成标记
    date > "$SETUP_DONE_FILE"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Coder 初始化完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "访问地址: ${BLUE}https://${SERVER_HOST:-localhost}:${GATEWAY_PORT:-8443}${NC}"
    echo -e "管理员:   ${BLUE}${CODER_ADMIN_EMAIL}${NC}"
    echo -e "密码:     ${BLUE}${CODER_ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "${YELLOW}用户创建 workspace 后，IDE 访问路径：${NC}"
    echo -e "  ${BLUE}https://${SERVER_HOST:-localhost}:${GATEWAY_PORT:-8443}/@<用户名>/<workspace名>.main/apps/code-server${NC}"
}

main "$@"
