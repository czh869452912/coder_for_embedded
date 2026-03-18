#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/docker"
CONFIGS_DIR="$PROJECT_ROOT/configs"
ENV_FILE="$DOCKER_DIR/.env"
SETUP_DONE_FILE="$DOCKER_DIR/.setup-done"

source "$SCRIPT_DIR/lib/offline-common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

USE_LLM=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --llm) USE_LLM=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
if [ ${#ARGS[@]} -gt 0 ]; then
    set -- "${ARGS[@]}"
else
    set --
fi

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: bash scripts/manage.sh <command> [arg] [--llm]

Commands:
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
  setup-coder           Create admin and push template
  test-api              Test Anthropic/LiteLLM API access
  test-llm-backend      Test the internal LLM backend base URL
  clean                 Clean Docker build cache

Notes:
  Deployment uses pinned image refs from configs/versions.lock.env.
  A new root CA requires one workspace rebuild. Later leaf rotations do not.
  LiteLLM remains a gateway layer to existing internal model infrastructure.
  Set TF_CLI_CONFIG_MOUNT=../configs/terraform.rc to allow connected Terraform fallback.
EOF
}

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
        "$CONFIGS_DIR/terraform-providers"
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

    local image
    for image in "${images[@]}"; do
        info "Pulling $image"
        docker pull "$image"
    done

    ok "Base images pulled"
    warn "Run build to produce the workspace image used by the template."
}

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

    # If the digest ref is no longer in the local cache (e.g. after pulling a newer tag via
    # refresh-versions without -Apply), fall back to name:tag so the save can still succeed.
    local image filename filepath image_to_save ref_key ref tag_key tag fallback
    for image in "${images[@]}"; do
        filename="$(printf '%s' "$image" | tr '/:@' '_').tar"
        filepath="$PROJECT_ROOT/images/$filename"

        image_to_save="$image"
        if [[ "$image" == *@sha256:* ]]; then
            if ! docker image inspect "$image" >/dev/null 2>&1; then
                fallback=""
                for ref_key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF CODE_SERVER_BASE_IMAGE_REF; do
                    ref="${!ref_key:-}"
                    [ "$ref" = "$image" ] || continue
                    tag_key="${ref_key/_REF/_TAG}"
                    tag="${!tag_key:-}"
                    [ -n "$tag" ] && fallback="${image%%@sha256:*}:${tag}"
                    break
                done
                if [ -n "$fallback" ]; then
                    warn "Digest ref not in local cache; saving $fallback instead."
                    warn "Run 'refresh-versions -Apply' then 'save' again to keep pinned digests in sync."
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
            for ref_key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF CODE_SERVER_BASE_IMAGE_REF; do
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

    if [ ! -d "$CONFIGS_DIR/terraform-providers/registry.terraform.io" ]; then
        if [ "$offline_terraform_mode" = true ]; then
            fail "Offline Terraform mode is active but the provider cache is missing."
        fi
        warn "Connected Terraform mode is active and the provider cache is missing. Terraform will fall back to the public registry."
    elif [ "$offline_terraform_mode" = false ]; then
        info "Connected Terraform mode is active. Local providers will be used first, then registry fallback is allowed."
    fi

    fix_provider_permissions

    # In offline/loaded mode Docker cannot resolve digest refs against the registry.
    # Override image ref env vars to use name:tag format before invoking compose,
    # so compose resolves against the locally loaded (and retagged) images.
    local ref_key ref tag_key tag
    local -a required_images=()
    for ref_key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF; do
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
        [ "$USE_LLM" = false ] && [[ "$img" == *litellm* ]] && continue
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            missing_images+=("$img")
        fi
    done
    if [ ${#missing_images[@]} -gt 0 ]; then
        fail "The following images are not available locally. Run 'load' (with the correct flags) first:$(printf '\n  - %s' "${missing_images[@]}")"
    fi

    cd "$DOCKER_DIR"
    if [ "$USE_LLM" = true ]; then
        "${COMPOSE_CMD[@]}" --profile llm up -d
    else
        "${COMPOSE_CMD[@]}" up -d
    fi

    ok "Platform started"
    echo

    if [ ! -f "$SETUP_DONE_FILE" ]; then
        warn "First startup detected. Running setup-coder after a short delay."
        sleep 8
        run_setup_coder
    else
        show_access_info
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
}

stop_services() {
    check_deps
    cd "$DOCKER_DIR"
    if [ "$USE_LLM" = true ]; then
        "${COMPOSE_CMD[@]}" --profile llm down
    else
        "${COMPOSE_CMD[@]}" down
    fi
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

run_setup_coder() {
    [ -f "$ENV_FILE" ] || fail "Run init first."
    rm -f "$SETUP_DONE_FILE"
    if [ "$USE_LLM" = true ]; then
        bash "$SCRIPT_DIR/setup-coder.sh" --llm
    else
        bash "$SCRIPT_DIR/setup-coder.sh"
    fi
}

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

main() {
    case "${1:-help}" in
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
