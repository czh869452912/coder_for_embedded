# Workspace Image Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Python backend and interactive agent development workspace image profiles to the existing Coder platform with stable catalog entries and offline bundle support.

**Architecture:** Keep one Coder template and drive interactive workspace choice through the existing image profile dropdown. Add fixed workspace image families for embedded, Python backend, and agent development; management scripts build all stable families during offline preparation and update one selected family during workspace-only releases. New Dockerfiles keep image-specific tooling separate while sharing code-server, startup, CA trust, Git identity, and model gateway behavior.

**Tech Stack:** Docker, code-server, Coder Terraform templates, PowerShell 5.1, Bash, Python JSON helpers in Bash, custom PowerShell regression tests, Markdown docs.

---

## File Structure

Create:

- `docker/Dockerfile.workspace-python-backend`: Python backend golden image.
- `docker/Dockerfile.workspace-agent-dev`: interactive agent development golden image.
- `configs/settings-python-backend.json`: code-server defaults for Python backend work.
- `configs/settings-agent-dev.json`: code-server defaults for agent development work.

Modify:

- `configs/versions.lock.env`: add Python backend and agent development image locks.
- `workspace-template/image-catalog.json`: add stable Python backend and agent development profiles.
- `scripts/manage.ps1`: add workspace image family registry, build all stable images in `prepare`, family-aware `update-workspace`, and fixed catalog mapping.
- `scripts/manage.sh`: mirror the PowerShell behavior in Bash.
- `tests/upgrade-scripts.tests.ps1`: add static and helper tests for the new contracts.
- `README.md`: document the new profiles and command examples.
- `docs/offline-image-release-management.md`: update the release model and offline bundle policy.

Do not modify `workspace-template/main.tf` unless implementation discovers that the current catalog-driven dropdown cannot display the new catalog entries. The current template already reads the catalog and generates options dynamically.

---

### Task 1: Add Failing Tests For Workspace Image Families

**Files:**

- Modify: `tests/upgrade-scripts.tests.ps1`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add a test for catalog and lock contracts**

Insert this function after `Test-BashWorkspaceImageCatalogChannels`:

```powershell
function Test-WorkspaceImageFamilyContracts {
    $catalog = Get-Content (Join-Path $RepoRoot 'workspace-template/image-catalog.json') -Raw | ConvertFrom-Json
    $profiles = @{}
    foreach ($profile in @($catalog.profiles)) {
        $profiles[$profile.key] = $profile
    }
    $lock = Get-Content (Join-Path $RepoRoot 'configs/versions.lock.env') -Raw
    $managePs1 = Get-Content (Join-Path $RepoRoot 'scripts/manage.ps1') -Raw
    $manageSh = Get-Content (Join-Path $RepoRoot 'scripts/manage.sh') -Raw

    Assert-Equal 'catalog default remains embedded stable' $catalog.default 'embedded_stable'
    Assert-True 'catalog contains embedded stable profile' $profiles.ContainsKey('embedded_stable')
    Assert-True 'catalog contains Python backend stable profile' $profiles.ContainsKey('python_backend_stable')
    Assert-True 'catalog contains agent dev stable profile' $profiles.ContainsKey('agent_dev_stable')

    Assert-Equal 'embedded profile image family' $profiles['embedded_stable'].image 'workspace-embedded:embedded-v20260607-r1'
    Assert-Equal 'Python backend profile image family' $profiles['python_backend_stable'].image 'workspace-python-backend:python-backend-v20260607-r1'
    Assert-Equal 'agent dev profile image family' $profiles['agent_dev_stable'].image 'workspace-agent-dev:agent-dev-v20260607-r1'

    Assert-True 'lock tracks Python backend image name' ($lock -match '(?m)^PYTHON_BACKEND_WORKSPACE_IMAGE=workspace-python-backend$')
    Assert-True 'lock tracks Python backend image tag' ($lock -match '(?m)^PYTHON_BACKEND_WORKSPACE_IMAGE_TAG=python-backend-v20260607-r1$')
    Assert-True 'lock tracks agent dev image name' ($lock -match '(?m)^AGENT_DEV_WORKSPACE_IMAGE=workspace-agent-dev$')
    Assert-True 'lock tracks agent dev image tag' ($lock -match '(?m)^AGENT_DEV_WORKSPACE_IMAGE_TAG=agent-dev-v20260607-r1$')

    Assert-True 'PowerShell declares workspace image families' ($managePs1 -match 'function Get-WorkspaceImageFamilies')
    Assert-True 'PowerShell supports workspace image family flag' ($managePs1 -match '\[string\]\$Family')
    Assert-True 'PowerShell prepare builds all stable workspace images' ($managePs1 -match 'foreach \(\$family in Get-WorkspaceImageFamilies\)')
    Assert-True 'PowerShell manifest includes all stable workspace images' ($managePs1 -match 'Get-WorkspaceImageManifestEntries')

    Assert-True 'Bash declares workspace image families' ($manageSh -match '_workspace_families\(\)')
    Assert-True 'Bash supports workspace image family flag' ($manageSh -match '--family')
    Assert-True 'Bash prepare builds all stable workspace images' ($manageSh -match 'for family in \$\(_workspace_families\)')
    Assert-True 'Bash manifest includes all stable workspace images' ($manageSh -match '_workspace_manifest_entries')
}
```

- [ ] **Step 2: Add a Bash helper test for stable profile mapping**

Replace the body of `Test-BashWorkspaceImageCatalogChannels` with this complete function:

```powershell
function Test-BashWorkspaceImageCatalogChannels {
    $script = @'
set -euo pipefail
source scripts/manage.sh __test_source_only 2>/dev/null || true
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
WORKSPACE_IMAGE_CATALOG_FILE="$root/image-catalog.json"
export WORKSPACE_IMAGE_CATALOG_FILE

_update_workspace_image_catalog "workspace-embedded" "embedded-v20260608-r1"
_update_workspace_image_catalog "workspace-python-backend" "python-backend-v20260608-r1"
_update_workspace_image_catalog "workspace-agent-dev" "agent-dev-v20260608-r1"
_update_workspace_image_catalog "workspace-ai" "ai-v20260608-r1"

python3 - <<'PY'
import json
import os
from pathlib import Path

catalog = json.loads(Path(os.environ["WORKSPACE_IMAGE_CATALOG_FILE"]).read_text(encoding="utf-8"))
profiles = {profile["key"]: profile for profile in catalog["profiles"]}
assert catalog["default"] == "embedded_stable", catalog
assert profiles["embedded_stable"]["name"] == "Embedded Stable", profiles
assert profiles["embedded_stable"]["image"] == "workspace-embedded:embedded-v20260608-r1", profiles
assert profiles["python_backend_stable"]["name"] == "Python Backend Stable", profiles
assert profiles["python_backend_stable"]["image"] == "workspace-python-backend:python-backend-v20260608-r1", profiles
assert profiles["agent_dev_stable"]["name"] == "Agent Dev Stable", profiles
assert profiles["agent_dev_stable"]["image"] == "workspace-agent-dev:agent-dev-v20260608-r1", profiles
assert profiles["workspace_ai_ai_v20260608_r1"]["image"] == "workspace-ai:ai-v20260608-r1", profiles
assert "workspace_python_backend_python_backend_v20260608_r1" not in profiles, profiles
assert "workspace_agent_dev_agent_dev_v20260608_r1" not in profiles, profiles
PY
'@
    Invoke-BashText $script | Out-Null
}
```

- [ ] **Step 3: Register the new test**

Add this line before `Test-BashLlmTemplateInjectionDefaults`:

```powershell
Test-WorkspaceImageFamilyContracts
```

- [ ] **Step 4: Run the regression test and confirm it fails for the new contract**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL with at least one assertion about missing `python_backend_stable`, missing `agent_dev_stable`, or missing family helper functions.

