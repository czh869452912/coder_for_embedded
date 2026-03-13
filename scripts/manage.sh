#!/bin/bash
# ============================================================
# Coder 生产平台管理脚本
# 支持 docker compose（v2/v1）运行模式
# ============================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/docker"
CONFIGS_DIR="$PROJECT_ROOT/configs"
ENV_FILE="$DOCKER_DIR/.env"
SETUP_DONE_FILE="$DOCKER_DIR/.setup-done"

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}  Coder 生产平台管理脚本${NC}"
echo -e "${BLUE}===============================================${NC}"
echo ""

# ============================================================
# 全局 flag 解析
# ============================================================
USE_LLM="${USE_LLM:-false}"
_args=()
for _a in "$@"; do
    case "$_a" in
        --llm) USE_LLM=true ;;
        *)     _args+=("$_a") ;;
    esac
done
set -- "${_args[@]+"${_args[@]}"}"

usage() {
    echo "用法: $0 [命令] [选项]"
    echo ""
    echo "命令:"
    echo "  init              初始化环境（创建 .env 配置文件）"
    echo "  build             构建 workspace Docker 镜像"
    echo "  pull              拉取平台基础镜像（联网）"
    echo "  save              保存所有镜像到 images/ 目录（离线打包）"
    echo "  load              从 images/ 目录加载镜像（离线部署）"
    echo "  up                启动平台（自动生成 SSL、首次初始化 Coder）"
    echo "  down              停止平台"
    echo "  status            查看服务状态"
    echo "  logs [服务名]     查看日志（可选: gateway, coder, postgres, llm-gateway）"
    echo "  shell <服务名>    进入指定服务的 shell"
    echo "  ssl [host]        生成自签名 SSL 证书（host 为服务器 IP 或域名）"
    echo "  setup-coder       手动触发 Coder 初始化（创建管理员+推送模板）"
    echo "  test-api          测试 LLM API 连接"
    echo "  clean             清理 Docker 构建缓存"
    echo ""
    echo "选项:"
    echo "  --llm             包含 LiteLLM AI 网关（需 configs/litellm_config.yaml）"
    echo ""
    echo "示例:"
    echo "  $0 init                    创建 .env 配置"
    echo "  $0 ssl 192.168.1.100       为内网 IP 生成证书"
    echo "  $0 build                   构建 workspace 镜像"
    echo "  $0 up                      启动平台"
    echo "  $0 up --llm                启动平台（含 LiteLLM）"
    echo "  $0 logs coder              查看 Coder 日志"
    echo "  $0 shell coder             进入 Coder 容器"
    echo ""
    echo "单端口访问（启动后）："
    echo "  管理后台:  https://<IP>:8443/"
    echo "  用户 IDE:  https://<IP>:8443/@<用户名>/<workspace>.main/apps/code-server"
    echo "  LiteLLM:  https://<IP>:8443/llm/  （--llm 模式下）"
    echo ""
    exit 0
}

check_deps() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}错误: 未找到 docker，请先安装 Docker Engine${NC}"
        exit 1
    fi

    if docker compose version &>/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
        COMPOSE_AVAILABLE=true
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE="docker-compose"
        COMPOSE_AVAILABLE=true
    else
        echo -e "${RED}错误: 未找到 docker compose，Coder 平台需要 Docker Compose${NC}"
        exit 1
    fi
}

init_dirs() {
    mkdir -p "$PROJECT_ROOT/images"
    mkdir -p "$PROJECT_ROOT/logs/nginx"
    mkdir -p "$CONFIGS_DIR/ssl"
    mkdir -p "$CONFIGS_DIR/vsix"
    mkdir -p "$CONFIGS_DIR/terraform-providers"
}

