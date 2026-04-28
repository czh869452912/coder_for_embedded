# Optional Service Switches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make optional service flags consistently control image preparation, image loading, Compose profiles, template app visibility, documentation, and tests.

**Architecture:** Introduce a small service metadata layer in both management scripts, then reuse it from `pull`, `save`, `prepare`, `load`, `up`, `down`, manifest writing, and template publishing. Keep Docker Compose service definitions mostly unchanged; align behavior at the script/template contract boundaries.

**Tech Stack:** PowerShell 5.1, Bash, Docker Compose, Terraform/Coder template, Markdown docs, existing static regression tests.

---

## File Structure

- Modify `scripts/manage.ps1`: service metadata helpers, selected-image resolution, `load` filtering, LDAP prepare/manifest support, Dex refresh, template variables, PowerShell SkillHub parity.
- Modify `scripts/manage.sh`: service metadata helpers, selected-image resolution, `load` filtering, LDAP prepare/manifest support, Dex refresh, template variables, help text cleanup.
- Modify `workspace-template/main.tf`: add enable variables and conditionally create optional app links.
- Modify `tests/upgrade-scripts.tests.ps1`: add static contract tests that fail on the current mismatches.
- Modify `README.md`: update optional service command examples and offline workflow.
- Modify `docs/upgrade-in-place.md`: remove fake `load` flag wording and replace with real selected-load semantics.
- Leave `configs/versions.lock.env` unchanged in this repair; do not run networked digest refresh as part of the implementation.

---

### Task 1: Add Regression Tests First

**Files:**
- Modify: `tests/upgrade-scripts.tests.ps1`

- [ ] **Step 1: Add failing static assertions for optional service parity**

Add assertions to `Test-ManagePowerShellStaticContracts`:

```powershell
Assert-True 'manage.ps1 prepare includes LDAP Dex image' ($text -match 'function Invoke-PrepareSavePlatformImages[\s\S]*UseLdap[\s\S]*DEX_IMAGE_REF')
Assert-True 'manage.ps1 manifest includes LDAP flag' ($text -match 'include_ldap\s*=\s*\[bool\]\$script:UseLdap')
Assert-True 'manage.ps1 manifest includes LDAP Dex image' ($text -match 'function Invoke-PrepareWriteManifest[\s\S]*UseLdap[\s\S]*DEX_IMAGE_REF')
Assert-True 'manage.ps1 load does not blindly load every tar' ($text -match 'Get-SelectedImageSpecs' -and $text -notmatch 'foreach \(\$tarFile in \$tarFiles\)\s*\{[\s\S]*docker load -i \$tarFile\.FullName')
Assert-True 'manage.ps1 exposes SkillHub preparation commands' ($text -match "'skillhub-prepare'" -and $text -match "'skillhub-refresh'")
Assert-True 'manage.ps1 refresh includes Dex digest target' ($text -match "RefKey = 'DEX_IMAGE_REF'")
```

Add assertions to `Test-ManageBashAndDocsStaticContracts`:

```powershell
Assert-True 'manage.sh prepare includes LDAP Dex image' ($manage -match '_prepare_save_platform_images\(\)[\s\S]*USE_LDAP[\s\S]*DEX_IMAGE_REF')
Assert-True 'manage.sh manifest includes LDAP flag' ($manage -match '"include_ldap": \$\{USE_LDAP,,\}')
Assert-True 'manage.sh manifest includes LDAP Dex image' ($manage -match '_prepare_write_manifest\(\)[\s\S]*USE_LDAP[\s\S]*DEX_IMAGE_REF')
Assert-True 'manage.sh load does not blindly load every tar' ($manage -match '_selected_image_refs' -and $manage -notmatch 'for tar_file in "\$\{tar_files\[@\]\}"')
Assert-True 'manage.sh refresh includes Dex digest target' ($manage -match 'DEX_IMAGE_REF="\$\(_rv_resolve_digest')
Assert-True 'upgrade docs describe selected load semantics' ($docs -match 'selected optional service' -and $docs -notmatch 'load --ldap --skillhub')
```