- [ ] **Step 5: Commit the failing tests**

```bash
git add tests/upgrade-scripts.tests.ps1
git commit -m "test: define workspace image family contracts"
```

---

### Task 2: Add Stable Catalog Entries And Version Locks

**Files:**

- Modify: `configs/versions.lock.env`
- Modify: `workspace-template/image-catalog.json`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add the new image locks**

Insert these lines after the existing `WORKSPACE_IMAGE_TAG` line:

```env
PYTHON_BACKEND_WORKSPACE_IMAGE=workspace-python-backend
PYTHON_BACKEND_WORKSPACE_IMAGE_TAG=python-backend-v20260607-r1
AGENT_DEV_WORKSPACE_IMAGE=workspace-agent-dev
AGENT_DEV_WORKSPACE_IMAGE_TAG=agent-dev-v20260607-r1
```

- [ ] **Step 2: Replace the catalog with all stable profiles**

Write `workspace-template/image-catalog.json` as:

```json
{
  "default": "embedded_stable",
  "profiles": [
    {
      "key": "embedded_stable",
      "name": "Embedded Stable",
      "image": "workspace-embedded:embedded-v20260607-r1"
    },
    {
      "key": "python_backend_stable",
      "name": "Python Backend Stable",
      "image": "workspace-python-backend:python-backend-v20260607-r1"
    },
    {
      "key": "agent_dev_stable",
      "name": "Agent Dev Stable",
      "image": "workspace-agent-dev:agent-dev-v20260607-r1"
    }
  ]
}
```

- [ ] **Step 3: Run the regression test and confirm the remaining failures are script-related**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL on missing script helper/function assertions, while catalog and lock assertions pass.

- [ ] **Step 4: Commit catalog and lock changes**

```bash
git add configs/versions.lock.env workspace-template/image-catalog.json
git commit -m "chore: add workspace image family locks"
```

---

### Task 3: Add PowerShell Workspace Image Family Registry

**Files:**

- Modify: `scripts/manage.ps1`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add a global family parameter**

In the top-level `param(...)` block, add this line after `[string]$Tag = "",`:

```powershell
    [string]$Family = "embedded",
```

- [ ] **Step 2: Replace catalog key helpers with family-aware helpers**

Replace `Get-WorkspaceImageProfileKey` and add the related helpers directly above `Update-WorkspaceImageCatalog`:

```powershell
function Get-WorkspaceImageFamilies {
    return @(
        [pscustomobject]@{
            Family       = 'embedded'
            ProfileKey   = 'embedded_stable'
            DisplayName  = 'Embedded Stable'
            ImageKey     = 'WORKSPACE_IMAGE'
            TagKey       = 'WORKSPACE_IMAGE_TAG'
            DefaultImage = 'workspace-embedded'
            DefaultTag   = 'embedded-v20260607-r1'
            Dockerfile   = 'Dockerfile.workspace'
        },
        [pscustomobject]@{
            Family       = 'python-backend'
            ProfileKey   = 'python_backend_stable'
            DisplayName  = 'Python Backend Stable'
            ImageKey     = 'PYTHON_BACKEND_WORKSPACE_IMAGE'
            TagKey       = 'PYTHON_BACKEND_WORKSPACE_IMAGE_TAG'
            DefaultImage = 'workspace-python-backend'
            DefaultTag   = 'python-backend-v20260607-r1'
            Dockerfile   = 'Dockerfile.workspace-python-backend'
        },
        [pscustomobject]@{
            Family       = 'agent-dev'
            ProfileKey   = 'agent_dev_stable'
            DisplayName  = 'Agent Dev Stable'
            ImageKey     = 'AGENT_DEV_WORKSPACE_IMAGE'
            TagKey       = 'AGENT_DEV_WORKSPACE_IMAGE_TAG'
            DefaultImage = 'workspace-agent-dev'
            DefaultTag   = 'agent-dev-v20260607-r1'
            Dockerfile   = 'Dockerfile.workspace-agent-dev'
        }
    )
}

function Get-WorkspaceImageFamily {
    param([string]$Family)
    $normalized = if ($Family) { $Family.ToLowerInvariant() } else { 'embedded' }
    foreach ($item in Get-WorkspaceImageFamilies) {
        if ($item.Family -eq $normalized) { return $item }
    }
    $valid = ((Get-WorkspaceImageFamilies | ForEach-Object { $_.Family }) -join ', ')
    Write-Fail "Unknown workspace image family '$Family'. Valid values: $valid"
    exit 1
}

function Resolve-WorkspaceImageFamily {
    param(
        [object]$FamilySpec,
        [hashtable]$Config
    )
    $imageName = if ($Config[$FamilySpec.ImageKey]) { $Config[$FamilySpec.ImageKey] } else { $FamilySpec.DefaultImage }
    $tag = if ($Config[$FamilySpec.TagKey]) { $Config[$FamilySpec.TagKey] } else { $FamilySpec.DefaultTag }
    return [pscustomobject]@{
        Family      = $FamilySpec.Family
        ProfileKey  = $FamilySpec.ProfileKey
        DisplayName = $FamilySpec.DisplayName
        ImageName   = $imageName
        Tag         = $tag
        Dockerfile  = $FamilySpec.Dockerfile
    }
}

function Get-WorkspaceImageProfileKey {
    param(
        [string]$ImageName,
        [string]$Tag
    )
    foreach ($family in Get-WorkspaceImageFamilies) {
        if ($ImageName -eq $family.DefaultImage) { return $family.ProfileKey }
    }
    return (($ImageName + '-' + $Tag).ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')
}

function Get-WorkspaceImageProfileName {
    param(
        [string]$ImageName,
        [string]$Tag,
        [string]$ProfileKey
    )
    foreach ($family in Get-WorkspaceImageFamilies) {
        if ($ProfileKey -eq $family.ProfileKey) { return $family.DisplayName }
    }
    return "${ImageName} ${Tag}"
}
```

- [ ] **Step 3: Make catalog updates use fixed stable names**

In `Update-WorkspaceImageCatalog`, replace:

```powershell
$profileName = if ($profileKey -eq 'embedded_stable') { 'Embedded Stable' } else { "${ImageName} ${Tag}" }
```

with:

```powershell
$profileName = Get-WorkspaceImageProfileName -ImageName $ImageName -Tag $Tag -ProfileKey $profileKey
```

- [ ] **Step 4: Run the regression test and confirm Bash still fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL on Bash family helper assertions and any prepare/update behavior not yet implemented.

- [ ] **Step 5: Commit the PowerShell family registry**

```bash
git add scripts/manage.ps1
git commit -m "feat: add PowerShell workspace image families"
```

---

### Task 4: Add Bash Workspace Image Family Registry

**Files:**

- Modify: `scripts/manage.sh`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add Bash family helpers**

Insert these functions above `_workspace_image_profile_key`:

