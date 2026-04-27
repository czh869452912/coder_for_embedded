#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/docker"
CONFIGS_DIR="$PROJECT_ROOT/configs"
ENV_FILE="$DOCKER_DIR/.env"
SETUP_DONE_FILE="$DOCKER_DIR/.setup-done"
MANIFEST_PATH="$PROJECT_ROOT/offline-manifest.json"
IMAGES_DIR="$PROJECT_ROOT/images"
LOCK_FILE="$CONFIGS_DIR/versions.lock.env"

source "$SCRIPT_DIR/lib/offline-common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

USE_LLM=false
USE_LDAP=false
USE_MINERU=false
USE_DOCTOOLS=false
USE_SKILLHUB=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --llm)       USE_LLM=true       ;;
        --ldap)      USE_LDAP=true      ;;
        --mineru)    USE_MINERU=true     ;;
        --doctools)  USE_DOCTOOLS=true   ;;
        --skillhub)  USE_SKILLHUB=true   ;;
        *) ARGS+=("$arg") ;;
    esac
done
if [ ${#ARGS[@]} -gt 0 ]; then
    set -- "${ARGS[@]}"
else
    set --
fi

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: bash scripts/manage.sh <command> [args] [--llm] [--ldap]

Online preparation commands:
  refresh-versions [--apply]
                        Check upstream image/provider versions; --apply writes lock file
  prepare [--llm] [--skillhub] [--skip-images] [--skip-build]
                        Download VSIX + TF providers, pull/save platform images,
                        build/save workspace image, write offline-manifest.json
  verify [--require-llm]
                        Verify offline bundle completeness (reads offline-manifest.json)
  skillhub-prepare      Pull pypiserver image, download scientific/engineering pip
                        packages (x86_64 manylinux wheels), generate skills.json catalog
  skillhub-refresh      Regenerate skills.json from configs/skillhub/skills/ (run after
                        uploading custom skills via WebDAV)

Platform lifecycle commands:
  init                  Create docker/.env
  ssl [host]            Issue/update TLS leaf certificate
  pull                  Pull pinned runtime and build-base images
  build                 Build the workspace image
  save                  Save deployment images into images/
  load                  Load images from images/*.tar
  up                    Start the platform
  down                  Stop the platform
  status                Show service status
  logs [service]        Follow logs
  shell <service>       Enter a service shell
  setup-coder           Create admin user and push workspace template (first-run bootstrap)
  test-api              Test Anthropic/LiteLLM API access
  test-llm-backend      Test the internal LLM backend base URL
  clean                 Clean Docker build cache

Workspace image version management:
  push-template         Push updated workspace template to running Coder (no admin setup)
  update-workspace [--tag <tag>]
                        Build a new versioned workspace image, save tar, update lock file,
                        and push template (tag defaults to v<YYYYMMDD>)
  load-workspace <tar>  Load a workspace image tar, update lock, push template
                        (for applying updates on an already-deployed offline server)

In-place upgrade (preserve users + workspaces across code/image changes):
  upgrade-backup [--dest <dir>] [--force]
                        Snapshot the running platform: pg_dumpall, every named volume
                        (postgres-data + each coder-*-home), docker/.env, configs/ssl/,
                        versions.lock.env. Default destination: backups/snapshot-<ts>/
  upgrade-restore-config <snapshot-dir> [--force]
                        After 'git checkout <new-ref>', restore docker/.env and
                        configs/ssl/ from a snapshot so the new code reuses the same
                        POSTGRES_PASSWORD and root CA. See docs/upgrade-in-place.md.

Flags:
  --llm      Enable LiteLLM AI gateway (--profile llm)
  --ldap     Enable Dex OIDC + LDAP authentication (--profile ldap)
             Requires DEX_LDAP_* and OIDC_CLIENT_SECRET in docker/.env
  --mineru   Enable MinerU GPU document-to-Markdown service (--profile mineru)
             Requires nvidia-docker2 on host (runtime: nvidia, GPU 0)
  --doctools Enable Pandoc Markdown→Word/PDF conversion service (--profile doctools)
             Uses pandoc --server (port 3030), supports mathml + xelatex
  --skillhub Enable Skill Hub marketplace + PyPI mirror (--profile skillhub)
             Requires: manage.sh skillhub-prepare first (pypiserver image + pip packages)
             Access: https://<SERVER>:<PORT>/skillhub/ (UI), /pypi/ (package index)

Typical online preparation workflow:
  manage.sh init
  manage.sh ssl <offline-server-ip>
  manage.sh refresh-versions [--apply]   # optional: update to latest upstream
  manage.sh prepare [--llm]
  manage.sh verify [--require-llm]
  # transfer entire project directory to offline server

Typical offline deployment workflow:
  manage.sh init
  manage.sh ssl <this-server-ip>
  manage.sh load [--llm] [--ldap]
  manage.sh up [--llm] [--ldap]          # auto-runs setup-coder on first start

Workspace image update workflow (online -> offline):
  manage.sh update-workspace --tag v20240324   # on online machine
  # transfer images/workspace-embedded_v20240324.tar + configs/versions.lock.env
  manage.sh load-workspace images/workspace-embedded_v20240324.tar  # on offline server
  # users restart their workspaces in the Coder UI

Notes:
  Deployment uses pinned image refs from configs/versions.lock.env.
  A new root CA requires one workspace rebuild. Later leaf rotations do not.
  LiteLLM remains a gateway layer to existing internal model infrastructure.
  Set TF_CLI_CONFIG_MOUNT=../configs/terraform.rc to allow connected Terraform fallback.
EOF
}

# ─── Core helpers ─────────────────────────────────────────────────────────────

check_deps() {
    command -v docker >/dev/null 2>&1 || fail "docker not found"
    docker info >/dev/null 2>&1 || fail "Docker daemon is not running"

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
    else
        fail "docker compose is not available"
    fi
}

init_dirs() {
    mkdir -p "$PROJECT_ROOT/images" \
        "$PROJECT_ROOT/logs/nginx" \
        "$CONFIGS_DIR/ssl" \
        "$CONFIGS_DIR/vsix" \
        "$CONFIGS_DIR/terraform-providers" \
        "$CONFIGS_DIR/provider-mirror/registry.terraform.io" \
        "$CONFIGS_DIR/gitea/seeds" \
        "$CONFIGS_DIR/pypi/packages"
}

load_config() {
    if [ -f "$ENV_FILE" ]; then
        ensure_env_defaults "$ENV_FILE" "$CONFIGS_DIR"
    fi
    load_effective_config "$CONFIGS_DIR" "$ENV_FILE"
}

workspace_image_ref() {
    load_config
    echo "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
}

llm_gateway_url() {
    load_config
    # 容器现已加入 coderplatform，直接通过 Docker DNS 访问网关服务更稳定
    echo "http://llm-gateway:4000"
}

terraform_cli_config_mount() {
    load_config
    echo "${TF_CLI_CONFIG_MOUNT:-../configs/terraform-offline.rc}"
}

assert_llm_config() {
    local config_path="$CONFIGS_DIR/litellm_config.yaml"
    [ "$USE_LLM" = true ] || return 0
    [ -f "$config_path" ] || fail "LiteLLM is enabled but configs/litellm_config.yaml is missing"

    load_config
    [ -n "${INTERNAL_API_BASE:-}" ] || fail "INTERNAL_API_BASE is not configured"
    [ -n "${INTERNAL_API_KEY:-}" ] || fail "INTERNAL_API_KEY is not configured"
    if grep -q 'YOUR_INTERNAL_MODEL' "$config_path"; then
        fail "LiteLLM config still contains YOUR_INTERNAL_MODEL placeholders"
    fi
}

# ─── init ─────────────────────────────────────────────────────────────────────

init_config() {
    info "Initializing docker/.env"
    if [ -f "$ENV_FILE" ]; then
        read -r -p "docker/.env already exists. Overwrite? (y/N): " reply
        [[ "$reply" =~ ^[Yy]$ ]] || { ok "Keeping existing docker/.env"; return; }
    fi

    local postgres_password server_host gateway_port admin_email admin_username admin_password anthropic_key anthropic_url
    if command -v openssl >/dev/null 2>&1; then
        postgres_password="$(openssl rand -hex 16)"
    else
        postgres_password="changeme_$(date +%s)"
    fi

    local default_ip="192.168.1.100"
    if command -v ip >/dev/null 2>&1; then
        local found_ip
        found_ip="$(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1 | grep -vE '^127\.|^172\.1[7-9]\.|^172\.2[0-9]\.|^172\.3[0-1]\.' | head -n 1 || true)"
        [ -n "$found_ip" ] && default_ip="$found_ip"
    fi

    warn "IMPORTANT: Do not use localhost if running workspaces in Docker. Provide your LAN IP instead."
    read -r -p "Server IP or hostname [$default_ip]: " server_host
    server_host="${server_host:-$default_ip}"
    read -r -p "Gateway port [8443]: " gateway_port
    gateway_port="${gateway_port:-8443}"
    read -r -p "Coder admin email [admin@company.local]: " admin_email
    admin_email="${admin_email:-admin@company.local}"
    read -r -p "Coder admin username [admin]: " admin_username
    admin_username="${admin_username:-admin}"
    read -r -s -p "Coder admin password (min 8 chars): " admin_password
    echo
    if [ ${#admin_password} -lt 8 ]; then
        admin_password="Coder@$(date +%Y)"
        warn "Password too short. Auto-generated: $admin_password"
    fi
    read -r -p "Anthropic API key (blank to skip): " anthropic_key
    read -r -p "Anthropic base URL (blank to skip): " anthropic_url

    cat > "$ENV_FILE" <<EOF
# Mutable environment for this deployment.

# ---- Network ----
SERVER_HOST=${server_host}
GATEWAY_PORT=${gateway_port}

# ---- Database ----
POSTGRES_PASSWORD=${postgres_password}

# ---- Coder admin ----
CODER_ADMIN_EMAIL=${admin_email}
CODER_ADMIN_USERNAME=${admin_username}
CODER_ADMIN_PASSWORD=${admin_password}

# ---- Claude / Anthropic settings ----
ANTHROPIC_API_KEY=${anthropic_key}
ANTHROPIC_BASE_URL=${anthropic_url}

# ---- LiteLLM gateway ----
LITELLM_MASTER_KEY=sk-devenv
INTERNAL_API_BASE=http://10.0.0.1:8000
INTERNAL_API_KEY=your-internal-api-key

# ---- Terraform provider resolution ----
TF_CLI_CONFIG_MOUNT=../configs/terraform-offline.rc

# ---- Internal ports ----
CODER_INTERNAL_PORT=7080
EOF

    ensure_env_defaults "$ENV_FILE" "$CONFIGS_DIR"
    ok "Created $ENV_FILE"

    read -r -p "Also create configs/litellm_config.yaml? (y/N): " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        local example_path="$CONFIGS_DIR/litellm_config.yaml.example"
        local config_path="$CONFIGS_DIR/litellm_config.yaml"
        if [ -f "$example_path" ] && [ ! -f "$config_path" ]; then
            cp "$example_path" "$config_path"
            ok "Created $config_path"
        elif [ -f "$config_path" ]; then
            warn "LiteLLM config already exists: $config_path"
        fi
    fi
}

# ─── ssl ──────────────────────────────────────────────────────────────────────

gen_ssl() {
    local server_host="${1:-localhost}"
    local ssl_dir="$CONFIGS_DIR/ssl"

    info "Issuing TLS leaf certificate for $server_host"
    issue_leaf_certificate "$ssl_dir" "$server_host"
    ok "Certificates written to $ssl_dir"

    if [ "${ROOT_CA_CREATED:-false}" = true ]; then
        warn "A new root CA was created. Rebuild the workspace image once so containers trust it."
    else
        info "Root CA already existed. Rotating only the leaf certificate does not require rebuilding the workspace image."
    fi
}

# ─── pull ─────────────────────────────────────────────────────────────────────

pull_images() {
    check_deps
    load_config

    local images=(
        "$CODER_IMAGE_REF"
        "$POSTGRES_IMAGE_REF"
        "$NGINX_IMAGE_REF"
        "$CODE_SERVER_BASE_IMAGE_REF"
    )
    if [ "$USE_LLM" = true ]; then
        images+=("$LITELLM_IMAGE_REF")
    fi
    if [ "$USE_LDAP" = true ]; then
        images+=("$DEX_IMAGE_REF")
    fi
    if [ "$USE_MINERU" = true ]; then
        images+=("$MINERU_IMAGE_REF")
    fi
    if [ "$USE_DOCTOOLS" = true ]; then
        images+=("$DOCCONV_IMAGE_REF")
    fi
    if [ "$USE_SKILLHUB" = true ]; then
        images+=("${GITEA_IMAGE_REF:-gitea/gitea:latest}")
        images+=("${PYPISERVER_IMAGE_REF:-pypiserver/pypiserver:latest}")
    fi

    local image
    for image in "${images[@]}"; do
        info "Pulling $image"
        docker pull "$image"
    done

    ok "Base images pulled"
    warn "Run build to produce the workspace image used by the template."
}

# ─── build ────────────────────────────────────────────────────────────────────

build_images() {
    check_deps
    init_dirs
    load_config

    ensure_root_ca "$CONFIGS_DIR/ssl"
    if [ "${ROOT_CA_CREATED:-false}" = true ]; then
        warn "Created a new root CA for workspace trust."
    fi

    info "Building ${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
    docker build \
        -f "$DOCKER_DIR/Dockerfile.workspace" \
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}" \
        -t "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}" \
        "$PROJECT_ROOT"

    ok "Built ${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
}

# ─── save ─────────────────────────────────────────────────────────────────────

save_images() {
    check_deps
    load_config
    mkdir -p "$PROJECT_ROOT/images"

    local images=(
        "$CODER_IMAGE_REF"
        "$POSTGRES_IMAGE_REF"
        "$NGINX_IMAGE_REF"
        "${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}"
    )
    if [ "$USE_LLM" = true ]; then
        images+=("$LITELLM_IMAGE_REF")
    fi
    if [ "$USE_LDAP" = true ]; then
        images+=("$DEX_IMAGE_REF")
    fi
    if [ "$USE_MINERU" = true ]; then
        images+=("$MINERU_IMAGE_REF")
    fi
    if [ "$USE_DOCTOOLS" = true ]; then
        images+=("$DOCCONV_IMAGE_REF")
    fi
    if [ "$USE_SKILLHUB" = true ]; then
        images+=("${GITEA_IMAGE_REF:-gitea/gitea:latest}")
        images+=("${PYPISERVER_IMAGE_REF:-pypiserver/pypiserver:latest}")
    fi

    # If the digest ref is no longer in the local cache (e.g. after pulling a newer tag via
    # refresh-versions without --apply), fall back to name:tag so the save can still succeed.
    local image filename filepath image_to_save ref_key ref fn tag_key tag fallback
    for image in "${images[@]}"; do
        filename="$(printf '%s' "$image" | tr '/:@' '_').tar"
        filepath="$PROJECT_ROOT/images/$filename"

        image_to_save="$image"
        if [[ "$image" == *@sha256:* ]]; then
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                fallback=""
                for ref_key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF CODE_SERVER_BASE_IMAGE_REF DEX_IMAGE_REF MINERU_IMAGE_REF DOCCONV_IMAGE_REF GITEA_IMAGE_REF PYPISERVER_IMAGE_REF; do
                    ref="${!ref_key:-}"
                    [ "$ref" = "$image" ] || continue
                    tag_key="${ref_key/_REF/_TAG}"
                    tag="${!tag_key:-}"
                    [ -n "$tag" ] && fallback="${image%%@sha256:*}:${tag}"
                    break
                done
                if [ -n "$fallback" ]; then
                    warn "Digest ref not in local cache; saving $fallback instead."
                    warn "Run 'refresh-versions --apply' then 'save' again to keep pinned digests in sync."
                    image_to_save="$fallback"
                fi
            fi
        fi

        info "Saving $image_to_save -> $filename"
        docker save -o "$filepath" "$image_to_save"
        local saved_bytes
        saved_bytes="$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)"
        if [ "$saved_bytes" -lt 1048576 ]; then
            fail "Saved file is unexpectedly small (${saved_bytes} bytes). docker save may have failed silently.
If Docker Desktop uses the containerd image store, try pulling with --platform linux/amd64 first, then re-save."
        fi
        ok "Saved $(( saved_bytes / 1048576 )) MB  ($filename)"
    done
}

# ─── load ─────────────────────────────────────────────────────────────────────

load_images() {
    check_deps
    load_config
    [ -d "$PROJECT_ROOT/images" ] || fail "images directory not found"
    shopt -s nullglob
    local tar_files=("$PROJECT_ROOT/images"/*.tar)
    shopt -u nullglob
    [ ${#tar_files[@]} -gt 0 ] || fail "No image tarballs found in images"

    # When an image is saved by digest ref (e.g. ghcr.io/coder/coder@sha256:...), the tar has
    # no RepoTag and docker load reports "Loaded image ID: sha256:..." with no usable name.
    # Retagging to name:tag lets docker compose find the image without hitting the registry.
    local tar_file base load_output image_id
    for tar_file in "${tar_files[@]}"; do
        base="$(basename "$tar_file")"
        info "Loading $base"
        load_output="$(docker load -i "$tar_file" 2>&1)"
        echo "$load_output"

        # If loaded without a repo tag, retag with name:tag so compose can resolve it offline
        image_id="$(echo "$load_output" | awk '/Loaded image ID:/{print $NF}')"
        if [ -n "$image_id" ]; then
            local ref_key ref fn tag_key tag
            for ref_key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF CODE_SERVER_BASE_IMAGE_REF DEX_IMAGE_REF MINERU_IMAGE_REF DOCCONV_IMAGE_REF GITEA_IMAGE_REF PYPISERVER_IMAGE_REF; do
                ref="${!ref_key:-}"
                [[ "$ref" == *@sha256:* ]] || continue
                fn="$(printf '%s' "$ref" | tr '/:@' '_').tar"
                [ "$fn" = "$base" ] || continue
                tag_key="${ref_key/_REF/_TAG}"
                tag="${!tag_key:-}"
                [ -n "$tag" ] || continue
                info "Tagging $image_id -> ${ref%%@sha256:*}:${tag}"
                docker tag "$image_id" "${ref%%@sha256:*}:${tag}"
                break
            done
        fi
    done

    ok "Images loaded"

    fix_provider_permissions
}

fix_provider_permissions() {
    local provider_root="$CONFIGS_DIR/terraform-providers"
    [ -d "$provider_root" ] || return 0

    local fixed_count=0
    while IFS= read -r -d '' bin_path; do
        chmod +x "$bin_path"
        fixed_count=$(( fixed_count + 1 ))
    done < <(find "$provider_root" -type f -name 'terraform-provider-*' ! -name '*.zip' -print0)

    if [ "$fixed_count" -gt 0 ]; then
        ok "Fixed execute permissions on $fixed_count Terraform provider binary/binaries"
    else
        info "Terraform provider binaries already executable (or none found)"
    fi
}

# ─── up ───────────────────────────────────────────────────────────────────────

start_services() {
    check_deps
    init_dirs
    [ -f "$ENV_FILE" ] || fail "docker/.env not found. Run init first."

    load_config
    if [ ! -f "$CONFIGS_DIR/ssl/server.crt" ]; then
        warn "TLS leaf certificate not found. Generating one now."
        gen_ssl "${SERVER_HOST:-localhost}"
    fi

    if [ "$USE_LLM" = true ]; then
        assert_llm_config
    fi

    local workspace_ref
    workspace_ref="$(workspace_image_ref)"
    if ! docker image inspect "$workspace_ref" >/dev/null 2>&1; then
        warn "Workspace image $workspace_ref not found. Building it now."
        build_images
    fi

    local terraform_config_mount terraform_config_host_path offline_terraform_mode
    terraform_config_mount="$(terraform_cli_config_mount)"
    if [[ "$terraform_config_mount" = /* ]]; then
        terraform_config_host_path="$terraform_config_mount"
    else
        terraform_config_host_path="$(cd "$DOCKER_DIR" && python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$terraform_config_mount")"
    fi
    [ -f "$terraform_config_host_path" ] || fail "Terraform CLI config not found: $terraform_config_host_path"

    offline_terraform_mode=false
    if [ "$(basename "$terraform_config_host_path")" = "terraform-offline.rc" ]; then
        offline_terraform_mode=true
    fi

    if ! find "$CONFIGS_DIR/provider-mirror/registry.terraform.io" \
             -name "index.json" -quit 2>/dev/null | grep -q .; then
        if [ "$offline_terraform_mode" = true ]; then
            fail "Offline Terraform mode is active but the provider mirror is empty. Run 'manage.sh prepare' or 'update-provider-mirror.sh' first."
        fi
        warn "Provider mirror is empty. Terraform will attempt direct registry access."
    elif [ "$offline_terraform_mode" = false ]; then
        info "Provider mirror ready. Connected mode: local mirror first, then registry fallback."
    fi

    fix_provider_permissions

    # In offline/loaded mode Docker cannot resolve digest refs against the registry.
    # Override image ref env vars to use name:tag format before invoking compose,
    # so compose resolves against the locally loaded (and retagged) images.
    local ref_key ref tag_key tag
    local -a required_images=()
    for ref_key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF DEX_IMAGE_REF MINERU_IMAGE_REF DOCCONV_IMAGE_REF PYPISERVER_IMAGE_REF; do
        ref="${!ref_key:-}"
        [ -n "$ref" ] || continue
        if [[ "$ref" == *@sha256:* ]]; then
            tag_key="${ref_key/_REF/_TAG}"
            tag="${!tag_key:-}"
            [ -n "$tag" ] || continue
            export "$ref_key"="${ref%%@sha256:*}:${tag}"
            required_images+=("${ref%%@sha256:*}:${tag}")
        else
            required_images+=("$ref")
        fi
    done

    # Pre-flight: verify every required image exists locally so compose never falls back to a pull
    local missing_images=()
    for img in "${required_images[@]}"; do
        [ "$USE_LLM"      = false ] && [[ "$img" == *litellm*     ]] && continue
        [ "$USE_LDAP"     = false ] && [[ "$img" == *dexidp*      ]] && continue
        [ "$USE_MINERU"   = false ] && [[ "$img" == *mineru*      ]] && continue
        [ "$USE_DOCTOOLS" = false ] && [[ "$img" == *pandoc*      ]] && continue
        [ "$USE_SKILLHUB" = false ] && [[ "$img" == *gitea*       ]] && continue
        [ "$USE_SKILLHUB" = false ] && [[ "$img" == *pypiserver*  ]] && continue
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            missing_images+=("$img")
        fi
    done
    if [ ${#missing_images[@]} -gt 0 ]; then
        fail "The following images are not available locally. Run 'load' (with the correct flags) first:$(printf '\n  - %s' "${missing_images[@]}")"
    fi

    cd "$DOCKER_DIR"
    local compose_profiles=()
    [ "$USE_LLM"      = true ] && compose_profiles+=(--profile llm)
    [ "$USE_LDAP"     = true ] && compose_profiles+=(--profile ldap)
    [ "$USE_MINERU"   = true ] && compose_profiles+=(--profile mineru)
    [ "$USE_DOCTOOLS" = true ] && compose_profiles+=(--profile doctools)
    [ "$USE_SKILLHUB" = true ] && compose_profiles+=(--profile skillhub)
    "${COMPOSE_CMD[@]}" "${compose_profiles[@]}" up -d

    ok "Platform started"
    echo

    if [ ! -f "$SETUP_DONE_FILE" ]; then
        warn "First startup detected. Running setup-coder after a short delay."
        sleep 8
        run_setup_coder
    else
        show_access_info
    fi

    # Initialize Gitea on first start (if skillhub enabled)
    if [ "$USE_SKILLHUB" = true ]; then
        local gitea_done_file="$DOCKER_DIR/.gitea-setup-done"
        if [ ! -f "$gitea_done_file" ]; then
            setup_gitea
        fi
    fi
}

show_access_info() {
    load_config
    local host="${SERVER_HOST:-localhost}"
    local port="${GATEWAY_PORT:-8443}"
    echo -e "Access URLs:"
    echo -e "  ${BLUE}https://${host}:${port}/${NC}"
    echo -e "  ${BLUE}https://${host}:${port}/@<username>/<workspace>.main/apps/code-server${NC}"
    if [ "$USE_LLM" = true ]; then
        echo -e "  ${BLUE}https://${host}:${port}/llm/${NC}"
    fi
    if [ "$USE_LDAP" = true ]; then
        echo -e "  ${BLUE}https://${host}:${port}/dex/${NC}  (Dex OIDC provider)"
    fi
    if [ "$USE_MINERU" = true ]; then
        echo -e "  ${BLUE}https://${host}:${port}/mineru/${NC}  (MinerU document → Markdown, Gradio UI)"
    fi
    if [ "$USE_DOCTOOLS" = true ]; then
        echo -e "  ${BLUE}https://${host}:${port}/docconv/${NC}  (Pandoc Markdown → Word/PDF)"
    fi
    if [ "$USE_SKILLHUB" = true ]; then
        echo -e "  ${BLUE}https://${host}:${port}/gitea/${NC}  (Gitea — Claude Code Skill/Command 市场)"
        echo -e "  ${BLUE}https://${host}:${port}/pypi/${NC}   (PyPI Mirror — 离线 Python 包)"
    fi
}

# ─── down ─────────────────────────────────────────────────────────────────────

stop_services() {
    check_deps
    cd "$DOCKER_DIR"
    local compose_profiles=()
    [ "$USE_LLM"      = true ] && compose_profiles+=(--profile llm)
    [ "$USE_LDAP"     = true ] && compose_profiles+=(--profile ldap)
    [ "$USE_MINERU"   = true ] && compose_profiles+=(--profile mineru)
    [ "$USE_DOCTOOLS" = true ] && compose_profiles+=(--profile doctools)
    [ "$USE_SKILLHUB" = true ] && compose_profiles+=(--profile skillhub)
    "${COMPOSE_CMD[@]}" "${compose_profiles[@]}" down
    ok "Platform stopped"
}

show_status() {
    check_deps
    cd "$DOCKER_DIR"
    "${COMPOSE_CMD[@]}" ps
}

show_logs() {
    check_deps
    cd "$DOCKER_DIR"
    if [ -n "${1:-}" ]; then
        "${COMPOSE_CMD[@]}" logs -f --tail=100 "$1"
    else
        "${COMPOSE_CMD[@]}" logs -f --tail=100
    fi
}

enter_shell() {
    local service="${1:-}"
    [ -n "$service" ] || fail "Specify a service name"
    check_deps
    cd "$DOCKER_DIR"
    "${COMPOSE_CMD[@]}" exec "$service" /bin/bash
}

# ─── Coder bootstrap (inlined from setup-coder.sh) ────────────────────────────

_wait_for_dex() {
    local secret="${OIDC_CLIENT_SECRET:-}"
    [ -n "$secret" ] || return 0

    info "Waiting for Dex OIDC provider..."
    local url="https://${SERVER_HOST:-localhost}:${GATEWAY_PORT:-8443}/dex/.well-known/openid-configuration"
    local attempt
    for attempt in $(seq 1 30); do
        if curl -sk "$url" >/dev/null 2>&1; then
            ok "Dex is ready"
            return 0
        fi
        sleep 3
    done
    warn "Dex did not become ready within 90 seconds. Coder OIDC init may fail."
}

_wait_for_coder() {
    load_config
    info "Waiting for Coder service..."
    local url="http://localhost:${CODER_INTERNAL_PORT:-7080}/healthz"
    local attempt
    for attempt in $(seq 1 60); do
        if curl -sf "$url" >/dev/null 2>&1; then
            ok "Coder is ready"
            return 0
        fi
        sleep 3
    done
    fail "Coder did not become ready within 180 seconds"
}

_create_admin_user() {
    load_config
    local coder_url="http://localhost:${CODER_INTERNAL_PORT:-7080}"
    info "Creating admin account ${CODER_ADMIN_EMAIL}"
    curl -sf -X POST \
        "${coder_url}/api/v2/users/first" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"${CODER_ADMIN_EMAIL}\",\"username\":\"${CODER_ADMIN_USERNAME}\",\"password\":\"${CODER_ADMIN_PASSWORD}\",\"trial\":false}" \
        >/dev/null
    ok "Admin account created"
}

_get_session_token() {
    load_config
    local coder_url="http://localhost:${CODER_INTERNAL_PORT:-7080}"
    curl -sf -X POST \
        "${coder_url}/api/v2/users/login" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"${CODER_ADMIN_EMAIL}\",\"password\":\"${CODER_ADMIN_PASSWORD}\"}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])"
}

# Shared template push logic; called by setup-coder, push-template, update-workspace, load-workspace
_do_push_template() {
    local token="$1"
    load_config
    local template_dir="$PROJECT_ROOT/workspace-template"
    local workspace_image="${WORKSPACE_IMAGE:-workspace-embedded}"
    local workspace_tag="${WORKSPACE_IMAGE_TAG:-latest}"
    local anthropic_key="${ANTHROPIC_API_KEY:-}"
    local anthropic_url="${ANTHROPIC_BASE_URL:-}"

    if [ "$USE_LLM" = true ]; then
        if [ -z "$anthropic_key" ]; then
            anthropic_key="${LITELLM_MASTER_KEY:-}"
        fi
        if [ -z "$anthropic_url" ]; then
            anthropic_url="$(llm_gateway_url)"
        fi
    fi

    info "Pushing workspace template (image=${workspace_image}:${workspace_tag})"
    docker exec coder-server sh -c 'rm -rf /tmp/template-push && mkdir -p /tmp/template-push' >/dev/null
    docker cp "$template_dir/." 'coder-server:/tmp/template-push/'

    docker exec coder-server sh -c "CODER_URL=http://localhost:7080 CODER_SESSION_TOKEN=${token} /opt/coder templates push embedded-dev --directory /tmp/template-push --yes --activate --var workspace_image=${workspace_image} --var workspace_image_tag=${workspace_tag} --var anthropic_api_key='${anthropic_key}' --var anthropic_base_url='${anthropic_url}' --var server_host='${SERVER_HOST:-localhost}' --var gateway_port='${GATEWAY_PORT:-8443}' --var skillhub_enabled='${USE_SKILLHUB}' ; rm -rf /tmp/template-push"
    ok "Workspace template pushed"
}

run_setup_coder() {
    [ -f "$ENV_FILE" ] || fail "Run init first."
    load_config
    rm -f "$SETUP_DONE_FILE"

    _wait_for_dex
    _wait_for_coder

    local coder_url="http://localhost:${CODER_INTERNAL_PORT:-7080}"
    local first_user_status
    first_user_status="$(curl -s -o /dev/null -w '%{http_code}' "${coder_url}/api/v2/users/first" || true)"
    if [ "$first_user_status" = "404" ]; then
        _create_admin_user
    else
        info "Admin account already exists"
    fi

    local session_token
    session_token="$(_get_session_token)"
    [ -n "$session_token" ] || fail "Failed to get Coder session token"
    ok "Logged in and obtained session token"

    local template_status
    template_status="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Coder-Session-Token: ${session_token}" \
        "${coder_url}/api/v2/organizations/default/templates/embedded-dev" || true)"
    if [ "$template_status" = "200" ]; then
        info "Template embedded-dev already exists. Pushing a new version to apply current variables."
    fi

    _do_push_template "$session_token"

    date > "$SETUP_DONE_FILE"
    echo
    ok "Coder initialization complete"
    show_access_info
}

# ─── push-template ────────────────────────────────────────────────────────────

cmd_push_template() {
    check_deps
    [ -f "$ENV_FILE" ] || fail "Run init first."
    load_config

    local coder_url="http://localhost:${CODER_INTERNAL_PORT:-7080}"
    curl -sf "${coder_url}/healthz" >/dev/null 2>&1 \
        || fail "Coder is not reachable at ${coder_url}. Is the platform running?"

    local session_token
    session_token="$(_get_session_token)"
    [ -n "$session_token" ] || fail "Failed to get Coder session token. Check admin credentials in docker/.env."
    ok "Obtained session token"

    _do_push_template "$session_token"
}

# ─── update-workspace ─────────────────────────────────────────────────────────

_update_lock_workspace_tag() {
    local new_tag="$1"
    [ -f "$LOCK_FILE" ] || fail "versions.lock.env not found: $LOCK_FILE"
    if grep -q '^WORKSPACE_IMAGE_TAG=' "$LOCK_FILE"; then
        sed -i "s|^WORKSPACE_IMAGE_TAG=.*|WORKSPACE_IMAGE_TAG=${new_tag}|" "$LOCK_FILE"
    else
        echo "WORKSPACE_IMAGE_TAG=${new_tag}" >> "$LOCK_FILE"
    fi
    ok "Updated WORKSPACE_IMAGE_TAG=${new_tag} in $(basename "$LOCK_FILE")"
}

update_workspace() {
    local new_tag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) shift; new_tag="${1:-}" ;;
        esac
        shift
    done

    if [ -z "$new_tag" ]; then
        new_tag="v$(date +%Y%m%d)"
        info "No tag specified, using auto-generated: $new_tag"
    fi

    check_deps
    init_dirs
    [ -f "$ENV_FILE" ] || fail "Run init first."
    load_config

    local image_name="${WORKSPACE_IMAGE:-workspace-embedded}"

    # Step 1: Update lock file with new tag
    _update_lock_workspace_tag "$new_tag"
    # Reload config so build uses new tag
    load_effective_config "$CONFIGS_DIR" "$ENV_FILE"

    # Step 2: Ensure CA and build with new tag
    ensure_root_ca "$CONFIGS_DIR/ssl"
    info "Building ${image_name}:${new_tag}"
    docker build \
        -f "$DOCKER_DIR/Dockerfile.workspace" \
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}" \
        -t "${image_name}:${new_tag}" \
        "$PROJECT_ROOT"
    ok "Built ${image_name}:${new_tag}"

    # Step 3: Save to tar
    mkdir -p "$IMAGES_DIR"
    local tar_file="$IMAGES_DIR/${image_name}_${new_tag}.tar"
    info "Saving ${image_name}:${new_tag} -> $(basename "$tar_file")"
    docker save -o "$tar_file" "${image_name}:${new_tag}"
    local saved_bytes
    saved_bytes="$(stat -c%s "$tar_file" 2>/dev/null || stat -f%z "$tar_file" 2>/dev/null || echo 0)"
    ok "Saved $(( saved_bytes / 1048576 )) MB  ($(basename "$tar_file"))"

    # Step 4: Push template if Coder is running locally
    local coder_url="http://localhost:${CODER_INTERNAL_PORT:-7080}"
    if curl -sf "${coder_url}/healthz" >/dev/null 2>&1; then
        info "Coder is running — pushing updated template"
        local session_token
        session_token="$(_get_session_token)"
        [ -n "$session_token" ] || fail "Failed to get Coder session token"
        _do_push_template "$session_token"
    else
        warn "Coder is not running locally — skipping template push."
        info "To push later: bash scripts/manage.sh push-template"
    fi

    echo
    ok "Workspace image update complete: ${image_name}:${new_tag}"
    info "Transfer $(basename "$tar_file") and configs/versions.lock.env to the offline server."
    info "Then run: bash scripts/manage.sh load-workspace $(basename "$tar_file")"
}

# ─── load-workspace ───────────────────────────────────────────────────────────

load_workspace() {
    local tar_path="${1:-}"
    [ -n "$tar_path" ] || fail "Usage: manage.sh load-workspace <path/to/workspace-image_tag.tar>"
    [ -f "$tar_path" ] || fail "File not found: $tar_path"
    [ -f "$ENV_FILE" ] || fail "Run init first."

    check_deps

    # Parse image name and tag from filename: <image-name>_<tag>.tar
    # Convention: workspace-embedded_v20240324.tar -> image=workspace-embedded, tag=v20240324
    local basename_noext
    basename_noext="$(basename "$tar_path" .tar)"
    local image_name tag
    image_name="${basename_noext%_*}"
    tag="${basename_noext##*_}"
    [ -n "$image_name" ] && [ -n "$tag" ] && [ "$image_name" != "$tag" ] \
        || fail "Cannot parse image name and tag from filename: $(basename "$tar_path"). Expected format: <image-name>_<tag>.tar"

    info "Loading workspace image from $(basename "$tar_path")"
    docker load -i "$tar_path"
    ok "Loaded ${image_name}:${tag}"

    # Update lock file with new tag
    _update_lock_workspace_tag "$tag"

    # Reload config to pick up new WORKSPACE_IMAGE_TAG
    load_config

    # Push updated template to Coder
    local coder_url="http://localhost:${CODER_INTERNAL_PORT:-7080}"
    curl -sf "${coder_url}/healthz" >/dev/null 2>&1 \
        || fail "Coder is not reachable at ${coder_url}. Is the platform running?"

    info "Pushing updated template to Coder"
    local session_token
    session_token="$(_get_session_token)"
    [ -n "$session_token" ] || fail "Failed to get Coder session token"
    _do_push_template "$session_token"

    echo
    ok "Workspace image ${image_name}:${tag} is now active."
    warn "Users must stop and restart their workspaces in the Coder UI to pick up the new image."
}

# ─── upgrade-backup / upgrade-restore-config ──────────────────────────────────
#
# 用于"原地升级"流程：旧部署的代码版本落后于当前仓库，但 Postgres 中的用户/
# workspace 元数据和每个 workspace 的 home volume 必须保留。具体步骤见
# docs/upgrade-in-place.md。
#
#   upgrade-backup [--dest <dir>] [--force]
#       在仍在运行的旧平台上拍快照（pg_dumpall + 所有 named volume + .env + ssl）。
#       不接触运行中的服务；pg_dumpall 是热备份，volume 备份直接读取磁盘。
#
#   upgrade-restore-config <snapshot-dir> [--force]
#       在切到新代码之后、bash scripts/manage.sh up 之前，把快照里的 .env 与
#       configs/ssl 还原回工作目录。这样新部署沿用同一 POSTGRES_PASSWORD 和
#       同一根 CA，否则 coder 连不上老 DB / workspace 拒绝信任内网证书。

_pick_backup_image_ref() {
    # 用一个本地已存在的镜像启动临时容器执行 tar。优先复用 coder-postgres 的镜像（一定在线/离线都可用）。
    local img
    img="$(docker inspect coder-postgres --format '{{.Image}}' 2>/dev/null || true)"
    if [ -n "$img" ]; then
        printf '%s\n' "$img"
        return 0
    fi
    # 退化路径：使用 .env / lock 中固定的 postgres 镜像引用
    load_config
    if [ -n "${POSTGRES_IMAGE_REF:-}" ]; then
        printf '%s\n' "${POSTGRES_IMAGE_REF}"
        return 0
    fi
    printf 'postgres:16-alpine\n'
}

upgrade_backup() {
    local dest="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --dest)  shift; dest="${1:-}" ;;
            --force) force=true ;;
            *) warn "Ignoring unrecognized argument: $1" ;;
        esac
        shift || true
    done

    check_deps
    [ -f "$ENV_FILE" ] || fail "docker/.env not found — nothing to back up"
    load_config

    docker ps --format '{{.Names}}' | grep -q '^coder-postgres$' \
        || fail "coder-postgres is not running. pg_dumpall needs the database online; start the platform with 'manage.sh up' before running upgrade-backup."

    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    [ -n "$dest" ] || dest="$PROJECT_ROOT/backups/snapshot-$timestamp"

    if [ -e "$dest" ]; then
        if [ "$force" = true ]; then
            warn "Overwriting existing snapshot at $dest"
            rm -rf "$dest"
        else
            fail "Snapshot directory already exists: $dest (re-run with --force to overwrite)"
        fi
    fi
    mkdir -p "$dest/volumes" "$dest/ssl"

    info "[1/5] pg_dumpall coder → $dest/coder.sql"
    if ! docker exec -i coder-postgres pg_dumpall -U coder > "$dest/coder.sql"; then
        fail "pg_dumpall failed; check 'docker logs coder-postgres'"
    fi
    local sql_bytes
    sql_bytes="$(stat -c%s "$dest/coder.sql" 2>/dev/null || stat -f%z "$dest/coder.sql" 2>/dev/null || echo 0)"
    [ "$sql_bytes" -gt 1024 ] || fail "coder.sql is suspiciously small (${sql_bytes} bytes); aborting"
    ok "      coder.sql ($(( sql_bytes / 1024 )) KB)"

    local backup_image pg_volume
    backup_image="$(_pick_backup_image_ref)"

    info "[2/5] Tarring postgres-data volume"
    pg_volume="$(docker inspect coder-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
    [ -n "$pg_volume" ] || fail "Could not locate postgres-data volume on coder-postgres"
    docker run --rm \
        -v "$pg_volume":/data:ro \
        -v "$(cd "$dest/volumes" && pwd)":/backup \
        --entrypoint /bin/sh \
        "$backup_image" \
        -c 'cd /data && tar czf /backup/postgres-data.tgz .' \
        || fail "Failed to archive postgres-data volume ($pg_volume)"
    ok "      volumes/postgres-data.tgz (volume: $pg_volume)"

    info "[3/5] Tarring workspace home volumes (coder-*-home)"
    local home_count=0 vol
    while IFS= read -r vol; do
        [ -n "$vol" ] || continue
        info "      - $vol"
        if docker run --rm \
            -v "$vol":/data:ro \
            -v "$(cd "$dest/volumes" && pwd)":/backup \
            --entrypoint /bin/sh \
            "$backup_image" \
            -c "cd /data && tar czf /backup/${vol}.tgz ." 2>/dev/null
        then
            home_count=$(( home_count + 1 ))
        else
            warn "        archive failed for $vol (continuing — re-run after stopping the affected workspace if needed)"
        fi
    done < <(docker volume ls --format '{{.Name}}' | grep -E '^coder-.*-home$' || true)
    ok "      $home_count workspace home volume(s) archived"

    info "[4/5] Copying configuration"
    cp "$ENV_FILE" "$dest/env.bak"
    cp -r "$CONFIGS_DIR/ssl/." "$dest/ssl/"
    [ -f "$LOCK_FILE" ] && cp "$LOCK_FILE" "$dest/versions.lock.env.bak"
    if [ -f "$DOCKER_DIR/.setup-done" ]; then
        cp "$DOCKER_DIR/.setup-done" "$dest/setup-done.bak"
    fi
    ok "      env.bak, ssl/, versions.lock.env.bak"

    info "[5/5] Writing meta.json"
    local git_sha git_branch
    git_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    git_branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    local created_iso
    created_iso="$(python3 - <<'PY' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat())
PY
)"
    cat > "$dest/meta.json" <<EOF
{
  "snapshot_kind": "upgrade-in-place",
  "created_at_utc": "${created_iso}",
  "git_branch": "${git_branch}",
  "git_commit": "${git_sha}",
  "server_host": "${SERVER_HOST:-}",
  "gateway_port": "${GATEWAY_PORT:-}",
  "workspace_image": "${WORKSPACE_IMAGE:-}:${WORKSPACE_IMAGE_TAG:-}",
  "postgres_volume": "${pg_volume}",
  "workspace_home_volumes": ${home_count}
}
EOF
    ok "      meta.json"

    local total
    total="$(du -sh "$dest" 2>/dev/null | awk '{print $1}')"
    echo
    ok "Backup complete: $dest  (total ${total:-unknown})"
    echo
    info "Next steps (see docs/upgrade-in-place.md for the full runbook):"
    echo -e "  1) Move/copy ${BLUE}$dest${NC} to durable storage outside this directory"
    echo -e "  2) ${BLUE}bash scripts/manage.sh down${NC}        # stop the old platform (NEVER pass -v)"
    echo -e "  3) ${BLUE}git fetch && git checkout <new-ref>${NC}"
    echo -e "  4) ${BLUE}bash scripts/manage.sh upgrade-restore-config $dest${NC}"
    echo -e "  5) ${BLUE}bash scripts/manage.sh load${NC}        # plus any --ldap/--skillhub flags you want to enable"
    echo -e "  6) ${BLUE}bash scripts/manage.sh up${NC}          # postgres schema migrates forward, users keep their accounts"
    echo -e "  7) ${BLUE}bash scripts/manage.sh update-workspace --tag v\$(date +%Y%m%d)${NC}   # bake new tools into a tagged image"
}

upgrade_restore_config() {
    local snapshot="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true ;;
            -*)      warn "Ignoring unknown flag: $1" ;;
            *)       [ -z "$snapshot" ] && snapshot="$1" || warn "Extra positional arg ignored: $1" ;;
        esac
        shift || true
    done
    [ -n "$snapshot" ] || fail "Usage: manage.sh upgrade-restore-config <snapshot-dir> [--force]"
    [ -d "$snapshot" ] || fail "Snapshot directory not found: $snapshot"
    [ -f "$snapshot/env.bak" ] || fail "$snapshot/env.bak not found — is this a snapshot from upgrade-backup?"
    [ -d "$snapshot/ssl" ]     || fail "$snapshot/ssl/ not found — incomplete snapshot"

    init_dirs

    # ── docker/.env ────────────────────────────────────────────────────────────
    if [ -f "$ENV_FILE" ]; then
        if [ "$force" != true ]; then
            fail "$ENV_FILE already exists. Pass --force to overwrite (the existing file will be saved as $ENV_FILE.before-restore)."
        fi
        cp "$ENV_FILE" "$ENV_FILE.before-restore"
        warn "Existing docker/.env saved to $ENV_FILE.before-restore"
    fi
    cp "$snapshot/env.bak" "$ENV_FILE"
    ok "Restored docker/.env"

    # 把缺失的新增 lock 默认值（如新版本添加的 *_IMAGE_REF）追加进来
    ensure_env_defaults "$ENV_FILE" "$CONFIGS_DIR"

    # ── configs/ssl ────────────────────────────────────────────────────────────
    if [ -d "$CONFIGS_DIR/ssl" ] && [ -n "$(ls -A "$CONFIGS_DIR/ssl" 2>/dev/null)" ]; then
        local existing_ca="$CONFIGS_DIR/ssl/ca.crt"
        local snap_ca="$snapshot/ssl/ca.crt"
        if [ -f "$existing_ca" ] && [ -f "$snap_ca" ] && ! cmp -s "$existing_ca" "$snap_ca"; then
            if [ "$force" != true ]; then
                fail "configs/ssl/ca.crt differs from snapshot. Pass --force to overwrite. WARNING: workspaces built against the current CA will need to be rebuilt to trust the restored CA."
            fi
            warn "Overwriting different ca.crt; existing tree saved to configs/ssl.before-restore"
        fi
        rm -rf "$CONFIGS_DIR/ssl.before-restore"
        mv "$CONFIGS_DIR/ssl" "$CONFIGS_DIR/ssl.before-restore"
    fi
    mkdir -p "$CONFIGS_DIR/ssl"
    cp -r "$snapshot/ssl/." "$CONFIGS_DIR/ssl/"
    ok "Restored configs/ssl/ (CA + leaf certificate)"

    # ── versions.lock.env (optional) ───────────────────────────────────────────
    # 不强制覆盖 lock 文件——新仓库自带的 lock 通常更新更全；但记录工作区镜像 tag 以便后续 update-workspace。
    if [ -f "$snapshot/versions.lock.env.bak" ] && [ -f "$LOCK_FILE" ]; then
        local snap_ws_tag
        snap_ws_tag="$(grep -E '^WORKSPACE_IMAGE_TAG=' "$snapshot/versions.lock.env.bak" | head -n1 | cut -d= -f2 || true)"
        if [ -n "$snap_ws_tag" ]; then
            info "Snapshot workspace image tag was: ${snap_ws_tag}"
            info "Current versions.lock.env tag:    ${WORKSPACE_IMAGE_TAG:-unset}"
            info "Build a fresh tagged image after upgrade with: manage.sh update-workspace --tag v\$(date +%Y%m%d)"
        fi
    fi

    # ── .setup-done (skip first-run admin creation) ────────────────────────────
    # 保留旧的 .setup-done 标记，让 manage.sh up 跳过首启动逻辑——admin 已经在 DB 里了。
    if [ -f "$snapshot/setup-done.bak" ] && [ ! -f "$DOCKER_DIR/.setup-done" ]; then
        cp "$snapshot/setup-done.bak" "$DOCKER_DIR/.setup-done"
        ok "Restored docker/.setup-done (skips first-run admin creation)"
    fi

    # ── Sanity ─────────────────────────────────────────────────────────────────
    load_config
    [ -n "${POSTGRES_PASSWORD:-}" ] || warn "POSTGRES_PASSWORD is empty in restored env — coder will fail to connect to postgres"
    [ -n "${SERVER_HOST:-}" ]       || warn "SERVER_HOST is empty in restored env"

    if [ -f "$snapshot/meta.json" ]; then
        echo
        info "Snapshot metadata:"
        sed 's/^/      /' "$snapshot/meta.json"
    fi

    echo
    ok "Configuration restored from $snapshot"
    echo
    info "Next steps:"
    echo -e "  1) Sanity-check ${BLUE}docker/.env${NC} — review any new keys appended from versions.lock.env"
    echo -e "  2) ${BLUE}bash scripts/manage.sh load${NC} [--ldap --skillhub …]"
    echo -e "  3) ${BLUE}bash scripts/manage.sh up${NC}        # new coder migrates the DB schema in-place"
    echo -e "  4) Verify a real user can log in, then build a tagged workspace image:"
    echo -e "     ${BLUE}bash scripts/manage.sh update-workspace --tag v\$(date +%Y%m%d)${NC}"
    echo -e "  5) Have users restart their workspaces in the UI to pick up the new image"
}

# ─── prepare (migrated from prepare-offline.sh) ───────────────────────────────

_prepare_download_vsix() {
    info '=== Step 0: Downloading VS Code extensions (.vsix) ==='
    local vsix_dir="$CONFIGS_DIR/vsix"
    mkdir -p "$vsix_dir"

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

_prepare_download_provider() {
    local namespace="$1"
    local provider_type="$2"
    local version="$3"
    local os="linux"
    local arch="amd64"
    local zip_name="terraform-provider-${provider_type}_${version}_${os}_${arch}.zip"

    local mirror_dir="$CONFIGS_DIR/provider-mirror/registry.terraform.io/${namespace}/${provider_type}/${version}/${os}_${arch}"
    local mirror_zip="$mirror_dir/$zip_name"
    mkdir -p "$mirror_dir"

    if [ ! -f "$mirror_zip" ]; then
        info "Downloading $zip_name"
        local download_url
        download_url="$(curl -fsSL "https://registry.terraform.io/v1/providers/${namespace}/${provider_type}/${version}/download/${os}/${arch}" \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['download_url'])")"
        curl -fL "$download_url" -o "$mirror_zip"
        ok "Saved (mirror) $mirror_zip"
    else
        ok "Already present (mirror): $zip_name"
    fi

    local fs_dir="$CONFIGS_DIR/terraform-providers/registry.terraform.io/${namespace}/${provider_type}/${version}/${os}_${arch}"
    local extracted_marker="$fs_dir/.extracted"
    mkdir -p "$fs_dir"
    if [ ! -f "$extracted_marker" ]; then
        info "Extracting $zip_name -> filesystem-mirror"
        unzip -q -o "$mirror_zip" -d "$fs_dir"
        find "$fs_dir" -maxdepth 1 -name 'terraform-provider-*' ! -name '*.zip' -exec chmod +x {} +
        touch "$extracted_marker"
        ok "Extracted to $fs_dir"
    fi
}

_prepare_download_providers() {
    info '=== Step 1: Downloading Terraform providers ==='
    load_config

    _prepare_download_provider coder coder "$TF_PROVIDER_CODER_VERSION"
    _prepare_download_provider kreuzwerker docker "$TF_PROVIDER_DOCKER_VERSION"

    info "Building network mirror indexes..."
    bash "$SCRIPT_DIR/update-provider-mirror.sh" coder/coder
    bash "$SCRIPT_DIR/update-provider-mirror.sh" kreuzwerker/docker
    ok "Network mirror indexes built"
}

_prepare_save_platform_images() {
    info '=== Step 2: Pulling and saving platform images ==='
    load_config
    mkdir -p "$IMAGES_DIR"

    local images=(
        "$CODER_IMAGE_REF"
        "$POSTGRES_IMAGE_REF"
        "$NGINX_IMAGE_REF"
    )
    if [ "$USE_LLM" = true ]; then
        images+=("$LITELLM_IMAGE_REF")
    fi
    if [ "$USE_MINERU" = true ]; then
        images+=("$MINERU_IMAGE_REF")
    fi
    if [ "$USE_DOCTOOLS" = true ]; then
        images+=("$DOCCONV_IMAGE_REF")
    fi
    if [ "$USE_SKILLHUB" = true ]; then
        images+=("${GITEA_IMAGE_REF:-gitea/gitea:latest}")
        images+=("${PYPISERVER_IMAGE_REF:-pypiserver/pypiserver:latest}")
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

_prepare_build_workspace() {
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

    local ws_image="${WORKSPACE_IMAGE:-workspace-embedded}"
    local ws_tag="${WORKSPACE_IMAGE_TAG:-latest}"
    info "Building ${ws_image}:${ws_tag}"
    docker build \
        -f "$DOCKER_DIR/Dockerfile.workspace" \
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}" \
        -t "${ws_image}:${ws_tag}" \
        "$PROJECT_ROOT"

    local tar_file="$IMAGES_DIR/${ws_image}_${ws_tag}.tar"
    info "Saving ${ws_image}:${ws_tag} -> $(basename "$tar_file")"
    docker save -o "$tar_file" "${ws_image}:${ws_tag}"
    ok "Saved $(basename "$tar_file")"
}

_prepare_write_manifest() {
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

    local ws_image="${WORKSPACE_IMAGE:-workspace-embedded}"
    local ws_tag="${WORKSPACE_IMAGE_TAG:-latest}"
    local ws_tar="${ws_image}_${ws_tag}.tar"
    local coder_tar postgres_tar nginx_tar
    coder_tar="$(printf '%s' "$CODER_IMAGE_REF" | tr '/:@' '_').tar"
    postgres_tar="$(printf '%s' "$POSTGRES_IMAGE_REF" | tr '/:@' '_').tar"
    nginx_tar="$(printf '%s' "$NGINX_IMAGE_REF" | tr '/:@' '_').tar"

    local llm_entry=''
    if [ "$USE_LLM" = true ]; then
        local litellm_tar
        litellm_tar="$(printf '%s' "$LITELLM_IMAGE_REF" | tr '/:@' '_').tar"
        llm_entry=",\n    {\"ref\": \"${LITELLM_IMAGE_REF}\", \"archive\": \"images/${litellm_tar}\"}"
    fi
    local mineru_entry=''
    if [ "$USE_MINERU" = true ]; then
        local mineru_tar
        mineru_tar="$(printf '%s' "$MINERU_IMAGE_REF" | tr '/:@' '_').tar"
        mineru_entry=",\n    {\"ref\": \"${MINERU_IMAGE_REF}\", \"archive\": \"images/${mineru_tar}\"}"
    fi
    local docconv_entry=''
    if [ "$USE_DOCTOOLS" = true ]; then
        local docconv_tar
        docconv_tar="$(printf '%s' "$DOCCONV_IMAGE_REF" | tr '/:@' '_').tar"
        docconv_entry=",\n    {\"ref\": \"${DOCCONV_IMAGE_REF}\", \"archive\": \"images/${docconv_tar}\"}"
    fi
    local skillhub_entry=''
    if [ "$USE_SKILLHUB" = true ]; then
        local gitea_ref gitea_tar pypiserver_ref pypiserver_tar
        gitea_ref="${GITEA_IMAGE_REF:-gitea/gitea:latest}"
        gitea_tar="$(printf '%s' "$gitea_ref" | tr '/:@' '_').tar"
        pypiserver_ref="${PYPISERVER_IMAGE_REF:-pypiserver/pypiserver:latest}"
        pypiserver_tar="$(printf '%s' "$pypiserver_ref" | tr '/:@' '_').tar"
        skillhub_entry=",\n    {\"ref\": \"${gitea_ref}\", \"archive\": \"images/${gitea_tar}\"}"
        skillhub_entry+=",\n    {\"ref\": \"${pypiserver_ref}\", \"archive\": \"images/${pypiserver_tar}\"}"
    fi

    cat > "$MANIFEST_PATH" <<EOF
{
  "generated_at_utc": "$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat())
PY
)",
  "include_llm": ${USE_LLM,,},
  "include_mineru": ${USE_MINERU,,},
  "include_doctools": ${USE_DOCTOOLS,,},
  "include_skillhub": ${USE_SKILLHUB,,},
  "terraform_cli_config_mount_default": "../configs/terraform-offline.rc",
  "ca_sha256": "${ca_sha256}",
  "images": [
    {"ref": "${CODER_IMAGE_REF}", "archive": "images/${coder_tar}"},
    {"ref": "${POSTGRES_IMAGE_REF}", "archive": "images/${postgres_tar}"},
    {"ref": "${NGINX_IMAGE_REF}", "archive": "images/${nginx_tar}"},
    {"ref": "${ws_image}:${ws_tag}", "archive": "images/${ws_tar}"}${llm_entry}${mineru_entry}${docconv_entry}${skillhub_entry}
  ],
  "providers": [
    {"source": "registry.terraform.io/coder/coder", "version": "${TF_PROVIDER_CODER_VERSION}", "archive": "configs/provider-mirror/registry.terraform.io/coder/coder/${TF_PROVIDER_CODER_VERSION}/linux_amd64/terraform-provider-coder_${TF_PROVIDER_CODER_VERSION}_linux_amd64.zip"},
    {"source": "registry.terraform.io/kreuzwerker/docker", "version": "${TF_PROVIDER_DOCKER_VERSION}", "archive": "configs/provider-mirror/registry.terraform.io/kreuzwerker/docker/${TF_PROVIDER_DOCKER_VERSION}/linux_amd64/terraform-provider-docker_${TF_PROVIDER_DOCKER_VERSION}_linux_amd64.zip"}
  ]
}
EOF
    ok "Wrote $MANIFEST_PATH"
}

prepare_offline() {
    local skip_images=false skip_build=false
    for arg in "$@"; do
        case "$arg" in
            --skip-images) skip_images=true ;;
            --skip-build)  skip_build=true  ;;
        esac
    done

    check_deps
    init_dirs

    echo -e "${BLUE}=== Coder Offline Resource Preparation ===${NC}"
    echo

    _prepare_download_vsix
    echo
    _prepare_download_providers
    echo

    if [ "$skip_images" = false ]; then
        _prepare_save_platform_images
        echo
    fi

    if [ "$skip_build" = false ]; then
        _prepare_build_workspace
        echo
    fi

    _prepare_write_manifest
    echo

    ok "Offline preparation complete"
    echo
    info "Recommended next steps:"
    echo "  ${BLUE}bash scripts/manage.sh verify [--require-llm]${NC}"
    echo "  ${BLUE}Transfer the whole project directory to the offline server${NC}"
    echo "  ${BLUE}# On the offline server:${NC}"
    echo "  ${BLUE}bash scripts/manage.sh init${NC}"
    echo "  ${BLUE}bash scripts/manage.sh ssl <TARGET_IP_OR_HOST>${NC}"
    echo "  ${BLUE}bash scripts/manage.sh load${NC}"
    echo "  ${BLUE}bash scripts/manage.sh up${NC}"
}

# ─── verify (migrated from verify-offline.sh) ─────────────────────────────────

verify_offline() {
    local require_llm=false
    for arg in "$@"; do
        case "$arg" in
            --require-llm) require_llm=true ;;
        esac
    done

    [ -f "$MANIFEST_PATH" ] || fail "offline-manifest.json is missing. Run 'manage.sh prepare' first."
    command -v python3 >/dev/null 2>&1 || fail "python3 not found"

    python3 - "$PROJECT_ROOT" "$CONFIGS_DIR" "$MANIFEST_PATH" "$require_llm" <<'PY'
import hashlib, json, os, sys
project_root, configs_dir, manifest_path, require_llm = sys.argv[1:5]
require_llm = require_llm.lower() == 'true'

with open(manifest_path, 'r', encoding='utf-8') as fh:
    manifest = json.load(fh)

missing = []
if require_llm and not manifest.get('include_llm'):
    missing.append('Manifest does not include LiteLLM artifacts, but --require-llm was requested.')

ca_cert = os.path.join(configs_dir, 'ssl', 'ca.crt')
ca_key = os.path.join(configs_dir, 'ssl', 'ca.key')
terraform_offline = os.path.join(configs_dir, 'terraform-offline.rc')
versions_lock = os.path.join(configs_dir, 'versions.lock.env')
for path in (ca_cert, ca_key, terraform_offline, versions_lock):
    if not os.path.exists(path):
        missing.append(os.path.relpath(path, project_root))

for image in manifest.get('images', []):
    path = os.path.join(project_root, image['archive'])
    if not os.path.exists(path):
        missing.append(image['archive'])

for provider in manifest.get('providers', []):
    path = os.path.join(project_root, provider['archive'])
    if not os.path.exists(path):
        missing.append(provider['archive'])

if os.path.exists(ca_cert) and manifest.get('ca_sha256'):
    with open(ca_cert, 'rb') as fh:
        current_hash = hashlib.sha256(fh.read()).hexdigest()
    if current_hash.lower() != manifest['ca_sha256'].lower():
        missing.append(f"CA fingerprint mismatch: manifest={manifest['ca_sha256']} current={current_hash}")

if missing:
    print('[FAIL]  Offline bundle verification failed.', file=sys.stderr)
    for item in missing:
        print(f'  - {item}', file=sys.stderr)
    raise SystemExit(1)

print('[ OK ]  Offline bundle verification passed.')
print(f'[INFO]  Manifest: {manifest_path}')
print(f"[INFO]  Images checked: {len(manifest.get('images', []))}")
print(f"[INFO]  Providers checked: {len(manifest.get('providers', []))}")
PY
}

# ─── refresh-versions (migrated from refresh-versions.sh) ─────────────────────

_rv_resolve_digest() {
    local repository="$1"
    local tag="$2"
    local tag_ref="${repository}:${tag}"
    info "Pulling $tag_ref" >&2
    docker pull "$tag_ref" >/dev/null
    docker image inspect "$tag_ref" --format '{{json .RepoDigests}}' | python3 - "$repository" <<'PY'
import json,sys
repo = sys.argv[1]
digests = json.load(sys.stdin)
for digest in digests:
    if digest.startswith(repo + '@'):
        print(digest)
        break
else:
    print(digests[0])
PY
}

_rv_latest_provider_version() {
    local namespace="$1"
    local provider_type="$2"
    local current_version="$3"
    local major="${current_version%%.*}"
    curl -fsSL "https://registry.terraform.io/v1/providers/${namespace}/${provider_type}/versions" | python3 - "$major" <<'PY'
import json,re,sys
major = sys.argv[1]
versions = json.load(sys.stdin)['versions']
matching = sorted(
    [
        v['version']
        for v in versions
        if re.fullmatch(rf"{re.escape(major)}\.\d+(?:\.\d+)*", v['version'])
    ],
    key=lambda s: tuple(int(part) for part in s.split('.')),
    reverse=True,
)
if not matching:
    raise SystemExit('no stable provider version found')
print(matching[0])
PY
}

refresh_versions() {
    local apply=false
    for arg in "$@"; do
        case "$arg" in
            --apply) apply=true ;;
        esac
    done

    command -v docker >/dev/null 2>&1 || fail "docker not found"
    docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
    command -v python3 >/dev/null 2>&1 || fail "python3 not found"
    command -v curl >/dev/null 2>&1 || fail "curl not found"
    [ -f "$LOCK_FILE" ] || fail "versions.lock.env not found: $LOCK_FILE"

    load_key_value_into_env "$LOCK_FILE"

    local OLD_CODER_IMAGE_REF="$CODER_IMAGE_REF"
    local OLD_POSTGRES_IMAGE_REF="$POSTGRES_IMAGE_REF"
    local OLD_NGINX_IMAGE_REF="$NGINX_IMAGE_REF"
    local OLD_LITELLM_IMAGE_REF="$LITELLM_IMAGE_REF"
    local OLD_CODE_SERVER_BASE_IMAGE_REF="$CODE_SERVER_BASE_IMAGE_REF"
    local OLD_TF_PROVIDER_CODER_VERSION="$TF_PROVIDER_CODER_VERSION"
    local OLD_TF_PROVIDER_DOCKER_VERSION="$TF_PROVIDER_DOCKER_VERSION"
    local OLD_MINERU_IMAGE_REF="${MINERU_IMAGE_REF:-}"
    local OLD_DOCCONV_IMAGE_REF="${DOCCONV_IMAGE_REF:-}"
    local OLD_GITEA_IMAGE_REF="${GITEA_IMAGE_REF:-}"
    local OLD_PYPISERVER_IMAGE_REF="${PYPISERVER_IMAGE_REF:-}"

    CODER_IMAGE_REF="$(_rv_resolve_digest "${CODER_IMAGE_REF%%@*}" "$CODER_IMAGE_TAG")"
    POSTGRES_IMAGE_REF="$(_rv_resolve_digest "${POSTGRES_IMAGE_REF%%@*}" "$POSTGRES_IMAGE_TAG")"
    NGINX_IMAGE_REF="$(_rv_resolve_digest "${NGINX_IMAGE_REF%%@*}" "$NGINX_IMAGE_TAG")"
    LITELLM_IMAGE_REF="$(_rv_resolve_digest "${LITELLM_IMAGE_REF%%@*}" "$LITELLM_IMAGE_TAG")"
    CODE_SERVER_BASE_IMAGE_REF="$(_rv_resolve_digest "${CODE_SERVER_BASE_IMAGE_REF%%@*}" "$CODE_SERVER_BASE_IMAGE_TAG")"
    TF_PROVIDER_CODER_VERSION="$(_rv_latest_provider_version coder coder "$TF_PROVIDER_CODER_VERSION")"
    TF_PROVIDER_DOCKER_VERSION="$(_rv_latest_provider_version kreuzwerker docker "$TF_PROVIDER_DOCKER_VERSION")"
    # Resolve optional service images only when they are present in the lock file
    if [ -n "${MINERU_IMAGE_REF:-}" ]; then
        MINERU_IMAGE_REF="$(_rv_resolve_digest "${MINERU_IMAGE_REF%%@*}" "$MINERU_IMAGE_TAG")"
    fi
    if [ -n "${DOCCONV_IMAGE_REF:-}" ]; then
        DOCCONV_IMAGE_REF="$(_rv_resolve_digest "${DOCCONV_IMAGE_REF%%@*}" "$DOCCONV_IMAGE_TAG")"
    fi
    if [ -n "${GITEA_IMAGE_REF:-}" ]; then
        GITEA_IMAGE_REF="$(_rv_resolve_digest "${GITEA_IMAGE_REF%%@*}" "$GITEA_IMAGE_TAG")"
    fi
    if [ -n "${PYPISERVER_IMAGE_REF:-}" ]; then
        PYPISERVER_IMAGE_REF="$(_rv_resolve_digest "${PYPISERVER_IMAGE_REF%%@*}" "$PYPISERVER_IMAGE_TAG")"
    fi

    echo
    local _rv_keys=(CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF CODE_SERVER_BASE_IMAGE_REF TF_PROVIDER_CODER_VERSION TF_PROVIDER_DOCKER_VERSION)
    [ -n "${MINERU_IMAGE_REF:-}"     ] && _rv_keys+=(MINERU_IMAGE_REF)
    [ -n "${DOCCONV_IMAGE_REF:-}"    ] && _rv_keys+=(DOCCONV_IMAGE_REF)
    [ -n "${GITEA_IMAGE_REF:-}"      ] && _rv_keys+=(GITEA_IMAGE_REF)
    [ -n "${PYPISERVER_IMAGE_REF:-}" ] && _rv_keys+=(PYPISERVER_IMAGE_REF)
    for key in "${_rv_keys[@]}"; do
        local old_var="OLD_${key}"
        local old_value="${!old_var}"
        local new_value="${!key}"
        if [ "$old_value" != "$new_value" ]; then
            echo "$key"
            echo "  old: $old_value"
            echo "  new: $new_value"
        else
            echo "$key unchanged"
        fi
    done

    if [ "$apply" = true ]; then
        # Build optional image lines conditionally so the lock file only includes
        # entries for services that are already tracked (avoids orphan entries).
        local _mineru_lines='' _docconv_lines='' _gitea_lines='' _pypiserver_lines=''
        if [ -n "${MINERU_IMAGE_REF:-}" ]; then
            _mineru_lines="# MinerU GPU 文档转 Markdown（--profile mineru，需 runtime: nvidia）
MINERU_IMAGE_REF=${MINERU_IMAGE_REF}
MINERU_IMAGE_TAG=${MINERU_IMAGE_TAG}"
        fi
        if [ -n "${DOCCONV_IMAGE_REF:-}" ]; then
            _docconv_lines="# Pandoc Markdown→Word/PDF（--profile doctools）
DOCCONV_IMAGE_REF=${DOCCONV_IMAGE_REF}
DOCCONV_IMAGE_TAG=${DOCCONV_IMAGE_TAG}"
        fi
        if [ -n "${GITEA_IMAGE_REF:-}" ]; then
            _gitea_lines="# Gitea 内网 Git 平台（Skill Hub，--profile skillhub）
GITEA_IMAGE_REF=${GITEA_IMAGE_REF}
GITEA_IMAGE_TAG=${GITEA_IMAGE_TAG}"
        fi
        if [ -n "${PYPISERVER_IMAGE_REF:-}" ]; then
            _pypiserver_lines="# PyPI Mirror 离线 Python 包服务器（--profile skillhub）
PYPISERVER_IMAGE_REF=${PYPISERVER_IMAGE_REF}
PYPISERVER_IMAGE_TAG=${PYPISERVER_IMAGE_TAG}"
        fi
        cat > "$LOCK_FILE" <<EOF
# Locked versions and digests for reproducible offline bundles.
CODER_IMAGE_REF=${CODER_IMAGE_REF}
CODER_IMAGE_TAG=${CODER_IMAGE_TAG}
POSTGRES_IMAGE_REF=${POSTGRES_IMAGE_REF}
POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG}
NGINX_IMAGE_REF=${NGINX_IMAGE_REF}
NGINX_IMAGE_TAG=${NGINX_IMAGE_TAG}
LITELLM_IMAGE_REF=${LITELLM_IMAGE_REF}
LITELLM_IMAGE_TAG=${LITELLM_IMAGE_TAG}
# Dex OIDC 提供方（LDAP 模式，--profile ldap 启用）
DEX_IMAGE_REF=${DEX_IMAGE_REF}
DEX_IMAGE_TAG=${DEX_IMAGE_TAG}
CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}
CODE_SERVER_BASE_IMAGE_TAG=${CODE_SERVER_BASE_IMAGE_TAG}
WORKSPACE_IMAGE=${WORKSPACE_IMAGE}
WORKSPACE_IMAGE_TAG=${WORKSPACE_IMAGE_TAG}
TF_PROVIDER_CODER_VERSION=${TF_PROVIDER_CODER_VERSION}
TF_PROVIDER_DOCKER_VERSION=${TF_PROVIDER_DOCKER_VERSION}
${_mineru_lines}
${_docconv_lines}
${_gitea_lines}
${_pypiserver_lines}
EOF
        ok "Updated $LOCK_FILE"
    else
        warn "Dry run only. Re-run with --apply to rewrite configs/versions.lock.env."
    fi
}

# ─── skillhub-prepare / skillhub-refresh / setup-gitea ────────────────────────

# Community skill repos to mirror at prepare time (url:dest-basename pairs)
_SKILLHUB_REPOS=(
    "https://github.com/wshobson/commands.git:wshobson-commands.git"
)

skillhub_prepare() {
    check_deps
    init_dirs
    load_config

    command -v git >/dev/null 2>&1 || fail "git not found — required for mirroring skill repos"

    info "=== Skill Hub Preparation ==="
    echo

    # ── Step 1: Pull and save Gitea image ──────────────────────────────────────
    local gitea_ref="${GITEA_IMAGE_REF:-gitea/gitea:latest}"
    info "Pulling $gitea_ref"
    docker pull "$gitea_ref"
    mkdir -p "$IMAGES_DIR"
    local gitea_tar="$IMAGES_DIR/$(printf '%s' "$gitea_ref" | tr '/:@' '_').tar"
    info "Saving Gitea image -> $(basename "$gitea_tar")"
    docker save -o "$gitea_tar" "$gitea_ref"
    ok "Saved Gitea image"
    echo

    # ── Step 2: Pull and save pypiserver image ─────────────────────────────────
    local pypiserver_ref="${PYPISERVER_IMAGE_REF:-pypiserver/pypiserver:latest}"
    info "Pulling $pypiserver_ref"
    docker pull "$pypiserver_ref"
    local pypiserver_tar="$IMAGES_DIR/$(printf '%s' "$pypiserver_ref" | tr '/:@' '_').tar"
    info "Saving pypiserver image -> $(basename "$pypiserver_tar")"
    docker save -o "$pypiserver_tar" "$pypiserver_ref"
    ok "Saved pypiserver image"
    echo

    # ── Step 3: Lock image digests in versions.lock.env ───────────────────────
    if [ -f "$LOCK_FILE" ]; then
        _lock_image_digest "$gitea_ref"      GITEA_IMAGE_REF      GITEA_IMAGE_TAG
        _lock_image_digest "$pypiserver_ref" PYPISERVER_IMAGE_REF PYPISERVER_IMAGE_TAG
    fi

    # ── Step 4: Mirror community skill repos ──────────────────────────────────
    skillhub_refresh
    echo

    # ── Step 5: Download pip packages (x86_64 manylinux wheels) ───────────────
    local packages_dir="$CONFIGS_DIR/pypi/packages"
    mkdir -p "$packages_dir"

    if command -v pip3 >/dev/null 2>&1; then
        info "Downloading scientific/engineering pip packages (x86_64 manylinux, Python 3.11)..."
        info "This may take a while (~600MB–1.5GB)..."
        pip3 download \
            --dest "$packages_dir" \
            --platform manylinux_2_17_x86_64 \
            --python-version 3.11 \
            --only-binary=:all: \
            numpy pandas matplotlib scipy scikit-learn sympy \
            pyserial pyelftools gcovr \
            sphinx breathe \
            pytest coverage \
            requests httpx \
            pydantic click rich tqdm \
            || warn "Some packages failed to download (non-fatal; partial set will still be available offline)"
        ok "Pip packages downloaded to $packages_dir"
    else
        warn "pip3 not found on host — skipping pip package download."
        warn "Manually copy .whl files into configs/pypi/packages/ before deploying."
    fi
    echo

    ok "Skill Hub preparation complete"
    info "Transfer the project directory (including images/ and configs/pypi/packages/) to the offline server."
    info "On the offline server: bash scripts/manage.sh load --skillhub && bash scripts/manage.sh up --skillhub"
}

# Helper: resolve and write image digest to versions.lock.env
_lock_image_digest() {
    local image_ref="$1" ref_key="$2" tag_key="$3"
    local digest tag
    digest="$(docker image inspect "$image_ref" --format '{{json .RepoDigests}}' | python3 - "${image_ref%%:*}" <<'PY'
import json,sys
repo = sys.argv[1]
digests = json.load(sys.stdin)
for d in digests:
    if d.startswith(repo + '@'):
        print(d); break
else:
    print(digests[0] if digests else '')
PY
)"
    [ -n "$digest" ] || return 0
    tag="${image_ref##*:}"
    [ "$tag" = "$image_ref" ] && tag="latest"
    if grep -q "^${ref_key}=" "$LOCK_FILE"; then
        sed -i "s|^${ref_key}=.*|${ref_key}=${digest}|" "$LOCK_FILE"
    else
        printf '\n%s=%s\n%s=%s\n' "$ref_key" "$digest" "$tag_key" "$tag" >> "$LOCK_FILE"
    fi
    ok "Locked ${ref_key} in $(basename "$LOCK_FILE")"
}

skillhub_refresh() {
    local seeds_dir="$CONFIGS_DIR/gitea/seeds"
    mkdir -p "$seeds_dir"

    command -v git >/dev/null 2>&1 || fail "git not found"

    info "Syncing community skill repo mirrors..."
    local entry url dest
    for entry in "${_SKILLHUB_REPOS[@]}"; do
        url="${entry%%:*}"
        dest="$seeds_dir/${entry##*:}"
        if [ -d "$dest" ]; then
            info "Updating mirror: $(basename "$dest")"
            git -C "$dest" remote update --prune \
                && ok "Updated $(basename "$dest")" \
                || warn "Update failed for $(basename "$dest") — will use existing mirror"
        else
            info "Cloning mirror: $url -> $(basename "$dest")"
            git clone --mirror "$url" "$dest" \
                && ok "Cloned $(basename "$dest")" \
                || fail "Failed to clone $url"
        fi
    done
    ok "Skill repo mirrors ready in $seeds_dir"
}

# Wait for Gitea API to respond, then initialize admin user and import seed repos
setup_gitea() {
    local gitea_done_file="$DOCKER_DIR/.gitea-setup-done"
    [ -f "$gitea_done_file" ] && return 0

    load_config
    local gitea_url="http://localhost:3000"
    local admin_pass="${GITEA_ADMIN_PASSWORD:-$(openssl rand -hex 12 2>/dev/null || echo "ChangeMe$(date +%s)")}"

    info "Waiting for Gitea to become ready..."
    local attempt
    for attempt in $(seq 1 30); do
        if curl -sf "${gitea_url}/-/ready" >/dev/null 2>&1; then
            ok "Gitea is ready"
            break
        fi
        sleep 3
    done
    curl -sf "${gitea_url}/-/ready" >/dev/null 2>&1 \
        || { warn "Gitea did not become ready in time — skipping initialization"; return 0; }

    # Create admin user (ignore error if already exists)
    info "Creating Gitea admin user..."
    docker exec coder-gitea gitea admin user create \
        --admin \
        --username admin \
        --password "$admin_pass" \
        --email "gitea-admin@internal" \
        --must-change-password=false \
        2>&1 | grep -v "already exists" || true

    # Get admin token via API basic auth
    local token_name="manage-sh-$(date +%s)"
    local token_json
    token_json="$(curl -sf -X POST "${gitea_url}/api/v1/users/admin/tokens" \
        -u "admin:${admin_pass}" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"${token_name}\"}" 2>/dev/null || echo '')"
    local token
    token="$(echo "$token_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha1',''))" 2>/dev/null || echo '')"
    if [ -z "$token" ]; then
        warn "Could not obtain Gitea API token — seed repos will not be imported automatically."
        warn "Import manually via: https://<SERVER>:<PORT>/gitea  (admin / $admin_pass)"
        return 0
    fi

    # Import each seed repo into Gitea (migrate from local path)
    local entry dest repo_name
    for entry in "${_SKILLHUB_REPOS[@]}"; do
        dest="$CONFIGS_DIR/gitea/seeds/${entry##*:}"
        repo_name="${entry##*:}"
        repo_name="${repo_name%.git}"
        # Strip username prefix (e.g. wshobson-commands -> commands)
        repo_name="${repo_name#*-}"
        [ -d "$dest" ] || continue
        info "Importing seed repo: $repo_name"
        local http_code
        http_code="$(curl -sf -o /dev/null -w '%{http_code}' \
            -X POST "${gitea_url}/api/v1/repos/migrate" \
            -H "Authorization: token ${token}" \
            -H 'Content-Type: application/json' \
            -d "{\"clone_addr\":\"/repos-seed/${entry##*:}\",\"repo_name\":\"${repo_name}\",\"uid\":1,\"private\":false,\"description\":\"Mirrored from ${entry%%:*}\"}" \
            2>/dev/null || echo '000')"
        if [ "$http_code" = "201" ]; then
            ok "Imported ${repo_name} into Gitea"
        elif [ "$http_code" = "409" ]; then
            info "${repo_name} already exists in Gitea"
        else
            warn "Import of ${repo_name} returned HTTP ${http_code} (non-fatal)"
        fi
    done

    # Save admin password for operator reference
    echo "$admin_pass" > "$DOCKER_DIR/.gitea-admin-password"
    chmod 600 "$DOCKER_DIR/.gitea-admin-password"
    date > "$gitea_done_file"

    ok "Gitea initialized"
    info "Gitea admin credentials saved to docker/.gitea-admin-password"
    warn "Change the Gitea admin password after first login: https://<SERVER>:<PORT>/gitea"
}

# ─── test / clean ─────────────────────────────────────────────────────────────

test_api() {
    [ -f "$ENV_FILE" ] || fail "Run init first."
    load_config

    local api_key="${ANTHROPIC_API_KEY:-}"
    local api_base_url="${ANTHROPIC_BASE_URL:-}"
    if [ "$USE_LLM" = true ] && [ -z "$api_base_url" ]; then
        api_base_url="$(llm_gateway_url)"
        if [ -z "$api_key" ]; then
            api_key="${LITELLM_MASTER_KEY:-}"
        fi
    fi
    api_base_url="${api_base_url:-https://api.anthropic.com}"
    [ -n "$api_key" ] || fail "ANTHROPIC_API_KEY is not configured"

    info "Testing $api_base_url"
    local http_code
    http_code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 10 \
        -X POST "$api_base_url/v1/messages" \
        -H "x-api-key: $api_key" \
        -H 'anthropic-version: 2023-06-01' \
        -H 'content-type: application/json' \
        -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
        || true)"
    [ -n "$http_code" ] || http_code=000

    if [ "$http_code" = "200" ]; then
        ok "API request succeeded"
    elif [ "$http_code" = "000" ]; then
        fail "Failed to connect to $api_base_url"
    else
        warn "API returned HTTP $http_code"
    fi
}

test_llm_backend() {
    [ -f "$ENV_FILE" ] || fail "Run init first."
    load_config
    [ -n "${INTERNAL_API_BASE:-}" ] || fail "INTERNAL_API_BASE is not configured"

    local curl_args=(-sk -o /dev/null -w '%{http_code}' --connect-timeout 10)
    if [ -n "${INTERNAL_API_KEY:-}" ]; then
        curl_args+=(-H "Authorization: Bearer ${INTERNAL_API_KEY}")
    fi

    local http_code
    http_code="$(curl "${curl_args[@]}" "$INTERNAL_API_BASE" || true)"
    [ -n "$http_code" ] || http_code=000
    if [ "$http_code" = "000" ]; then
        fail "Failed to reach $INTERNAL_API_BASE"
    fi
    ok "Internal LLM backend is reachable (HTTP $http_code)"
}

clean() {
    check_deps
    info "Cleaning Docker build cache..."
    docker system prune -f
    ok "Cleanup complete"
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
    case "${1:-help}" in
        # Online preparation
        refresh-versions)
            refresh_versions "${@:2}"
            ;;
        prepare)
            prepare_offline "${@:2}"
            ;;
        verify)
            verify_offline "${@:2}"
            ;;
        skillhub-prepare)
            skillhub_prepare
            ;;
        skillhub-refresh)
            skillhub_refresh
            ;;
        # Platform lifecycle
        init)
            init_dirs
            init_config
            ;;
        ssl)
            init_dirs
            gen_ssl "${2:-localhost}"
            ;;
        pull)
            pull_images
            ;;
        build)
            build_images
            ;;
        save)
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
            run_setup_coder
            ;;
        test-api)
            test_api
            ;;
        test-llm-backend)
            test_llm_backend
            ;;
        clean)
            clean
            ;;
        # Workspace version management
        push-template)
            cmd_push_template
            ;;
        update-workspace)
            update_workspace "${@:2}"
            ;;
        load-workspace)
            load_workspace "${2:-}"
            ;;
        upgrade-backup)
            upgrade_backup "${@:2}"
            ;;
        upgrade-restore-config)
            upgrade_restore_config "${@:2}"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