Add assertions to `Test-WorkspaceAiToolingStaticContracts`:

```powershell
Assert-True 'workspace template gates MinerU app' ($template -match 'variable "mineru_enabled"' -and $template -match 'resource "coder_app" "mineru"[\s\S]*count\s*=')
Assert-True 'workspace template gates docconv app' ($template -match 'variable "doctools_enabled"' -and $template -match 'resource "coder_app" "docconv"[\s\S]*count\s*=')
Assert-True 'workspace template gates SkillHub app' ($template -match 'resource "coder_app" "skill_hub"[\s\S]*count\s*=')
Assert-True 'manage.sh passes optional app flags into template push' ($manageSh -match "--var mineru_enabled='\\$\\{USE_MINERU\\}'" -and $manageSh -match "--var doctools_enabled='\\$\\{USE_DOCTOOLS\\}'")
Assert-True 'manage.ps1 passes optional app flags into template push' ($managePs1 -match "--var mineru_enabled='\\$mineruEnabled'" -and $managePs1 -match "--var doctools_enabled='\\$doctoolsEnabled'")
```

- [ ] **Step 2: Run tests and verify they fail for the known issues**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: FAIL on at least LDAP prepare/manifest, load filtering, and template gating assertions.

- [ ] **Step 3: Commit failing tests**

```powershell
git add tests\upgrade-scripts.tests.ps1
git commit -m "test: capture optional service switch contracts"
```

---

### Task 2: Add Shared PowerShell Service Metadata and Selected Image Resolution

**Files:**
- Modify: `scripts/manage.ps1`

- [ ] **Step 1: Add service metadata helpers near existing config/image helpers**

Insert after `Get-ImageRepositoryFromRef`:

```powershell
function Get-OptionalServiceDefinitions {
    return @(
        [ordered]@{ Key = 'llm';      Enabled = [bool]$script:UseLlm;      Profile = 'llm';      Images = @(@{ Ref = 'LITELLM_IMAGE_REF'; Tag = 'LITELLM_IMAGE_TAG'; Match = 'litellm' }) },
        [ordered]@{ Key = 'ldap';     Enabled = [bool]$script:UseLdap;     Profile = 'ldap';     Images = @(@{ Ref = 'DEX_IMAGE_REF';     Tag = 'DEX_IMAGE_TAG';     Match = 'dexidp' }) },
        [ordered]@{ Key = 'mineru';   Enabled = [bool]$script:UseMineru;   Profile = 'mineru';   Images = @(@{ Ref = 'MINERU_IMAGE_REF';  Tag = 'MINERU_IMAGE_TAG';  Match = 'mineru' }) },
        [ordered]@{ Key = 'doctools'; Enabled = [bool]$script:UseDoctools; Profile = 'doctools'; Images = @(@{ Ref = 'DOCCONV_IMAGE_REF'; Tag = 'DOCCONV_IMAGE_TAG'; Match = 'pandoc' }) },
        [ordered]@{ Key = 'skillhub'; Enabled = [bool]$script:UseSkillHub; Profile = 'skillhub'; Images = @(
            @{ Ref = 'GITEA_IMAGE_REF';      Tag = 'GITEA_IMAGE_TAG';      Match = 'gitea';      Default = 'gitea/gitea:latest' },
            @{ Ref = 'PYPISERVER_IMAGE_REF'; Tag = 'PYPISERVER_IMAGE_TAG'; Match = 'pypiserver'; Default = 'pypiserver/pypiserver:latest' }
        ) }
    )
}

function Get-ImageArchiveName {
    param([string]$ImageRef)
    return ($ImageRef -replace '[:/@]', '_') + '.tar'
}

function Get-SelectedImageSpecs {
    param(
        [hashtable]$Config,
        [switch]$IncludeWorkspace,
        [switch]$IncludeCodeServerBase
    )
    $specs = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(
        @{ Ref = 'CODER_IMAGE_REF';    Tag = 'CODER_IMAGE_TAG';    Required = $true },
        @{ Ref = 'POSTGRES_IMAGE_REF'; Tag = 'POSTGRES_IMAGE_TAG'; Required = $true },
        @{ Ref = 'NGINX_IMAGE_REF';    Tag = 'NGINX_IMAGE_TAG';    Required = $true }
    )) {
        if ($Config[$entry.Ref]) { $specs.Add($entry) }
    }
    if ($IncludeCodeServerBase -and $Config['CODE_SERVER_BASE_IMAGE_REF']) {
        $specs.Add(@{ Ref = 'CODE_SERVER_BASE_IMAGE_REF'; Tag = 'CODE_SERVER_BASE_IMAGE_TAG'; Required = $true })
    }
    if ($IncludeWorkspace) {
        $workspaceImage = if ($Config['WORKSPACE_IMAGE']) { $Config['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
        $workspaceTag = if ($Config['WORKSPACE_IMAGE_TAG']) { $Config['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
        $specs.Add(@{ LiteralRef = "${workspaceImage}:${workspaceTag}"; Required = $true })
    }
    foreach ($svc in Get-OptionalServiceDefinitions) {
        if (-not $svc.Enabled) { continue }
        foreach ($img in $svc.Images) {
            $ref = if ($Config[$img.Ref]) { $Config[$img.Ref] } else { $img.Default }
            if ($ref) {
                $specs.Add(@{ Ref = $img.Ref; Tag = $img.Tag; LiteralRef = $ref; OptionalService = $svc.Key; Match = $img.Match })
            }
        }
    }
    return $specs
}
```

