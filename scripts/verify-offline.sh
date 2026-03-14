#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIGS_DIR="$PROJECT_ROOT/configs"
MANIFEST_PATH="$PROJECT_ROOT/offline-manifest.json"

REQUIRE_LLM=false
for arg in "$@"; do
    case "$arg" in
        --require-llm) REQUIRE_LLM=true ;;
    esac
done

info() { echo "[INFO]  $*"; }
ok() { echo "[ OK ]  $*"; }
fail() { echo "[FAIL]  $*" >&2; exit 1; }

[ -f "$MANIFEST_PATH" ] || fail "offline-manifest.json is missing. Run prepare-offline first."
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

python3 - "$PROJECT_ROOT" "$CONFIGS_DIR" "$MANIFEST_PATH" "$REQUIRE_LLM" <<'PY'
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