```bash
_workspace_families() {
    printf '%s\n' embedded python-backend agent-dev
}

_workspace_family_profile_key() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' embedded_stable ;;
        python-backend) printf '%s\n' python_backend_stable ;;
        agent-dev) printf '%s\n' agent_dev_stable ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_display_name() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' "Embedded Stable" ;;
        python-backend) printf '%s\n' "Python Backend Stable" ;;
        agent-dev) printf '%s\n' "Agent Dev Stable" ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_image_key() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' WORKSPACE_IMAGE ;;
        python-backend) printf '%s\n' PYTHON_BACKEND_WORKSPACE_IMAGE ;;
        agent-dev) printf '%s\n' AGENT_DEV_WORKSPACE_IMAGE ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_tag_key() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' WORKSPACE_IMAGE_TAG ;;
        python-backend) printf '%s\n' PYTHON_BACKEND_WORKSPACE_IMAGE_TAG ;;
        agent-dev) printf '%s\n' AGENT_DEV_WORKSPACE_IMAGE_TAG ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_default_image() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' workspace-embedded ;;
        python-backend) printf '%s\n' workspace-python-backend ;;
        agent-dev) printf '%s\n' workspace-agent-dev ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_default_tag() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' embedded-v20260607-r1 ;;
        python-backend) printf '%s\n' python-backend-v20260607-r1 ;;
        agent-dev) printf '%s\n' agent-dev-v20260607-r1 ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_dockerfile() {
    case "${1:-embedded}" in
        embedded) printf '%s\n' Dockerfile.workspace ;;
        python-backend) printf '%s\n' Dockerfile.workspace-python-backend ;;
        agent-dev) printf '%s\n' Dockerfile.workspace-agent-dev ;;
        *) fail "Unknown workspace image family '$1'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}

_workspace_family_from_image_name() {
    case "${1:-}" in
        workspace-embedded) printf '%s\n' embedded ;;
        workspace-python-backend) printf '%s\n' python-backend ;;
        workspace-agent-dev) printf '%s\n' agent-dev ;;
        *) return 1 ;;
    esac
}

_workspace_config_value() {
    local key="$1"
    local fallback="$2"
    local value="${!key:-}"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$fallback"
    fi
}

_workspace_resolved_image_name() {
    local family="$1"
    _workspace_config_value "$(_workspace_family_image_key "$family")" "$(_workspace_family_default_image "$family")"
}

_workspace_resolved_tag() {
    local family="$1"
    _workspace_config_value "$(_workspace_family_tag_key "$family")" "$(_workspace_family_default_tag "$family")"
}
```

- [ ] **Step 2: Replace `_workspace_image_profile_key`**

Use this complete function:

```bash
_workspace_image_profile_key() {
    local image_name="${1:-workspace-embedded}"
    local tag="${2:-latest}"
    local family=""
    if family="$(_workspace_family_from_image_name "$image_name")"; then
        _workspace_family_profile_key "$family"
        return 0
    fi
    printf '%s-%s\n' "$image_name" "$tag" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}
```

- [ ] **Step 3: Replace profile name logic in `_update_workspace_image_catalog`**

Replace:

```bash
if [ "$profile_key" = "embedded_stable" ]; then
    profile_name="Embedded Stable"
else
    profile_name="${image_name} ${tag}"
fi
```

with:

```bash
local family_for_name=""
if family_for_name="$(_workspace_family_from_image_name "$image_name")"; then
    profile_name="$(_workspace_family_display_name "$family_for_name")"
else
    profile_name="${image_name} ${tag}"
fi
```

- [ ] **Step 4: Run the regression test and confirm prepare/update tests still fail**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL only on missing prepare/update behavior and missing Dockerfiles/settings.

- [ ] **Step 5: Commit the Bash family registry**

```bash
git add scripts/manage.sh tests/upgrade-scripts.tests.ps1
git commit -m "feat: add Bash workspace image families"
```

---

### Task 5: Build And Manifest All Stable Workspace Images During Prepare

**Files:**

- Modify: `scripts/manage.ps1`
- Modify: `scripts/manage.sh`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add PowerShell manifest entries helper**

Add this function after `Resolve-WorkspaceImageFamily`:

```powershell
function Get-WorkspaceImageManifestEntries {
    param([hashtable]$Config)
    $entries = @()
    foreach ($family in Get-WorkspaceImageFamilies) {
        $resolved = Resolve-WorkspaceImageFamily -FamilySpec $family -Config $Config
        $entries += [ordered]@{
            ref     = "$($resolved.ImageName):$($resolved.Tag)"
            archive = "images/$($resolved.ImageName)_$($resolved.Tag).tar"
        }
    }
    return $entries
}
```

- [ ] **Step 2: Replace `Invoke-PrepareBuildWorkspace`**

Use this complete function:

```powershell
function Invoke-PrepareBuildWorkspace {
    Write-Info '=== Step 3: Building and saving workspace images ==='
    $cfg = Get-Config
    $sslDir = Join-Path $ConfigsDir 'ssl'
    $serverHost = if ($cfg['SERVER_HOST']) { $cfg['SERVER_HOST'] } else { 'localhost' }

    if (-not (Test-Path (Join-Path $sslDir 'ca.crt')) -or -not (Test-Path (Join-Path $sslDir 'server.crt'))) {
        Write-Warn 'Missing CA or leaf certificate. Generating them now.'
        Issue-LeafCertificate -SslDir $sslDir -ServerHost $serverHost | Out-Null
    }

    Write-Info "Pulling build base image $($cfg['CODE_SERVER_BASE_IMAGE_REF'])"
    docker pull $cfg['CODE_SERVER_BASE_IMAGE_REF']
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to pull code-server base image'; exit 1 }

    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null
    foreach ($family in Get-WorkspaceImageFamilies) {
        $resolved = Resolve-WorkspaceImageFamily -FamilySpec $family -Config $cfg
        $dockerfile = Join-Path $DockerDir $resolved.Dockerfile
        if (-not (Test-Path $dockerfile)) { Write-Fail "Workspace Dockerfile missing: $dockerfile"; exit 1 }

        Write-Info "Building $($resolved.ImageName):$($resolved.Tag) from $($resolved.Dockerfile)"
        docker build -f $dockerfile --build-arg "CODE_SERVER_BASE_IMAGE_REF=$($cfg['CODE_SERVER_BASE_IMAGE_REF'])" -t "$($resolved.ImageName):$($resolved.Tag)" $ProjectRoot
        if ($LASTEXITCODE -ne 0) { Write-Fail "Workspace image build failed: $($resolved.ImageName):$($resolved.Tag)"; exit 1 }

        $tarFile = Join-Path $ImagesDir "$($resolved.ImageName)_$($resolved.Tag).tar"
        Write-Info "Saving $($resolved.ImageName):$($resolved.Tag) -> $(Split-Path $tarFile -Leaf)"
        docker save "$($resolved.ImageName):$($resolved.Tag)" -o $tarFile
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to save workspace image: $($resolved.ImageName):$($resolved.Tag)"; exit 1 }
        Write-OK "Saved $(Split-Path $tarFile -Leaf)"
        Update-WorkspaceImageCatalog -ImageName $resolved.ImageName -Tag $resolved.Tag | Out-Null
    }
}
```

- [ ] **Step 3: Update PowerShell manifest generation**

In `Invoke-PrepareWriteManifest`, replace:

```powershell
$wsImage = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
$wsTag   = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
```

with:

```powershell
$workspaceImageEntries = Get-WorkspaceImageManifestEntries -Config $cfg
```

Then remove this single workspace image entry:

```powershell
[ordered]@{ ref = "${wsImage}:${wsTag}"; archive = "images/${wsImage}_${wsTag}.tar" }
```

Build `$images` with explicit append operations:

```powershell
$images = @(
    (& $imageEntry $cfg['CODER_IMAGE_REF']),
    (& $imageEntry $cfg['POSTGRES_IMAGE_REF']),
    (& $imageEntry $cfg['NGINX_IMAGE_REF'])
)
$images += $workspaceImageEntries
```

- [ ] **Step 4: Add Bash manifest helper**

Add this function after `_workspace_resolved_tag`:

