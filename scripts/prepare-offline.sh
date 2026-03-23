#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIGS_DIR="$PROJECT_ROOT/configs"
DOCKER_DIR="$PROJECT_ROOT/docker"
IMAGES_DIR="$PROJECT_ROOT/images"
ENV_FILE="$DOCKER_DIR/.env"
MANIFEST_PATH="$PROJECT_ROOT/offline-manifest.json"

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

image_archive_name() {
    local image_ref="$1"
    printf '%s.tar\n' "$(printf '%s' "$image_ref" | tr '/:@' '_')"
}

workspace_archive_name() {
    load_config
    printf '%s_%s.tar\n' "${WORKSPACE_IMAGE:-workspace-embedded}" "${WORKSPACE_IMAGE_TAG:-latest}"
}

download_vsix_extensions() {
    info '=== Step 0: Downloading VS Code extensions (.vsix) ==='
    local vsix_dir="$CONFIGS_DIR/vsix"
    mkdir -p "$vsix_dir"

    # Extensions unavailable on Open VSX that must be pre-downloaded as .vsix files.
    # The Dockerfile installs any .vsix found in configs/vsix/ as a fallback.

    # cmake-tools: not on Open VSX (Microsoft proprietary), simple direct URL
    local cmake_dest="$vsix_dir/ms-vscode.cmake-tools.vsix"
    if [ -f "$cmake_dest" ]; then
        ok "Already downloaded: ms-vscode.cmake-tools.vsix"
    else
        info "Downloading ms-vscode.cmake-tools"
        local cmake_url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode/vsextensions/cmake-tools/latest/vspackage"
        if curl -fL --connect-timeout 30 --retry 3 -o "$cmake_dest" "$cmake_url" 2>/dev/null; then
            ok "Saved ms-vscode.cmake-tools.vsix"
        else
            warn "Failed to download cmake-tools — continuing without it (not fatal)"
            rm -f "$cmake_dest"
        fi
    fi

    # cpptools linux-x64: platform-specific extension, requires Gallery API to resolve CDN URL
    local cpptools_dest="$vsix_dir/ms-vscode.cpptools-linux-x64.vsix"
    if [ -f "$cpptools_dest" ]; then
        ok "Already downloaded: ms-vscode.cpptools-linux-x64.vsix"
    else
        info "Downloading ms-vscode.cpptools (linux-x64)"
        local cpptools_url
        cpptools_url="$(curl -fsSL --connect-timeout 15 \
            -X POST 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json;api-version=3.0-preview.1' \
            -d '{"filters":[{"criteria":[{"filterType":7,"value":"ms-vscode.cpptools"}]}],"flags":2151}' \
            2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
versions=data['results'][0]['extensions'][0]['versions']
ver=[v for v in versions if v.get('targetPlatform')=='linux-x64'][0]
files=ver['files']
url=[f['source'] for f in files if f['assetType']=='Microsoft.VisualStudio.Services.VSIXPackage'][0]
print(url)
" 2>/dev/null)"
        if [ -n "$cpptools_url" ] && curl -fL --connect-timeout 30 --retry 3 -o "$cpptools_dest" "$cpptools_url" 2>/dev/null; then
            ok "Saved ms-vscode.cpptools-linux-x64.vsix"
        else
            warn "Failed to download cpptools — continuing without it (not fatal)"
            rm -f "$cpptools_dest"
        fi
    fi
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
        local zip_name="terraform-provider-${provider_type}_${version}_${os}_${arch}.zip"

        # --- Network mirror location (zip kept for serving by provider-mirror nginx) ---
        local mirror_dir="$CONFIGS_DIR/provider-mirror/registry.terraform.io/${namespace}/${provider_type}/${version}/${os}_${arch}"
        local mirror_zip="$mirror_dir/$zip_name"

        mkdir -p "$mirror_dir"
        if [ ! -f "$mirror_zip" ]; then
            info "Downloading $zip_name"
            local download_url
            download_url="$(curl -fsSL "https://registry.terraform.io/v1/providers/${namespace}/${provider_type}/${version}/download/${os}/${arch}" | python3 -c "import json,sys; print(json.load(sys.stdin)['download_url'])")"
            curl -fL "$download_url" -o "$mirror_zip"
            ok "Saved (mirror) $mirror_zip"
        else
            ok "Already present (mirror): $zip_name"
        fi

        # --- Filesystem mirror location (extracted binary, kept for backward compat) ---
        local fs_dir="$CONFIGS_DIR/terraform-providers/registry.terraform.io/${namespace}/${provider_type}/${version}/${os}_${arch}"
        local extracted_marker="$fs_dir/.extracted"

        mkdir -p "$fs_dir"
        if [ ! -f "$extracted_marker" ]; then
            info "Extracting $zip_name -> filesystem-mirror (backward compat)"
            unzip -q -o "$mirror_zip" -d "$fs_dir"
            find "$fs_dir" -maxdepth 1 -name 'terraform-provider-*' ! -name '*.zip' -exec chmod +x {} +
            touch "$extracted_marker"
            ok "Extracted to $fs_dir"
        fi
    }

    download_provider coder coder "$TF_PROVIDER_CODER_VERSION"
    download_provider kreuzwerker docker "$TF_PROVIDER_DOCKER_VERSION"

    # Build index.json and <version>.json for the network mirror
    info "Building network mirror indexes..."
    bash "$SCRIPT_DIR/update-provider-mirror.sh" coder/coder
    bash "$SCRIPT_DIR/update-provider-mirror.sh" kreuzwerker/docker
    ok "Network mirror indexes built"
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
        filename="$(image_archive_name "$image")"
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

    local output_file="$IMAGES_DIR/$(workspace_archive_name)"
    info "Saving ${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest} -> $(basename "$output_file")"
    docker save -o "$output_file" "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
    ok "Saved $(basename "$output_file")"
}

