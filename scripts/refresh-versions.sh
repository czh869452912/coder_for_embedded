#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIGS_DIR="$PROJECT_ROOT/configs"
LOCK_FILE="$CONFIGS_DIR/versions.lock.env"

source "$SCRIPT_DIR/lib/offline-common.sh"

APPLY=false
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=true ;;
    esac
done

info() { echo "[INFO]  $*"; }
ok() { echo "[ OK ]  $*"; }
warn() { echo "[WARN]  $*"; }
fail() { echo "[FAIL]  $*" >&2; exit 1; }

assert_prereqs() {
    command -v docker >/dev/null 2>&1 || fail "docker not found"
    docker info >/dev/null 2>&1 || fail "Docker daemon is not running"
    command -v python3 >/dev/null 2>&1 || fail "python3 not found"
    command -v curl >/dev/null 2>&1 || fail "curl not found"
}

load_current_lock() {
    load_key_value_into_env "$LOCK_FILE"
}

repository_from_ref() {
    local reference="$1"
    printf '%s\n' "${reference%%@*}"
}

resolved_digest_ref() {
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

latest_provider_version() {
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

write_lock_file() {
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
CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}
CODE_SERVER_BASE_IMAGE_TAG=${CODE_SERVER_BASE_IMAGE_TAG}
WORKSPACE_IMAGE=${WORKSPACE_IMAGE}
WORKSPACE_IMAGE_TAG=${WORKSPACE_IMAGE_TAG}
TF_PROVIDER_CODER_VERSION=${TF_PROVIDER_CODER_VERSION}
TF_PROVIDER_DOCKER_VERSION=${TF_PROVIDER_DOCKER_VERSION}
EOF
}

assert_prereqs
load_current_lock

OLD_CODER_IMAGE_REF="$CODER_IMAGE_REF"
OLD_POSTGRES_IMAGE_REF="$POSTGRES_IMAGE_REF"
OLD_NGINX_IMAGE_REF="$NGINX_IMAGE_REF"
OLD_LITELLM_IMAGE_REF="$LITELLM_IMAGE_REF"
OLD_CODE_SERVER_BASE_IMAGE_REF="$CODE_SERVER_BASE_IMAGE_REF"
OLD_TF_PROVIDER_CODER_VERSION="$TF_PROVIDER_CODER_VERSION"
OLD_TF_PROVIDER_DOCKER_VERSION="$TF_PROVIDER_DOCKER_VERSION"

CODER_IMAGE_REF="$(resolved_digest_ref "$(repository_from_ref "$CODER_IMAGE_REF")" "$CODER_IMAGE_TAG")"
POSTGRES_IMAGE_REF="$(resolved_digest_ref "$(repository_from_ref "$POSTGRES_IMAGE_REF")" "$POSTGRES_IMAGE_TAG")"
NGINX_IMAGE_REF="$(resolved_digest_ref "$(repository_from_ref "$NGINX_IMAGE_REF")" "$NGINX_IMAGE_TAG")"
LITELLM_IMAGE_REF="$(resolved_digest_ref "$(repository_from_ref "$LITELLM_IMAGE_REF")" "$LITELLM_IMAGE_TAG")"
CODE_SERVER_BASE_IMAGE_REF="$(resolved_digest_ref "$(repository_from_ref "$CODE_SERVER_BASE_IMAGE_REF")" "$CODE_SERVER_BASE_IMAGE_TAG")"
TF_PROVIDER_CODER_VERSION="$(latest_provider_version coder coder "$TF_PROVIDER_CODER_VERSION")"
TF_PROVIDER_DOCKER_VERSION="$(latest_provider_version kreuzwerker docker "$TF_PROVIDER_DOCKER_VERSION")"

echo
for key in CODER_IMAGE_REF POSTGRES_IMAGE_REF NGINX_IMAGE_REF LITELLM_IMAGE_REF CODE_SERVER_BASE_IMAGE_REF TF_PROVIDER_CODER_VERSION TF_PROVIDER_DOCKER_VERSION; do
    old_var="OLD_${key}"
    old_value="${!old_var}"
    new_value="${!key}"
    if [ "$old_value" != "$new_value" ]; then
        echo "$key"
        echo "  old: $old_value"
        echo "  new: $new_value"
    else
        echo "$key unchanged"
    fi
done

if [ "$APPLY" = true ]; then
    write_lock_file
    ok "Updated $LOCK_FILE"
else
    warn "Dry run only. Re-run with --apply to rewrite configs/versions.lock.env."
fi