```bash
_workspace_manifest_entries_json() {
    load_config
    python3 - <<'PY'
import json
import os

families = [
    ("WORKSPACE_IMAGE", "WORKSPACE_IMAGE_TAG", "workspace-embedded", "embedded-v20260607-r1"),
    ("PYTHON_BACKEND_WORKSPACE_IMAGE", "PYTHON_BACKEND_WORKSPACE_IMAGE_TAG", "workspace-python-backend", "python-backend-v20260607-r1"),
    ("AGENT_DEV_WORKSPACE_IMAGE", "AGENT_DEV_WORKSPACE_IMAGE_TAG", "workspace-agent-dev", "agent-dev-v20260607-r1"),
]
entries = []
for image_key, tag_key, default_image, default_tag in families:
    image = os.environ.get(image_key) or default_image
    tag = os.environ.get(tag_key) or default_tag
    entries.append({"ref": f"{image}:{tag}", "archive": f"images/{image}_{tag}.tar"})
print(json.dumps(entries, ensure_ascii=False))
PY
}
```

- [ ] **Step 5: Replace Bash `_prepare_build_workspace` loop**

Inside `_prepare_build_workspace`, replace the single-image build/save block with:

```bash
for family in $(_workspace_families); do
    local ws_image ws_tag ws_dockerfile tar_file
    ws_image="$(_workspace_resolved_image_name "$family")"
    ws_tag="$(_workspace_resolved_tag "$family")"
    ws_dockerfile="$DOCKER_DIR/$(_workspace_family_dockerfile "$family")"
    [ -f "$ws_dockerfile" ] || fail "Workspace Dockerfile missing: $ws_dockerfile"

    info "Building ${ws_image}:${ws_tag} from $(basename "$ws_dockerfile")"
    docker build \
        -f "$ws_dockerfile" \
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}" \
        -t "${ws_image}:${ws_tag}" \
        "$PROJECT_ROOT"

    tar_file="$IMAGES_DIR/${ws_image}_${ws_tag}.tar"
    info "Saving ${ws_image}:${ws_tag} -> $(basename "$tar_file")"
    docker save -o "$tar_file" "${ws_image}:${ws_tag}"
    ok "Saved $(basename "$tar_file")"
    _update_workspace_image_catalog "$ws_image" "$ws_tag"
done
```

- [ ] **Step 6: Update Bash manifest JSON**

In `_prepare_write_manifest`, remove the single workspace image variables:

```bash
local ws_image="${WORKSPACE_IMAGE:-workspace-embedded}"
local ws_tag="${WORKSPACE_IMAGE_TAG:-latest}"
local ws_tar="${ws_image}_${ws_tag}.tar"
```

Add this local after the platform tar variables:

```bash
local workspace_entries_json
workspace_entries_json="$(_workspace_manifest_entries_json)"
```

Then replace the here-doc based manifest write with this JSON writer:

```bash
MANIFEST_PATH="$MANIFEST_PATH" \
CA_SHA256="$ca_sha256" \
WORKSPACE_ENTRIES_JSON="$workspace_entries_json" \
CODER_TAR="$coder_tar" \
POSTGRES_TAR="$postgres_tar" \
NGINX_TAR="$nginx_tar" \
USE_LLM="$USE_LLM" \
USE_LDAP="$USE_LDAP" \
USE_MINERU="$USE_MINERU" \
USE_DOCTOOLS="$USE_DOCTOOLS" \
USE_SKILLHUB="$USE_SKILLHUB" \
python3 - <<'PY' > "$MANIFEST_PATH"
import json
import os
from datetime import datetime, timezone

def image_archive_name(ref: str) -> str:
    return "images/" + ref.translate(str.maketrans({"/": "_", ":": "_", "@": "_"})) + ".tar"

images = [
    {"ref": os.environ["CODER_IMAGE_REF"], "archive": f"images/{os.environ['CODER_TAR']}"},
    {"ref": os.environ["POSTGRES_IMAGE_REF"], "archive": f"images/{os.environ['POSTGRES_TAR']}"},
    {"ref": os.environ["NGINX_IMAGE_REF"], "archive": f"images/{os.environ['NGINX_TAR']}"},
]
images.extend(json.loads(os.environ["WORKSPACE_ENTRIES_JSON"]))

optional = [
    ("USE_LLM", "LITELLM_IMAGE_REF"),
    ("USE_LDAP", "DEX_IMAGE_REF"),
    ("USE_MINERU", "MINERU_IMAGE_REF"),
    ("USE_DOCTOOLS", "DOCCONV_IMAGE_REF"),
]
for flag, ref_key in optional:
    if os.environ.get(flag, "").lower() == "true":
        ref = os.environ[ref_key]
        images.append({"ref": ref, "archive": image_archive_name(ref)})

if os.environ.get("USE_SKILLHUB", "").lower() == "true":
    for ref in [
        os.environ.get("GITEA_IMAGE_REF") or "gitea/gitea:latest",
        os.environ.get("PYPISERVER_IMAGE_REF") or "pypiserver/pypiserver:latest",
    ]:
        images.append({"ref": ref, "archive": image_archive_name(ref)})

manifest = {
    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    "include_llm": os.environ.get("USE_LLM", "").lower() == "true",
    "include_ldap": os.environ.get("USE_LDAP", "").lower() == "true",
    "include_mineru": os.environ.get("USE_MINERU", "").lower() == "true",
    "include_doctools": os.environ.get("USE_DOCTOOLS", "").lower() == "true",
    "include_skillhub": os.environ.get("USE_SKILLHUB", "").lower() == "true",
    "terraform_cli_config_mount_default": "../configs/terraform-offline.rc",
    "ca_sha256": os.environ.get("CA_SHA256", ""),
    "images": images,
    "providers": [
        {
            "source": "registry.terraform.io/coder/coder",
            "version": os.environ["TF_PROVIDER_CODER_VERSION"],
            "archive": f"configs/provider-mirror/registry.terraform.io/coder/coder/{os.environ['TF_PROVIDER_CODER_VERSION']}/linux_amd64/terraform-provider-coder_{os.environ['TF_PROVIDER_CODER_VERSION']}_linux_amd64.zip",
        },
        {
            "source": "registry.terraform.io/kreuzwerker/docker",
            "version": os.environ["TF_PROVIDER_DOCKER_VERSION"],
            "archive": f"configs/provider-mirror/registry.terraform.io/kreuzwerker/docker/{os.environ['TF_PROVIDER_DOCKER_VERSION']}/linux_amd64/terraform-provider-docker_{os.environ['TF_PROVIDER_DOCKER_VERSION']}_linux_amd64.zip",
        },
    ],
}
json.dump(manifest, open(os.environ["MANIFEST_PATH"], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(os.environ["MANIFEST_PATH"], "a", encoding="utf-8").write("\n")
PY
```

Keep the existing `ok "Wrote $MANIFEST_PATH"` line after the Python writer.

- [ ] **Step 7: Run the regression test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL only on `update-workspace` family behavior and missing Dockerfiles/settings.

- [ ] **Step 8: Commit prepare and manifest behavior**

```bash
git add scripts/manage.ps1 scripts/manage.sh
git commit -m "feat: prepare all stable workspace images"
```

---

### Task 6: Make Workspace-Only Releases Family-Aware

**Files:**

- Modify: `scripts/manage.ps1`
- Modify: `scripts/manage.sh`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add PowerShell lock update helper**

Replace `Update-LockWorkspaceTag` with this complete function:

```powershell
function Update-LockWorkspaceFamily {
    param(
        [object]$FamilySpec,
        [string]$ImageName,
        [string]$NewTag
    )
    $lockContent = Get-Content $LockFile -Raw
    foreach ($pair in @(
        @{ Key = $FamilySpec.ImageKey; Value = $ImageName },
        @{ Key = $FamilySpec.TagKey; Value = $NewTag }
    )) {
        if ($lockContent -match "(?m)^$($pair.Key)=") {
            $lockContent = $lockContent -replace "(?m)^$($pair.Key)=.*", "$($pair.Key)=$($pair.Value)"
        } else {
            $lockContent += "`r`n$($pair.Key)=$($pair.Value)"
        }
    }
    [System.IO.File]::WriteAllText($LockFile, $lockContent, [System.Text.UTF8Encoding]::new($false))
    Write-OK "Updated $($FamilySpec.ImageKey)=$ImageName and $($FamilySpec.TagKey)=$NewTag in versions.lock.env"
}
```

