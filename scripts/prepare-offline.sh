#!/bin/bash
# ============================================================
# 离线准备脚本（在联网环境执行）
#
# 功能：
#   1. 拉取并保存 Docker 镜像到 images/ 目录（tar 格式）
#   2. 构建 workspace 镜像并保存
#   3. 下载 Terraform provider zip 到 configs/terraform-providers/
#   4. 检查 VSIX 扩展文件
#
# 执行后，将以下内容传输到内网服务器：
#   images/              → Docker 镜像包
#   configs/terraform-providers/  → Terraform provider 包
#   configs/vsix/        → VS Code 扩展包（如有）
#
# 内网服务器执行：
#   bash scripts/manage.sh load
#   bash scripts/manage.sh up
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGES_DIR="$PROJECT_ROOT/images"
PROVIDERS_DIR="$PROJECT_ROOT/configs/terraform-providers"
VSIX_DIR="$PROJECT_ROOT/configs/vsix"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# 版本配置（可通过环境变量覆盖）
# ============================================================
CODER_IMAGE="${CODER_IMAGE:-ghcr.io/coder/coder}"
CODER_VERSION="${CODER_VERSION:-latest}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
LITELLM_VERSION="${LITELLM_VERSION:-main-latest}"
WORKSPACE_IMAGE="${WORKSPACE_IMAGE:-workspace-embedded}"
WORKSPACE_IMAGE_TAG="${WORKSPACE_IMAGE_TAG:-latest}"