- [ ] **Step 2: Run PowerShell parser**

Run:

```powershell
$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts\manage.ps1'), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { $errors; exit 1 }
```

Expected: exit 0.

---

### Task 3: Refactor PowerShell Image Commands to Use Selected Image Specs

**Files:**
- Modify: `scripts/manage.ps1`

- [ ] **Step 1: Update `Invoke-Pull`**

Replace the local `$images` construction with:

```powershell
$images = [System.Collections.Generic.List[string]]::new()
foreach ($spec in Get-SelectedImageSpecs -Config $cfg -IncludeCodeServerBase) {
    $ref = if ($spec.LiteralRef) { $spec.LiteralRef } else { $cfg[$spec.Ref] }
    if ($ref) { $images.Add($ref) }
}
```

- [ ] **Step 2: Update `Invoke-Save`**

Replace the local `$images` construction with:

```powershell
$images = [System.Collections.Generic.List[string]]::new()
foreach ($spec in Get-SelectedImageSpecs -Config $cfg -IncludeWorkspace) {
    $ref = if ($spec.LiteralRef) { $spec.LiteralRef } else { $cfg[$spec.Ref] }
    if ($ref) { $images.Add($ref) }
}
```

Keep the existing digest fallback map and save loop.

- [ ] **Step 3: Rewrite `Invoke-Load` to load selected images only**

Build the selected refs first:

```powershell
$manifestPath = Join-Path $ProjectRoot 'offline-manifest.json'
$manifestByRef = @{}
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    foreach ($image in $manifest.images) {
        $manifestByRef[[string]$image.ref] = [string]$image.archive
    }
}

$selectedRefs = [System.Collections.Generic.List[string]]::new()
foreach ($spec in Get-SelectedImageSpecs -Config $cfg -IncludeWorkspace) {
    $ref = if ($spec.LiteralRef) { $spec.LiteralRef } else { $cfg[$spec.Ref] }
    if ($ref) { $selectedRefs.Add($ref) }
}
```

Resolve each tarball:

```powershell
foreach ($imageRef in $selectedRefs) {
    $archive = if ($manifestByRef.ContainsKey($imageRef)) { $manifestByRef[$imageRef] } else { "images/$(Get-ImageArchiveName $imageRef)" }
    $tarPath = Join-Path $ProjectRoot $archive
    if (-not (Test-Path $tarPath)) {
        Write-Fail "Required image archive missing for ${imageRef}: $archive"
        exit 1
    }
    Write-Info "Loading $(Split-Path $tarPath -Leaf)"
    $loadOutput = docker load -i $tarPath 2>&1
    $loadOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to load $(Split-Path $tarPath -Leaf)"
        exit 1
    }
}
```

