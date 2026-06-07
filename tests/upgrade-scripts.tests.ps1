#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Equal {
    param(
        [string]$Name,
        [object]$Actual,
        [object]$Expected
    )
    if ($Actual -ne $Expected) {
        throw "$Name expected '$Expected' but got '$Actual'"
    }
}

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition
    )
    if (-not $Condition) {
        throw "$Name failed"
    }
}

function Assert-NotContains {
    param(
        [string]$Name,
        [string]$Text,
        [string]$Pattern
    )
    if ($Text -match $Pattern) {
        throw "$Name should not match pattern '$Pattern'"
    }
}

function New-TestConfigTree {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("coder-upgrade-test-" + [guid]::NewGuid().ToString('N'))
    $configs = Join-Path $root 'configs'
    $docker = Join-Path $root 'docker'
    New-Item -ItemType Directory -Path $configs, $docker -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $configs 'versions.lock.env'),
        "WORKSPACE_IMAGE_TAG=vnew`nCODER_IMAGE_REF=lock-coder`nPOSTGRES_IMAGE_REF=lock-postgres`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $docker '.env'),
        "WORKSPACE_IMAGE_TAG=vold`nSERVER_HOST=old.example`nPOSTGRES_PASSWORD=keepme`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    return @{
        Root = $root
        Configs = $configs
        Env = Join-Path $docker '.env'
    }
}

function Invoke-BashText {
    param([string]$Script)
    $scriptName = ".upgrade-bash-test-$([guid]::NewGuid().ToString('N')).sh"
    $scriptPath = Join-Path $RepoRoot $scriptName
    [System.IO.File]::WriteAllText($scriptPath, $Script, [System.Text.UTF8Encoding]::new($false))
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & bash $scriptName 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) {
        throw "bash test failed with exit $exitCode`n$output"
    }
    return ($output | Out-String)
}

function Test-PowerShellEffectiveConfig {
    . (Join-Path $RepoRoot 'scripts/lib/offline-common.ps1')
    $tree = New-TestConfigTree
    try {
        Ensure-EnvDefaults -EnvFile $tree.Env -ConfigsDir $tree.Configs
        $envText = Get-Content $tree.Env -Raw
        Assert-NotContains 'Ensure-EnvDefaults leaves lock refs out of .env' $envText '^CODER_IMAGE_REF='

        $cfg = Get-EffectiveConfig -ConfigsDir $tree.Configs -EnvFile $tree.Env
        Assert-Equal 'PowerShell lock tag wins over stale .env tag' $cfg['WORKSPACE_IMAGE_TAG'] 'vnew'
        Assert-Equal 'PowerShell mutable env value still wins when absent from lock' $cfg['SERVER_HOST'] 'old.example'
    } finally {
        Remove-Item -Recurse -Force $tree.Root -ErrorAction SilentlyContinue
    }
}

function Test-BashEffectiveConfig {
    $script = @'
set -euo pipefail
source scripts/lib/offline-common.sh
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/configs" "$root/docker"
cat > "$root/configs/versions.lock.env" <<EOF
WORKSPACE_IMAGE_TAG=vnew
CODER_IMAGE_REF=lock-coder
POSTGRES_IMAGE_REF=lock-postgres
EOF
cat > "$root/docker/.env" <<EOF
WORKSPACE_IMAGE_TAG=vold
SERVER_HOST=old.example
POSTGRES_PASSWORD=keepme
EOF
ensure_env_defaults "$root/docker/.env" "$root/configs"
if grep -q '^CODER_IMAGE_REF=' "$root/docker/.env"; then
  echo "Ensure-EnvDefaults appended lock ref into .env" >&2
  exit 1
fi
load_effective_config "$root/configs" "$root/docker/.env"
[ "${WORKSPACE_IMAGE_TAG}" = "vnew" ] || { echo "expected lock tag vnew, got ${WORKSPACE_IMAGE_TAG}" >&2; exit 1; }
[ "${SERVER_HOST}" = "old.example" ] || { echo "expected SERVER_HOST from .env, got ${SERVER_HOST}" >&2; exit 1; }
'@
    Invoke-BashText $script | Out-Null
}