# ============================================================
# init: 创建 .env 配置文件
# ============================================================
init_config() {
    echo -e "${YELLOW}初始化 Coder 平台配置...${NC}"

    if [ -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}配置文件已存在: $ENV_FILE${NC}"
        read -p "是否覆盖? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}保留现有配置${NC}"
            return
        fi
    fi

    # 自动生成 PostgreSQL 密码
    local pg_password
    if command -v openssl &>/dev/null; then
        pg_password=$(openssl rand -hex 16)
    else
        pg_password="changeme_$(date +%s)"
    fi

    read -p "服务器 IP 或域名 [localhost]: " server_host
    server_host="${server_host:-localhost}"

    read -p "网关端口 [8443]: " gateway_port
    gateway_port="${gateway_port:-8443}"

    read -p "Coder 管理员邮箱 [admin@company.local]: " admin_email
    admin_email="${admin_email:-admin@company.local}"

    read -p "Coder 管理员用户名 [admin]: " admin_username
    admin_username="${admin_username:-admin}"

    read -s -p "Coder 管理员密码 (至少8位): " admin_password
    echo
    if [ ${#admin_password} -lt 8 ]; then
        admin_password="Coder@$(date +%Y)"
        echo -e "${YELLOW}密码太短，已使用自动生成: $admin_password${NC}"
    fi

    read -p "Anthropic API Key (可留空): " anthropic_key
    read -p "Anthropic Base URL (内网代理地址，可留空): " anthropic_url

    cat > "$ENV_FILE" << EOF
# ============================================================
# Coder 生产平台配置
# 由 manage.sh init 自动生成
# ============================================================

# ---- 网络配置 ----
SERVER_HOST=${server_host}
GATEWAY_PORT=${gateway_port}

# ---- Coder 镜像版本 ----
CODER_IMAGE=ghcr.io/coder/coder
CODER_VERSION=latest
WORKSPACE_IMAGE=workspace-embedded
WORKSPACE_IMAGE_TAG=latest

# ---- 数据库（自动生成密码，请勿修改）----
POSTGRES_PASSWORD=${pg_password}

# ---- Coder 管理员账号（首次启动时自动创建）----
CODER_ADMIN_EMAIL=${admin_email}
CODER_ADMIN_USERNAME=${admin_username}
CODER_ADMIN_PASSWORD=${admin_password}

# ---- Claude Code API ----
# 方案A: 官方 Anthropic API -> 填写 ANTHROPIC_API_KEY，留空 ANTHROPIC_BASE_URL
# 方案B: 内网直接代理（实现 Anthropic /v1/messages 协议）
# 方案C: LiteLLM 网关 -> ANTHROPIC_BASE_URL=https://${server_host}:${gateway_port}/llm，ANTHROPIC_API_KEY=sk-devenv
# 方案D: 留空，用户在 workspace 终端执行 claude 手动登录
ANTHROPIC_API_KEY=${anthropic_key:-}
ANTHROPIC_BASE_URL=${anthropic_url:-}

# ---- LiteLLM AI 网关（可选，--llm 模式启用）----
# 启用: bash manage.sh up --llm
# 前置: cp configs/litellm_config.yaml.example configs/litellm_config.yaml 并填写内网 API
LITELLM_MASTER_KEY=sk-devenv
INTERNAL_API_BASE=http://10.0.0.1:8000
INTERNAL_API_KEY=your-internal-api-key

# ---- 内部端口（通常不需要修改）----
CODER_INTERNAL_PORT=7080
EOF

    echo -e "${GREEN}✓ 配置文件已创建: $ENV_FILE${NC}"
    echo -e "${YELLOW}请检查并按需修改 $ENV_FILE${NC}"

    read -p "是否同时创建 LiteLLM 配置文件? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local llm_example="$CONFIGS_DIR/litellm_config.yaml.example"
        local llm_config="$CONFIGS_DIR/litellm_config.yaml"
        if [ -f "$llm_example" ] && [ ! -f "$llm_config" ]; then
            cp "$llm_example" "$llm_config"
            echo -e "${GREEN}✓ LiteLLM 配置已创建: $llm_config${NC}"
            echo -e "${YELLOW}请编辑该文件填写内网 API 地址${NC}"
        fi
    fi
}

# ============================================================
# ssl: 生成自签名 SSL 证书
# ============================================================
gen_ssl() {
    local server_host="${1:-}"

    echo -e "${YELLOW}生成自签名 SSL 证书（含 SAN）...${NC}"

    SSL_DIR="$CONFIGS_DIR/ssl"
    mkdir -p "$SSL_DIR"

    local alt_names
    alt_names="DNS.1 = localhost
DNS.2 = coder.local
IP.1  = 127.0.0.1"

    if [ -n "$server_host" ]; then
        if [[ "$server_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            alt_names="${alt_names}
IP.2  = ${server_host}"
        else
            alt_names="${alt_names}
DNS.3 = ${server_host}"
        fi
        echo -e "${BLUE}  SAN 包含服务器地址: $server_host${NC}"
    fi

    cat > "$SSL_DIR/openssl.cnf" <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = CN
ST = Beijing
L  = Beijing
O  = Coder Platform
CN = ${server_host:-localhost}

[v3_req]
subjectAltName      = @alt_names
keyUsage            = critical, digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth
basicConstraints    = CA:FALSE

[alt_names]
${alt_names}
EOF

    openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
        -keyout "$SSL_DIR/server.key" \
        -out    "$SSL_DIR/server.crt" \
        -config "$SSL_DIR/openssl.cnf" 2>/dev/null
    rm "$SSL_DIR/openssl.cnf"

    echo -e "${GREEN}✓ SSL 证书已生成: $SSL_DIR/${NC}"
    echo -e "${YELLOW}  提示: 运行 'manage.sh build' 将证书嵌入 workspace 镜像（确保 workspace 容器信任此证书）${NC}"
    if [ -n "$server_host" ]; then
        echo -e "${YELLOW}  访问地址: https://${server_host}:${GATEWAY_PORT:-8443}/${NC}"
    fi
}

# ============================================================
# pull: 拉取平台镜像（联网操作）
# ============================================================
pull_images() {
    echo -e "${YELLOW}拉取平台基础镜像...${NC}"

    source "$ENV_FILE" 2>/dev/null || true

    docker pull "${CODER_IMAGE:-ghcr.io/coder/coder}:${CODER_VERSION:-latest}"
    docker pull "postgres:${POSTGRES_VERSION:-16}-alpine"
    docker pull "nginx:alpine"

    if [ "${USE_LLM:-false}" = "true" ]; then
        docker pull "ghcr.io/berriai/litellm:main-latest"
    fi

    echo -e "${GREEN}✓ 基础镜像拉取完成${NC}"
    echo -e "${YELLOW}  提示: workspace 镜像需要单独构建（bash manage.sh build）${NC}"
}

# ============================================================
# build: 构建 workspace 镜像
# ============================================================
build_images() {
    echo -e "${YELLOW}构建 workspace 镜像...${NC}"

    source "$ENV_FILE" 2>/dev/null || true

    # 确保 SSL 证书存在（将嵌入到镜像中）
    if [ ! -f "$CONFIGS_DIR/ssl/server.crt" ]; then
        echo -e "${YELLOW}SSL 证书不存在，自动生成（localhost）...${NC}"
        gen_ssl "localhost"
        echo -e "${YELLOW}提示: 生产部署请先运行 'manage.sh ssl <服务器IP>' 再运行 build${NC}"
    fi

    echo -e "${BLUE}构建 ${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}...${NC}"
    echo -e "${BLUE}注意: 完整嵌入式工具链约需 20-40 分钟，首次构建请耐心等待${NC}"

    docker build \
        -f "$DOCKER_DIR/Dockerfile.workspace" \
        -t "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}" \
        "$PROJECT_ROOT"

    echo -e "${GREEN}✓ workspace 镜像构建完成${NC}"
}

# ============================================================
# save: 保存镜像为 tar 文件（离线打包）
# ============================================================
save_images() {
    echo -e "${YELLOW}保存镜像到 images/ 目录...${NC}"

    source "$ENV_FILE" 2>/dev/null || true

    mkdir -p "$PROJECT_ROOT/images"
    cd "$PROJECT_ROOT/images"

    local images=(
        "${CODER_IMAGE:-ghcr.io/coder/coder}:${CODER_VERSION:-latest}"
        "postgres:${POSTGRES_VERSION:-16}-alpine"
        "nginx:alpine"
        "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
    )
    if [ "${USE_LLM:-false}" = "true" ]; then
        images+=("ghcr.io/berriai/litellm:main-latest")
    fi

    for img in "${images[@]}"; do
        local filename
        filename=$(echo "$img" | tr '/:' '_').tar
        echo -e "${BLUE}  保存 $img → $filename（无进度条，请耐心等待）...${NC}"
        docker save "$img" > "$filename"
        local size_mb
        size_mb=$(( $(stat -c%s "$filename" 2>/dev/null || stat -f%z "$filename") / 1048576 ))
        echo -e "${GREEN}  ✓ 已保存 ${size_mb} MB${NC}"
    done

    echo -e "${GREEN}✓ 所有镜像已保存至 $PROJECT_ROOT/images/${NC}"
}

# ============================================================
# load: 从 tar 文件加载镜像（离线部署）
# ============================================================
load_images() {
    echo -e "${YELLOW}从 images/ 目录加载镜像...${NC}"

    if [ ! -d "$PROJECT_ROOT/images" ] || [ -z "$(ls "$PROJECT_ROOT/images"/*.tar 2>/dev/null)" ]; then
        echo -e "${RED}错误: images/ 目录不存在或没有 .tar 文件${NC}"
        echo -e "${YELLOW}请先在联网环境运行 'manage.sh save' 或 'scripts/prepare-offline.sh'${NC}"
        exit 1
    fi

    cd "$PROJECT_ROOT/images"
    for tarfile in *.tar; do
        if [ -f "$tarfile" ]; then
            size_mb=$(( $(stat -c%s "$tarfile" 2>/dev/null || stat -f%z "$tarfile") / 1048576 ))
            echo -e "${BLUE}  加载 $tarfile (${size_mb} MB)...${NC}"
            docker load < "$tarfile"
        fi
    done

    echo -e "${GREEN}✓ 镜像加载完成${NC}"
}

# ============================================================
# up: 启动平台
# ============================================================
start_services() {
    echo -e "${YELLOW}启动 Coder 平台...${NC}"

    cd "$DOCKER_DIR"

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}错误: .env 文件不存在${NC}"
        echo -e "${YELLOW}请先运行: $0 init${NC}"
        exit 1
    fi
    source "$ENV_FILE"

    # 自动生成 SSL 证书（若不存在）
    if [ ! -f "$CONFIGS_DIR/ssl/server.crt" ]; then
        echo -e "${YELLOW}SSL 证书不存在，自动生成...${NC}"
        gen_ssl "${SERVER_HOST:-localhost}"
        echo -e "${YELLOW}提示: 证书已为 ${SERVER_HOST:-localhost} 生成，workspace 镜像需包含此证书（运行 build 更新）${NC}"
    fi

    # 检查 workspace 镜像是否存在
    if ! docker image inspect "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}" &>/dev/null; then
        echo -e "${YELLOW}workspace 镜像不存在，自动构建...${NC}"
        build_images
    fi

    # 检查 Terraform provider 离线包
    if [ ! -d "$CONFIGS_DIR/terraform-providers/registry.terraform.io" ]; then
        echo -e "${YELLOW}警告: Terraform provider 离线包不存在（$CONFIGS_DIR/terraform-providers/）${NC}"
        echo -e "${YELLOW}  联网环境下运行: bash scripts/prepare-offline.sh 下载 provider${NC}"
        echo -e "${YELLOW}  或确保 Coder 容器能访问 registry.terraform.io（联网环境下会自动下载）${NC}"
    fi

    mkdir -p "$PROJECT_ROOT/logs/nginx"

    local compose_args=""
    [ "${USE_LLM:-false}" = "true" ] && compose_args="--profile llm"

    $DOCKER_COMPOSE $compose_args up -d

    echo ""
    echo -e "${GREEN}✓ 平台已启动${NC}"

    # 首次运行：自动配置 Coder（创建管理员 + 推送模板）
    if [ ! -f "$SETUP_DONE_FILE" ]; then
        echo ""
        echo -e "${YELLOW}检测到首次启动，开始初始化 Coder 配置...${NC}"
        sleep 5  # 给 Coder 一点启动时间
        bash "$SCRIPT_DIR/setup-coder.sh"
    else
        echo ""
        show_access_info
    fi
}

show_access_info() {
    source "$ENV_FILE" 2>/dev/null || true
    local host="${SERVER_HOST:-localhost}"
    local port="${GATEWAY_PORT:-8443}"
    echo -e "访问地址:"
    echo -e "  ${BLUE}https://${host}:${port}/${NC}    管理后台"
    echo -e "  ${BLUE}https://${host}:${port}/@<用户名>/<workspace>.main/apps/code-server${NC}"
    if [ "${USE_LLM:-false}" = "true" ]; then
        echo -e "  ${BLUE}https://${host}:${port}/llm/${NC}  LiteLLM AI 网关"
    fi
    echo ""
    echo -e "管理员账号: ${BLUE}${CODER_ADMIN_EMAIL:-admin}${NC}"
}

# ============================================================
# down: 停止平台
# ============================================================
stop_services() {
    echo -e "${YELLOW}停止 Coder 平台...${NC}"
    cd "$DOCKER_DIR"
    local compose_args=""
    [ "${USE_LLM:-false}" = "true" ] && compose_args="--profile llm"
    $DOCKER_COMPOSE $compose_args down
    echo -e "${GREEN}✓ 平台已停止${NC}"
}

# ============================================================
# status: 服务状态
# ============================================================
show_status() {
    cd "$DOCKER_DIR"
    $DOCKER_COMPOSE ps
}

# ============================================================
# logs: 查看日志
# ============================================================
show_logs() {
    cd "$DOCKER_DIR"
    if [ -z "${1:-}" ]; then
        $DOCKER_COMPOSE logs -f --tail=100
    else
        $DOCKER_COMPOSE logs -f --tail=100 "$1"
    fi
}

# ============================================================
# shell: 进入容器
# ============================================================
enter_shell() {
    local service="${1:-}"
    if [ -z "$service" ]; then
        echo -e "${RED}错误: 请指定服务名${NC}"
        echo "可用服务: gateway, coder, postgres, llm-gateway"
        exit 1
    fi
    cd "$DOCKER_DIR"
    $DOCKER_COMPOSE exec "$service" /bin/bash
}

# ============================================================
# setup-coder: 手动触发 Coder 初始化
# ============================================================
run_setup_coder() {
    echo -e "${YELLOW}手动运行 Coder 初始化...${NC}"
    # 移除标记文件，强制重新执行
    rm -f "$SETUP_DONE_FILE"
    bash "$SCRIPT_DIR/setup-coder.sh"
}

# ============================================================
# test-api: 测试 LLM API 连接
# ============================================================
test_api() {
    echo -e "${YELLOW}测试 LLM API 连接...${NC}"

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}错误: 配置文件不存在，请先运行 init${NC}"
        exit 1
    fi
    source "$ENV_FILE"

    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo -e "${RED}错误: ANTHROPIC_API_KEY 未配置${NC}"
        exit 1
    fi

    local base_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
    echo -e "${BLUE}API URL: $base_url${NC}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 \
        -X POST "$base_url/v1/messages" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        echo -e "${GREEN}✓ API 连接成功${NC}"
    elif [ "$http_code" = "401" ]; then
        echo -e "${RED}✗ API Key 无效（401）${NC}"
    elif [ "$http_code" = "000" ]; then
        echo -e "${RED}✗ 无法连接到 $base_url${NC}"
    else
        echo -e "${YELLOW}? API 返回状态码: $http_code${NC}"
    fi
}

# ============================================================
# clean: 清理构建缓存
# ============================================================
clean() {
    echo -e "${YELLOW}清理 Docker 构建缓存...${NC}"
    docker system prune -f
    echo -e "${GREEN}✓ 清理完成${NC}"
}

# ============================================================
# main
# ============================================================
main() {
    check_deps
    init_dirs

    case "${1:-}" in
        init)
            init_config
            ;;
        ssl)
            gen_ssl "${2:-}"
            ;;
        pull)
            pull_images
            ;;
        build)
            if [ ! -f "$ENV_FILE" ]; then
                echo -e "${YELLOW}提示: 未找到 .env，使用默认镜像名构建${NC}"
            fi
            build_images
            ;;
        save)
            [ -f "$ENV_FILE" ] || { echo -e "${RED}请先运行 init${NC}"; exit 1; }
            save_images
            ;;
        load)
            load_images
            ;;
        up|start)
            start_services
            ;;
        down|stop)
            stop_services
            ;;
        status|ps)
            show_status
            ;;
        logs)
            show_logs "${2:-}"
            ;;
        shell)
            enter_shell "${2:-}"
            ;;
        setup-coder)
            [ -f "$ENV_FILE" ] || { echo -e "${RED}请先运行 init${NC}"; exit 1; }
            run_setup_coder
            ;;
        test-api)
            test_api
            ;;
        clean)
            clean
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