Retain the existing retagging map and apply it inside this selected-image loop.

- [ ] **Step 4: Run tests and parser**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: tests still fail only for Bash/template/docs/SkillHub items not implemented yet.

---

### Task 4: Refactor Bash Image Selection and `load`

**Files:**
- Modify: `scripts/manage.sh`

- [ ] **Step 1: Add helper functions near `workspace_image_ref`**

```bash
image_archive_name() {
    printf '%s' "$1" | tr '/:@' '_'
    printf '.tar'
}

_selected_image_refs() {
    local include_workspace="${1:-false}"
    local include_code_server_base="${2:-false}"
    local refs=(
        "$CODER_IMAGE_REF"
        "$POSTGRES_IMAGE_REF"
        "$NGINX_IMAGE_REF"
    )
    [ "$include_code_server_base" = true ] && refs+=("$CODE_SERVER_BASE_IMAGE_REF")
    if [ "$include_workspace" = true ]; then
        refs+=("${WORKSPACE_IMAGE:-workspace-embedded}:${WORKSPACE_IMAGE_TAG:-latest}")
    fi
    [ "$USE_LLM" = true ] && refs+=("$LITELLM_IMAGE_REF")
    [ "$USE_LDAP" = true ] && refs+=("$DEX_IMAGE_REF")
    [ "$USE_MINERU" = true ] && refs+=("$MINERU_IMAGE_REF")
    [ "$USE_DOCTOOLS" = true ] && refs+=("$DOCCONV_IMAGE_REF")
    if [ "$USE_SKILLHUB" = true ]; then
        refs+=("${GITEA_IMAGE_REF:-gitea/gitea:latest}")
        refs+=("${PYPISERVER_IMAGE_REF:-pypiserver/pypiserver:latest}")
    fi
    printf '%s\n' "${refs[@]}"
}
```

- [ ] **Step 2: Update `pull_images`**

Replace hand-built arrays with:

```bash
mapfile -t images < <(_selected_image_refs false true)
```

- [ ] **Step 3: Update `save_images`**

Replace hand-built arrays with:

```bash
mapfile -t images < <(_selected_image_refs true false)
```

- [ ] **Step 4: Rewrite `load_images`**

Use selected refs instead of `"$PROJECT_ROOT/images"/*.tar`:

```bash
load_images() {
    check_deps
    load_config
    [ -d "$PROJECT_ROOT/images" ] || fail "images directory not found"

    local image_ref archive tar_file base load_output image_id
    mapfile -t selected_refs < <(_selected_image_refs true false)
    for image_ref in "${selected_refs[@]}"; do
        archive="$(python3 - "$MANIFEST_PATH" "$image_ref" <<'PY'
import json, os, sys
manifest_path, image_ref = sys.argv[1:3]
if os.path.exists(manifest_path):
    with open(manifest_path, 'r', encoding='utf-8') as fh:
        manifest = json.load(fh)
    for image in manifest.get('images', []):
        if image.get('ref') == image_ref:
            print(image.get('archive', ''))
            break
PY
)"
        [ -n "$archive" ] || archive="images/$(image_archive_name "$image_ref")"
        tar_file="$PROJECT_ROOT/$archive"
        [ -f "$tar_file" ] || fail "Required image archive missing for ${image_ref}: ${archive}"
        base="$(basename "$tar_file")"
        info "Loading $base"
        load_output="$(docker load -i "$tar_file" 2>&1)"
        echo "$load_output"
        image_id="$(echo "$load_output" | awk '/Loaded image ID:/{print $NF}')"
        if [ -n "$image_id" ]; then
            _retag_loaded_image_if_needed "$image_id" "$base"
        fi
    done
    ok "Images loaded"
    fix_provider_permissions
}
```

Move the current ref-key retag loop into `_retag_loaded_image_if_needed`.

- [ ] **Step 5: Run Bash syntax check**

```bash
bash -n scripts/manage.sh
```

Expected: exit 0.

---