# Terraform provider 版本（需与 workspace-template/main.tf 中声明的版本一致）
TF_PROVIDER_CODER_VERSION="${TF_PROVIDER_CODER_VERSION:-2.1.3}"
TF_PROVIDER_DOCKER_VERSION="${TF_PROVIDER_DOCKER_VERSION:-3.0.2}"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE} Coder 生产环境 - 离线资源准备${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ============================================================
# Phase 1: 生成 SSL 证书（如未生成）
# ============================================================
echo -e "${YELLOW}=== Phase 1: SSL 证书检查 ===${NC}"
if [ ! -f "$PROJECT_ROOT/configs/ssl/server.crt" ]; then
    echo -e "${YELLOW}SSL 证书不存在，先运行 manage.sh ssl 再继续${NC}"
    echo -e "${BLUE}  用法: bash scripts/manage.sh ssl <服务器IP或域名>${NC}"
    echo -e "${YELLOW}继续时证书会被嵌入 workspace 镜像，确保 workspace 容器能验证 Coder 服务器的 HTTPS 证书${NC}"
    read -p "是否先生成证书? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        read -p "请输入服务器 IP 或域名: " server_host
        bash "$SCRIPT_DIR/manage.sh" ssl "${server_host:-localhost}"
    fi
fi

if [ -f "$PROJECT_ROOT/configs/ssl/server.crt" ]; then
    echo -e "${GREEN}✓ SSL 证书就绪${NC}"
else
    echo -e "${YELLOW}⚠ 跳过 SSL 证书（workspace 容器将无法验证自签名证书）${NC}"
fi

# ============================================================
# Phase 2: 拉取平台 Docker 镜像
# ============================================================
echo ""
echo -e "${YELLOW}=== Phase 2: 拉取平台 Docker 镜像 ===${NC}"

pull_image() {
    local image="$1"
    echo -e "${BLUE}  拉取: $image${NC}"
    docker pull "$image"
}

pull_image "${CODER_IMAGE}:${CODER_VERSION}"
pull_image "postgres:${POSTGRES_VERSION}-alpine"
pull_image "nginx:alpine"

if [ "${INCLUDE_LLM:-false}" = "true" ]; then
    pull_image "ghcr.io/berriai/litellm:${LITELLM_VERSION}"
    echo -e "${GREEN}✓ LiteLLM 镜像已拉取${NC}"
fi

echo -e "${GREEN}✓ 平台镜像拉取完成${NC}"

# ============================================================
# Phase 3: 构建 workspace 镜像
# ============================================================
echo ""
echo -e "${YELLOW}=== Phase 3: 构建 workspace 镜像 ===${NC}"
echo -e "${BLUE}  镜像: ${WORKSPACE_IMAGE}:${WORKSPACE_IMAGE_TAG}${NC}"
echo -e "${BLUE}  注意: 首次构建包含完整嵌入式工具链，约需 20-40 分钟，最终镜像约 5GB${NC}"

docker build \
    -f "$PROJECT_ROOT/docker/Dockerfile.workspace" \
    -t "${WORKSPACE_IMAGE}:${WORKSPACE_IMAGE_TAG}" \
    "$PROJECT_ROOT"

echo -e "${GREEN}✓ workspace 镜像构建完成${NC}"

# ============================================================
# Phase 4: 保存 Docker 镜像为 tar 文件
# ============================================================
echo ""
echo -e "${YELLOW}=== Phase 4: 保存 Docker 镜像 ===${NC}"
mkdir -p "$IMAGES_DIR"

save_image() {
    local image="$1"
    local filename
    filename=$(echo "$image" | tr '/:' '_').tar
    local filepath="$IMAGES_DIR/$filename"
    echo -e "${BLUE}  保存 $image → $filename（无进度条，大镜像请耐心等待）...${NC}"
    docker save "$image" > "$filepath"
    local size_mb
    size_mb=$(( $(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath") / 1048576 ))
    echo -e "${GREEN}  ✓ 已保存 ${size_mb} MB${NC}"
}

save_image "${CODER_IMAGE}:${CODER_VERSION}"
save_image "postgres:${POSTGRES_VERSION}-alpine"
save_image "nginx:alpine"
save_image "${WORKSPACE_IMAGE}:${WORKSPACE_IMAGE_TAG}"

if [ "${INCLUDE_LLM:-false}" = "true" ]; then
    save_image "ghcr.io/berriai/litellm:${LITELLM_VERSION}"
fi

echo -e "${GREEN}✓ 所有镜像已保存至 $IMAGES_DIR/${NC}"

# ============================================================
# Phase 5: 下载 Terraform provider zip 包
# ============================================================
echo ""
echo -e "${YELLOW}=== Phase 5: 下载 Terraform provider ===${NC}"

download_provider() {
    local namespace="$1"
    local provider_type="$2"
    local version="$3"
    local os_arch="${4:-linux_amd64}"

    local dest_dir="$PROVIDERS_DIR/registry.terraform.io/${namespace}/${provider_type}/${version}/${os_arch}"
    local zip_name="terraform-provider-${provider_type}_${version}_${os_arch}.zip"
    local dest_file="$dest_dir/$zip_name"

    if [ -f "$dest_file" ]; then
        echo -e "${YELLOW}  [skip] $zip_name 已存在${NC}"
        return 0
    fi

    mkdir -p "$dest_dir"

    echo -e "${BLUE}  获取 ${namespace}/${provider_type} v${version} 下载地址...${NC}"

    # 从 Terraform registry API 获取下载 URL
    # API 路径中 OS/arch 用 / 分隔（linux/amd64 而非 linux_amd64）
    local api_os_arch
    api_os_arch=$(echo "$os_arch" | sed 's/_/\//')
    local download_url
    download_url=$(curl -sf \
        "https://registry.terraform.io/v1/providers/${namespace}/${provider_type}/${version}/download/${api_os_arch}" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)['download_url'])")

    if [ -z "$download_url" ]; then
        echo -e "${RED}  错误: 无法获取 ${namespace}/${provider_type} v${version} 的下载地址${NC}"
        return 1
    fi

    echo -e "${BLUE}  下载: $download_url${NC}"
    curl -fL "$download_url" -o "$dest_file"
    echo -e "${GREEN}  ✓ 已保存: $dest_file${NC}"
}

download_provider "coder" "coder" "$TF_PROVIDER_CODER_VERSION"
download_provider "kreuzwerker" "docker" "$TF_PROVIDER_DOCKER_VERSION"

echo -e "${GREEN}✓ Terraform provider 下载完成${NC}"
echo -e "${YELLOW}  提示: workspace-template/main.tf 中 version 必须与以下版本一致:${NC}"
echo -e "    coder/coder:         ~> ${TF_PROVIDER_CODER_VERSION%.*}"
echo -e "    kreuzwerker/docker:  ~> ${TF_PROVIDER_DOCKER_VERSION%.*}"

# ============================================================
# Phase 6: 检查 VSIX 扩展文件
# ============================================================
echo ""
echo -e "${YELLOW}=== Phase 6: VSIX 扩展检查 ===${NC}"
mkdir -p "$VSIX_DIR"
VSIX_COUNT=$(ls "$VSIX_DIR"/*.vsix 2>/dev/null | wc -l || echo 0)
echo -e "${BLUE}  找到 ${VSIX_COUNT} 个 VSIX 文件${NC}"

if [ "$VSIX_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}  提示: 若需离线安装 anthropic.claude-code 等扩展，请下载 .vsix 放到 configs/vsix/${NC}"
    echo -e "${YELLOW}  参考: configs/vsix/README.md${NC}"
fi

# ============================================================
# 汇总
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} 离线准备完成！${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "传输到内网服务器的文件："
echo -e "  ${BLUE}images/                        ${NC}Docker 镜像包"
echo -e "  ${BLUE}configs/terraform-providers/   ${NC}Terraform provider 包"
if [ "$VSIX_COUNT" -gt 0 ]; then
    echo -e "  ${BLUE}configs/vsix/                  ${NC}VS Code 扩展包"
fi
echo ""
echo -e "内网服务器部署步骤："
echo -e "  ${BLUE}1. 传输整个项目目录到内网服务器${NC}"
echo -e "  ${BLUE}2. bash scripts/manage.sh init${NC}"
echo -e "  ${BLUE}3. bash scripts/manage.sh load${NC}"
echo -e "  ${BLUE}4. bash scripts/manage.sh ssl <服务器IP>${NC}  (若未在此机器上生成)"
echo -e "  ${BLUE}5. bash scripts/manage.sh up${NC}"