- [ ] **Step 2: Add family-specific default tag helper**

Add this function before `Invoke-UpdateWorkspace`:

```powershell
function New-WorkspaceFamilyTag {
    param([object]$FamilySpec)
    $date = Get-Date -Format 'yyyyMMdd'
    switch ($FamilySpec.Family) {
        'embedded'       { return "embedded-v${date}-r1" }
        'python-backend' { return "python-backend-v${date}-r1" }
        'agent-dev'      { return "agent-dev-v${date}-r1" }
        default          { return "workspace-v${date}-r1" }
    }
}
```

- [ ] **Step 3: Replace `Invoke-UpdateWorkspace`**

Use this complete function:

```powershell
function Invoke-UpdateWorkspace {
    param(
        [string]$NewTag = '',
        [string]$FamilyName = 'embedded'
    )

    $familySpec = Get-WorkspaceImageFamily -Family $FamilyName
    if (-not $NewTag) {
        $NewTag = New-WorkspaceFamilyTag -FamilySpec $familySpec
        Write-Info "No tag specified, using auto-generated: $NewTag"
    }

    Assert-Docker
    Initialize-Dirs
    if (-not (Test-Path $EnvFile)) { Write-Fail 'Run init first.'; exit 1 }
    $cfg = Get-Config
    $resolved = Resolve-WorkspaceImageFamily -FamilySpec $familySpec -Config $cfg
    $imageName = $resolved.ImageName

    $sslDir = Join-Path $ConfigsDir 'ssl'
    Ensure-RootCA -SslDir $sslDir | Out-Null
    $codeServerBase = $cfg['CODE_SERVER_BASE_IMAGE_REF']
    $dockerfile = Join-Path $DockerDir $familySpec.Dockerfile
    if (-not (Test-Path $dockerfile)) { Write-Fail "Workspace Dockerfile missing: $dockerfile"; exit 1 }

    Write-Info "Building ${imageName}:${NewTag} from $($familySpec.Dockerfile)"
    docker build -f $dockerfile --build-arg "CODE_SERVER_BASE_IMAGE_REF=$codeServerBase" -t "${imageName}:${NewTag}" $ProjectRoot
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Workspace image build failed.'; exit 1 }
    Write-OK "Built ${imageName}:${NewTag}"

    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null
    $tarFile = Join-Path $ImagesDir "${imageName}_${NewTag}.tar"
    Write-Info "Saving ${imageName}:${NewTag} -> $(Split-Path $tarFile -Leaf)"
    docker save "${imageName}:${NewTag}" -o $tarFile
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to save workspace image.'; exit 1 }
    $sizeMb = [math]::Round((Get-Item $tarFile).Length / 1MB)
    Write-OK "Saved ${sizeMb} MB  ($(Split-Path $tarFile -Leaf))"

    Update-LockWorkspaceFamily -FamilySpec $familySpec -ImageName $imageName -NewTag $NewTag
    Update-WorkspaceImageCatalog -ImageName $imageName -Tag $NewTag | Out-Null

    Write-Host ''
    Write-OK "Workspace image prepared: ${imageName}:${NewTag}"
    Write-Info "Transfer $(Split-Path $tarFile -Leaf), configs\versions.lock.env, and workspace-template\image-catalog.json to the offline server."
    Write-Info "Then run: .\scripts\manage.ps1 load-workspace $(Split-Path $tarFile -Leaf)"
    Write-Info "Publish as a staged Coder version: .\scripts\manage.ps1 push-template -Name workspace-${NewTag}"
    Write-Info "Promote after validation in the Coder UI or with: coder templates versions promote --template=embedded-dev --template-version=workspace-${NewTag}"
}
```

- [ ] **Step 4: Wire PowerShell CLI family argument and help**

Change the switch arm to:

```powershell
'update-workspace'      { Invoke-UpdateWorkspace -NewTag $Tag -FamilyName $Family; break }
```

Update help text:

```text
  update-workspace [-Family embedded|python-backend|agent-dev] [-Tag v]
                              Build one workspace image family, save tar, update catalog
```

Add this flag description:

```text
  -Family <f>  Workspace image family for update-workspace: embedded, python-backend, agent-dev
```

- [ ] **Step 5: Add Bash lock update and tag helpers**

Replace `_update_lock_workspace_tag` with:

```bash
_update_lock_workspace_family() {
    local family="$1"
    local image_name="$2"
    local new_tag="$3"
    local image_key tag_key
    image_key="$(_workspace_family_image_key "$family")"
    tag_key="$(_workspace_family_tag_key "$family")"

    if grep -q "^${image_key}=" "$LOCK_FILE"; then
        sed -i "s|^${image_key}=.*|${image_key}=${image_name}|" "$LOCK_FILE"
    else
        printf '\n%s=%s\n' "$image_key" "$image_name" >> "$LOCK_FILE"
    fi
    if grep -q "^${tag_key}=" "$LOCK_FILE"; then
        sed -i "s|^${tag_key}=.*|${tag_key}=${new_tag}|" "$LOCK_FILE"
    else
        printf '%s=%s\n' "$tag_key" "$new_tag" >> "$LOCK_FILE"
    fi
    ok "Updated ${image_key}=${image_name} and ${tag_key}=${new_tag} in $(basename "$LOCK_FILE")"
}

_new_workspace_family_tag() {
    local family="$1"
    local date_part
    date_part="$(date +%Y%m%d)"
    case "$family" in
        embedded) printf 'embedded-v%s-r1\n' "$date_part" ;;
        python-backend) printf 'python-backend-v%s-r1\n' "$date_part" ;;
        agent-dev) printf 'agent-dev-v%s-r1\n' "$date_part" ;;
        *) fail "Unknown workspace image family '$family'. Valid values: embedded, python-backend, agent-dev" ;;
    esac
}
```

- [ ] **Step 6: Replace Bash `update_workspace`**

Use this complete function:

```bash
update_workspace() {
    local new_tag=""
    local family="embedded"
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag) shift; new_tag="${1:-}" ;;
            --family) shift; family="${1:-embedded}" ;;
        esac
        shift
    done

    _workspace_family_profile_key "$family" >/dev/null
    if [ -z "$new_tag" ]; then
        new_tag="$(_new_workspace_family_tag "$family")"
        info "No tag specified, using auto-generated: $new_tag"
    fi

    check_deps
    init_dirs
    [ -f "$ENV_FILE" ] || fail "Run init first."
    load_config

    local image_name dockerfile
    image_name="$(_workspace_resolved_image_name "$family")"
    dockerfile="$DOCKER_DIR/$(_workspace_family_dockerfile "$family")"
    [ -f "$dockerfile" ] || fail "Workspace Dockerfile missing: $dockerfile"

    ensure_root_ca "$CONFIGS_DIR/ssl"
    info "Building ${image_name}:${new_tag} from $(basename "$dockerfile")"
    docker build \
        -f "$dockerfile" \
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=${CODE_SERVER_BASE_IMAGE_REF}" \
        -t "${image_name}:${new_tag}" \
        "$PROJECT_ROOT"
    ok "Built ${image_name}:${new_tag}"

    mkdir -p "$IMAGES_DIR"
    local tar_file="$IMAGES_DIR/${image_name}_${new_tag}.tar"
    info "Saving ${image_name}:${new_tag} -> $(basename "$tar_file")"
    docker save -o "$tar_file" "${image_name}:${new_tag}"
    local saved_bytes
    saved_bytes="$(stat -c%s "$tar_file" 2>/dev/null || stat -f%z "$tar_file" 2>/dev/null || echo 0)"
    ok "Saved $(( saved_bytes / 1048576 )) MB  ($(basename "$tar_file"))"

    _update_lock_workspace_family "$family" "$image_name" "$new_tag"
    _update_workspace_image_catalog "$image_name" "$new_tag"

    echo
    ok "Workspace image prepared: ${image_name}:${new_tag}"
    info "Transfer $(basename "$tar_file"), configs/versions.lock.env, and workspace-template/image-catalog.json to the offline server."
    info "Then run: bash scripts/manage.sh load-workspace $(basename "$tar_file")"
    info "Publish as a staged Coder version: bash scripts/manage.sh push-template --name workspace-${new_tag}"
    info "Promote after validation in the Coder UI or with: coder templates versions promote --template=embedded-dev --template-version=workspace-${new_tag}"
}
```