### Task 5: Fix Prepare, Manifest, and Version Refresh for LDAP/Dex

**Files:**
- Modify: `scripts/manage.ps1`
- Modify: `scripts/manage.sh`

- [ ] **Step 1: Add LDAP/Dex to PowerShell prepare image saving**

In `Invoke-PrepareSavePlatformImages`, add:

```powershell
if ($script:UseLdap) { $images.Add($cfg['DEX_IMAGE_REF']) }
```

Place it beside the other optional service image additions.

- [ ] **Step 2: Add LDAP/Dex to PowerShell manifest**

In `Invoke-PrepareWriteManifest`, add:

```powershell
if ($script:UseLdap) { $images += (& $imageEntry $cfg['DEX_IMAGE_REF']) }
```

Add the include flag:

```powershell
include_ldap = [bool]$script:UseLdap
```

- [ ] **Step 3: Add LDAP/Dex to Bash prepare image saving**

In `_prepare_save_platform_images`, add:

```bash
if [ "$USE_LDAP" = true ]; then
    images+=("$DEX_IMAGE_REF")
fi
```

- [ ] **Step 4: Add LDAP/Dex to Bash manifest**

In `_prepare_write_manifest`, add:

```bash
local ldap_entry=''
if [ "$USE_LDAP" = true ]; then
    local dex_tar
    dex_tar="$(printf '%s' "$DEX_IMAGE_REF" | tr '/:@' '_').tar"
    ldap_entry=",\n    {\"ref\": \"${DEX_IMAGE_REF}\", \"archive\": \"images/${dex_tar}\"}"
fi
```

Add:

```json
"include_ldap": ${USE_LDAP,,},
```

Include `${ldap_entry}` in the image list before other optional entries.

- [ ] **Step 5: Include Dex in version refresh**

PowerShell: add Dex to `$imageTargets`:

```powershell
@{ RefKey = 'DEX_IMAGE_REF'; TagKey = 'DEX_IMAGE_TAG' },
```

Bash: add:

```bash
local OLD_DEX_IMAGE_REF="${DEX_IMAGE_REF:-}"
DEX_IMAGE_REF="$(_rv_resolve_digest "$(_rv_repository_from_ref "$DEX_IMAGE_REF")" "$DEX_IMAGE_TAG")"
```

Add `DEX_IMAGE_REF` to `_rv_keys` display if not already present.

- [ ] **Step 6: Run regression tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: LDAP prepare/manifest and Dex refresh assertions pass.

---

### Task 6: Gate Optional Workspace Apps and Pass Template Variables

**Files:**
- Modify: `workspace-template/main.tf`
- Modify: `scripts/manage.ps1`
- Modify: `scripts/manage.sh`

- [ ] **Step 1: Add template variables**

Append near the existing `skillhub_enabled` variable:

```hcl
variable "mineru_enabled" {
  description = "Whether MinerU app link should be exposed in the workspace UI"
  type        = string
  default     = "false"
}

variable "doctools_enabled" {
  description = "Whether docconv app link should be exposed in the workspace UI"
  type        = string
  default     = "false"
}
```

- [ ] **Step 2: Add `count` to optional apps**

For MinerU:

```hcl
resource "coder_app" "mineru" {
  count        = var.mineru_enabled == "true" ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "mineru"
  display_name = "MinerU 文档转 Markdown"
  icon         = "/icon/pdf.svg"
  url          = "https://${var.server_host}:${var.gateway_port}/mineru/"
  external     = true
}
```

For docconv:

```hcl
resource "coder_app" "docconv" {
  count        = var.doctools_enabled == "true" ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "docconv"
  display_name = "Pandoc Markdown→Word"
  icon         = "/icon/markdown.svg"
  url          = "https://${var.server_host}:${var.gateway_port}/docconv/"
  external     = true
}
```

For SkillHub:

```hcl
resource "coder_app" "skill_hub" {
  count        = var.skillhub_enabled == "true" ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "skill-hub"
  display_name = "Gitea (Skills)"
  icon         = "/icon/git.svg"
  url          = "https://${var.server_host}:${var.gateway_port}/gitea/"
  external     = true
}
```

