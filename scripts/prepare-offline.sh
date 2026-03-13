#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIGS_DIR="$PROJECT_ROOT/configs"
DOCKER_DIR="$PROJECT_ROOT/docker"
IMAGES_DIR="$PROJECT_ROOT/images"
ENV_FILE="$DOCKER_DIR/.env"

source "$SCRIPT_DIR/lib/offline-common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INCLUDE_LLM=false
SKIP_IMAGES=false
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --llm) INCLUDE_LLM=true ;;
        --skip-images) SKIP_IMAGES=true ;;
        --skip-build) SKIP_BUILD=true ;;
    esac
done

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

load_config() {
    if [ -f "$ENV_FILE" ]; then
        ensure_env_defaults "$ENV_FILE" "$CONFIGS_DIR"
    fi
    load_effective_config "$CONFIGS_DIR" "$ENV_FILE"
}

download_terraform_providers() {
    info '=== Step 1: Downloading Terraform providers ==='
    load_config

    download_provider() {
        local namespace="$1"
        local provider_type="$2"
        local version="$3"
        local os="linux"
        local arch="amd64"
        local destination_dir="$CONFIGS_DIR/terraform-providers/registry.terraform.io/${namespace}/${provider_type}/${version}/${os}_${arch}"
        local zip_name="terraform-provider-${provider_type}_${version}_${os}_${arch}.zip"
        local zip_path="$destination_dir/$zip_name"

        mkdir -p "$destination_dir"
        if [ -f "$zip_path" ]; then
            ok "Already downloaded: $zip_name"
            return 0
        fi

        info "Downloading $zip_name"
        local download_url
        download_url="$(curl -fsSL "https://registry.terraform.io/v1/providers/${namespace}/${provider_type}/${version}/download/${os}/${arch}" | python3 -c "import json,sys; print(json.load(sys.stdin)['download_url'])")"
        curl -fL "$download_url" -o "$zip_path"
        ok "Saved $zip_name"
    }

    download_provider coder coder "$TF_PROVIDER_CODER_VERSION"
    download_provider kreuzwerker docker "$TF_PROVIDER_DOCKER_VERSION"
}

save_runtime_images() {
    info '=== Step 2: Pulling and saving runtime images ==='
    load_config
    mkdir -p "$IMAGES_DIR"

    local images=(
        "$CODER_IMAGE_REF"
        "$POSTGRES_IMAGE_REF"
        "$NGINX_IMAGE_REF"
    )
    if [ "$INCLUDE_LLM" = true ]; then
        images+=("$LITELLM_IMAGE_REF")
    fi

    local image filename filepath
    for image in "${images[@]}"; do
        info "Pulling $image"
        docker pull "$image"
        filename="$(printf '%s' "$image" | tr '/:@' '_').tar"
        filepath="$IMAGES_DIR/$filename"
        info "Saving $image -> $filename"
        docker save -o "$filepath" "$image"
        ok "Saved $filename"
    done
}

build_workspace_image() {
    info '=== Step 3: Building and saving workspace image ==='
    load_config
    mkdir -p "$IMAGES_DIR" "$CONFIGS_DIR/ssl"

    local server_host="${SERVER_HOST:-localhost}"
    if [ ! -f "$CONFIGS_DIR/ssl/ca.crt" ] || [ ! -f "$CONFIGS_DIR/ssl/server.crt" ]; then
        warn 'Missing CA or leaf certificate. Generating them now.'
        issue_leaf_certificate "$CONFIGS_DIR/ssl" "$server_host"
    fi

    info "Pulling build base image $CODE_SERVER_BASE_IMAGE_REF"
    docker pull "$CODE_SERVER_BASE_IMAGE_REF"

    info "Building ${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
    docker build \
        -f "$DOCKER_DIR/Dockerfile.workspace" \
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}" \
        -t "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}" \
        "$PROJECT_ROOT"

    local output_file="$IMAGES_DIR/${WORKSPACE_IMAGE:-workspace-embedded}_${WORKSPACE_IMAGE_TAG:-latest}.tar"
    info "Saving ${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest} -> $(basename "$output_file")"
    docker save -o "$output_file" "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
    ok "Saved $(basename "$output_file")"
}

echo -e "${BLUE}=== Coder Offline Resource Preparation ===${NC}"
echo

download_terraform_providers
echo

if [ "$SKIP_IMAGES" = false ]; then
    save_runtime_images
    echo
fi

if [ "$SKIP_BUILD" = false ]; then
    build_workspace_image
    echo
fi

echo -e "${GREEN}Offline preparation complete${NC}"
echo -e "Transfer these items to the offline server:"
echo -e "  ${BLUE}entire project directory${NC}"
echo -e "  ${BLUE}images/${NC}"
echo -e "  ${BLUE}configs/ssl/${NC}  keep ca.crt and ca.key so the target only reissues a leaf cert"
echo -e "  ${BLUE}configs/terraform-providers/${NC}"
echo
echo -e "Offline deployment path:"
echo -e "  ${BLUE}bash scripts/manage.sh load${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh init${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh ssl <TARGET_IP_OR_HOST>${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh up${NC}"
echo
echo -e "${YELLOW}If the CA changes on the offline side, rebuild the workspace image once. Leaf-only rotation does not require rebuild.${NC}"
