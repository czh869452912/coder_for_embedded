param(
    [switch]$SkipImages,
    [switch]$SkipBuild,
    [switch]$IncludeLlm
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSNativeCommandUseErrorActionPreference = $false

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigsDir = Join-Path $ProjectRoot 'configs'
$DockerDir = Join-Path $ProjectRoot 'docker'
$ImagesDir = Join-Path $ProjectRoot 'images'
$EnvFile = Join-Path $DockerDir '.env'
$ManifestPath = Join-Path $ProjectRoot 'offline-manifest.json'

. (Join-Path $ScriptDir 'lib\offline-common.ps1')

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-OK { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL]  $Message" -ForegroundColor Red }

function Get-Config {
    if (Test-Path $EnvFile) {
        Ensure-EnvDefaults -EnvFile $EnvFile -ConfigsDir $ConfigsDir
    }
    return Get-EffectiveConfig -ConfigsDir $ConfigsDir -EnvFile $EnvFile
}

function Get-ImageArchiveName {
    param([string]$ImageRef)
    return (($ImageRef -replace '[:/@]', '_') + '.tar')
}

function Get-WorkspaceArchiveName {
    param([hashtable]$Config)
    $workspaceImage = if ($Config['WORKSPACE_IMAGE']) { $Config['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $workspaceTag = if ($Config['WORKSPACE_IMAGE_TAG']) { $Config['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
    return "${workspaceImage}_$workspaceTag.tar"
}

function Get-VsixExtensions {
    Write-Info '=== Step 0: Downloading VS Code extensions (.vsix) ==='
    $vsixDir = Join-Path $ConfigsDir 'vsix'
    New-Item -ItemType Directory -Path $vsixDir -Force | Out-Null

    # Extensions unavailable on Open VSX that must be pre-downloaded as .vsix files.
    # The Dockerfile installs any .vsix found in configs/vsix/ as a fallback.

    # cmake-tools: not on Open VSX (Microsoft proprietary), simple direct URL
    $cmakeDest = Join-Path $vsixDir 'ms-vscode.cmake-tools.vsix'
    if (Test-Path $cmakeDest) {
        Write-OK 'Already downloaded: ms-vscode.cmake-tools.vsix'
    } else {
        Write-Info 'Downloading ms-vscode.cmake-tools'
        $cmakeUrl = 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode/vsextensions/cmake-tools/latest/vspackage'
        try {
            Invoke-WebRequest -Uri $cmakeUrl -OutFile $cmakeDest -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
            Write-OK 'Saved ms-vscode.cmake-tools.vsix'
        } catch {
            Write-Warn "Failed to download cmake-tools — continuing without it (not fatal)"
            Remove-Item $cmakeDest -Force -ErrorAction SilentlyContinue
        }
    }

    # cpptools linux-x64: platform-specific extension, requires Gallery API to resolve CDN URL
    $cpptoolsDest = Join-Path $vsixDir 'ms-vscode.cpptools-linux-x64.vsix'
    if (Test-Path $cpptoolsDest) {
        Write-OK 'Already downloaded: ms-vscode.cpptools-linux-x64.vsix'
    } else {
        Write-Info 'Downloading ms-vscode.cpptools (linux-x64)'
        try {
            $queryBody = '{"filters":[{"criteria":[{"filterType":7,"value":"ms-vscode.cpptools"}]}],"flags":2151}'
            $apiResp = Invoke-RestMethod -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' `
                -Method POST -ContentType 'application/json' -Body $queryBody `
                -Headers @{ 'Accept' = 'application/json;api-version=3.0-preview.1' } -TimeoutSec 20 -ErrorAction Stop
            $versions = $apiResp.results[0].extensions[0].versions
            $linuxVer = $versions | Where-Object { $_.targetPlatform -eq 'linux-x64' } | Select-Object -First 1
            $vsixAsset = $linuxVer.files | Where-Object { $_.assetType -eq 'Microsoft.VisualStudio.Services.VSIXPackage' }
            Invoke-WebRequest -Uri $vsixAsset.source -OutFile $cpptoolsDest -TimeoutSec 300 -UseBasicParsing -ErrorAction Stop
            Write-OK 'Saved ms-vscode.cpptools-linux-x64.vsix'
        } catch {
            Write-Warn "Failed to download cpptools — continuing without it (not fatal)"
            Remove-Item $cpptoolsDest -Force -ErrorAction SilentlyContinue
        }
    }
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
        $extractedMarker = Join-Path $destinationDir '.extracted'
        
        if (Test-Path $extractedMarker) {
            Write-OK "Already downloaded and extracted: $zipName"
            continue
        }

        Write-Info "Downloading $zipName"
        $downloadInfo = Invoke-RestMethod -Uri $downloadInfoUrl -TimeoutSec 30
        Invoke-WebRequest -Uri $downloadInfo.download_url -OutFile $zipPath -TimeoutSec 300
        Expand-Archive -Path $zipPath -DestinationPath $destinationDir -Force
        Remove-Item $zipPath -Force
        Set-Content -Path $extractedMarker -Value '1'
        Write-OK "Saved and extracted $zipName"
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

        $fileName = Get-ImageArchiveName -ImageRef $image
        $filePath = Join-Path $ImagesDir $fileName
        Write-Info "Saving $image -> $fileName"
        docker save $image -o $filePath
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to save $image"; exit 1 }
        Write-OK "Saved $fileName"
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
    $fileName = Get-WorkspaceArchiveName -Config $cfg
    $filePath = Join-Path $ImagesDir $fileName
    Write-Info "Saving ${workspaceImage}:${workspaceTag} -> $fileName"
    docker save "${workspaceImage}:${workspaceTag}" -o $filePath
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to save workspace image'; exit 1 }
    Write-OK "Saved $fileName"
}

function Write-OfflineManifest {
    $cfg = Get-Config
    $caCert = Join-Path $ConfigsDir 'ssl\ca.crt'
    $images = @(
        [ordered]@{ ref = $cfg['CODER_IMAGE_REF']; archive = "images/$((Get-ImageArchiveName -ImageRef $cfg['CODER_IMAGE_REF']))" },
        [ordered]@{ ref = $cfg['POSTGRES_IMAGE_REF']; archive = "images/$((Get-ImageArchiveName -ImageRef $cfg['POSTGRES_IMAGE_REF']))" },
        [ordered]@{ ref = $cfg['NGINX_IMAGE_REF']; archive = "images/$((Get-ImageArchiveName -ImageRef $cfg['NGINX_IMAGE_REF']))" },
        [ordered]@{ ref = "$(if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }):$(if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' })"; archive = "images/$((Get-WorkspaceArchiveName -Config $cfg))" }
    )
    if ($IncludeLlm) {
        $images += [ordered]@{ ref = $cfg['LITELLM_IMAGE_REF']; archive = "images/$((Get-ImageArchiveName -ImageRef $cfg['LITELLM_IMAGE_REF']))" }
    }

    $providers = @(
        [ordered]@{
            source = 'registry.terraform.io/coder/coder'
            version = $cfg['TF_PROVIDER_CODER_VERSION']
            archive = "configs/terraform-providers/registry.terraform.io/coder/coder/$($cfg['TF_PROVIDER_CODER_VERSION'])/linux_amd64/.extracted"
        },
        [ordered]@{
            source = 'registry.terraform.io/kreuzwerker/docker'
            version = $cfg['TF_PROVIDER_DOCKER_VERSION']
            archive = "configs/terraform-providers/registry.terraform.io/kreuzwerker/docker/$($cfg['TF_PROVIDER_DOCKER_VERSION'])/linux_amd64/.extracted"
        }
    )

    $manifest = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        include_llm = [bool]$IncludeLlm
        terraform_cli_config_mount_default = '../configs/terraform-offline.rc'
        ca_sha256 = if (Test-Path $caCert) { (Get-FileHash $caCert -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
        images = $images
        providers = $providers
    }

    $json = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($ManifestPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
    Write-OK "Wrote $ManifestPath"
}

Write-Host '=== Coder Offline Resource Preparation ===' -ForegroundColor Blue
Write-Host ''

Get-VsixExtensions
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

Write-OfflineManifest
Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' Offline preparation complete' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Recommended next steps:' -ForegroundColor Cyan
Write-Host '  .\scripts\verify-offline.ps1' -ForegroundColor White
Write-Host '  Transfer the whole project directory to the offline server' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 load' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 init' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 ssl <TARGET_IP_OR_HOST>' -ForegroundColor White
Write-Host '  .\scripts\manage.ps1 up' -ForegroundColor White