- [ ] **Step 7: Update Bash help**

Change help text:

```text
  update-workspace [--family embedded|python-backend|agent-dev] [--tag <tag>]
                        Build one workspace image family, save tar, update lock
                        and image catalog (tag defaults to <family>-v<YYYYMMDD>-r1)
```

Update the workflow example:

```text
  manage.sh update-workspace --family python-backend --tag python-backend-v20260608-r1
```

- [ ] **Step 8: Run the regression test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL only on missing Dockerfiles/settings or docs assertions added later.

- [ ] **Step 9: Commit family-aware release commands**

```bash
git add scripts/manage.ps1 scripts/manage.sh
git commit -m "feat: release workspace images by family"
```

---

### Task 7: Add Python Backend And Agent Development Images

**Files:**

- Create: `docker/Dockerfile.workspace-python-backend`
- Create: `docker/Dockerfile.workspace-agent-dev`
- Create: `configs/settings-python-backend.json`
- Create: `configs/settings-agent-dev.json`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Create Python backend settings**

Create `configs/settings-python-backend.json`:

```json
{
    "workbench.colorTheme": "Dark+",
    "workbench.iconTheme": "vscode-icons",
    "editor.fontSize": 14,
    "editor.fontFamily": "'Fira Code', 'Courier New', monospace",
    "editor.fontLigatures": true,
    "editor.tabSize": 4,
    "editor.insertSpaces": true,
    "editor.detectIndentation": true,
    "editor.formatOnSave": true,
    "editor.formatOnPaste": true,
    "files.autoSave": "afterDelay",
    "files.autoSaveDelay": 1000,
    "files.exclude": {
        "**/.git": true,
        "**/.DS_Store": true,
        "**/.venv": true,
        "**/__pycache__": true,
        "**/.pytest_cache": true,
        "**/node_modules": true,
        "**/dist": true
    },
    "terminal.integrated.defaultProfile.linux": "bash",
    "terminal.integrated.profiles.linux": {
        "bash": {
            "path": "/bin/bash"
        }
    },
    "python.defaultInterpreterPath": "/usr/bin/python3",
    "python.terminal.activateEnvironment": true,
    "python.testing.pytestEnabled": true,
    "python.testing.unittestEnabled": false,
    "ruff.enable": true
}
```

- [ ] **Step 2: Create agent development settings**

Create `configs/settings-agent-dev.json`:

```json
{
    "workbench.colorTheme": "Dark+",
    "workbench.iconTheme": "vscode-icons",
    "editor.fontSize": 14,
    "editor.fontFamily": "'Fira Code', 'Courier New', monospace",
    "editor.fontLigatures": true,
    "editor.tabSize": 4,
    "editor.insertSpaces": true,
    "editor.detectIndentation": true,
    "editor.formatOnSave": true,
    "editor.formatOnPaste": true,
    "files.autoSave": "afterDelay",
    "files.autoSaveDelay": 1000,
    "files.exclude": {
        "**/.git": true,
        "**/.DS_Store": true,
        "**/.venv": true,
        "**/__pycache__": true,
        "**/.pytest_cache": true,
        "**/node_modules": true,
        "**/dist": true,
        "**/.playwright": true
    },
    "terminal.integrated.defaultProfile.linux": "bash",
    "terminal.integrated.profiles.linux": {
        "bash": {
            "path": "/bin/bash"
        }
    },
    "python.defaultInterpreterPath": "/usr/bin/python3",
    "python.terminal.activateEnvironment": true,
    "python.testing.pytestEnabled": true,
    "python.testing.unittestEnabled": false,
    "ruff.enable": true
}
```

- [ ] **Step 3: Create Python backend Dockerfile**

Create `docker/Dockerfile.workspace-python-backend`:

```dockerfile
ARG CODE_SERVER_BASE_IMAGE_REF=codercom/code-server:latest
FROM ${CODE_SERVER_BASE_IMAGE_REF}

USER root

RUN if [ -f /etc/apt/sources.list ] && grep -q "ubuntu" /etc/apt/sources.list 2>/dev/null; then \
        sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list && \
        sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list; \
    elif [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list.d/debian.sources && \
        sed -i 's|http://security.debian.org/debian-security|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list.d/debian.sources; \
    elif [ -f /etc/apt/sources.list ]; then \
        sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list && \
        sed -i 's|http://security.debian.org|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list; \
    fi

RUN printf 'Acquire::http::Timeout "120";\nAcquire::https::Timeout "120";\nAcquire::Retries "5";\n' \
    > /etc/apt/apt.conf.d/99network-resilience

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    git-lfs \
    vim \
    nano \
    htop \
    tree \
    jq \
    unzip \
    zip \
    build-essential \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    pipx \
    postgresql-client \
    redis-tools \
    sqlite3 \
    libpq-dev \
    openssh-client \
    pandoc \
    graphviz \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages \
    uv \
    ruff \
    black \
    pytest \
    pytest-cov \
    coverage \
    ipython \
    httpie \
    fastapi \
    "uvicorn[standard]" \
    pydantic \
    sqlalchemy \
    alembic \
    "psycopg[binary]" \
    redis \
    requests \
    httpx

ENV CODE_SERVER_EXTENSIONS_SEED=/opt/code-server-extensions-seed
RUN mkdir -p ${CODE_SERVER_EXTENSIONS_SEED}

RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension ms-python.python \
    || echo "[WARN] Python extension not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension charliermarsh.ruff \
    || echo "[WARN] Ruff extension not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension redhat.vscode-yaml \
    || echo "[WARN] YAML extension not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension eamodio.gitlens \
    || echo "[WARN] GitLens not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension mhutchie.git-graph \
    || echo "[WARN] Git Graph not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension pkief.material-icon-theme \
    || echo "[WARN] material icon theme not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension usernamehw.errorlens \
    || echo "[WARN] Error Lens not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension christian-kohler.path-intellisense \
    || echo "[WARN] path-intellisense not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension yzhang.markdown-all-in-one \
    || echo "[WARN] markdown-all-in-one not available, skipping"

RUN mkdir -p /tmp/vsix
COPY configs/vsix/ /tmp/vsix/
RUN if ls /tmp/vsix/*.vsix 1>/dev/null 2>&1; then \
        for vsix in /tmp/vsix/*.vsix; do \
            echo "Installing: $vsix" && \
            code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension "$vsix" || echo "Failed: $vsix"; \
        done; \
    else \
        echo "[INFO] No VSIX files, skipping offline install"; \
    fi

RUN mkdir -p /usr/local/share/ca-certificates
COPY configs/ssl/ca.crt /tmp/coder-root-ca.crt
RUN if [ -f /tmp/coder-root-ca.crt ]; then \
        cp /tmp/coder-root-ca.crt /usr/local/share/ca-certificates/coder-platform-root-ca.crt && \
        update-ca-certificates 2>/dev/null && \
        echo "[INFO] Coder platform root CA trusted in workspace image"; \
    else \
        echo "[INFO] No CA cert found (run manage.ps1 ssl or manage.sh ssl before build)"; \
    fi && \
    rm -f /tmp/coder-root-ca.crt

COPY --chown=coder:coder configs/settings-python-backend.json /home/coder/.local/share/code-server/User/settings.json

RUN printf '# ==== Python Backend Dev Environment ====\n\
alias py="python3"\n\
alias venv="python3 -m venv .venv"\n\
alias activate=". .venv/bin/activate"\n\
alias test="pytest -q"\n\
alias cov="pytest --cov=. --cov-report=term-missing"\n\
alias lint="ruff check ."\n\
alias fmt="ruff format ."\n\
alias serve="uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload"\n\
' > /etc/profile.d/python-backend-dev.sh \
    && cat /etc/profile.d/python-backend-dev.sh >> /etc/bash.bashrc

COPY scripts/workspace-startup.sh /opt/workspace-startup.sh
RUN sed -i 's/\r$//' /opt/workspace-startup.sh && chmod +x /opt/workspace-startup.sh

ENV SHELL=/bin/bash
WORKDIR /home/coder
```

