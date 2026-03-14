param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSNativeCommandUseErrorActionPreference = $false

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir = Join-Path $ProjectRoot 'configs'
$LockFile = Join-Path $ConfigsDir 'versions.lock.env'

. (Join-Path $ScriptDir 'lib\offline-common.ps1')

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-OK { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL]  $Message" -ForegroundColor Red }

function Assert-Prereqs {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'docker not found'
    }
    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker daemon is not running'
    }
}

function Get-RepositoryFromRef {
    param([string]$Reference)
    if (-not $Reference) { throw 'empty image reference' }
    return ($Reference -split '@')[0]
}

function Get-ResolvedDigestRef {
    param(
        [string]$Repository,
        [string]$Tag
    )

    $tagRef = "${Repository}:${Tag}"
    Write-Info "Pulling $tagRef"
    docker pull $tagRef | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to pull $tagRef"
    }

    $repoDigestsJson = docker image inspect $tagRef --format '{{json .RepoDigests}}'
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect $tagRef"
    }

    $repoDigests = $repoDigestsJson | ConvertFrom-Json
    if (-not $repoDigests -or $repoDigests.Count -eq 0) {
        throw "No repo digests found for $tagRef"
    }

    foreach ($digest in $repoDigests) {
        if ($digest -like "$Repository@*") {
            return $digest
        }
    }
    return $repoDigests[0]
}

function Get-LatestProviderVersion {
    param(
        [string]$Namespace,
        [string]$Type,
        [string]$CurrentVersion
    )

    $major = ($CurrentVersion -split '\.')[0]
    $response = Invoke-RestMethod -Uri "https://registry.terraform.io/v1/providers/$Namespace/$Type/versions" -TimeoutSec 30
    $matchingVersions = $response.versions.version |
        Where-Object { $_ -match "^$([regex]::Escape($major))\.\d+(?:\.\d+)*$" } |
        Sort-Object { [version]$_ } -Descending

    if (-not $matchingVersions) {
        throw "No stable provider version found for $Namespace/$Type major $major"
    }

    return $matchingVersions[0]
}

function New-LockContent {
    param([hashtable]$Config)

    $orderedKeys = @(
        'CODER_IMAGE_REF',
        'CODER_IMAGE_TAG',
        'POSTGRES_IMAGE_REF',
        'POSTGRES_IMAGE_TAG',
        'NGINX_IMAGE_REF',
        'NGINX_IMAGE_TAG',
        'LITELLM_IMAGE_REF',
        'LITELLM_IMAGE_TAG',
        'CODE_SERVER_BASE_IMAGE_REF',
        'CODE_SERVER_BASE_IMAGE_TAG',
        'WORKSPACE_IMAGE',
        'WORKSPACE_IMAGE_TAG',
        'TF_PROVIDER_CODER_VERSION',
        'TF_PROVIDER_DOCKER_VERSION'
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Locked versions and digests for reproducible offline bundles.')
    foreach ($key in $orderedKeys) {
        $lines.Add("$key=$($Config[$key])")
    }
    return ($lines -join "`r`n") + "`r`n"
}

Assert-Prereqs
$current = Read-KeyValueFile $LockFile
$updated = @{}
foreach ($entry in $current.GetEnumerator()) {
    $updated[$entry.Key] = $entry.Value
}

$imageTargets = @(
    @{ RefKey = 'CODER_IMAGE_REF'; TagKey = 'CODER_IMAGE_TAG' },
    @{ RefKey = 'POSTGRES_IMAGE_REF'; TagKey = 'POSTGRES_IMAGE_TAG' },
    @{ RefKey = 'NGINX_IMAGE_REF'; TagKey = 'NGINX_IMAGE_TAG' },
    @{ RefKey = 'LITELLM_IMAGE_REF'; TagKey = 'LITELLM_IMAGE_TAG' },
    @{ RefKey = 'CODE_SERVER_BASE_IMAGE_REF'; TagKey = 'CODE_SERVER_BASE_IMAGE_TAG' }
)

foreach ($target in $imageTargets) {
    $repository = Get-RepositoryFromRef $current[$target.RefKey]
    $updated[$target.RefKey] = Get-ResolvedDigestRef -Repository $repository -Tag $current[$target.TagKey]
}

$updated['TF_PROVIDER_CODER_VERSION'] = Get-LatestProviderVersion -Namespace 'coder' -Type 'coder' -CurrentVersion $current['TF_PROVIDER_CODER_VERSION']
$updated['TF_PROVIDER_DOCKER_VERSION'] = Get-LatestProviderVersion -Namespace 'kreuzwerker' -Type 'docker' -CurrentVersion $current['TF_PROVIDER_DOCKER_VERSION']

Write-Host ''
Write-Host 'Proposed version lock updates:' -ForegroundColor Cyan
foreach ($key in @('CODER_IMAGE_REF','POSTGRES_IMAGE_REF','NGINX_IMAGE_REF','LITELLM_IMAGE_REF','CODE_SERVER_BASE_IMAGE_REF','TF_PROVIDER_CODER_VERSION','TF_PROVIDER_DOCKER_VERSION')) {
    if ($current[$key] -ne $updated[$key]) {
        Write-Host "  $key" -ForegroundColor Yellow
        Write-Host "    old: $($current[$key])" -ForegroundColor DarkGray
        Write-Host "    new: $($updated[$key])" -ForegroundColor White
    } else {
        Write-Host "  $key unchanged" -ForegroundColor DarkGray
    }
}

if ($Apply) {
    [System.IO.File]::WriteAllText($LockFile, (New-LockContent -Config $updated), [System.Text.UTF8Encoding]::new($false))
    Write-OK "Updated $LockFile"
} else {
    Write-Warn 'Dry run only. Re-run with -Apply to rewrite configs/versions.lock.env.'
}
