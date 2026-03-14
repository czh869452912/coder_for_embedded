param(
    [switch]$RequireLlm
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir = Join-Path $ProjectRoot 'configs'
$ManifestPath = Join-Path $ProjectRoot 'offline-manifest.json'

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-OK { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL]  $Message" -ForegroundColor Red }

if (-not (Test-Path $ManifestPath)) {
    Write-Fail 'offline-manifest.json is missing. Run prepare-offline first.'
    exit 1
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$missing = [System.Collections.Generic.List[string]]::new()

if ($RequireLlm -and -not $manifest.include_llm) {
    $missing.Add('Manifest does not include LiteLLM artifacts, but -RequireLlm was requested.')
}

$caCert = Join-Path $ConfigsDir 'ssl\ca.crt'
$caKey = Join-Path $ConfigsDir 'ssl\ca.key'
if (-not (Test-Path $caCert)) { $missing.Add('configs/ssl/ca.crt') }
if (-not (Test-Path $caKey)) { $missing.Add('configs/ssl/ca.key') }
if (-not (Test-Path (Join-Path $ConfigsDir 'terraform-offline.rc'))) { $missing.Add('configs/terraform-offline.rc') }
if (-not (Test-Path (Join-Path $ConfigsDir 'versions.lock.env'))) { $missing.Add('configs/versions.lock.env') }

foreach ($image in $manifest.images) {
    $path = Join-Path $ProjectRoot $image.archive
    if (-not (Test-Path $path)) {
        $missing.Add($image.archive)
    }
}

foreach ($provider in $manifest.providers) {
    $path = Join-Path $ProjectRoot $provider.archive
    if (-not (Test-Path $path)) {
        $missing.Add($provider.archive)
    }
}

if ((Test-Path $caCert) -and $manifest.ca_sha256) {
    $currentHash = (Get-FileHash $caCert -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -ne $manifest.ca_sha256.ToLowerInvariant()) {
        $missing.Add("CA fingerprint mismatch: manifest=$($manifest.ca_sha256) current=$currentHash")
    }
}

if ($missing.Count -gt 0) {
    Write-Fail 'Offline bundle verification failed.'
    foreach ($item in $missing) {
        Write-Host "  - $item" -ForegroundColor Yellow
    }
    exit 1
}

Write-OK 'Offline bundle verification passed.'
Write-Info "Manifest: $ManifestPath"
Write-Info "Images checked: $($manifest.images.Count)"
Write-Info "Providers checked: $($manifest.providers.Count)"