- [ ] **Step 4: Create agent development Dockerfile**

Create `docker/Dockerfile.workspace-agent-dev`:

```dockerfile
ARG CODE_SERVER_BASE_IMAGE_REF=codercom/code-server:latest
FROM ${CODE_SERVER_BASE_IMAGE_REF}

USER root

RUN if [ -f /etc/apt/sources.list ] && grep -q "ubuntu" /etc/apt/sources.list 2>/dev/null; then \
        sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list && \
        sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list; \
    elif [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list.d/debian.sources && \
        sed -i 's|http://security.debian.org/debian-security|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list.d/debian.sources; \
    elif [ -f /etc/apt/sources.list ]; then \
        sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list && \
        sed -i 's|http://security.debian.org|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list; \
    fi

RUN printf 'Acquire::http::Timeout "120";\nAcquire::https::Timeout "120";\nAcquire::Retries "5";\n' \
    > /etc/apt/apt.conf.d/99network-resilience

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    git-lfs \
    vim \
    nano \
    htop \
    tree \
    jq \
    unzip \
    zip \
    build-essential \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    pipx \
    openssh-client \
    postgresql-client \
    redis-tools \
    sqlite3 \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    pandoc \
    graphviz \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_MAJOR=22
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages \
    uv \
    ruff \
    pytest \
    pytest-cov \
    ipython \
    httpie \
    requests \
    httpx \
    fastapi \
    pydantic \
    openai \
    anthropic \
    mcp \
    langchain \
    langgraph \
    playwright

RUN python3 -m playwright install chromium \
    || echo "[WARN] Playwright browser download failed, install manually if needed"

RUN npm install -g @anthropic-ai/claude-code \
    || echo "[WARN] claude-code install failed, skipping"
RUN npm install -g opencode-ai \
    || echo "[WARN] opencode install failed, skipping"
RUN npm install -g @openai/codex \
    || echo "[WARN] codex install failed, skipping"
RUN npm install -g @kilocode/cli \
    || echo "[WARN] kilo-code CLI install failed, skipping"
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent
RUN PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 pi install npm:pi-provider-litellm

ENV CODE_SERVER_EXTENSIONS_SEED=/opt/code-server-extensions-seed
RUN mkdir -p ${CODE_SERVER_EXTENSIONS_SEED}

RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension ms-python.python \
    || echo "[WARN] Python extension not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension charliermarsh.ruff \
    || echo "[WARN] Ruff extension not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension openai.chatgpt \
    || echo "[INFO] OpenAI Codex extension not in marketplace, use VSIX instead"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension anthropic.claude-code \
    || echo "[INFO] Claude Code extension not in marketplace, use VSIX instead"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension saoudrizwan.claude-dev \
    || echo "[INFO] Cline not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension RooVeterinaryInc.roo-cline \
    || echo "[WARN] Roo Code not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension kilocode.kilo-code \
    || echo "[WARN] Kilo Code not available, use VSIX instead"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension redhat.vscode-yaml \
    || echo "[WARN] YAML extension not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension eamodio.gitlens \
    || echo "[WARN] GitLens not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension mhutchie.git-graph \
    || echo "[WARN] Git Graph not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension pkief.material-icon-theme \
    || echo "[WARN] material icon theme not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension usernamehw.errorlens \
    || echo "[WARN] Error Lens not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension bierner.markdown-mermaid \
    || echo "[WARN] markdown-mermaid not available, skipping"
RUN code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension yzhang.markdown-all-in-one \
    || echo "[WARN] markdown-all-in-one not available, skipping"

RUN mkdir -p /tmp/vsix
COPY configs/vsix/ /tmp/vsix/
RUN if ls /tmp/vsix/*.vsix 1>/dev/null 2>&1; then \
        for vsix in /tmp/vsix/*.vsix; do \
            echo "Installing: $vsix" && \
            code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} --install-extension "$vsix" || echo "Failed: $vsix"; \
        done; \
    else \
        echo "[INFO] No VSIX files, skipping offline install"; \
    fi

RUN mkdir -p /usr/local/share/ca-certificates
COPY configs/ssl/ca.crt /tmp/coder-root-ca.crt
RUN if [ -f /tmp/coder-root-ca.crt ]; then \
        cp /tmp/coder-root-ca.crt /usr/local/share/ca-certificates/coder-platform-root-ca.crt && \
        update-ca-certificates 2>/dev/null && \
        echo "[INFO] Coder platform root CA trusted in workspace image"; \
    else \
        echo "[INFO] No CA cert found (run manage.ps1 ssl or manage.sh ssl before build)"; \
    fi && \
    rm -f /tmp/coder-root-ca.crt

COPY --chown=coder:coder configs/settings-agent-dev.json /home/coder/.local/share/code-server/User/settings.json

RUN printf '# ==== Agent Dev Environment ====\n\
export PI_OFFLINE=1\n\
export PI_SKIP_VERSION_CHECK=1\n\
export PI_TELEMETRY=0\n\
alias py="python3"\n\
alias venv="python3 -m venv .venv"\n\
alias activate=". .venv/bin/activate"\n\
alias test="pytest -q"\n\
alias lint="ruff check ."\n\
alias fmt="ruff format ."\n\
alias pwtest="python3 -m pytest -q"\n\
alias node-test="npm test"\n\
' > /etc/profile.d/agent-dev.sh \
    && cat /etc/profile.d/agent-dev.sh >> /etc/bash.bashrc

COPY scripts/workspace-startup.sh /opt/workspace-startup.sh
RUN sed -i 's/\r$//' /opt/workspace-startup.sh && chmod +x /opt/workspace-startup.sh

ENV SHELL=/bin/bash
WORKDIR /home/coder
```

- [ ] **Step 5: Add static assertions for new Dockerfiles**

In `Test-WorkspaceAiToolingStaticContracts`, add these reads:

```powershell
$pythonDockerfile = Get-Content (Join-Path $RepoRoot 'docker/Dockerfile.workspace-python-backend') -Raw
$agentDockerfile = Get-Content (Join-Path $RepoRoot 'docker/Dockerfile.workspace-agent-dev') -Raw
$pythonSettings = Get-Content (Join-Path $RepoRoot 'configs/settings-python-backend.json') -Raw
$agentSettings = Get-Content (Join-Path $RepoRoot 'configs/settings-agent-dev.json') -Raw
```

Add these assertions before the function closes:

