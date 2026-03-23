#Requires -Version 5.1
# update-provider-mirror.ps1 — Add or refresh a provider in the local network mirror.
#
# This script is intended to be run on an ONLINE machine to download provider
# zip files and generate the JSON index files required by the Terraform Network
# Mirror Protocol.  Once generated, transfer the files to the offline server —
# no service restart is needed because provider-mirror uses a bind-mount and
# nginx serves files on every request.
#
# Usage:
#   .\scripts\update-provider-mirror.ps1 -Provider coder/coder -Version 2.14.0
#       Download provider zip, compute zh: hash, write index.json and <version>.json.
#
#   .\scripts\update-provider-mirror.ps1 -Provider coder/coder
#       Rebuild index.json and all <version>.json from already-downloaded zips.
#       Safe to run offline — only reads local zip files.
#
# Examples:
#   .\scripts\update-provider-mirror.ps1 -Provider coder/coder -Version 2.14.0
#   .\scripts\update-provider-mirror.ps1 -Provider kreuzwerker/docker -Version 3.6.2
#   .\scripts\update-provider-mirror.ps1 -Provider hashicorp/kubernetes -Version 2.31.0
#   .\scripts\update-provider-mirror.ps1 -Provider coder/coder          # rebuild indexes only

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Provider,   # Format: <namespace>/<type>

    [Parameter(Position=1)]
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSNativeCommandUseErrorActionPreference = $false

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$MirrorRoot  = Join-Path $ProjectRoot 'configs\provider-mirror\registry.terraform.io'

$OS   = 'linux'
$Arch = 'amd64'

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-OK   { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL]  $Message" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Parse namespace/type
# ---------------------------------------------------------------------------
$parts = $Provider -split '/', 2
if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
    Write-Fail "Provider must be <namespace>/<type>, e.g. coder/coder"
}
$Namespace    = $parts[0]
$ProviderType = $parts[1]

