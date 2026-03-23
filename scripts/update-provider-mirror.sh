#!/bin/bash
# update-provider-mirror.sh — Add or refresh a provider in the local network mirror.
#
# This script is intended to be run on an ONLINE machine to download provider
# zip files and generate the JSON index files required by the Terraform Network
# Mirror Protocol.  Once the files are generated, transfer them to the offline
# server — no service restart is needed because the provider-mirror container
# uses a bind-mount and nginx serves files on every request.
#
# Usage:
#   bash scripts/update-provider-mirror.sh <namespace>/<type> <version>
#       Download provider zip from registry.terraform.io, compute zh: hash,
#       write/update index.json and <version>.json.
#
#   bash scripts/update-provider-mirror.sh <namespace>/<type>
#       Rebuild index.json and all <version>.json from already-downloaded zips.
#       Safe to run offline — only reads local zip files.
#
# The script is idempotent: re-running with the same args is safe.
#
# Examples:
#   bash scripts/update-provider-mirror.sh coder/coder 2.14.0
#   bash scripts/update-provider-mirror.sh kreuzwerker/docker 3.6.2
#   bash scripts/update-provider-mirror.sh hashicorp/kubernetes 2.31.0
#   bash scripts/update-provider-mirror.sh coder/coder          # rebuild indexes only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MIRROR_ROOT="$PROJECT_ROOT/configs/provider-mirror/registry.terraform.io"

OS="linux"
ARCH="amd64"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage:"
    echo "  $0 <namespace>/<type> <version>   # download + rebuild indexes"
    echo "  $0 <namespace>/<type>             # rebuild indexes from existing zips"
    exit 1
}

[ $# -ge 1 ] || usage

provider_slug="$1"
version="${2:-}"

IFS='/' read -r namespace provider_type <<< "$provider_slug"
[ -n "$namespace" ] && [ -n "$provider_type" ] || fail "Provider must be <namespace>/<type>, e.g. coder/coder"

# ---------------------------------------------------------------------------
# zh: hash — Terraform Network Mirror Protocol requires this format:
#   "zh:" + base64(sha256(zip_file_bytes))
# Computed entirely from the local zip file; no internet access required.
# ---------------------------------------------------------------------------
compute_zh_hash() {
    local zip_path="$1"
    python3 - "$zip_path" <<'PY'
import base64, hashlib, sys
data = open(sys.argv[1], 'rb').read()
print("zh:" + base64.b64encode(hashlib.sha256(data).digest()).decode())
PY
}

# ---------------------------------------------------------------------------
# Write <version>.json for a single version/zip combination.
# The URL in the JSON is relative to the provider's base directory
# (registry.terraform.io/<namespace>/<type>/), so Terraform resolves it as:
#   https://provider-mirror/registry.terraform.io/<ns>/<type>/<ver>/<os>_<arch>/<zip>
# ---------------------------------------------------------------------------
rebuild_version_json() {
    local base="$1"   # e.g. MIRROR_ROOT/coder/coder
    local ver="$2"
    local zip_file="$3"

    local zip_name hash
    zip_name="$(basename "$zip_file")"
    hash="$(compute_zh_hash "$zip_file")"

    printf '{"archives":{"%s_%s":{"url":"%s/%s_%s/%s","hashes":["%s"]}}}\n' \
        "$OS" "$ARCH" "$ver" "$OS" "$ARCH" "$zip_name" "$hash" \
        > "$base/${ver}.json"
    ok "Wrote ${ver}.json  (hash=${hash})"
}

# ---------------------------------------------------------------------------
# Rebuild index.json by scanning all version directories for zip files.
# ---------------------------------------------------------------------------
rebuild_index() {
    local base="$1"

    local versions_json="" sep=""
    while IFS= read -r -d '' zip_file; do
        local ver
        # path: <base>/<version>/<os>_<arch>/<zipname>
        ver="$(basename "$(dirname "$(dirname "$zip_file")")")"
        versions_json="${versions_json}${sep}\"${ver}\":{}"
        sep=","
    done < <(find "$base" -name "*.zip" -print0 | sort -z)

    if [ -z "$versions_json" ]; then
        warn "No zip files found under $base — index.json not written"
        return
    fi

    printf '{"versions":{%s}}\n' "$versions_json" > "$base/index.json"
    ok "Wrote index.json"
}

# ---------------------------------------------------------------------------
# Download a provider zip from registry.terraform.io.
# Requires internet access.
# ---------------------------------------------------------------------------
download_provider() {
    local ns="$1" ptype="$2" ver="$3"
    local zip_name="terraform-provider-${ptype}_${ver}_${OS}_${ARCH}.zip"
    local ver_dir="$MIRROR_ROOT/$ns/$ptype/${ver}/${OS}_${ARCH}"
    local zip_path="$ver_dir/$zip_name"

    if [ -f "$zip_path" ]; then
        ok "Already present: $zip_name"
        return 0
    fi

    mkdir -p "$ver_dir"
    info "Querying registry.terraform.io for $ns/$ptype $ver ..."
    local download_url
    download_url="$(curl -fsSL \
        "https://registry.terraform.io/v1/providers/${ns}/${ptype}/${ver}/download/${OS}/${ARCH}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['download_url'])")"

    info "Downloading $zip_name ..."
    curl -fL --progress-bar "$download_url" -o "$zip_path"
    ok "Saved $zip_path"
}

# ---------------------------------------------------------------------------
# Rebuild all version JSONs and the index for namespace/type.
# ---------------------------------------------------------------------------
rebuild_all() {
    local ns="$1" ptype="$2"
    local base="$MIRROR_ROOT/$ns/$ptype"

    [ -d "$base" ] || { warn "No mirror directory for $ns/$ptype — nothing to index"; return; }

    while IFS= read -r -d '' zip_file; do
        local ver
        ver="$(basename "$(dirname "$(dirname "$zip_file")")")"
        rebuild_version_json "$base" "$ver" "$zip_file"
    done < <(find "$base" -name "*.zip" -print0)

    rebuild_index "$base"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ -n "$version" ]; then
    info "=== Adding $namespace/$provider_type $version to provider mirror ==="
    download_provider "$namespace" "$provider_type" "$version"
else
    info "=== Rebuilding indexes for $namespace/$provider_type (no download) ==="
fi

rebuild_all "$namespace" "$provider_type"

echo
ok "Done. Mirror path: $MIRROR_ROOT/$namespace/$provider_type/"
if [ -n "$version" ]; then
    echo
    echo "To import into the offline server, transfer the new files:"
    echo "  rsync -av configs/provider-mirror/registry.terraform.io/$namespace/$provider_type/ \\"
    echo "      <offline-server>:/path/to/project/configs/provider-mirror/registry.terraform.io/$namespace/$provider_type/"
    echo
    echo "No service restart is required — the provider is immediately available."
fi