```powershell
Assert-True 'Python backend image installs backend tooling' (
    $pythonDockerfile -match 'uv' -and
    $pythonDockerfile -match 'ruff' -and
    $pythonDockerfile -match 'pytest' -and
    $pythonDockerfile -match 'fastapi' -and
    $pythonDockerfile -match 'postgresql-client' -and
    $pythonDockerfile -match 'redis-tools'
)
Assert-True 'agent dev image installs AI agent tooling' (
    $agentDockerfile -match '@anthropic-ai/claude-code' -and
    $agentDockerfile -match '@openai/codex' -and
    $agentDockerfile -match '@kilocode/cli' -and
    $agentDockerfile -match '@earendil-works/pi-coding-agent' -and
    $agentDockerfile -match 'pi install npm:pi-provider-litellm' -and
    $agentDockerfile -match 'playwright'
)
Assert-True 'Python backend settings avoid embedded compiler defaults' (
    $pythonSettings -match 'python.defaultInterpreterPath' -and
    $pythonSettings -notmatch 'arm-none-eabi'
)
Assert-True 'agent dev settings avoid embedded compiler defaults' (
    $agentSettings -match 'python.defaultInterpreterPath' -and
    $agentSettings -notmatch 'arm-none-eabi'
)
```

- [ ] **Step 6: Run the regression test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: PASS for static tests if all previous tasks are complete.

- [ ] **Step 7: Run connected Dockerfile smoke builds when network is available**

Run:

```powershell
docker build -f docker\Dockerfile.workspace-python-backend --build-arg CODE_SERVER_BASE_IMAGE_REF=codercom/code-server:latest -t workspace-python-backend:plan-smoke .
docker build -f docker\Dockerfile.workspace-agent-dev --build-arg CODE_SERVER_BASE_IMAGE_REF=codercom/code-server:latest -t workspace-agent-dev:plan-smoke .
```

Expected: both builds exit 0. If marketplace extension downloads fail, they should be logged as warnings because each extension install command is guarded with `|| echo`.

- [ ] **Step 8: Commit image definitions**

```bash
git add docker/Dockerfile.workspace-python-backend docker/Dockerfile.workspace-agent-dev configs/settings-python-backend.json configs/settings-agent-dev.json tests/upgrade-scripts.tests.ps1
git commit -m "feat: add Python and agent workspace images"
```

---

### Task 8: Update User-Facing Documentation

**Files:**

- Modify: `README.md`
- Modify: `docs/offline-image-release-management.md`
- Test: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Update README workspace image section**

In the workspace image versioning section, add this text after the paragraph that explains `image-catalog.json`:

```markdown
The template exposes three stable workspace profiles:

| Profile | Image family | Intended use |
|---------|--------------|--------------|
| `embedded_stable` | `workspace-embedded` | Embedded C/C++ development |
| `python_backend_stable` | `workspace-python-backend` | Python backend services, APIs, tests, and database clients |
| `agent_dev_stable` | `workspace-agent-dev` | Interactive agent, MCP, and AI tooling development |

`embedded_stable` remains the default. `prepare` builds and saves all stable
workspace profiles so an offline deployment does not expose a profile whose
image was not transferred.
```

- [ ] **Step 2: Update README update workflow examples**

Replace the single-family examples with this Markdown text:

```markdown
Windows:

    .\scripts\manage.ps1 update-workspace -Family embedded -Tag embedded-v20260608-r1
    .\scripts\manage.ps1 update-workspace -Family python-backend -Tag python-backend-v20260608-r1
    .\scripts\manage.ps1 update-workspace -Family agent-dev -Tag agent-dev-v20260608-r1

Linux:

    bash scripts/manage.sh update-workspace --family embedded --tag embedded-v20260608-r1
    bash scripts/manage.sh update-workspace --family python-backend --tag python-backend-v20260608-r1
    bash scripts/manage.sh update-workspace --family agent-dev --tag agent-dev-v20260608-r1
```

- [ ] **Step 3: Update the offline image release runbook**

Add this text to the multi-image strategy or release model section:

```markdown
This deployment currently treats embedded, Python backend, and interactive agent
development as three stable profiles in one Coder template. They share the same
workspace contract: Coder agent, code-server app, persistent home volume,
resource parameters, CA trust, Git identity, and model gateway variables.

The stable profile mapping is fixed:

| Profile key | Docker image | Tag pattern |
|-------------|--------------|-------------|
| `embedded_stable` | `workspace-embedded` | `embedded-vYYYYMMDD-rN` |
| `python_backend_stable` | `workspace-python-backend` | `python-backend-vYYYYMMDD-rN` |
| `agent_dev_stable` | `workspace-agent-dev` | `agent-dev-vYYYYMMDD-rN` |

Use `update-workspace --family <family>` to release one image family without
changing the other stable profiles. Use full `prepare` when building a complete
offline bundle; it includes all stable workspace profiles by default.
```

- [ ] **Step 4: Add documentation assertions**

In `Test-ManageBashAndDocsStaticContracts`, add:

```powershell
$readme = Get-Content (Join-Path $RepoRoot 'README.md') -Raw
$imageRunbook = Get-Content (Join-Path $RepoRoot 'docs/offline-image-release-management.md') -Raw
Assert-True 'README documents stable workspace profiles' (
    $readme -match 'python_backend_stable' -and
    $readme -match 'agent_dev_stable' -and
    $readme -match 'prepare.*all stable workspace profiles'
)
Assert-True 'image runbook documents workspace family release policy' (
    $imageRunbook -match 'workspace-python-backend' -and
    $imageRunbook -match 'workspace-agent-dev' -and
    $imageRunbook -match 'update-workspace --family'
)
```

- [ ] **Step 5: Run the regression test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: PASS.

- [ ] **Step 6: Commit documentation changes**

```bash
git add README.md docs/offline-image-release-management.md tests/upgrade-scripts.tests.ps1
git commit -m "docs: describe workspace image profiles"
```

---

### Task 9: Final Verification And Release Notes Check

**Files:**

- Review only unless a previous task missed a doc or test update.
- Test: all changed files.

- [ ] **Step 1: Check working tree scope**

Run:

```powershell
git status --short
```

Expected: only files intentionally changed by this plan are listed. If unrelated user changes are present, do not stage them.

- [ ] **Step 2: Run static regression tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: `upgrade script regression tests passed`.

- [ ] **Step 3: Validate JSON files**

Run:

```powershell
@(
  'workspace-template\image-catalog.json',
  'configs\settings-python-backend.json',
  'configs\settings-agent-dev.json'
) | ForEach-Object {
  Get-Content $_ -Raw | ConvertFrom-Json | Out-Null
  Write-Host "valid json: $_"
}
```

Expected: three `valid json:` lines and exit 0.

- [ ] **Step 4: Smoke-test Bash helper loading**

Run:

```powershell
bash -lc "source scripts/manage.sh __test_source_only 2>/dev/null || true; _workspace_families; _workspace_image_profile_key workspace-python-backend python-backend-v20260608-r1; _workspace_image_profile_key workspace-agent-dev agent-dev-v20260608-r1"
```

Expected output contains:

```text
embedded
python-backend
agent-dev
python_backend_stable
agent_dev_stable
```

- [ ] **Step 5: Inspect final diff**

Run:

```powershell
git diff --stat HEAD
git diff --check
```

Expected: no whitespace errors from `git diff --check`.

- [ ] **Step 6: Commit any final fixes**

If the previous steps required small corrections, stage only the files changed by this plan:

```bash
git add configs/versions.lock.env workspace-template/image-catalog.json scripts/manage.ps1 scripts/manage.sh tests/upgrade-scripts.tests.ps1 docker/Dockerfile.workspace-python-backend docker/Dockerfile.workspace-agent-dev configs/settings-python-backend.json configs/settings-agent-dev.json README.md docs/offline-image-release-management.md
git commit -m "chore: verify workspace image profiles"
```

Expected: commit succeeds, or no commit is needed because all checks already passed.