- [ ] **Step 3: Pass PowerShell template variables**

In `Invoke-PushTemplate`, add:

```powershell
$mineruEnabled = if ($script:UseMineru) { 'true' } else { 'false' }
$doctoolsEnabled = if ($script:UseDoctools) { 'true' } else { 'false' }
```

Extend `$pushCmd` with:

```powershell
--var mineru_enabled='$mineruEnabled' --var doctools_enabled='$doctoolsEnabled'
```

- [ ] **Step 4: Pass Bash template variables**

In `_do_push_template`, extend the `templates push` command with:

```bash
--var mineru_enabled='${USE_MINERU}' --var doctools_enabled='${USE_DOCTOOLS}'
```

- [ ] **Step 5: Run tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: template gating assertions pass.

---

### Task 7: Add PowerShell SkillHub Parity

**Files:**
- Modify: `scripts/manage.ps1`

- [ ] **Step 1: Add SkillHub repo list helper**

Near other helpers:

```powershell
function Get-SkillHubRepos {
    return @(
        @{ Url = 'https://github.com/wshobson/commands.git'; Dest = 'wshobson-commands.git' }
    )
}
```

- [ ] **Step 2: Add `Invoke-SkillHubRefresh`**

Implement:

```powershell
function Invoke-SkillHubRefresh {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Fail 'git not found - required for mirroring skill repos'
        exit 1
    }
    $seedsDir = Join-Path $ConfigsDir 'gitea\seeds'
    New-Item -ItemType Directory -Path $seedsDir -Force | Out-Null
    foreach ($repo in Get-SkillHubRepos) {
        $dest = Join-Path $seedsDir $repo.Dest
        if (Test-Path $dest) {
            Write-Info "Updating mirror: $($repo.Dest)"
            git -C $dest remote update --prune
            if ($LASTEXITCODE -ne 0) { Write-Warn "Update failed for $($repo.Dest); keeping existing mirror" }
        } else {
            Write-Info "Cloning mirror: $($repo.Url) -> $($repo.Dest)"
            git clone --mirror $repo.Url $dest
            if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to clone $($repo.Url)"; exit 1 }
        }
    }
    Write-OK "Skill repo mirrors ready in $seedsDir"
}
```

- [ ] **Step 3: Add `Invoke-SkillHubPrepare`**

Implement image pull/save, digest lock, repo refresh, and package download:

```powershell
function Invoke-SkillHubPrepare {
    Assert-Docker
    Initialize-Dirs
    $cfg = Get-Config
    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null

    foreach ($imageRef in @(
        (Get-ConfigValueOrDefault -Config $cfg -Key 'GITEA_IMAGE_REF' -Default 'gitea/gitea:latest'),
        (Get-ConfigValueOrDefault -Config $cfg -Key 'PYPISERVER_IMAGE_REF' -Default 'pypiserver/pypiserver:latest')
    )) {
        Write-Info "Pulling $imageRef"
        docker pull $imageRef
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $imageRef"; exit 1 }
        $tarPath = Join-Path $ImagesDir (Get-ImageArchiveName $imageRef)
        Write-Info "Saving $imageRef -> $(Split-Path $tarPath -Leaf)"
        docker save $imageRef -o $tarPath
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to save $imageRef"; exit 1 }
    }

    Invoke-SkillHubRefresh

    $packagesDir = Join-Path $ConfigsDir 'pypi\packages'
    New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null
    $pip = Get-Command pip3 -ErrorAction SilentlyContinue
    if (-not $pip) { $pip = Get-Command pip -ErrorAction SilentlyContinue }
    if ($pip) {
        & $pip.Source download --dest $packagesDir --platform manylinux_2_17_x86_64 --python-version 3.11 --only-binary=:all: numpy pandas matplotlib scipy scikit-learn sympy pyserial pyelftools gcovr sphinx breathe pytest coverage requests httpx pydantic click rich tqdm
        if ($LASTEXITCODE -ne 0) { Write-Warn 'Some packages failed to download; partial package set will still be available offline' }
    } else {
        Write-Warn 'pip not found on host; manually copy wheels into configs\pypi\packages before deploying.'
    }
    Write-OK 'Skill Hub preparation complete'
}
```