# ---------------------------------------------------------------------------
# zh: hash — base64(sha256(zip_file_bytes))
# Computed entirely from the local zip; no internet access required.
# ---------------------------------------------------------------------------
function Get-ZhHash {
    param([string]$ZipPath)
    $bytes  = [System.IO.File]::ReadAllBytes($ZipPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $digest = $sha256.ComputeHash($bytes)
    $b64    = [Convert]::ToBase64String($digest)
    return "zh:$b64"
}

# ---------------------------------------------------------------------------
# Write <version>.json for a single version/zip.
# The URL is relative to the provider's base directory
# (registry.terraform.io/<namespace>/<type>/), so Terraform resolves it as:
#   https://provider-mirror/registry.terraform.io/<ns>/<type>/<ver>/<os>_<arch>/<zip>
# ---------------------------------------------------------------------------
function Write-VersionJson {
    param(
        [string]$BaseDir,   # e.g. MirrorRoot\coder\coder
        [string]$Ver,
        [string]$ZipPath
    )
    $zipName  = [System.IO.Path]::GetFileName($ZipPath)
    $hash     = Get-ZhHash -ZipPath $ZipPath
    $platform = "${OS}_${Arch}"
    $relUrl   = "$Ver/${platform}/$zipName"
    $json     = "{`"archives`":{`"${platform}`":{`"url`":`"$relUrl`",`"hashes`":[`"$hash`"]}}}"
    $outPath  = Join-Path $BaseDir "${Ver}.json"
    [System.IO.File]::WriteAllText($outPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-OK "Wrote ${Ver}.json  (hash=$hash)"
}

# ---------------------------------------------------------------------------
# Rebuild index.json from all version directories that contain a zip.
# ---------------------------------------------------------------------------
function Write-IndexJson {
    param([string]$BaseDir)
    $zips = Get-ChildItem -Path $BaseDir -Filter '*.zip' -Recurse -ErrorAction SilentlyContinue
    if (-not $zips) {
        Write-Warn "No zip files found under $BaseDir — index.json not written"
        return
    }
    $versions = @{}
    foreach ($zip in $zips) {
        # Path: <BaseDir>\<version>\<os>_<arch>\<zipname>
        $ver = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $zip.FullName))
        $versions[$ver] = $true
    }
    $versionEntries = ($versions.Keys | Sort-Object | ForEach-Object { "`"$_`":{}" }) -join ','
    $json = "{`"versions`":{$versionEntries}}"
    $outPath = Join-Path $BaseDir 'index.json'
    [System.IO.File]::WriteAllText($outPath, $json, [System.Text.UTF8Encoding]::new($false))
    Write-OK "Wrote index.json"
}

# ---------------------------------------------------------------------------
# Download provider zip from registry.terraform.io.
# Requires internet access.
# ---------------------------------------------------------------------------
function Invoke-DownloadProvider {
    param(
        [string]$Ns,
        [string]$Ptype,
        [string]$Ver
    )
    $zipName = "terraform-provider-${Ptype}_${Ver}_${OS}_${Arch}.zip"
    $verDir  = Join-Path $MirrorRoot "$Ns\$Ptype\$Ver\${OS}_${Arch}"
    $zipPath = Join-Path $verDir $zipName

    if (Test-Path $zipPath) {
        Write-OK "Already present: $zipName"
        return
    }

    New-Item -ItemType Directory -Path $verDir -Force | Out-Null

    Write-Info "Querying registry.terraform.io for $Ns/$Ptype $Ver ..."
    $infoUrl     = "https://registry.terraform.io/v1/providers/$Ns/$Ptype/$Ver/download/$OS/$Arch"
    $downloadInfo = Invoke-RestMethod -Uri $infoUrl -TimeoutSec 30

    Write-Info "Downloading $zipName ..."
    Invoke-WebRequest -Uri $downloadInfo.download_url -OutFile $zipPath -TimeoutSec 300 -UseBasicParsing
    Write-OK "Saved $zipPath"
}

# ---------------------------------------------------------------------------
# Rebuild all version JSONs and the index for namespace/type.
# ---------------------------------------------------------------------------
function Invoke-RebuildAll {
    param([string]$Ns, [string]$Ptype)
    $baseDir = Join-Path $MirrorRoot "$Ns\$Ptype"
    if (-not (Test-Path $baseDir)) {
        Write-Warn "No mirror directory for $Ns/$Ptype — nothing to index"
        return
    }
    $zips = Get-ChildItem -Path $baseDir -Filter '*.zip' -Recurse -ErrorAction SilentlyContinue
    foreach ($zip in $zips) {
        $ver = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $zip.FullName))
        Write-VersionJson -BaseDir $baseDir -Ver $ver -ZipPath $zip.FullName
    }
    Write-IndexJson -BaseDir $baseDir
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($Version) {
    Write-Info "=== Adding $Namespace/$ProviderType $Version to provider mirror ==="
    Invoke-DownloadProvider -Ns $Namespace -Ptype $ProviderType -Ver $Version
} else {
    Write-Info "=== Rebuilding indexes for $Namespace/$ProviderType (no download) ==="
}

Invoke-RebuildAll -Ns $Namespace -Ptype $ProviderType

Write-Host ''
Write-OK "Done. Mirror path: $MirrorRoot\$Namespace\$ProviderType\"
if ($Version) {
    Write-Host ''
    Write-Host 'To import into the offline server, transfer the new files:' -ForegroundColor Cyan
    Write-Host "  robocopy configs\provider-mirror\registry.terraform.io\$Namespace\$ProviderType\" -ForegroundColor White
    Write-Host "          <offline-server-share>\configs\provider-mirror\registry.terraform.io\$Namespace\$ProviderType\ /E" -ForegroundColor White
    Write-Host ''
    Write-Host 'No service restart is required — the provider is immediately available.' -ForegroundColor Green
}
