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
    Assert-True 'docs clarify restore-config does not restore volumes' ($docs -match 'does not restore Docker volumes')
}

Test-PowerShellEffectiveConfig
Test-BashEffectiveConfig
Test-ManagePowerShellStaticContracts
Test-ManageBashAndDocsStaticContracts

Write-Host 'upgrade script regression tests passed'