- [ ] **Step 4: Add first-start Gitea initialization call**

After the setup/template refresh block in `Invoke-Up`, add:

```powershell
if ($script:UseSkillHub) {
    Invoke-SetupGitea
}
```

Add this function near the SkillHub helpers:

```powershell
function Invoke-SetupGitea {
    $giteaDoneFile = Join-Path $DockerDir '.gitea-setup-done'
    if (Test-Path $giteaDoneFile) { return }

    $cfg = Get-Config
    $giteaUrl = 'http://localhost:3000'
    $adminPass = if ($cfg['GITEA_ADMIN_PASSWORD']) { $cfg['GITEA_ADMIN_PASSWORD'] } else { New-RandomHex -Bytes 12 }

    Write-Info 'Waiting for Gitea to become ready...'
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            Invoke-WebRequest -Uri "$giteaUrl/-/ready" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
            $ready = $true
            break
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    if (-not $ready) {
        Write-Warn 'Gitea did not become ready in time; skipping initialization.'
        return
    }
    Write-OK 'Gitea is ready'

    Write-Info 'Creating Gitea admin user...'
    $createOutput = docker exec coder-gitea gitea admin user create `
        --admin `
        --username admin `
        --password "$adminPass" `
        --email 'gitea-admin@internal' `
        --must-change-password=false 2>&1
    $createText = $createOutput | Out-String
    if ($LASTEXITCODE -ne 0 -and $createText -notmatch 'already exists') {
        Write-Warn 'Could not create Gitea admin user; seed repo import will be skipped.'
        return
    }

    $tokenName = "manage-ps1-$(Get-Date -Format yyyyMMddHHmmss)"
    $tokenBody = @{ name = $tokenName } | ConvertTo-Json -Compress
    try {
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:${adminPass}"))
        $tokenJson = Invoke-RestMethod -Uri "$giteaUrl/api/v1/users/admin/tokens" `
            -Method Post `
            -Headers @{ Authorization = "Basic $basic" } `
            -ContentType 'application/json' `
            -Body $tokenBody `
            -TimeoutSec 10
        $token = $tokenJson.sha1
    } catch {
        $token = ''
    }

    if (-not $token) {
        Write-Warn "Could not obtain Gitea API token. Import seed repos manually via https://<SERVER>:<PORT>/gitea (admin / $adminPass)."
        return
    }

    foreach ($repo in Get-SkillHubRepos) {
        $repoName = [System.IO.Path]::GetFileNameWithoutExtension($repo.Dest)
        $repoName = $repoName -replace '^[^-]+-', ''
        $payload = @{
            clone_addr  = "/repos-seed/$($repo.Dest)"
            repo_name   = $repoName
            uid         = 1
            private     = $false
            description = "Mirrored from $($repo.Url)"
        } | ConvertTo-Json -Compress

        Write-Info "Importing seed repo: $repoName"
        try {
            Invoke-RestMethod -Uri "$giteaUrl/api/v1/repos/migrate" `
                -Method Post `
                -Headers @{ Authorization = "token $token" } `
                -ContentType 'application/json' `
                -Body $payload `
                -TimeoutSec 30 | Out-Null
            Write-OK "Imported $repoName into Gitea"
        } catch {
            $statusCode = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($statusCode -eq 409) {
                Write-Info "$repoName already exists in Gitea"
            } else {
                Write-Warn "Import of $repoName failed with HTTP $statusCode"
            }
        }
    }

    [System.IO.File]::WriteAllText((Join-Path $DockerDir '.gitea-admin-password'), $adminPass, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($giteaDoneFile, (Get-Date).ToString('o'), [System.Text.UTF8Encoding]::new($false))
    Write-OK 'Gitea initialized'
    Write-Info 'Gitea admin credentials saved to docker\.gitea-admin-password'
}
```

- [ ] **Step 5: Add command dispatch entries**

In `Show-Help`, list:

```powershell
'  skillhub-prepare            Prepare Skill Hub images, repo mirrors, and PyPI packages',
'  skillhub-refresh            Refresh mirrored Skill Hub repositories',
```

In the command switch, add:

```powershell
'skillhub-prepare' { Invoke-SkillHubPrepare; break }
'skillhub-refresh' { Invoke-SkillHubRefresh; break }
```

- [ ] **Step 6: Run PowerShell parser and tests**

```powershell
$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts\manage.ps1'), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { $errors; exit 1 }
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: SkillHub parity static assertions pass.

