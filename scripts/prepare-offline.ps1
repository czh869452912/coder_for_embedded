# ============================================================
# Prepare offline resources (run on an internet-connected machine)
#
# Downloads:
#   1. Terraform provider zips -> configs\terraform-providers\
#   2. Platform Docker images  -> images\*.tar
#   3. Builds workspace image  -> images\workspace-embedded_latest.tar
#
# Usage:
#   .\scripts\prepare-offline.ps1
#   .\scripts\prepare-offline.ps1 -SkipImages   # only download TF providers
#   .\scripts\prepare-offline.ps1 -SkipBuild    # skip workspace image build
# ============================================================
#Requires -Version 5.1

param(
    [switch]$SkipImages,   # skip docker pull/save
    [switch]$SkipBuild,    # skip workspace image build+save
    [switch]$IncludeLlm    # also save litellm image
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir  = Join-Path $ProjectRoot "configs"
$DockerDir   = Join-Path $ProjectRoot "docker"
$ImagesDir   = Join-Path $ProjectRoot "images"

function Write-Info { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "[ OK ]  $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "[FAIL]  $msg" -ForegroundColor Red }

function Read-EnvFile {
    $h = @{}
    $envFile = Join-Path $DockerDir ".env"
    if (-not (Test-Path $envFile)) { return $h }
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
            $h[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $h
}

# ============================================================
# Step 1: Download Terraform providers
# ============================================================
function Get-TerraformProviders {
    Write-Info "=== Step 1: Downloading Terraform providers ==="

    # Read provider versions from main.tf
    $mainTf = Join-Path $ProjectRoot "workspace-template\main.tf"
    $tfContent = Get-Content $mainTf -Raw

    # Extract version constraints (take the latest matching version)
    $coderVerConstraint   = if ($tfContent -match '"~>\s*([\d\.]+)"[^}]*coder/coder|coder/coder[^}]*"~>\s*([\d\.]+)"') { $matches[1] + $matches[2] } else { "2" }
    $dockerVerConstraint  = if ($tfContent -match '"~>\s*([\d\.]+)"[^}]*kreuzwerker/docker|kreuzwerker/docker[^}]*"~>\s*([\d\.]+)"') { $matches[1] + $matches[2] } else { "3" }

    # Provider specs: [namespace, type, major_version, os, arch]
    $providers = @(
        @{ ns = "coder";        type = "coder";  major = "2"; os = "linux"; arch = "amd64" },
        @{ ns = "kreuzwerker";  type = "docker"; major = "3"; os = "linux"; arch = "amd64" }
    )

    foreach ($p in $providers) {
        $regUrl = "https://registry.terraform.io/v1/providers/$($p.ns)/$($p.type)/versions"
        Write-Info "  Fetching available versions for $($p.ns)/$($p.type)..."

        try {
            $versionsResp = Invoke-RestMethod -Uri $regUrl -TimeoutSec 30 -ErrorAction Stop
        } catch {
            Write-Fail "  Failed to query registry for $($p.ns)/$($p.type): $_"
            continue
        }

        # Find latest version matching major version constraint
        $matching = $versionsResp.versions |
            Where-Object { $_.version -match "^$($p.major)\." } |
            Sort-Object { [version]$_.version } -Descending |
            Select-Object -First 1

        if (-not $matching) {
            Write-Fail "  No matching version found for $($p.ns)/$($p.type) ~> $($p.major).x"
            continue
        }

        $version = $matching.version
        Write-Info "  Latest $($p.ns)/$($p.type): v$version"

        # Get download URL
        $dlUrl = "https://registry.terraform.io/v1/providers/$($p.ns)/$($p.type)/$version/download/$($p.os)/$($p.arch)"
        try {
            $dlInfo = Invoke-RestMethod -Uri $dlUrl -TimeoutSec 30 -ErrorAction Stop
        } catch {
            Write-Fail "  Failed to get download info: $_"
            continue
        }

        # Create directory structure
        $destDir = Join-Path $ConfigsDir "terraform-providers\registry.terraform.io\$($p.ns)\$($p.type)\$version\$($p.os)_$($p.arch)"
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        $zipName = "terraform-provider-$($p.type)_${version}_$($p.os)_$($p.arch).zip"
        $zipPath = Join-Path $destDir $zipName

        if (Test-Path $zipPath) {
            Write-OK "  Already downloaded: $zipName"
            continue
        }

        Write-Info "  Downloading $zipName..."
        try {
            Invoke-WebRequest -Uri $dlInfo.download_url -OutFile $zipPath -TimeoutSec 300 -ErrorAction Stop
            $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
            Write-OK "  Downloaded $zipName (${sizeMB} MB)"
        } catch {
            Write-Fail "  Download failed: $_"
            Remove-Item $zipPath -ErrorAction SilentlyContinue
        }
    }
    Write-OK "Terraform providers download complete."
    Write-Info "  Directory: $ConfigsDir\terraform-providers\"
}

# ============================================================
# Step 2: Pull and save platform Docker images
# ============================================================
function Save-PlatformImages {
    Write-Info "=== Step 2: Pulling and saving platform Docker images ==="
    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null

    $env      = Read-EnvFile
    $coderImg = if ($env["CODER_IMAGE"])       { $env["CODER_IMAGE"] }       else { "ghcr.io/coder/coder" }
    $coderVer = if ($env["CODER_VERSION"])     { $env["CODER_VERSION"] }     else { "latest" }
    $pgVer    = if ($env["POSTGRES_VERSION"]) { $env["POSTGRES_VERSION"] } else { "16" }

    $images = [System.Collections.Generic.List[string]]@(
        "${coderImg}:${coderVer}",
        "postgres:${pgVer}-alpine",
        "nginx:alpine"
    )
    if ($IncludeLlm) { $images.Add("ghcr.io/berriai/litellm:main-latest") }

    foreach ($img in $images) {
        Write-Info "  Pulling $img..."
        docker pull $img
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $img"; exit 1 }

        $fname = ($img -replace "[:/]", "_") + ".tar"
        $fpath = Join-Path $ImagesDir $fname
        Write-Info "  Saving $img -> $fname..."
        docker save $img -o $fpath
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to save $img"; exit 1 }
        $sizeMB = [math]::Round((Get-Item $fpath).Length / 1MB)
        Write-OK "  Saved $fname (${sizeMB} MB)"
    }
}

# ============================================================
# Step 3: Build and save workspace image
# ============================================================
function Build-WorkspaceImage {
    Write-Info "=== Step 3: Building workspace image ==="

    $env     = Read-EnvFile
    $imgName = if ($env["WORKSPACE_IMAGE"])     { $env["WORKSPACE_IMAGE"] }     else { "workspace-embedded" }
    $imgTag  = if ($env["WORKSPACE_IMAGE_TAG"]) { $env["WORKSPACE_IMAGE_TAG"] } else { "latest" }

    # Ensure SSL cert exists (baked into workspace image)
    $sslCrt = Join-Path $ConfigsDir "ssl\server.crt"
    if (-not (Test-Path $sslCrt)) {
        Write-Warn "SSL cert not found. Generating for localhost..."
        & (Join-Path $ScriptDir "manage.ps1") ssl localhost
    }

    Write-Info "  Building ${imgName}:${imgTag} (may take 20-40 minutes)..."
    docker build -f "$DockerDir\Dockerfile.workspace" -t "${imgName}:${imgTag}" $ProjectRoot
    if ($LASTEXITCODE -ne 0) { Write-Fail "Build failed."; exit 1 }
    Write-OK "  Build complete: ${imgName}:${imgTag}"

    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null
    $fname = ($imgName -replace "[:/]", "_") + "_$imgTag.tar"
    $fpath = Join-Path $ImagesDir $fname
    Write-Info "  Saving workspace image -> $fname..."
    docker save "${imgName}:${imgTag}" -o $fpath
    if ($LASTEXITCODE -ne 0) { Write-Fail "Save failed."; exit 1 }
    $sizeMB = [math]::Round((Get-Item $fpath).Length / 1MB)
    Write-OK "  Saved $fname (${sizeMB} MB)"
}

# ============================================================
# Main
# ============================================================
Write-Host "=== Coder Offline Resource Preparation ===" -ForegroundColor Blue
Write-Host ""

# Always download TF providers
Get-TerraformProviders
Write-Host ""

if (-not $SkipImages) {
    Save-PlatformImages
    Write-Host ""
}

if (-not $SkipBuild) {
    Build-WorkspaceImage
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Green
Write-Host " Offline preparation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Transfer the following to the offline server:" -ForegroundColor Cyan
Write-Host "  images\          -> Docker image tarballs" -ForegroundColor White
Write-Host "  configs\ssl\     -> TLS certificates" -ForegroundColor White
Write-Host "  configs\terraform-providers\ -> TF provider zips" -ForegroundColor White
Write-Host ""
Write-Host "On the offline server:" -ForegroundColor Cyan
Write-Host "  .\scripts\manage.ps1 load     # load Docker images" -ForegroundColor White
Write-Host "  .\scripts\manage.ps1 init     # create .env" -ForegroundColor White
Write-Host "  .\scripts\manage.ps1 ssl <IP> # regenerate cert for server IP" -ForegroundColor White
Write-Host "  .\scripts\manage.ps1 build    # rebuild workspace image with correct cert" -ForegroundColor White
Write-Host "  .\scripts\manage.ps1 up       # start platform" -ForegroundColor White
