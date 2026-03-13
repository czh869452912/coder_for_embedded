#Requires -Version 5.1

param(
    [switch]$SkipImages,
    [switch]$SkipBuild,
    [switch]$IncludeLlm
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir  = Join-Path $ProjectRoot 'configs'
$DockerDir   = Join-Path $ProjectRoot 'docker'
$ImagesDir   = Join-Path $ProjectRoot 'images'
$EnvFile     = Join-Path $DockerDir '.env'

. (Join-Path $ScriptDir 'lib\offline-common.ps1')

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-OK   { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL]  $Message" -ForegroundColor Red }

function Get-Config {
    if (Test-Path $EnvFile) {
        Ensure-EnvDefaults -EnvFile $EnvFile -ConfigsDir $ConfigsDir
    }
    return Get-EffectiveConfig -ConfigsDir $ConfigsDir -EnvFile $EnvFile
}

function Get-TerraformProviders {
    Write-Info '=== Step 1: Downloading Terraform providers ==='
    $cfg = Get-Config

    $providers = @(
        @{ Namespace = 'coder'; Type = 'coder'; Version = $cfg['TF_PROVIDER_CODER_VERSION']; Os = 'linux'; Arch = 'amd64' },
        @{ Namespace = 'kreuzwerker'; Type = 'docker'; Version = $cfg['TF_PROVIDER_DOCKER_VERSION']; Os = 'linux'; Arch = 'amd64' }
    )

    foreach ($provider in $providers) {
        $downloadInfoUrl = "https://registry.terraform.io/v1/providers/$($provider.Namespace)/$($provider.Type)/$($provider.Version)/download/$($provider.Os)/$($provider.Arch)"
        $destinationDir = Join-Path $ConfigsDir "terraform-providers\registry.terraform.io\$($provider.Namespace)\$($provider.Type)\$($provider.Version)\$($provider.Os)_$($provider.Arch)"
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

        $zipName = "terraform-provider-$($provider.Type)_$($provider.Version)_$($provider.Os)_$($provider.Arch).zip"
        $zipPath = Join-Path $destinationDir $zipName
        if (Test-Path $zipPath) {
            Write-OK "Already downloaded: $zipName"
            continue
        }

        Write-Info "Downloading $zipName"
        $downloadInfo = Invoke-RestMethod -Uri $downloadInfoUrl -TimeoutSec 30
        Invoke-WebRequest -Uri $downloadInfo.download_url -OutFile $zipPath -TimeoutSec 300
        $sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-OK "Saved $zipName (${sizeMb} MB)"
    }
}

function Save-PlatformImages {
    Write-Info '=== Step 2: Pulling and saving runtime images ==='
    $cfg = Get-Config
    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null

    $images = [System.Collections.Generic.List[string]]@(
        $cfg['CODER_IMAGE_REF'],
        $cfg['POSTGRES_IMAGE_REF'],
        $cfg['NGINX_IMAGE_REF']
    )
    if ($IncludeLlm) {
        $images.Add($cfg['LITELLM_IMAGE_REF'])
    }

    foreach ($image in $images) {
        Write-Info "Pulling $image"
        docker pull $image
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $image"; exit 1 }

        $fileName = ($image -replace '[:/@]', '_') + '.tar'
        $filePath = Join-Path $ImagesDir $fileName
        Write-Info "Saving $image -> $fileName"
        docker save $image -o $filePath
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to save $image"; exit 1 }
        $sizeMb = [math]::Round((Get-Item $filePath).Length / 1MB)
        Write-OK "Saved $fileName (${sizeMb} MB)"
    }
}

function Build-WorkspaceImage {
    Write-Info '=== Step 3: Building and saving workspace image ==='
    $cfg = Get-Config
    $sslDir = Join-Path $ConfigsDir 'ssl'
    $serverHost = if ($cfg['SERVER_HOST']) { $cfg['SERVER_HOST'] } else { 'localhost' }
    $workspaceImage = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $workspaceTag = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }

    if (-not (Test-Path (Join-Path $sslDir 'ca.crt'))) {
        Write-Warn 'No root CA found. Generating CA and leaf certificate now.'
        Issue-LeafCertificate -SslDir $sslDir -ServerHost $serverHost | Out-Null
    } elseif (-not (Test-Path (Join-Path $sslDir 'server.crt'))) {
        Write-Warn 'Root CA exists but leaf certificate is missing. Issuing one now.'
        Issue-LeafCertificate -SslDir $sslDir -ServerHost $serverHost | Out-Null
    }

    Write-Info "Pulling build base image $($cfg['CODE_SERVER_BASE_IMAGE_REF'])"
    docker pull $cfg['CODE_SERVER_BASE_IMAGE_REF']
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to pull code-server base image'; exit 1 }

    Write-Info "Building ${workspaceImage}:${workspaceTag}"
    docker build -f "$DockerDir\Dockerfile.workspace" --build-arg "CODE_SERVER_BASE_IMAGE_REF=$($cfg['CODE_SERVER_BASE_IMAGE_REF'])" -t "${workspaceImage}:${workspaceTag}" $ProjectRoot
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Workspace image build failed'; exit 1 }

    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null
    $fileName = "${workspaceImage}_$workspaceTag.tar"
    $filePath = Join-Path $ImagesDir $fileName
    Write-Info "Saving ${workspaceImage}:${workspaceTag} -> $fileName"
    docker save "${workspaceImage}:${workspaceTag}" -o $filePath
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to save workspace image'; exit 1 }
    $sizeMb = [math]::Round((Get-Item $filePath).Length / 1MB)
    Write-OK "Saved $fileName (${sizeMb} MB)"
}

Write-Host '=== Coder Offline Resource Preparation ===' -ForegroundColor Blue
Write-Host ''

Get-TerraformProviders
Write-Host ''

if (-not $SkipImages) {
    Save-PlatformImages
    Write-Host ''
}

if (-not $SkipBuild) {
    Build-WorkspaceImage
    Write-Host ''
}

Write-Host '========================================' -ForegroundColor Green
Write-Host ' Offline preparation complete' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Transfer these items to the offline server:' -ForegroundColor Cyan
Write-Host '  entire project directory' -ForegroundColor White
Write-Host '  images\' -ForegroundColor White
Write-Host '  configs\ssl\   (keep ca.crt and ca.key so the target only reissues a leaf cert)' -ForegroundColor White
Write-Host '  configs\terraform-providers\' -ForegroundColor White
Write-Host ''
Write-Host 'Offline deployment path:' -ForegroundColor Cyan
Write-Host '  .\scripts\manage.ps1 load' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 init' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 ssl <TARGET_IP_OR_HOST>' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 up' -ForegroundColor White
Write-Host ''
Write-Host 'If the CA changes on the offline side, rebuild the workspace image once. Leaf-only rotation does not require rebuild.' -ForegroundColor Yellow
