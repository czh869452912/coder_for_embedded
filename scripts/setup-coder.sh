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
for arg in "$@"; do
    case "$arg" in
        --llm) USE_LLM=true ;;
    esac
done

info() { echo -e "${BLUE}[setup]${NC} $*"; }
ok() { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
fail() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || fail "$ENV_FILE is missing. Run manage.sh init first."

ensure_env_defaults "$ENV_FILE" "$CONFIGS_DIR"
load_effective_config "$CONFIGS_DIR" "$ENV_FILE"

CODER_INTERNAL_URL="http://localhost:${CODER_INTERNAL_PORT:-7080}"

llm_gateway_url() {
    local host="${SERVER_HOST:-localhost}"
    local port="${GATEWAY_PORT:-8443}"
    if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
        host="host.docker.internal"
    fi
    echo "https://${host}:${port}/llm"
}

wait_for_coder() {
    info "Waiting for Coder service..."
    local url="${CODER_INTERNAL_URL}/healthz"
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

check_first_user() {
    curl -s -o /dev/null -w '%{http_code}' "${CODER_INTERNAL_URL}/api/v2/users/first" || true
}

create_admin_user() {
    info "Creating admin account ${CODER_ADMIN_EMAIL}"
    curl -sf -X POST \
        "${CODER_INTERNAL_URL}/api/v2/users/first" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"${CODER_ADMIN_EMAIL}\",\"username\":\"${CODER_ADMIN_USERNAME}\",\"password\":\"${CODER_ADMIN_PASSWORD}\",\"trial\":false}" \
        >/dev/null
    ok "Admin account created"
}

get_session_token() {
    curl -sf -X POST \
        "${CODER_INTERNAL_URL}/api/v2/users/login" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"${CODER_ADMIN_EMAIL}\",\"password\":\"${CODER_ADMIN_PASSWORD}\"}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['session_token'])"
}

check_template_exists() {
    local token="$1"
    curl -s -o /dev/null -w '%{http_code}' \
        -H "Coder-Session-Token: ${token}" \
        "${CODER_INTERNAL_URL}/api/v2/organizations/default/templates/embedded-dev" || true
}

push_template() {
    local token="$1"
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

    info "Pushing workspace template"
    docker exec coder-server sh -c 'rm -rf /tmp/template-push && mkdir -p /tmp/template-push' >/dev/null
    docker cp "$template_dir/." 'coder-server:/tmp/template-push/'

    docker exec coder-server sh -c "CODER_URL=http://localhost:7080 CODER_SESSION_TOKEN=${token} /opt/coder templates push embedded-dev --directory /tmp/template-push --yes --activate --var workspace_image=${workspace_image} --var workspace_image_tag=${workspace_tag} --var anthropic_api_key='${anthropic_key}' --var anthropic_base_url='${anthropic_url}' ; rm -rf /tmp/template-push"
    ok "Workspace template pushed"
}

main() {
    info "Starting Coder bootstrap"
    wait_for_coder

    local first_user_status
    first_user_status="$(check_first_user)"
    if [ "$first_user_status" = "404" ]; then
        create_admin_user
    else
        info "Admin account already exists"
    fi

    local session_token
    session_token="$(get_session_token)"
    [ -n "$session_token" ] || fail "Failed to get Coder session token"
    ok "Logged in and obtained session token"

    local template_status
    template_status="$(check_template_exists "$session_token")"
    if [ "$template_status" = "200" ]; then
        warn "Template embedded-dev already exists. Skipping push."
    else
        push_template "$session_token"
    fi

    date > "$SETUP_DONE_FILE"
    echo
    ok "Coder initialization complete"
    echo -e "  ${BLUE}https://${SERVER_HOST:-localhost}:${GATEWAY_PORT:-8443}/${NC}"
}

main "$@"