---

### Task 8: Align Help Text and Documentation

**Files:**
- Modify: `scripts/manage.ps1`
- Modify: `scripts/manage.sh`
- Modify: `README.md`
- Modify: `docs/upgrade-in-place.md`

- [ ] **Step 1: Update script help usage**

PowerShell usage should show all flags:

```text
Usage: .\scripts\manage.ps1 <command> [arg] [-Llm] [-Ldap] [-Mineru] [-Doctools] [-SkillHub] [flags]
```

Bash usage should show:

```text
Usage: bash scripts/manage.sh <command> [args] [--llm] [--ldap] [--mineru] [--doctools] [--skillhub]
```

Update `prepare` lines to include `-Ldap` / `--ldap` and `-SkillHub` / `--skillhub`.

- [ ] **Step 2: Update README offline preparation**

Change optional flags list to include LDAP/Dex:

```markdown
- `-Ldap` / `--ldap` also saves the Dex OIDC image
```

Change common commands:

```markdown
.\scripts\manage.ps1 load [-Llm] [-Ldap] [-Mineru] [-Doctools] [-SkillHub]
bash scripts/manage.sh load [--llm] [--ldap] [--mineru] [--doctools] [--skillhub]
```

Add one sentence:

```markdown
Use the same optional service flags for `prepare`, `load`, and `up` when deploying those services offline.
```

- [ ] **Step 3: Update upgrade runbook**

Replace the fake flag explanation with:

```markdown
`load` now loads the base images plus whichever optional service images you select. If the upgraded deployment will enable LDAP, SkillHub, or MinerU, pass the same flags to `load` that you will pass to `up`.
```

Use examples:

```bash
bash scripts/manage.sh load --ldap --skillhub
bash scripts/manage.sh up --ldap --skillhub
```

```powershell
.\scripts\manage.ps1 load -Ldap -SkillHub
.\scripts\manage.ps1 up -Ldap -SkillHub
```

- [ ] **Step 4: Run documentation static tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: docs assertions pass.

---

### Task 9: Final Verification

**Files:**
- All changed files

- [ ] **Step 1: Run full lightweight regression suite**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1
```

Expected: `upgrade script regression tests passed`.

- [ ] **Step 2: Run PowerShell parser checks**

```powershell
$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts\manage.ps1'), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { $errors; exit 1 }
$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'scripts\lib\offline-common.ps1'), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { $errors; exit 1 }
```

Expected: exit 0.

- [ ] **Step 3: Run Bash syntax check**

```bash
bash -n scripts/manage.sh
```

Expected: exit 0.

- [ ] **Step 4: Inspect diff for scope**

```powershell
git diff -- scripts\manage.ps1 scripts\manage.sh workspace-template\main.tf tests\upgrade-scripts.tests.ps1 README.md docs\upgrade-in-place.md
```

Expected: only optional-service switch semantics, docs, tests, and SkillHub parity changes.

- [ ] **Step 5: Final commit**

```powershell
git add scripts\manage.ps1 scripts\manage.sh workspace-template\main.tf tests\upgrade-scripts.tests.ps1 README.md docs\upgrade-in-place.md
git commit -m "fix: unify optional service switch behavior"
```

---

## Self-Review Checklist

- Every issue from the design doc maps to at least one task.
- The plan keeps Docker operations out of verification.
- Tests are added before implementation.
- Bash and PowerShell are changed in parallel.
- Template app visibility is controlled during template publishing.
- Documentation no longer advertises behavior that scripts do not implement.
