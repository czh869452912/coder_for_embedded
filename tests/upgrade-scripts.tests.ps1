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
}

function Test-WorkspaceAiToolingStaticContracts {
    $dockerfile = Get-Content (Join-Path $RepoRoot 'docker/Dockerfile.workspace') -Raw
    $startup = Get-Content (Join-Path $RepoRoot 'scripts/workspace-startup.sh') -Raw
    $manageSh = Get-Content (Join-Path $RepoRoot 'scripts/manage.sh') -Raw
    $managePs1 = Get-Content (Join-Path $RepoRoot 'scripts/manage.ps1') -Raw
    $template = Get-Content (Join-Path $RepoRoot 'workspace-template/main.tf') -Raw
    $envExample = Get-Content (Join-Path $RepoRoot '.env.example') -Raw
    $vsixReadme = Get-Content (Join-Path $RepoRoot 'configs/vsix/README.md') -Raw

    Assert-True 'workspace image installs Codex CLI' ($dockerfile -match '@openai/codex')
    Assert-True 'workspace image installs Kilo Code CLI' ($dockerfile -match '@kilocode/cli')
    Assert-True 'workspace image seeds OpenAI Codex extension' ($dockerfile -match 'openai\.chatgpt')
    Assert-True 'workspace image seeds Kilo Code extension' ($dockerfile -match 'kilocode\.kilo-code')
    Assert-True 'workspace startup verifies codex CLI' ($startup -match 'command -v codex')
    Assert-True 'workspace startup verifies kilo CLI' ($startup -match 'command -v kilo')
    Assert-True 'workspace template exposes OpenAI API key' ($template -match 'OPENAI_API_KEY\s*=\s*var\.openai_api_key')
    Assert-True 'workspace template exposes OpenAI base URL' ($template -match 'OPENAI_BASE_URL\s*=\s*var\.openai_base_url')
    Assert-True 'manage.sh passes OpenAI vars into template push' ($manageSh.Contains("--var openai_api_key='`${openai_key}'") -and $manageSh.Contains("--var openai_base_url='`${openai_url}'"))
    Assert-True 'manage.ps1 passes OpenAI vars into template push' ($managePs1.Contains("--var openai_api_key='`$openaiKey'") -and $managePs1.Contains("--var openai_base_url='`$openaiUrl'"))
    Assert-True '.env.example documents OpenAI-compatible config for Codex/Kilo' ($envExample -match 'OPENAI_BASE_URL' -and $envExample -match 'Codex / Kilo')
    Assert-True 'VSIX README documents Codex and Kilo offline extension fallbacks' ($vsixReadme -match 'openai\.chatgpt' -and $vsixReadme -match 'kilocode\.kilo-code')
    Assert-True 'workspace template gates MinerU app' ($template -match 'variable "mineru_enabled"' -and $template -match 'resource "coder_app" "mineru"[\s\S]*count\s*=')
    Assert-True 'workspace template gates docconv app' ($template -match 'variable "doctools_enabled"' -and $template -match 'resource "coder_app" "docconv"[\s\S]*count\s*=')
    Assert-True 'workspace template gates SkillHub app' ($template -match 'resource "coder_app" "skill_hub"[\s\S]*count\s*=')
    Assert-True 'manage.sh passes optional app flags into template push' ($manageSh -match "--var mineru_enabled='\$\{USE_MINERU\}'" -and $manageSh -match "--var doctools_enabled='\$\{USE_DOCTOOLS\}'")
    Assert-True 'manage.ps1 passes optional app flags into template push' ($managePs1.Contains("--var mineru_enabled='`$mineruEnabled'") -and $managePs1.Contains("--var doctools_enabled='`$doctoolsEnabled'"))
}

Test-PowerShellEffectiveConfig
Test-BashEffectiveConfig
Test-ManagePowerShellStaticContracts
Test-ManageBashAndDocsStaticContracts
Test-WorkspaceAiToolingStaticContracts

Write-Host 'upgrade script regression tests passed'