function Test-ManagePowerShellStaticContracts {
    $text = Get-Content (Join-Path $RepoRoot 'scripts/manage.ps1') -Raw

    Assert-True 'manage.ps1 exposes -SkillHub' ($text -match '\[switch\]\$SkillHub')
    Assert-True 'manage.ps1 tracks UseSkillHub' ($text -match '\$script:UseSkillHub\s*=\s*\$SkillHub\.IsPresent')
    Assert-True 'manage.ps1 uses skillhub compose profile' ($text -match "--profile',\s*'skillhub")
    Assert-True 'manage.ps1 handles SkillHub images' ($text -match 'GITEA_IMAGE_REF' -and $text -match 'PYPISERVER_IMAGE_REF')
    Assert-True 'manage.ps1 saves SkillHub images' ($text -match 'function Invoke-Save[\s\S]*UseSkillHub[\s\S]*GITEA_IMAGE_REF')
    Assert-True 'manage.ps1 refresh preserves SkillHub image locks' ($text -match "foreach \(\`$prefix in @\('MINERU', 'DOCCONV', 'GITEA', 'PYPISERVER'\)")
    Assert-True 'manage.ps1 prepare includes LDAP Dex image' ($text -match 'function Invoke-PrepareSavePlatformImages[\s\S]*UseLdap[\s\S]*DEX_IMAGE_REF')
    Assert-True 'manage.ps1 manifest includes LDAP flag' ($text -match 'include_ldap\s*=\s*\[bool\]\$script:UseLdap')
    Assert-True 'manage.ps1 manifest includes LDAP Dex image' ($text -match 'function Invoke-PrepareWriteManifest[\s\S]*UseLdap[\s\S]*DEX_IMAGE_REF')
    Assert-True 'manage.ps1 load uses selected image specs' ($text -match 'Get-SelectedImageSpecs' -and $text -notmatch 'foreach \(\$tarFile in \$tarFiles\)\s*\{[\s\S]*docker load -i \$tarFile\.FullName')
    Assert-True 'manage.ps1 exposes SkillHub preparation commands' ($text -match "'skillhub-prepare'" -and $text -match "'skillhub-refresh'")
    Assert-True 'manage.ps1 refresh includes Dex digest target' ($text -match "RefKey = 'DEX_IMAGE_REF'")
    Assert-True 'update-workspace passes Tag to NewTag parameter' ($text -match '''update-workspace''\s*\{\s*Invoke-UpdateWorkspace\s+-NewTag\s+\$Tag')
    Assert-True 'upgrade restore writes pending marker' ($text -match '\.upgrade-restore-pending')
    Assert-True 'backup includes LiteLLM runtime config' ($text -match 'litellm_config\.yaml\.bak')

    $loadWorkspaceBlock = [regex]::Match(
        $text,
        'function Invoke-LoadWorkspace[\s\S]*?# ─── prepare'
    ).Value
    Assert-True 'load-workspace registers imported image without changing active template state' (
        $loadWorkspaceBlock -match 'Update-WorkspaceImageCatalog' -and
        $loadWorkspaceBlock -notmatch 'Update-LockWorkspaceTag' -and
        $loadWorkspaceBlock -notmatch 'Invoke-PushTemplate' -and
        $loadWorkspaceBlock -notmatch 'Coder is not reachable'
    )
    Assert-True 'push-template supports staged Coder template versions' (
        $text -match 'ActivateTemplate' -and
        $text -match 'ConvertTo-SafeTemplateVersionName' -and
        $text -match '--activate=\$activateValue' -and
        $text -match '--name=\$safeVersionName' -and
        $text -match 'Invoke-PushTemplate -SessionToken \$sessionToken -VersionName \$Name -ActivateTemplate:\$activateTemplate'
    )

    $updateWorkspaceBlock = [regex]::Match(
        $text,
        'function Invoke-UpdateWorkspace[\s\S]*?# ─── load-workspace'
    ).Value
    Assert-True 'update-workspace prepares image catalog without auto-pushing template state' (
        $updateWorkspaceBlock -match 'Update-WorkspaceImageCatalog' -and
        $updateWorkspaceBlock -notmatch 'Invoke-PushTemplate'
    )
}

function Test-ManageBashAndDocsStaticContracts {
    $manage = Get-Content (Join-Path $RepoRoot 'scripts/manage.sh') -Raw
    $docs = Get-Content (Join-Path $RepoRoot 'docs/upgrade-in-place.md') -Raw

    Assert-True 'manage.sh uses upgrade pending marker' ($manage -match '\.upgrade-restore-pending')
    Assert-True 'manage.sh refreshes template after pending upgrade restore' ($manage -match 'run_upgrade_template_refresh')
    Assert-True 'manage.sh backs up LiteLLM runtime config' ($manage -match 'litellm_config\.yaml\.bak')
    Assert-True 'manage.sh preflights Gitea SkillHub image' ($manage -match 'DOCCONV_IMAGE_REF GITEA_IMAGE_REF PYPISERVER_IMAGE_REF')
    Assert-True 'manage.sh prepare includes LDAP Dex image' ($manage -match '_prepare_save_platform_images\(\)[\s\S]*USE_LDAP[\s\S]*DEX_IMAGE_REF')
    Assert-True 'manage.sh manifest includes LDAP flag' ($manage -match '"include_ldap": \$\{USE_LDAP,,\}')
    Assert-True 'manage.sh manifest includes LDAP Dex image' ($manage -match '_prepare_write_manifest\(\)[\s\S]*USE_LDAP[\s\S]*DEX_IMAGE_REF')
    Assert-True 'manage.sh load uses selected image refs' ($manage -match '_selected_image_refs' -and $manage -notmatch 'for tar_file in "\$\{tar_files\[@\]\}"')
    Assert-True 'manage.sh refresh includes Dex digest target' ($manage -match 'DEX_IMAGE_REF="\$\(_rv_resolve_digest')
    Assert-True 'upgrade docs describe selected load semantics' ($docs -match 'selected optional service' -and $docs -notmatch 'load \[--ldap')
    Assert-True 'docs clarify restore-config does not restore volumes' ($docs -match 'does not restore Docker volumes')

    $loadWorkspaceBlock = [regex]::Match(
        $manage,
        'load_workspace\(\) \{[\s\S]*?# ───'
    ).Value
    Assert-True 'manage.sh load-workspace registers image without changing active template state' (
        $loadWorkspaceBlock -match '_update_workspace_image_catalog' -and
        $loadWorkspaceBlock -notmatch '_update_lock_workspace_tag' -and
        $loadWorkspaceBlock -notmatch '_do_push_template' -and
        $loadWorkspaceBlock -notmatch 'Coder is not reachable'
    )
    Assert-True 'manage.sh push-template supports staged Coder template versions' (
        $manage -match 'local activate_template="\$\{3:-true\}"' -and
        $manage -match '_safe_template_version_name' -and
        $manage -match '--activate=\$\{activate_template\}' -and
        $manage -match "--name='\$\{version_name\}'" -and
        $manage -match 'cmd_push_template\(\)[\s\S]*activate_template=false' -and
        $manage -match '_do_push_template "\$session_token" "\$version_name" "\$activate_template"'
    )

    $updateWorkspaceBlock = [regex]::Match(
        $manage,
        'update_workspace\(\) \{[\s\S]*?# ─── load-workspace'
    ).Value
    Assert-True 'manage.sh update-workspace prepares catalog without auto-pushing template state' (
        $updateWorkspaceBlock -match '_update_workspace_image_catalog' -and
        $updateWorkspaceBlock -notmatch '_do_push_template'
    )
}

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

function Test-BashTemplateVersionNameSanitizer {
    $script = @'
set -euo pipefail
source scripts/manage.sh __test_source_only 2>/dev/null || true
actual="$(_template_version_name 'bad name;rm -rf /' 'workspace/image' 'tag:latest')"
[ "$actual" = "bad-name-rm--rf" ] || { echo "unexpected sanitized version: $actual" >&2; exit 1; }
'@
    Invoke-BashText $script | Out-Null
}

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

function Test-BashLlmTemplateInjectionDefaults {
    $script = @'
set -euo pipefail
source scripts/manage.sh --llm __test_source_only 2>/dev/null || true

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/configs" "$root/docker"
cat > "$root/configs/versions.lock.env" <<EOF
WORKSPACE_IMAGE_TAG=vtest
EOF
cat > "$root/docker/.env" <<EOF
SERVER_HOST=host.test
GATEWAY_PORT=9443
LITELLM_MASTER_KEY=sk-test
ANTHROPIC_API_KEY=
ANTHROPIC_BASE_URL=
OPENAI_API_KEY=
OPENAI_BASE_URL=
LITELLM_API_KEY=
LITELLM_BASE_URL=
EOF

CONFIGS_DIR="$root/configs"
ENV_FILE="$root/docker/.env"
capture="$root/docker-calls.txt"

docker() {
  if [ "$1" = "exec" ] && [ "$2" = "coder-server" ] && [ "$3" = "sh" ] && [ "$4" = "-c" ]; then
    printf '%s\n' "$5" >> "$capture"
  fi
}

_do_push_template "session-token" "llm-defaults-test" "false" >/dev/null
push_cmd="$(grep '/opt/coder templates push' "$capture")"

case "$push_cmd" in
  *"--var anthropic_api_key='sk-test'"*) : ;; *) echo "missing Anthropic key injection: $push_cmd" >&2; exit 1 ;;
esac
case "$push_cmd" in
  *"--var anthropic_base_url='http://llm-gateway:4000'"*) : ;; *) echo "missing Anthropic URL injection: $push_cmd" >&2; exit 1 ;;
esac
case "$push_cmd" in
  *"--var openai_api_key='sk-test'"*) : ;; *) echo "missing OpenAI key injection: $push_cmd" >&2; exit 1 ;;
esac
case "$push_cmd" in
  *"--var openai_base_url='http://llm-gateway:4000/v1'"*) : ;; *) echo "missing OpenAI URL injection: $push_cmd" >&2; exit 1 ;;
esac
case "$push_cmd" in
  *"--var litellm_api_key='sk-test'"*) : ;; *) echo "missing Pi LiteLLM key injection: $push_cmd" >&2; exit 1 ;;
esac
case "$push_cmd" in
  *"--var litellm_base_url='http://llm-gateway:4000'"*) : ;; *) echo "missing Pi LiteLLM URL injection: $push_cmd" >&2; exit 1 ;;
esac
'@
    Invoke-BashText $script | Out-Null
}

function Test-BashWorkspaceStartupAiGatewayProfile {
    $script = @'
set -euo pipefail

tmp_home="$(mktemp -d)"
tmp_profile="$(mktemp -d)"
tmp_bin="$(mktemp -d)"
trap 'rm -rf "$tmp_home" "$tmp_profile" "$tmp_bin"' EXIT

cat > "$tmp_bin/code-server" <<'SH'
#!/bin/sh
if [ "$1" = "--extensions-dir" ]; then
  exit 0
fi
while [ "$#" -gt 0 ]; do
  shift
done
exit 0
SH
cat > "$tmp_bin/dumb-init" <<'SH'
#!/bin/sh
shift
exec "$@"
SH
for cmd in claude codex kilo pi curl git; do
  cat > "$tmp_bin/$cmd" <<'SH'
#!/bin/sh
exit 0
SH
done
chmod +x "$tmp_bin"/*

HOME="$tmp_home" \
PATH="$tmp_bin:$PATH" \
AI_GATEWAY_PROFILE_DIR="$tmp_profile" \
ANTHROPIC_API_KEY='sk-ant"quoted$' \
ANTHROPIC_BASE_URL='http://llm-gateway:4000' \
OPENAI_API_KEY='' \
OPENAI_BASE_URL='' \
LITELLM_API_KEY='sk-lit`tick\slash' \
LITELLM_BASE_URL='' \
CODE_SERVER_EXTENSIONS_SEED="$tmp_home/no-seed" \
bash scripts/workspace-startup.sh >/tmp/workspace-startup-test.log 2>&1

profile="$tmp_profile/ai-gateway.sh"
[ -f "$profile" ] || { echo "missing profile" >&2; cat /tmp/workspace-startup-test.log >&2; exit 1; }

grep -q '^export ANTHROPIC_API_KEY=' "$profile" || { echo "missing non-empty Anthropic key export" >&2; cat "$profile" >&2; exit 1; }
grep -q '^export LITELLM_API_KEY=' "$profile" || { echo "missing non-empty LiteLLM key export" >&2; cat "$profile" >&2; exit 1; }
if grep -q '^export OPENAI_API_KEY=' "$profile" || grep -q '^export OPENAI_BASE_URL=' "$profile" || grep -q '^export LITELLM_BASE_URL=' "$profile"; then
  echo "empty AI variables should not be exported" >&2
  cat "$profile" >&2
  exit 1
fi

set +u
. "$profile"
set -u
[ "$ANTHROPIC_API_KEY" = 'sk-ant"quoted$' ] || { echo "Anthropic key was not shell-quoted safely" >&2; exit 1; }
[ "$LITELLM_API_KEY" = 'sk-lit`tick\slash' ] || { echo "LiteLLM key was not shell-quoted safely" >&2; exit 1; }
[ "$PI_OFFLINE" = '1' ] || { echo "Pi offline flag missing" >&2; exit 1; }
'@
    Invoke-BashText $script | Out-Null
}

function Test-WorkspaceAiToolingStaticContracts {
    $dockerfile = Get-Content (Join-Path $RepoRoot 'docker/Dockerfile.workspace') -Raw
    $startup = Get-Content (Join-Path $RepoRoot 'scripts/workspace-startup.sh') -Raw
    $manageSh = Get-Content (Join-Path $RepoRoot 'scripts/manage.sh') -Raw
    $managePs1 = Get-Content (Join-Path $RepoRoot 'scripts/manage.ps1') -Raw
    $template = Get-Content (Join-Path $RepoRoot 'workspace-template/main.tf') -Raw
    $envExample = Get-Content (Join-Path $RepoRoot '.env.example') -Raw
    $vsixReadme = Get-Content (Join-Path $RepoRoot 'configs/vsix/README.md') -Raw
    $pythonDockerfile = Get-Content (Join-Path $RepoRoot 'docker/Dockerfile.workspace-python-backend') -Raw
    $agentDockerfile = Get-Content (Join-Path $RepoRoot 'docker/Dockerfile.workspace-agent-dev') -Raw
    $pythonSettings = Get-Content (Join-Path $RepoRoot 'configs/settings-python-backend.json') -Raw
    $agentSettings = Get-Content (Join-Path $RepoRoot 'configs/settings-agent-dev.json') -Raw

    Assert-True 'workspace image installs Codex CLI' ($dockerfile -match '@openai/codex')
    Assert-True 'workspace image installs Kilo Code CLI' ($dockerfile -match '@kilocode/cli')
    Assert-True 'workspace image uses Node 22 for current Pi agent support' ($dockerfile -match 'ENV NODE_MAJOR=22')
    Assert-True 'workspace image installs Pi CLI' ($dockerfile -match '@earendil-works/pi-coding-agent')
    Assert-True 'workspace image registers Pi LiteLLM provider package' ($dockerfile -match 'pi install npm:pi-provider-litellm')
    Assert-NotContains 'workspace image does not ignore Pi install failures' $dockerfile 'pi coding agent install failed|pi LiteLLM provider install failed'
    Assert-True 'workspace image seeds OpenAI Codex extension' ($dockerfile -match 'openai\.chatgpt')
    Assert-True 'workspace image seeds Kilo Code extension' ($dockerfile -match 'kilocode\.kilo-code')
    Assert-True 'workspace startup verifies codex CLI' ($startup -match 'command -v codex')
    Assert-True 'workspace startup verifies kilo CLI' ($startup -match 'command -v kilo')
    Assert-True 'workspace startup verifies pi CLI' ($startup -match 'command -v pi')
    Assert-True 'workspace startup writes unified AI gateway shell profile' (
        $startup -match 'ai-gateway\.sh' -and
        $startup -match 'ANTHROPIC_API_KEY' -and
        $startup -match 'OPENAI_API_KEY' -and
        $startup -match 'LITELLM_BASE_URL' -and
        $startup -match 'LITELLM_API_KEY' -and
        $startup -match 'PI_SKIP_VERSION_CHECK'
    )
    Assert-True 'workspace template exposes OpenAI API key' ($template -match 'OPENAI_API_KEY\s*=\s*var\.openai_api_key')
    Assert-True 'workspace template exposes OpenAI base URL' ($template -match 'OPENAI_BASE_URL\s*=\s*var\.openai_base_url')
    Assert-True 'workspace template exposes LiteLLM API key' ($template -match 'LITELLM_API_KEY\s*=\s*var\.litellm_api_key')
    Assert-True 'workspace template exposes LiteLLM base URL' ($template -match 'LITELLM_BASE_URL\s*=\s*var\.litellm_base_url')
    Assert-True 'manage.sh passes OpenAI vars into template push' ($manageSh.Contains("--var openai_api_key='`${openai_key}'") -and $manageSh.Contains("--var openai_base_url='`${openai_url}'"))
    Assert-True 'manage.sh passes Pi LiteLLM vars into template push' ($manageSh.Contains("--var litellm_api_key='`${litellm_key}'") -and $manageSh.Contains("--var litellm_base_url='`${litellm_url}'"))
    Assert-True 'manage.ps1 passes OpenAI vars into template push' ($managePs1.Contains("--var openai_api_key='`$openaiKey'") -and $managePs1.Contains("--var openai_base_url='`$openaiUrl'"))
    Assert-True 'manage.ps1 passes Pi LiteLLM vars into template push' ($managePs1.Contains("--var litellm_api_key='`$litellmKey'") -and $managePs1.Contains("--var litellm_base_url='`$litellmUrl'"))
    Assert-True '.env.example documents OpenAI-compatible config for Codex/Kilo/Pi' ($envExample -match 'OPENAI_BASE_URL' -and $envExample -match 'Codex / Kilo / Pi')
    Assert-True '.env.example documents Pi LiteLLM auto-config' ($envExample -match 'LITELLM_BASE_URL' -and $envExample -match 'LITELLM_API_KEY')
    Assert-True 'VSIX README documents Codex and Kilo offline extension fallbacks' ($vsixReadme -match 'openai\.chatgpt' -and $vsixReadme -match 'kilocode\.kilo-code')
    Assert-True 'workspace template gates MinerU app' ($template -match 'variable "mineru_enabled"' -and $template -match 'resource "coder_app" "mineru"[\s\S]*count\s*=')
    Assert-True 'workspace template gates docconv app' ($template -match 'variable "doctools_enabled"' -and $template -match 'resource "coder_app" "docconv"[\s\S]*count\s*=')
    Assert-True 'workspace template gates SkillHub app' ($template -match 'resource "coder_app" "skill_hub"[\s\S]*count\s*=')
    Assert-True 'manage.sh passes optional app flags into template push' ($manageSh -match "--var mineru_enabled='\$\{USE_MINERU\}'" -and $manageSh -match "--var doctools_enabled='\$\{USE_DOCTOOLS\}'")
    Assert-True 'manage.ps1 passes optional app flags into template push' ($managePs1.Contains("--var mineru_enabled='`$mineruEnabled'") -and $managePs1.Contains("--var doctools_enabled='`$doctoolsEnabled'"))
    Assert-True 'workspace template uses Coder parameter for image profile selection' (
        $template -match 'image-catalog\.json' -and
        $template -match 'data "coder_parameter" "image_profile"' -and
        $template -match 'form_type\s*=\s*"dropdown"' -and
        $template -match 'local\.selected_workspace_image' -and
        $template -match 'image\s*=\s*local\.selected_workspace_image'
    )
    Assert-True 'workspace template enforces hard CPU and memory limits' (
        $template -match 'cpu_period\s*=\s*100000' -and
        $template -match 'cpu_quota\s*=\s*data\.coder_parameter\.cpu_cores\.value \* 100000' -and
        $template -notmatch 'cpu_shares\s*=' -and
        $template -match 'memory\s*=\s*data\.coder_parameter\.memory_gb\.value \* 1024' -and
        $template -match 'memory_swap\s*=\s*data\.coder_parameter\.memory_gb\.value \* 1024'
    )
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
}

Test-PowerShellEffectiveConfig
Test-BashEffectiveConfig
Test-ManagePowerShellStaticContracts
Test-ManageBashAndDocsStaticContracts
Test-BashTemplateVersionNameSanitizer
Test-WorkspaceImageFamilyContracts
Test-BashWorkspaceImageCatalogChannels
Test-BashLlmTemplateInjectionDefaults
Test-BashWorkspaceStartupAiGatewayProfile
Test-WorkspaceAiToolingStaticContracts

Write-Host 'upgrade script regression tests passed'