write_manifest() {
    load_config
    local ca_sha256=""
    if [ -f "$CONFIGS_DIR/ssl/ca.crt" ]; then
        ca_sha256="$(python3 - "$CONFIGS_DIR/ssl/ca.crt" <<'PY'
import hashlib,sys
with open(sys.argv[1], 'rb') as fh:
    print(hashlib.sha256(fh.read()).hexdigest())
PY
)"
    fi

    local llm_manifest=''
    if [ "$INCLUDE_LLM" = true ]; then
        llm_manifest=",\n    {\"ref\": \"${LITELLM_IMAGE_REF}\", \"archive\": \"images/$(image_archive_name "$LITELLM_IMAGE_REF")\"}"
    fi

    cat > "$MANIFEST_PATH" <<EOF
{
  "generated_at_utc": "$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat())
PY
)",
  "include_llm": ${INCLUDE_LLM,,},
  "terraform_cli_config_mount_default": "../configs/terraform-offline.rc",
  "ca_sha256": "${ca_sha256}",
  "images": [
    {"ref": "${CODER_IMAGE_REF}", "archive": "images/$(image_archive_name "$CODER_IMAGE_REF")"},
    {"ref": "${POSTGRES_IMAGE_REF}", "archive": "images/$(image_archive_name "$POSTGRES_IMAGE_REF")"},
    {"ref": "${NGINX_IMAGE_REF}", "archive": "images/$(image_archive_name "$NGINX_IMAGE_REF")"},
    {"ref": "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}", "archive": "images/$(workspace_archive_name)"}${llm_manifest}
  ],
  "providers": [
    {"source": "registry.terraform.io/coder/coder", "version": "${TF_PROVIDER_CODER_VERSION}", "archive": "configs/provider-mirror/registry.terraform.io/coder/coder/${TF_PROVIDER_CODER_VERSION}/linux_amd64/terraform-provider-coder_${TF_PROVIDER_CODER_VERSION}_linux_amd64.zip"},
    {"source": "registry.terraform.io/kreuzwerker/docker", "version": "${TF_PROVIDER_DOCKER_VERSION}", "archive": "configs/provider-mirror/registry.terraform.io/kreuzwerker/docker/${TF_PROVIDER_DOCKER_VERSION}/linux_amd64/terraform-provider-docker_${TF_PROVIDER_DOCKER_VERSION}_linux_amd64.zip"}
  ]
}
EOF
    ok "Wrote $MANIFEST_PATH"
}

echo -e "${BLUE}=== Coder Offline Resource Preparation ===${NC}"
echo

download_vsix_extensions
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

write_manifest
echo

echo -e "${GREEN}Offline preparation complete${NC}"
echo -e "Recommended next steps:"
echo -e "  ${BLUE}bash scripts/verify-offline.sh${NC}"
echo -e "  ${BLUE}Transfer the whole project directory to the offline server${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh load${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh init${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh ssl <TARGET_IP_OR_HOST>${NC}"
echo -e "  ${BLUE}bash scripts/manage.sh up${NC}"
