#Requires -Version 5.1

param(
    [Parameter(Position=0)]
    [string]$Command = "help",
    [Parameter(Position=1)]
    [string]$Arg1 = "",
    [switch]$Llm,
    [switch]$Ldap,
    [switch]$Mineru,
    [switch]$Doctools,
    [string]$Tag = "",
    [switch]$Apply,
    [switch]$RequireLlm,
    [switch]$SkipImages,
    [switch]$SkipBuild,
    [string]$Dest = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSNativeCommandUseErrorActionPreference = $false

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DockerDir   = Join-Path $ProjectRoot "docker"
$ConfigsDir  = Join-Path $ProjectRoot "configs"
$EnvFile     = Join-Path $DockerDir ".env"
$SetupDone   = Join-Path $DockerDir ".setup-done"
$ImagesDir   = Join-Path $ProjectRoot "images"
$LockFile    = Join-Path $ConfigsDir "versions.lock.env"
$script:UseLlm      = $Llm.IsPresent
$script:UseLdap     = $Ldap.IsPresent
$script:UseMineru   = $Mineru.IsPresent
$script:UseDoctools = $Doctools.IsPresent
$script:Apply      = $Apply.IsPresent
$script:RequireLlm = $RequireLlm.IsPresent
$script:SkipImages = $SkipImages.IsPresent
$script:SkipBuild  = $SkipBuild.IsPresent

. (Join-Path $ScriptDir "lib\offline-common.ps1")

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-OK   { param([string]$Message) Write-Host "[ OK ]  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL]  $Message" -ForegroundColor Red }

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Fail "docker not found. Please install Docker Desktop."
        exit 1
    }

    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker info 2>&1 | Out-Null
    $dockerExit = $LASTEXITCODE
    docker compose version 2>&1 | Out-Null
    $composeExit = $LASTEXITCODE
    $ErrorActionPreference = $eap

    if ($dockerExit -ne 0) {
        Write-Fail "Docker daemon is not running."
        exit 1
    }
    if ($composeExit -ne 0) {
        Write-Fail "docker compose is not available."
        exit 1
    }
}

function Initialize-Dirs {
    foreach ($path in @(
        $DockerDir,
        (Join-Path $ConfigsDir "ssl"),
        (Join-Path $ConfigsDir "terraform-providers"),
        (Join-Path $ConfigsDir "vsix"),
        (Join-Path $ConfigsDir "provider-mirror\registry.terraform.io"),
        (Join-Path $ProjectRoot "images"),
        (Join-Path $ProjectRoot "logs\nginx")
    )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Get-Config {
    if (Test-Path $EnvFile) {
        Ensure-EnvDefaults -EnvFile $EnvFile -ConfigsDir $ConfigsDir
    }
    return Get-EffectiveConfig -ConfigsDir $ConfigsDir -EnvFile $EnvFile
}

function New-RandomHex {
    param([int]$Bytes = 16)
    $buffer = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return ($buffer | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}

function Get-WorkspaceImageRef {
    $cfg = Get-Config
    $image = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $tag = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
    return "${image}:${tag}"
}

function Get-LlmGatewayUrl {
    param([hashtable]$Config)
    # 容器现已加入 coderplatform，直接通过 Docker DNS 访问网关服务更稳定
    return "http://llm-gateway:4000"
}

function Get-TerraformCliConfigMount {
    param([hashtable]$Config)
    if ($Config['TF_CLI_CONFIG_MOUNT']) { return $Config['TF_CLI_CONFIG_MOUNT'] }
    return '../configs/terraform-offline.rc'
}

function Assert-LlmConfig {
    if (-not $script:UseLlm) { return }

    $cfg = Get-Config
    $configPath = Join-Path $ConfigsDir 'litellm_config.yaml'
    if (-not (Test-Path $configPath)) {
        Write-Fail "LiteLLM is enabled but configs\litellm_config.yaml is missing."
        exit 1
    }
    if (-not $cfg['INTERNAL_API_BASE']) {
        Write-Fail "INTERNAL_API_BASE is not configured."
        exit 1
    }
    if (-not $cfg['INTERNAL_API_KEY']) {
        Write-Fail "INTERNAL_API_KEY is not configured."
        exit 1
    }

    $configText = Get-Content $configPath -Raw
    if ($configText -match 'YOUR_INTERNAL_MODEL') {
        Write-Fail "LiteLLM config still contains YOUR_INTERNAL_MODEL placeholders."
        exit 1
    }
}

function Invoke-Init {
    Write-Info "Initializing docker/.env ..."
    if (Test-Path $EnvFile) {
        $answer = Read-Host "docker/.env already exists. Overwrite? (y/N)"
        if ($answer -notmatch '^[Yy]$') {
            Write-OK "Keeping existing docker/.env"
            return
        }
    }

    $postgresPassword = New-RandomHex -Bytes 16
    $defaultIp = '192.168.1.100'
    try {
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL' -and $_.IPAddress -match '^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.' }
        if ($adapters) { $defaultIp = ($adapters | Select-Object -First 1).IPAddress }
    } catch {}

    Write-Host '! IMPORTANT: Do not use localhost if running workspaces in Docker. Provide your LAN IP instead.' -ForegroundColor Yellow
    $serverHost = Read-Host "Server IP or hostname [$defaultIp]"
    if (-not $serverHost) { $serverHost = $defaultIp }

    $gatewayPort = Read-Host 'Gateway port [8443]'
    if (-not $gatewayPort) { $gatewayPort = '8443' }

    $adminEmail = Read-Host 'Coder admin email [admin@company.local]'
    if (-not $adminEmail) { $adminEmail = 'admin@company.local' }

    $adminUsername = Read-Host 'Coder admin username [admin]'
    if (-not $adminUsername) { $adminUsername = 'admin' }

    $adminPasswordSec = Read-Host 'Coder admin password (min 8 chars)' -AsSecureString
    $adminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPasswordSec)
    )
    if ($adminPassword.Length -lt 8) {
        $adminPassword = "Coder@$(Get-Date -Format 'yyyy')"
        Write-Warn "Password too short. Auto-generated: $adminPassword"
    }

    $anthropicKey = Read-Host 'Anthropic API key (blank to skip)'
    $anthropicUrl = Read-Host 'Anthropic base URL (blank to skip)'

    $lines = @(
        '# Mutable environment for this deployment.',
        '',
        '# ---- Network ----',
        "SERVER_HOST=$serverHost",
        "GATEWAY_PORT=$gatewayPort",
        '',
        '# ---- Database ----',
        "POSTGRES_PASSWORD=$postgresPassword",
        '',
        '# ---- Coder admin ----',
        "CODER_ADMIN_EMAIL=$adminEmail",
        "CODER_ADMIN_USERNAME=$adminUsername",
        "CODER_ADMIN_PASSWORD=$adminPassword",
        '',
        '# ---- Claude / Anthropic settings ----',
        "ANTHROPIC_API_KEY=$anthropicKey",
        "ANTHROPIC_BASE_URL=$anthropicUrl",
        '',
        '# ---- LiteLLM gateway ----',
        'LITELLM_MASTER_KEY=sk-devenv',
        'INTERNAL_API_BASE=http://10.0.0.1:8000',
        'INTERNAL_API_KEY=your-internal-api-key',
        '',
        '# ---- Terraform provider resolution ----',
        'TF_CLI_CONFIG_MOUNT=../configs/terraform-offline.rc',
        '',
        '# ---- Internal ports ----',
        'CODER_INTERNAL_PORT=7080'
    )

    [System.IO.File]::WriteAllText($EnvFile, ($lines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
    Ensure-EnvDefaults -EnvFile $EnvFile -ConfigsDir $ConfigsDir
    Write-OK "Created $EnvFile"

    $createLlmConfig = Read-Host 'Also create configs/litellm_config.yaml? (y/N)'
    if ($createLlmConfig -match '^[Yy]$') {
        $examplePath = Join-Path $ConfigsDir 'litellm_config.yaml.example'
        $configPath = Join-Path $ConfigsDir 'litellm_config.yaml'
        if ((Test-Path $examplePath) -and (-not (Test-Path $configPath))) {
            Copy-Item $examplePath $configPath
            Write-OK "Created $configPath"
        } elseif (Test-Path $configPath) {
            Write-Warn "LiteLLM config already exists: $configPath"
        }
    }
}

function Invoke-GenSSL {
    param([string]$ServerHost = '')

    $sslDir = Join-Path $ConfigsDir 'ssl'
    $resolvedHost = if ($ServerHost) { $ServerHost } else { 'localhost' }
    Write-Info "Issuing TLS leaf certificate for $resolvedHost"
    $result = Issue-LeafCertificate -SslDir $sslDir -ServerHost $resolvedHost
    Write-OK "Certificates written to $sslDir"

    if (Import-RootCAToWindows -CaCert $result.CaCert) {
        Write-OK 'Imported root CA into Windows Trusted Root store.'
    } else {
        Write-Warn "Could not import root CA automatically. Import $($result.CaCert) manually if you want the browser to trust it."
    }

    if ($result.CaCreated) {
        Write-Warn 'A new root CA was created. Rebuild the workspace image once so containers trust it.'
    } else {
        Write-Info 'Root CA already existed. Rotating only the leaf certificate does not require rebuilding the workspace image.'
    }
}

function Invoke-Pull {
    Assert-Docker
    $cfg = Get-Config

    $images = [System.Collections.Generic.List[string]]@(
        $cfg['CODER_IMAGE_REF'],
        $cfg['POSTGRES_IMAGE_REF'],
        $cfg['NGINX_IMAGE_REF'],
        $cfg['CODE_SERVER_BASE_IMAGE_REF']
    )
    if ($script:UseLlm)      { $images.Add($cfg['LITELLM_IMAGE_REF']) }
    if ($script:UseLdap)     { $images.Add($cfg['DEX_IMAGE_REF']) }
    if ($script:UseMineru)   { $images.Add($cfg['MINERU_IMAGE_REF']) }
    if ($script:UseDoctools) { $images.Add($cfg['DOCCONV_IMAGE_REF']) }

    foreach ($image in $images) {
        Write-Info "Pulling $image"
        docker pull $image
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to pull $image"
            exit 1
        }
    }

    Write-OK 'Base images pulled.'
    Write-Warn 'Run build to produce the workspace image used by the template.'
}

function Invoke-Build {
    Assert-Docker
    Initialize-Dirs
    $cfg = Get-Config

    $sslDir = Join-Path $ConfigsDir 'ssl'
    $ca = Ensure-RootCA -SslDir $sslDir
    if ($ca.Created) {
        Write-Warn 'Created a new root CA for workspace trust.'
    }

    $image = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $tag = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
    $codeServerBase = $cfg['CODE_SERVER_BASE_IMAGE_REF']

    Write-Info "Building ${image}:${tag}"
    docker build `
        -f "$DockerDir\Dockerfile.workspace" `
        --build-arg "CODE_SERVER_BASE_IMAGE_REF=$codeServerBase" `
        -t "${image}:${tag}" `
        $ProjectRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Workspace image build failed.'
        exit 1
    }

    Write-OK "Built ${image}:${tag}"
}

function Invoke-Save {
    Assert-Docker
    $cfg = Get-Config
    $imagesDir = Join-Path $ProjectRoot 'images'
    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null

    $workspaceImage = Get-WorkspaceImageRef
    $images = [System.Collections.Generic.List[string]]@(
        $cfg['CODER_IMAGE_REF'],
        $cfg['POSTGRES_IMAGE_REF'],
        $cfg['NGINX_IMAGE_REF'],
        $workspaceImage
    )
    if ($script:UseLlm)      { $images.Add($cfg['LITELLM_IMAGE_REF']) }
    if ($script:UseLdap)     { $images.Add($cfg['DEX_IMAGE_REF']) }
    if ($script:UseMineru)   { $images.Add($cfg['MINERU_IMAGE_REF']) }
    if ($script:UseDoctools) { $images.Add($cfg['DOCCONV_IMAGE_REF']) }

    # Build a digest-ref -> name:tag fallback map in case the digest ref is no longer cached
    # (e.g. after pulling a newer version of the tag via refresh-versions without -Apply).
    $refTagFallback = @{}
    foreach ($entry in @(
        @{ Ref = 'CODER_IMAGE_REF';           Tag = 'CODER_IMAGE_TAG' },
        @{ Ref = 'POSTGRES_IMAGE_REF';         Tag = 'POSTGRES_IMAGE_TAG' },
        @{ Ref = 'NGINX_IMAGE_REF';            Tag = 'NGINX_IMAGE_TAG' },
        @{ Ref = 'LITELLM_IMAGE_REF';          Tag = 'LITELLM_IMAGE_TAG' },
        @{ Ref = 'CODE_SERVER_BASE_IMAGE_REF'; Tag = 'CODE_SERVER_BASE_IMAGE_TAG' },
        @{ Ref = 'DEX_IMAGE_REF';              Tag = 'DEX_IMAGE_TAG' },
        @{ Ref = 'MINERU_IMAGE_REF';           Tag = 'MINERU_IMAGE_TAG' },
        @{ Ref = 'DOCCONV_IMAGE_REF';          Tag = 'DOCCONV_IMAGE_TAG' }
    )) {
        $r = $cfg[$entry.Ref]; $t = $cfg[$entry.Tag]
        if ($r -and $t -and ($r -match '@sha256:')) {
            $refTagFallback[$r] = "$(($r -split '@')[0]):${t}"
        }
    }

    foreach ($image in $images) {
        $fileName = ($image -replace '[:/@]', '_') + '.tar'
        $filePath = Join-Path $imagesDir $fileName

        # If the digest ref is no longer in the local cache, fall back to name:tag
        $imageToSave = $image
        if ($image -match '@sha256:') {
            $eapSv = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            docker image inspect $image 2>&1 | Out-Null
            $checkExit = $LASTEXITCODE
            $ErrorActionPreference = $eapSv
            if ($checkExit -ne 0 -and $refTagFallback.ContainsKey($image)) {
                $imageToSave = $refTagFallback[$image]
                Write-Warn "Digest ref not in local cache; saving $imageToSave instead."
                Write-Warn "Run 'refresh-versions -Apply' then 'save' again to keep pinned digests in sync."
            }
        }

        Write-Info "Saving $imageToSave -> $fileName"
        docker save $imageToSave -o $filePath
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to save $imageToSave"
            exit 1
        }
        $savedBytes = (Get-Item $filePath).Length
        $sizeMb = [math]::Round($savedBytes / 1MB)
        if ($savedBytes -lt 1MB) {
            Write-Fail "Saved file is unexpectedly small (${savedBytes} bytes). docker save may have failed silently."
            Write-Fail "If Docker Desktop uses the containerd image store, try: Settings > General > uncheck 'Use containerd for pulling and storing images', restart Docker, then re-pull and re-save."
            exit 1
        }
        Write-OK "Saved ${sizeMb} MB"
    }
}

function Invoke-Load {
    Assert-Docker
    $imagesDir = Join-Path $ProjectRoot 'images'
    if (-not (Test-Path $imagesDir)) {
        Write-Fail 'images directory not found.'
        exit 1
    }

    $tarFiles = Get-ChildItem "$imagesDir\*.tar" -ErrorAction SilentlyContinue
    if (-not $tarFiles) {
        Write-Fail 'No image tarballs found in images.'
        exit 1
    }

    # Build filename -> name:tag map so digest-referenced images can be retagged after load.
    # When an image is saved by digest ref (e.g. ghcr.io/coder/coder@sha256:...), the tar has
    # no RepoTag and docker load reports "Loaded image ID: sha256:..." with no usable name.
    # Retagging to name:tag lets docker compose find the image without hitting the registry.
    $cfg = Get-Config
    $fileTagMap = @{}
    foreach ($entry in @(
        @{ Ref = 'CODER_IMAGE_REF';           Tag = 'CODER_IMAGE_TAG' },
        @{ Ref = 'POSTGRES_IMAGE_REF';         Tag = 'POSTGRES_IMAGE_TAG' },
        @{ Ref = 'NGINX_IMAGE_REF';            Tag = 'NGINX_IMAGE_TAG' },
        @{ Ref = 'LITELLM_IMAGE_REF';          Tag = 'LITELLM_IMAGE_TAG' },
        @{ Ref = 'CODE_SERVER_BASE_IMAGE_REF'; Tag = 'CODE_SERVER_BASE_IMAGE_TAG' },
        @{ Ref = 'DEX_IMAGE_REF';              Tag = 'DEX_IMAGE_TAG' },
        @{ Ref = 'MINERU_IMAGE_REF';           Tag = 'MINERU_IMAGE_TAG' },
        @{ Ref = 'DOCCONV_IMAGE_REF';          Tag = 'DOCCONV_IMAGE_TAG' }
    )) {
        $ref = $cfg[$entry.Ref]
        $tag = $cfg[$entry.Tag]
        if ($ref -and $tag -and ($ref -match '@sha256:')) {
            $fn = ($ref -replace '[:/@]', '_') + '.tar'
            $imageName = ($ref -split '@')[0]
            $fileTagMap[$fn] = "${imageName}:${tag}"
        }
    }

    foreach ($tarFile in $tarFiles) {
        $sizeMb = [math]::Round($tarFile.Length / 1MB)
        Write-Info "Loading $($tarFile.Name) (${sizeMb} MB)"
        $loadOutput = docker load -i $tarFile.FullName 2>&1
        $loadOutput | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to load $($tarFile.Name)"
            exit 1
        }

        # If loaded without a repo tag, retag with name:tag so compose can resolve it offline
        $outputStr = $loadOutput | Out-String
        if ($outputStr -match 'Loaded image ID:\s*(sha256:\S+)') {
            $imageId = $Matches[1]
            $targetTag = $fileTagMap[$tarFile.Name]
            if ($targetTag) {
                Write-Info "Tagging $imageId -> $targetTag"
                docker tag $imageId $targetTag
            }
        }
    }

    Write-OK 'Images loaded.'
}

function Invoke-Up {
    Assert-Docker
    Initialize-Dirs

    if (-not (Test-Path $EnvFile)) {
        Write-Fail 'docker/.env not found. Run init first.'
        exit 1
    }

    $cfg = Get-Config
    $sslDir = Join-Path $ConfigsDir 'ssl'
    if (-not (Test-Path (Join-Path $sslDir 'server.crt'))) {
        Write-Warn 'TLS leaf certificate not found. Generating one now.'
        Invoke-GenSSL -ServerHost $cfg['SERVER_HOST']
    }

    if ($script:UseLlm) {
        Assert-LlmConfig
    }

    $workspaceImage = Get-WorkspaceImageRef
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker image inspect $workspaceImage 2>&1 | Out-Null
    $imageExists = $LASTEXITCODE
    $ErrorActionPreference = $eap
    if ($imageExists -ne 0) {
        Write-Warn "Workspace image $workspaceImage not found. Building it now."
        Invoke-Build
    }

    $terraformConfigMount = Get-TerraformCliConfigMount -Config $cfg
    $terraformConfigHostPath = if ([System.IO.Path]::IsPathRooted($terraformConfigMount)) {
        $terraformConfigMount
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $DockerDir $terraformConfigMount))
    }
    if (-not (Test-Path $terraformConfigHostPath)) {
        Write-Fail "Terraform CLI config not found: $terraformConfigHostPath"
        exit 1
    }

    $mirrorRoot = Join-Path $ConfigsDir 'provider-mirror\registry.terraform.io'
    $offlineTerraformMode = ([System.IO.Path]::GetFileName($terraformConfigHostPath) -ieq 'terraform-offline.rc')
    $mirrorHasIndexes = (Get-ChildItem -Path $mirrorRoot -Filter 'index.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
    if (-not $mirrorHasIndexes) {
        if ($offlineTerraformMode) {
            Write-Fail "Offline Terraform mode is active but the provider mirror is empty. Run '.\scripts\manage.ps1 prepare' or 'update-provider-mirror.ps1' first."
            exit 1
        }
        Write-Warn 'Provider mirror is empty. Terraform will attempt direct registry access.'
    } elseif (-not $offlineTerraformMode) {
        Write-Info 'Provider mirror ready. Connected mode: local mirror first, then registry fallback.'
    }

    # In offline/loaded mode Docker cannot resolve digest refs against the registry.
    # Override image ref env vars to use name:tag format before invoking compose,
    # so compose resolves against the locally loaded (and retagged) images.
    $requiredImages = [System.Collections.Generic.List[string]]@()
    foreach ($mapping in @(
        @{ Ref = 'CODER_IMAGE_REF';    Tag = 'CODER_IMAGE_TAG'    },
        @{ Ref = 'POSTGRES_IMAGE_REF'; Tag = 'POSTGRES_IMAGE_TAG' },
        @{ Ref = 'NGINX_IMAGE_REF';    Tag = 'NGINX_IMAGE_TAG'    },
        @{ Ref = 'LITELLM_IMAGE_REF';  Tag = 'LITELLM_IMAGE_TAG'  },
        @{ Ref = 'DEX_IMAGE_REF';      Tag = 'DEX_IMAGE_TAG'      }
    )) {
        $ref = $cfg[$mapping.Ref]
        $tag = $cfg[$mapping.Tag]
        if (-not $ref) { continue }
        if ($ref -match '@sha256:' -and $tag) {
            $nameTag = "$(($ref -split '@')[0]):${tag}"
            [System.Environment]::SetEnvironmentVariable($mapping.Ref, $nameTag, 'Process')
            $requiredImages.Add($nameTag)
        } else {
            $requiredImages.Add($ref)
        }
    }

    # Pre-flight: verify every required image exists locally so compose never falls back to a pull
    $missingImages = [System.Collections.Generic.List[string]]@()
    $eapPf = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    foreach ($img in $requiredImages) {
        if (-not $script:UseLlm      -and $img -match 'litellm') { continue }
        if (-not $script:UseLdap     -and $img -match 'dexidp')  { continue }
        if (-not $script:UseMineru   -and $img -match 'mineru')   { continue }
        if (-not $script:UseDoctools -and $img -match 'pandoc')   { continue }
        docker image inspect $img 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $missingImages.Add($img) }
    }
    $ErrorActionPreference = $eapPf
    if ($missingImages.Count -gt 0) {
        Write-Fail "The following images are not available locally. Run 'load' (with the correct flags) first:"
        $missingImages | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }

    $composeArgs = [System.Collections.Generic.List[string]]@()
    if ($script:UseLlm)      { $composeArgs.AddRange([string[]]@('--profile', 'llm')) }
    if ($script:UseLdap)     { $composeArgs.AddRange([string[]]@('--profile', 'ldap')) }
    if ($script:UseMineru)   { $composeArgs.AddRange([string[]]@('--profile', 'mineru')) }
    if ($script:UseDoctools) { $composeArgs.AddRange([string[]]@('--profile', 'doctools')) }
    $composeArgs.AddRange([string[]]@('up', '-d'))
    Push-Location $DockerDir
    docker compose @composeArgs
    $composeExit = $LASTEXITCODE
    Pop-Location
    if ($composeExit -ne 0) {
        Write-Fail 'docker compose up failed.'
        exit 1
    }

    Write-OK 'Platform started.'

    if (-not (Test-Path $SetupDone)) {
        Write-Warn 'First startup detected. Running setup-coder after a short delay.'
        Start-Sleep -Seconds 8
        Invoke-SetupCoder
    } else {
        Show-AccessInfo
    }
}

function Invoke-Down {
    Assert-Docker
    $downArgs = [System.Collections.Generic.List[string]]@()
    if ($script:UseLlm)      { $downArgs.AddRange([string[]]@('--profile', 'llm')) }
    if ($script:UseLdap)     { $downArgs.AddRange([string[]]@('--profile', 'ldap')) }
    if ($script:UseMineru)   { $downArgs.AddRange([string[]]@('--profile', 'mineru')) }
    if ($script:UseDoctools) { $downArgs.AddRange([string[]]@('--profile', 'doctools')) }
    $downArgs.Add('down')
    Push-Location $DockerDir
    docker compose @downArgs
    $composeExit = $LASTEXITCODE
    Pop-Location
    if ($composeExit -ne 0) {
        Write-Fail 'docker compose down failed.'
        exit 1
    }
    Write-OK 'Platform stopped.'
}

function Invoke-Status {
    Assert-Docker
    Push-Location $DockerDir
    docker compose ps
    Pop-Location
}

function Invoke-Logs {
    Assert-Docker
    Push-Location $DockerDir
    if ($Arg1) {
        docker compose logs -f --tail=100 $Arg1
    } else {
        docker compose logs -f --tail=100
    }
    Pop-Location
}

function Invoke-Shell {
    Assert-Docker
    if (-not $Arg1) {
        Write-Fail 'Specify a service name. Example: .\scripts\manage.ps1 shell coder'
        exit 1
    }
    Push-Location $DockerDir
    docker compose exec $Arg1 /bin/bash
    Pop-Location
}

function Invoke-SetupCoder {
    if (-not (Test-Path $EnvFile)) {
        Write-Fail 'Run init first.'
        exit 1
    }

    $cfg = Get-Config
    $internalPort = if ($cfg['CODER_INTERNAL_PORT']) { $cfg['CODER_INTERNAL_PORT'] } else { '7080' }
    $baseUrl = "http://localhost:$internalPort"
    $adminEmail = if ($cfg['CODER_ADMIN_EMAIL']) { $cfg['CODER_ADMIN_EMAIL'] } else { 'admin@company.local' }
    $adminUsername = if ($cfg['CODER_ADMIN_USERNAME']) { $cfg['CODER_ADMIN_USERNAME'] } else { 'admin' }
    $adminPassword = if ($cfg['CODER_ADMIN_PASSWORD']) { $cfg['CODER_ADMIN_PASSWORD'] } else { '' }

    if ($script:UseLlm) {
        Assert-LlmConfig
    }

    Write-Info 'Waiting for Coder health endpoint...'
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "$baseUrl/healthz" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {}
        Start-Sleep -Seconds 3
    }
    if (-not $ready) {
        Write-Fail 'Coder did not become ready within 180 seconds.'
        exit 1
    }
    Write-OK 'Coder is ready.'

    try {
        $firstUserResponse = Invoke-WebRequest -Uri "$baseUrl/api/v2/users/first" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $firstUserStatus = $firstUserResponse.StatusCode
    } catch {
        $firstUserStatus = $_.Exception.Response.StatusCode.Value__
    }

    if ($firstUserStatus -eq 404) {
        Write-Info "Creating admin account $adminEmail"
        $body = '{"email":"' + $adminEmail + '","username":"' + $adminUsername + '","password":"' + $adminPassword + '","trial":false}'
        Invoke-RestMethod -Uri "$baseUrl/api/v2/users/first" -Method POST -ContentType 'application/json' -Body $body | Out-Null
        Write-OK 'Admin account created.'
    } else {
        Write-Info 'Admin account already exists.'
    }

    $loginBody = '{"email":"' + $adminEmail + '","password":"' + $adminPassword + '"}'
    $loginResponse = Invoke-RestMethod -Uri "$baseUrl/api/v2/users/login" -Method POST -ContentType 'application/json' -Body $loginBody
    $sessionToken = $loginResponse.session_token
    if (-not $sessionToken) {
        Write-Fail 'Failed to get Coder session token.'
        exit 1
    }

    try {
        $templateResponse = Invoke-WebRequest -Uri "$baseUrl/api/v2/organizations/default/templates/embedded-dev" -Headers @{ 'Coder-Session-Token' = $sessionToken } -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $templateExists = ($templateResponse.StatusCode -eq 200)
    } catch {
        $templateExists = $false
    }

    if ($templateExists) {
        Write-Info "Template 'embedded-dev' already exists. Pushing a new version to apply current variables."
    }

    Invoke-PushTemplate -SessionToken $sessionToken

    Get-Date | Set-Content $SetupDone
    Show-AccessInfo
}

# Shared template push — called by setup-coder, push-template, update-workspace, load-workspace
function Invoke-PushTemplate {
    param([string]$SessionToken)
    $cfg = Get-Config
    $workspaceImageName = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $workspaceImageTag  = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
    $anthropicKey = if ($cfg['ANTHROPIC_API_KEY']) { $cfg['ANTHROPIC_API_KEY'] } else { '' }
    $anthropicUrl = if ($cfg['ANTHROPIC_BASE_URL']) { $cfg['ANTHROPIC_BASE_URL'] } else { '' }

    if ($script:UseLlm) {
        if (-not $anthropicKey -and $cfg['LITELLM_MASTER_KEY']) {
            $anthropicKey = $cfg['LITELLM_MASTER_KEY']
        }
        if (-not $anthropicUrl) {
            $anthropicUrl = Get-LlmGatewayUrl -Config $cfg
        }
    }

    Write-Info "Pushing workspace template (image=${workspaceImageName}:${workspaceImageTag})"
    docker exec coder-server sh -c "rm -rf /tmp/template-push && mkdir -p /tmp/template-push" | Out-Null
    docker cp "$($ProjectRoot)\workspace-template\." "coder-server:/tmp/template-push/"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Failed to copy template into coder-server.'
        exit 1
    }

    $serverHost  = if ($cfg['SERVER_HOST'])  { $cfg['SERVER_HOST'] }  else { 'localhost' }
    $gatewayPort = if ($cfg['GATEWAY_PORT']) { $cfg['GATEWAY_PORT'] } else { '8443' }
    $pushCmd = "CODER_URL=http://localhost:7080 CODER_SESSION_TOKEN=$SessionToken /opt/coder templates push embedded-dev --directory /tmp/template-push --yes --activate --var workspace_image=$workspaceImageName --var workspace_image_tag=$workspaceImageTag --var anthropic_api_key='$anthropicKey' --var anthropic_base_url='$anthropicUrl' --var server_host='$serverHost' --var gateway_port='$gatewayPort' ; rm -rf /tmp/template-push"
    docker exec coder-server sh -c $pushCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Template push failed.'
        exit 1
    }
    Write-OK 'Workspace template pushed.'
}

function Show-AccessInfo {
    $cfg = Get-Config
    $serverHost = if ($cfg['SERVER_HOST']) { $cfg['SERVER_HOST'] } else { 'localhost' }
    $gatewayPort = if ($cfg['GATEWAY_PORT']) { $cfg['GATEWAY_PORT'] } else { '8443' }

    Write-Host "Access URLs:" -ForegroundColor Cyan
    Write-Host "  Admin Dashboard: https://${serverHost}:${gatewayPort}/" -ForegroundColor White
    Write-Host "  User IDE:        https://${serverHost}:${gatewayPort}/@<username>/<workspace>.main/apps/code-server" -ForegroundColor White
    if ($script:UseLlm) {
        Write-Host "  LiteLLM:         https://${serverHost}:${gatewayPort}/llm/" -ForegroundColor White
    }
    if ($script:UseLdap) {
        Write-Host "  Dex OIDC:        https://${serverHost}:${gatewayPort}/dex/" -ForegroundColor White
    }
    if ($script:UseMineru) {
        Write-Host "  MinerU:          https://${serverHost}:${gatewayPort}/mineru/  (document -> Markdown, Gradio UI)" -ForegroundColor White
    }
    if ($script:UseDoctools) {
        Write-Host "  Pandoc docconv:  https://${serverHost}:${gatewayPort}/docconv/  (Markdown -> Word/PDF)" -ForegroundColor White
    }
}

function Invoke-TestApi {
    if (-not (Test-Path $EnvFile)) {
        Write-Fail 'Run init first.'
        exit 1
    }

    $cfg = Get-Config
    $apiKey = if ($cfg['ANTHROPIC_API_KEY']) { $cfg['ANTHROPIC_API_KEY'] } else { '' }
    $apiBaseUrl = if ($cfg['ANTHROPIC_BASE_URL']) { $cfg['ANTHROPIC_BASE_URL'] } else { '' }

    if ($script:UseLlm -and -not $apiBaseUrl) {
        $apiBaseUrl = Get-LlmGatewayUrl -Config $cfg
        if (-not $apiKey -and $cfg['LITELLM_MASTER_KEY']) {
            $apiKey = $cfg['LITELLM_MASTER_KEY']
        }
    }
    if (-not $apiBaseUrl) {
        $apiBaseUrl = 'https://api.anthropic.com'
    }
    if (-not $apiKey) {
        Write-Fail 'ANTHROPIC_API_KEY is not configured.'
        exit 1
    }

    $body = '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
    Write-Info "Testing $apiBaseUrl"
    try {
        Invoke-RestMethod -Uri "$apiBaseUrl/v1/messages" -Method POST `
            -Headers @{ 'x-api-key' = $apiKey; 'anthropic-version' = '2023-06-01' } `
            -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null
        Write-OK 'API request succeeded.'
    } catch {
        if ($_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode.Value__
            Write-Warn "API returned HTTP $status"
        } else {
            Write-Fail "Failed to connect to $apiBaseUrl"
        }
    }
}

function Invoke-TestLlmBackend {
    if (-not (Test-Path $EnvFile)) {
        Write-Fail 'Run init first.'
        exit 1
    }

    $cfg = Get-Config
    if (-not $cfg['INTERNAL_API_BASE']) {
        Write-Fail 'INTERNAL_API_BASE is not configured.'
        exit 1
    }

    $headers = @{}
    if ($cfg['INTERNAL_API_KEY']) {
        $headers['Authorization'] = "Bearer $($cfg['INTERNAL_API_KEY'])"
    }

    try {
        Invoke-WebRequest -Uri $cfg['INTERNAL_API_BASE'] -UseBasicParsing -Headers $headers -TimeoutSec 10 | Out-Null
        Write-OK 'Internal LLM backend is reachable.'
    } catch {
        if ($_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode.Value__
            Write-OK "Internal LLM backend is reachable and returned HTTP $status."
        } else {
            Write-Fail "Failed to reach $($cfg['INTERNAL_API_BASE'])"
            exit 1
        }
    }
}

function Invoke-Clean {
    Write-Info 'Cleaning Docker build cache...'
    docker system prune -f
    Write-OK 'Cleanup complete.'
}

# ─── upgrade-backup / upgrade-restore-config ──────────────────────────────────

function Invoke-UpgradeBackup {
    Assert-Docker
    if (-not (Test-Path $EnvFile)) {
        Write-Fail 'docker/.env not found — nothing to back up.'
        exit 1
    }
    $cfg = Get-Config

    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pgNames = docker ps --format '{{.Names}}' 2>$null
    $pgRunning = ($pgNames -match '^coder-postgres$')
    $ErrorActionPreference = $eap
    if (-not $pgRunning) {
        Write-Fail 'coder-postgres is not running. Start the platform before running upgrade-backup.'
        exit 1
    }

    $timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (-not $Dest) {
        $Dest = Join-Path $ProjectRoot "backups\snapshot-$timestamp"
    }
    $Dest = [System.IO.Path]::GetFullPath($Dest)

    if (Test-Path $Dest) {
        if ($Force) {
            Write-Warn "Overwriting existing snapshot at $Dest"
            Remove-Item -Recurse -Force $Dest
        } else {
            Write-Fail "Snapshot directory already exists: $Dest (re-run with -Force to overwrite)"
            exit 1
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $Dest 'volumes') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Dest 'ssl') -Force | Out-Null

    # Step 1: pg_dumpall
    Write-Info '[1/5] pg_dumpall coder -> coder.sql'
    $sqlPath = Join-Path $Dest 'coder.sql'
    $eap2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdout = docker exec coder-postgres pg_dumpall -U coder 2>$null
    $pgExit = $LASTEXITCODE
    $ErrorActionPreference = $eap2
    if ($pgExit -ne 0) {
        Write-Fail 'pg_dumpall failed; check docker logs coder-postgres'
        exit 1
    }
    [System.IO.File]::WriteAllText($sqlPath, $stdout, [System.Text.UTF8Encoding]::new($false))
    $sqlBytes = (Get-Item $sqlPath).Length
    if ($sqlBytes -lt 1024) {
        Write-Fail "coder.sql is suspiciously small ($sqlBytes bytes); aborting"
        exit 1
    }
    Write-OK "      coder.sql ($([math]::Round($sqlBytes / 1024)) KB)"

    # Pick backup image
    $backupImage = $null
    try {
        $backupImage = (docker inspect coder-postgres --format '{{.Image}}' 2>$null)
    } catch {}
    if (-not $backupImage) {
        $backupImage = if ($cfg['POSTGRES_IMAGE_REF']) { $cfg['POSTGRES_IMAGE_REF'] } else { 'postgres:16-alpine' }
    }

    # Step 2: postgres-data volume
    Write-Info '[2/5] Tarring postgres-data volume'
    $eap3 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pgVolume = (docker inspect coder-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>$null)
    $ErrorActionPreference = $eap3
    if (-not $pgVolume) {
        Write-Fail 'Could not locate postgres-data volume on coder-postgres'
        exit 1
    }
    $volDir = Join-Path $Dest 'volumes'
    docker run --rm `
        -v "${pgVolume}:/data:ro" `
        -v "$($volDir):/backup" `
        --entrypoint /bin/sh `
        $backupImage `
        -c 'cd /data && tar czf /backup/postgres-data.tgz .'
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to archive postgres-data volume ($pgVolume)"
        exit 1
    }
    Write-OK "      volumes\postgres-data.tgz (volume: $pgVolume)"

    # Step 3: workspace home volumes
    Write-Info '[3/5] Tarring workspace home volumes (coder-*-home)'
    $eap4 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $allVolumes = docker volume ls --format '{{.Name}}' 2>$null
    $ErrorActionPreference = $eap4
    $homeVolumes = $allVolumes | Where-Object { $_ -match '^coder-.*-home$' }
    $homeCount = 0
    foreach ($vol in $homeVolumes) {
        Write-Info "      - $vol"
        docker run --rm `
            -v "${vol}:/data:ro" `
            -v "$($volDir):/backup" `
            --entrypoint /bin/sh `
            $backupImage `
            -c "cd /data && tar czf /backup/${vol}.tgz ."
        if ($LASTEXITCODE -eq 0) {
            $homeCount++
        } else {
            Write-Warn "        archive failed for $vol (continuing)"
        }
    }
    Write-OK "      $homeCount workspace home volume(s) archived"

    # Step 4: configuration
    Write-Info '[4/5] Copying configuration'
    Copy-Item $EnvFile (Join-Path $Dest 'env.bak')
    $sslSrc = Join-Path $ConfigsDir 'ssl'
    $sslDst = Join-Path $Dest 'ssl'
    if (Test-Path $sslSrc) {
        foreach ($item in (Get-ChildItem $sslSrc -ErrorAction SilentlyContinue)) {
            Copy-Item $item.FullName $sslDst -Recurse -Force
        }
    }
    if (Test-Path $LockFile) {
        Copy-Item $LockFile (Join-Path $Dest 'versions.lock.env.bak')
    }
    if (Test-Path $SetupDone) {
        Copy-Item $SetupDone (Join-Path $Dest 'setup-done.bak')
    }
    Write-OK "      env.bak, ssl\, versions.lock.env.bak"

    # Step 5: metadata
    Write-Info '[5/5] Writing meta.json'
    $gitSha = 'unknown'
    $gitBranch = 'unknown'
    try {
        Push-Location $ProjectRoot
        $gitSha = (git rev-parse HEAD 2>$null)
        $gitBranch = (git rev-parse --abbrev-ref HEAD 2>$null)
        Pop-Location
    } catch {}

    $meta = [ordered]@{
        snapshot_kind = 'upgrade-in-place'
        created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        git_branch = $gitBranch
        git_commit = $gitSha
        server_host = $cfg['SERVER_HOST']
        gateway_port = $cfg['GATEWAY_PORT']
        workspace_image = "$($cfg['WORKSPACE_IMAGE']):$($cfg['WORKSPACE_IMAGE_TAG'])"
        postgres_volume = $pgVolume
        workspace_home_volumes = $homeCount
    }
    $metaJson = $meta | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $Dest 'meta.json'), $metaJson + "`r`n", [System.Text.UTF8Encoding]::new($false))
    Write-OK "      meta.json"

    $total = (Get-ChildItem $Dest -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $totalMb = [math]::Round($total / 1MB)
    Write-Host ''
    Write-OK "Backup complete: $Dest (total ${totalMb} MB)"
    Write-Host ''
    Write-Info 'Next steps (see docs/upgrade-in-place.md for the full runbook):'
    Write-Host '  1) Move/copy snapshot to durable storage outside this directory'
    Write-Host '  2) .\scripts\manage.ps1 down           # stop the old platform (never pass -v)'
    Write-Host '  3) git fetch && git checkout <new-ref>'
    Write-Host '  4) .\scripts\manage.ps1 upgrade-restore-config <snapshot-dir>'
    Write-Host '  5) .\scripts\manage.ps1 load          # plus -Ldap -SkillHub etc as needed'
    Write-Host '  6) .\scripts\manage.ps1 up            # new coder migrates DB in-place'
    Write-Host '  7) .\scripts\manage.ps1 update-workspace -Tag v$(Get-Date -Format yyyyMMdd)'
}

function Invoke-UpgradeRestoreConfig {
    param([string]$SnapshotDir)
    if (-not $SnapshotDir) {
        Write-Fail 'Usage: manage.ps1 upgrade-restore-config <snapshot-dir> [-Force]'
        exit 1
    }
    $SnapshotDir = [System.IO.Path]::GetFullPath($SnapshotDir)
    if (-not (Test-Path $SnapshotDir)) {
        Write-Fail "Snapshot directory not found: $SnapshotDir"
        exit 1
    }
    $envBak = Join-Path $SnapshotDir 'env.bak'
    $sslBak = Join-Path $SnapshotDir 'ssl'
    if (-not (Test-Path $envBak)) {
        Write-Fail "$envBak not found — is this a snapshot from upgrade-backup?"
        exit 1
    }
    if (-not (Test-Path $sslBak)) {
        Write-Fail "$sslBak not found — incomplete snapshot"
        exit 1
    }

    Initialize-Dirs

    # .env
    if (Test-Path $EnvFile) {
        if (-not $Force) {
            Write-Fail "$EnvFile already exists. Pass -Force to overwrite (the existing file will be saved as .env.before-restore)."
            exit 1
        }
        Copy-Item $EnvFile "$EnvFile.before-restore"
        Write-Warn "Existing docker/.env saved to $EnvFile.before-restore"
    }
    Copy-Item $envBak $EnvFile
    Write-OK 'Restored docker/.env'
    Ensure-EnvDefaults -EnvFile $EnvFile -ConfigsDir $ConfigsDir

    # SSL
    $sslTarget = Join-Path $ConfigsDir 'ssl'
    $caExisting = Join-Path $sslTarget 'ca.crt'
    $caSnapshot = Join-Path $sslBak 'ca.crt'
    if ((Test-Path $caExisting) -and (Test-Path $caSnapshot)) {
        $existingHash = (Get-FileHash $caExisting -Algorithm SHA256).Hash
        $snapshotHash = (Get-FileHash $caSnapshot -Algorithm SHA256).Hash
        if ($existingHash -ne $snapshotHash) {
            if (-not $Force) {
                Write-Fail 'configs/ssl/ca.crt differs from snapshot. Pass -Force to overwrite. WARNING: workspaces built against the current CA will need to be rebuilt.'
                exit 1
            }
        }
    }
    if (Test-Path $sslTarget) {
        $backupSsl = Join-Path $ConfigsDir 'ssl.before-restore'
        Remove-Item -Recurse -Force $backupSsl -ErrorAction SilentlyContinue
        Move-Item $sslTarget $backupSsl
        Write-Warn 'Existing configs/ssl saved to configs/ssl.before-restore'
    }
    New-Item -ItemType Directory -Path $sslTarget -Force | Out-Null
    foreach ($item in (Get-ChildItem $sslBak -ErrorAction SilentlyContinue)) {
        Copy-Item $item.FullName $sslTarget -Recurse -Force
    }
    Write-OK 'Restored configs/ssl/ (CA + leaf certificate)'

    # versions.lock.env reference
    $lockBak = Join-Path $SnapshotDir 'versions.lock.env.bak'
    if ((Test-Path $lockBak) -and (Test-Path $LockFile)) {
        $match = Select-String -Path $lockBak -Pattern '^WORKSPACE_IMAGE_TAG=(.*)$' -ErrorAction SilentlyContinue
        if ($match) {
            $bakTag = $match.Matches.Groups[1].Value.Trim()
            Write-Info "Snapshot workspace image tag was: $bakTag"
            Write-Info "Current versions.lock.env tag:    $($cfg['WORKSPACE_IMAGE_TAG'])"
            Write-Info "Build a fresh tagged image after upgrade with: manage.ps1 update-workspace -Tag v$(Get-Date -Format yyyyMMdd)"
        }
    }

    # setup-done
    $setupDoneBak = Join-Path $SnapshotDir 'setup-done.bak'
    if ((Test-Path $setupDoneBak) -and (-not (Test-Path $SetupDone))) {
        Copy-Item $setupDoneBak $SetupDone
        Write-OK 'Restored docker/.setup-done (skips first-run admin creation)'
    }

    # Sanity
    $cfg = Get-Config
    if (-not $cfg['POSTGRES_PASSWORD']) {
        Write-Warn 'POSTGRES_PASSWORD is empty in restored env — coder will fail to connect to postgres'
    }
    if (-not $cfg['SERVER_HOST']) {
        Write-Warn 'SERVER_HOST is empty in restored env'
    }

    $metaPath = Join-Path $SnapshotDir 'meta.json'
    if (Test-Path $metaPath) {
        Write-Host ''
        Write-Info 'Snapshot metadata:'
        (Get-Content $metaPath) | ForEach-Object { Write-Host "      $_" }
    }

    Write-Host ''
    Write-OK "Configuration restored from $SnapshotDir"
    Write-Host ''
    Write-Info 'Next steps:'
    Write-Host '  1) Sanity-check docker/.env — review any new keys appended from versions.lock.env'
    Write-Host '  2) .\scripts\manage.ps1 load [-Ldap -SkillHub …]'
    Write-Host '  3) .\scripts\manage.ps1 up       # new coder migrates the DB schema in-place'
    Write-Host '  4) Verify a real user can log in, then build a tagged workspace image:'
    Write-Host '     .\scripts\manage.ps1 update-workspace -Tag v$(Get-Date -Format yyyyMMdd)'
    Write-Host '  5) Have users restart their workspaces in the UI to pick up the new image'
}

# ─── push-template ────────────────────────────────────────────────────────────

function Invoke-CmdPushTemplate {
    Assert-Docker
    if (-not (Test-Path $EnvFile)) { Write-Fail 'Run init first.'; exit 1 }
    $cfg = Get-Config
    $port = if ($cfg['CODER_INTERNAL_PORT']) { $cfg['CODER_INTERNAL_PORT'] } else { '7080' }
    $baseUrl = "http://localhost:$port"

    try {
        $h = Invoke-WebRequest -Uri "$baseUrl/healthz" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($h.StatusCode -ne 200) { throw "not ready" }
    } catch {
        Write-Fail "Coder is not reachable at $baseUrl. Is the platform running?"
        exit 1
    }

    $adminEmail    = if ($cfg['CODER_ADMIN_EMAIL'])    { $cfg['CODER_ADMIN_EMAIL'] }    else { 'admin@company.local' }
    $adminPassword = if ($cfg['CODER_ADMIN_PASSWORD']) { $cfg['CODER_ADMIN_PASSWORD'] } else { '' }
    $loginBody = '{"email":"' + $adminEmail + '","password":"' + $adminPassword + '"}'
    $loginResponse = Invoke-RestMethod -Uri "$baseUrl/api/v2/users/login" -Method POST -ContentType 'application/json' -Body $loginBody
    $sessionToken = $loginResponse.session_token
    if (-not $sessionToken) { Write-Fail 'Failed to get Coder session token. Check admin credentials in docker/.env.'; exit 1 }
    Write-OK 'Obtained session token.'

    Invoke-PushTemplate -SessionToken $sessionToken
}

# ─── update-workspace ─────────────────────────────────────────────────────────

function Update-LockWorkspaceTag {
    param([string]$NewTag)
    $lockContent = Get-Content $LockFile -Raw
    if ($lockContent -match 'WORKSPACE_IMAGE_TAG=') {
        $lockContent = $lockContent -replace 'WORKSPACE_IMAGE_TAG=.*', "WORKSPACE_IMAGE_TAG=$NewTag"
    } else {
        $lockContent += "`r`nWORKSPACE_IMAGE_TAG=$NewTag"
    }
    [System.IO.File]::WriteAllText($LockFile, $lockContent, [System.Text.UTF8Encoding]::new($false))
    Write-OK "Updated WORKSPACE_IMAGE_TAG=$NewTag in versions.lock.env"
}

function Invoke-UpdateWorkspace {
    param([string]$NewTag = '')

    if (-not $NewTag) {
        $NewTag = "v$(Get-Date -Format 'yyyyMMdd')"
        Write-Info "No tag specified, using auto-generated: $NewTag"
    }

    Assert-Docker
    Initialize-Dirs
    if (-not (Test-Path $EnvFile)) { Write-Fail 'Run init first.'; exit 1 }
    $cfg = Get-Config
    $imageName = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }

    # Step 1: Update lock file
    Update-LockWorkspaceTag -NewTag $NewTag
    $cfg = Get-Config  # reload

    # Step 2: Ensure CA and build
    $sslDir = Join-Path $ConfigsDir 'ssl'
    Ensure-RootCA -SslDir $sslDir | Out-Null
    $codeServerBase = $cfg['CODE_SERVER_BASE_IMAGE_REF']
    Write-Info "Building ${imageName}:${NewTag}"
    docker build -f "$DockerDir\Dockerfile.workspace" --build-arg "CODE_SERVER_BASE_IMAGE_REF=$codeServerBase" -t "${imageName}:${NewTag}" $ProjectRoot
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Workspace image build failed.'; exit 1 }
    Write-OK "Built ${imageName}:${NewTag}"

    # Step 3: Save to tar
    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null
    $tarFile = Join-Path $ImagesDir "${imageName}_${NewTag}.tar"
    Write-Info "Saving ${imageName}:${NewTag} -> $(Split-Path $tarFile -Leaf)"
    docker save "${imageName}:${NewTag}" -o $tarFile
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to save workspace image.'; exit 1 }
    $sizeMb = [math]::Round((Get-Item $tarFile).Length / 1MB)
    Write-OK "Saved ${sizeMb} MB  ($(Split-Path $tarFile -Leaf))"

    # Step 4: Push template if Coder is running
    $port = if ($cfg['CODER_INTERNAL_PORT']) { $cfg['CODER_INTERNAL_PORT'] } else { '7080' }
    $baseUrl = "http://localhost:$port"
    $coderRunning = $false
    try {
        $h = Invoke-WebRequest -Uri "$baseUrl/healthz" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $coderRunning = ($h.StatusCode -eq 200)
    } catch {}

    if ($coderRunning) {
        Write-Info 'Coder is running — pushing updated template.'
        $adminEmail    = if ($cfg['CODER_ADMIN_EMAIL'])    { $cfg['CODER_ADMIN_EMAIL'] }    else { 'admin@company.local' }
        $adminPassword = if ($cfg['CODER_ADMIN_PASSWORD']) { $cfg['CODER_ADMIN_PASSWORD'] } else { '' }
        $loginBody = '{"email":"' + $adminEmail + '","password":"' + $adminPassword + '"}'
        $loginResponse = Invoke-RestMethod -Uri "$baseUrl/api/v2/users/login" -Method POST -ContentType 'application/json' -Body $loginBody
        $sessionToken = $loginResponse.session_token
        if (-not $sessionToken) { Write-Fail 'Failed to get Coder session token.'; exit 1 }
        Invoke-PushTemplate -SessionToken $sessionToken
    } else {
        Write-Warn 'Coder is not running locally — skipping template push.'
        Write-Info "To push later: .\scripts\manage.ps1 push-template"
    }

    Write-Host ''
    Write-OK "Workspace image update complete: ${imageName}:${NewTag}"
    Write-Info "Transfer $(Split-Path $tarFile -Leaf) and configs\versions.lock.env to the offline server."
    Write-Info "Then run: .\scripts\manage.ps1 load-workspace -Arg1 $(Split-Path $tarFile -Leaf)"
}

# ─── load-workspace ───────────────────────────────────────────────────────────

function Invoke-LoadWorkspace {
    param([string]$TarPath)

    if (-not $TarPath) { Write-Fail 'Usage: manage.ps1 load-workspace <path\to\workspace-image_tag.tar>'; exit 1 }
    if (-not (Test-Path $TarPath)) { Write-Fail "File not found: $TarPath"; exit 1 }
    if (-not (Test-Path $EnvFile)) { Write-Fail 'Run init first.'; exit 1 }
    Assert-Docker

    # Parse image name and tag from filename: <image-name>_<tag>.tar
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($TarPath)
    $lastUnderscore = $baseName.LastIndexOf('_')
    if ($lastUnderscore -le 0) {
        Write-Fail "Cannot parse image name and tag from filename: $(Split-Path $TarPath -Leaf). Expected format: <image-name>_<tag>.tar"
        exit 1
    }
    $imageName = $baseName.Substring(0, $lastUnderscore)
    $tag       = $baseName.Substring($lastUnderscore + 1)

    Write-Info "Loading workspace image from $(Split-Path $TarPath -Leaf)"
    docker load -i $TarPath
    if ($LASTEXITCODE -ne 0) { Write-Fail 'docker load failed.'; exit 1 }
    Write-OK "Loaded ${imageName}:${tag}"

    # Update lock file
    Update-LockWorkspaceTag -NewTag $tag

    # Reload config
    $cfg = Get-Config
    $port = if ($cfg['CODER_INTERNAL_PORT']) { $cfg['CODER_INTERNAL_PORT'] } else { '7080' }
    $baseUrl = "http://localhost:$port"

    try {
        $h = Invoke-WebRequest -Uri "$baseUrl/healthz" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($h.StatusCode -ne 200) { throw "not ready" }
    } catch {
        Write-Fail "Coder is not reachable at $baseUrl. Is the platform running?"
        exit 1
    }

    Write-Info 'Pushing updated template to Coder.'
    $adminEmail    = if ($cfg['CODER_ADMIN_EMAIL'])    { $cfg['CODER_ADMIN_EMAIL'] }    else { 'admin@company.local' }
    $adminPassword = if ($cfg['CODER_ADMIN_PASSWORD']) { $cfg['CODER_ADMIN_PASSWORD'] } else { '' }
    $loginBody = '{"email":"' + $adminEmail + '","password":"' + $adminPassword + '"}'
    $loginResponse = Invoke-RestMethod -Uri "$baseUrl/api/v2/users/login" -Method POST -ContentType 'application/json' -Body $loginBody
    $sessionToken = $loginResponse.session_token
    if (-not $sessionToken) { Write-Fail 'Failed to get Coder session token.'; exit 1 }
    Invoke-PushTemplate -SessionToken $sessionToken

    Write-Host ''
    Write-OK "Workspace image ${imageName}:${tag} is now active."
    Write-Warn 'Users must stop and restart their workspaces in the Coder UI to pick up the new image.'
}

# ─── prepare (migrated from prepare-offline.ps1) ──────────────────────────────

function Invoke-PrepareDownloadVsix {
    Write-Info '=== Step 0: Downloading VS Code extensions (.vsix) ==='
    $vsixDir = Join-Path $ConfigsDir 'vsix'
    New-Item -ItemType Directory -Path $vsixDir -Force | Out-Null

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

function Invoke-PrepareDownloadProviders {
    Write-Info '=== Step 1: Downloading Terraform providers ==='
    $cfg = Get-Config

    $providers = @(
        @{ Namespace = 'coder';       Type = 'coder';  Version = $cfg['TF_PROVIDER_CODER_VERSION'];   Os = 'linux'; Arch = 'amd64' },
        @{ Namespace = 'kreuzwerker'; Type = 'docker'; Version = $cfg['TF_PROVIDER_DOCKER_VERSION']; Os = 'linux'; Arch = 'amd64' }
    )

    foreach ($provider in $providers) {
        $zipName = "terraform-provider-$($provider.Type)_$($provider.Version)_$($provider.Os)_$($provider.Arch).zip"
        $mirrorDir = Join-Path $ConfigsDir "provider-mirror\registry.terraform.io\$($provider.Namespace)\$($provider.Type)\$($provider.Version)\$($provider.Os)_$($provider.Arch)"
        $mirrorZip = Join-Path $mirrorDir $zipName
        New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null

        if (-not (Test-Path $mirrorZip)) {
            Write-Info "Downloading $zipName"
            $downloadInfoUrl = "https://registry.terraform.io/v1/providers/$($provider.Namespace)/$($provider.Type)/$($provider.Version)/download/$($provider.Os)/$($provider.Arch)"
            $downloadInfo = Invoke-RestMethod -Uri $downloadInfoUrl -TimeoutSec 30
            Invoke-WebRequest -Uri $downloadInfo.download_url -OutFile $mirrorZip -TimeoutSec 300 -UseBasicParsing
            Write-OK "Saved (mirror) $mirrorZip"
        } else {
            Write-OK "Already present (mirror): $zipName"
        }

        $fsDir = Join-Path $ConfigsDir "terraform-providers\registry.terraform.io\$($provider.Namespace)\$($provider.Type)\$($provider.Version)\$($provider.Os)_$($provider.Arch)"
        $extractedMarker = Join-Path $fsDir '.extracted'
        New-Item -ItemType Directory -Path $fsDir -Force | Out-Null
        if (-not (Test-Path $extractedMarker)) {
            Write-Info "Extracting $zipName -> filesystem-mirror"
            Expand-Archive -Path $mirrorZip -DestinationPath $fsDir -Force
            Set-Content -Path $extractedMarker -Value '1'
            Write-OK "Extracted to $fsDir"
        }
    }

    Write-Info "Building network mirror indexes..."
    & (Join-Path $ScriptDir 'update-provider-mirror.ps1') -Provider 'coder/coder'
    & (Join-Path $ScriptDir 'update-provider-mirror.ps1') -Provider 'kreuzwerker/docker'
    Write-OK "Network mirror indexes built"
}

function Invoke-PrepareSavePlatformImages {
    Write-Info '=== Step 2: Pulling and saving platform images ==='
    $cfg = Get-Config
    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null

    $images = [System.Collections.Generic.List[string]]@(
        $cfg['CODER_IMAGE_REF'],
        $cfg['POSTGRES_IMAGE_REF'],
        $cfg['NGINX_IMAGE_REF']
    )
    if ($script:UseLlm)      { $images.Add($cfg['LITELLM_IMAGE_REF']) }
    if ($script:UseMineru)   { $images.Add($cfg['MINERU_IMAGE_REF']) }
    if ($script:UseDoctools) { $images.Add($cfg['DOCCONV_IMAGE_REF']) }

    foreach ($image in $images) {
        Write-Info "Pulling $image"
        docker pull $image
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $image"; exit 1 }
        $fileName = ($image -replace '[:/@]', '_') + '.tar'
        $filePath = Join-Path $ImagesDir $fileName
        Write-Info "Saving $image -> $fileName"
        docker save $image -o $filePath
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to save $image"; exit 1 }
        Write-OK "Saved $fileName"
    }
}

function Invoke-PrepareBuildWorkspace {
    Write-Info '=== Step 3: Building and saving workspace image ==='
    $cfg = Get-Config
    $sslDir = Join-Path $ConfigsDir 'ssl'
    $serverHost = if ($cfg['SERVER_HOST']) { $cfg['SERVER_HOST'] } else { 'localhost' }
    $workspaceImage = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $workspaceTag   = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }

    if (-not (Test-Path (Join-Path $sslDir 'ca.crt')) -or -not (Test-Path (Join-Path $sslDir 'server.crt'))) {
        Write-Warn 'Missing CA or leaf certificate. Generating them now.'
        Issue-LeafCertificate -SslDir $sslDir -ServerHost $serverHost | Out-Null
    }

    Write-Info "Pulling build base image $($cfg['CODE_SERVER_BASE_IMAGE_REF'])"
    docker pull $cfg['CODE_SERVER_BASE_IMAGE_REF']
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to pull code-server base image'; exit 1 }

    Write-Info "Building ${workspaceImage}:${workspaceTag}"
    docker build -f "$DockerDir\Dockerfile.workspace" --build-arg "CODE_SERVER_BASE_IMAGE_REF=$($cfg['CODE_SERVER_BASE_IMAGE_REF'])" -t "${workspaceImage}:${workspaceTag}" $ProjectRoot
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Workspace image build failed'; exit 1 }

    New-Item -ItemType Directory -Path $ImagesDir -Force | Out-Null
    $tarFile = Join-Path $ImagesDir "${workspaceImage}_${workspaceTag}.tar"
    Write-Info "Saving ${workspaceImage}:${workspaceTag} -> $(Split-Path $tarFile -Leaf)"
    docker save "${workspaceImage}:${workspaceTag}" -o $tarFile
    if ($LASTEXITCODE -ne 0) { Write-Fail 'Failed to save workspace image'; exit 1 }
    Write-OK "Saved $(Split-Path $tarFile -Leaf)"
}

function Invoke-PrepareWriteManifest {
    $cfg = Get-Config
    $caCert = Join-Path $ConfigsDir 'ssl\ca.crt'
    $wsImage = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $wsTag   = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }

    $imageEntry = { param([string]$Ref) [ordered]@{ ref = $Ref; archive = "images/$(($Ref -replace '[:/@]','_') + '.tar')" } }
    $images = @(
        (& $imageEntry $cfg['CODER_IMAGE_REF']),
        (& $imageEntry $cfg['POSTGRES_IMAGE_REF']),
        (& $imageEntry $cfg['NGINX_IMAGE_REF']),
        [ordered]@{ ref = "${wsImage}:${wsTag}"; archive = "images/${wsImage}_${wsTag}.tar" }
    )
    if ($script:UseLlm)      { $images += (& $imageEntry $cfg['LITELLM_IMAGE_REF']) }
    if ($script:UseMineru)   { $images += (& $imageEntry $cfg['MINERU_IMAGE_REF']) }
    if ($script:UseDoctools) { $images += (& $imageEntry $cfg['DOCCONV_IMAGE_REF']) }

    $manifest = [ordered]@{
        generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        include_llm      = [bool]$script:UseLlm
        include_mineru   = [bool]$script:UseMineru
        include_doctools = [bool]$script:UseDoctools
        terraform_cli_config_mount_default = '../configs/terraform-offline.rc'
        ca_sha256 = if (Test-Path $caCert) { (Get-FileHash $caCert -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
        images = $images
        providers = @(
            [ordered]@{
                source  = 'registry.terraform.io/coder/coder'
                version = $cfg['TF_PROVIDER_CODER_VERSION']
                archive = "configs/provider-mirror/registry.terraform.io/coder/coder/$($cfg['TF_PROVIDER_CODER_VERSION'])/linux_amd64/terraform-provider-coder_$($cfg['TF_PROVIDER_CODER_VERSION'])_linux_amd64.zip"
            },
            [ordered]@{
                source  = 'registry.terraform.io/kreuzwerker/docker'
                version = $cfg['TF_PROVIDER_DOCKER_VERSION']
                archive = "configs/provider-mirror/registry.terraform.io/kreuzwerker/docker/$($cfg['TF_PROVIDER_DOCKER_VERSION'])/linux_amd64/terraform-provider-docker_$($cfg['TF_PROVIDER_DOCKER_VERSION'])_linux_amd64.zip"
            }
        )
    }

    $json = $manifest | ConvertTo-Json -Depth 6
    $manifestPath = Join-Path $ProjectRoot 'offline-manifest.json'
    [System.IO.File]::WriteAllText($manifestPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
    Write-OK "Wrote $manifestPath"
}

function Invoke-Prepare {
    Assert-Docker
    Initialize-Dirs

    Write-Host '=== Coder Offline Resource Preparation ===' -ForegroundColor Blue
    Write-Host ''

    Invoke-PrepareDownloadVsix
    Write-Host ''
    Invoke-PrepareDownloadProviders
    Write-Host ''

    if (-not $script:SkipImages) {
        Invoke-PrepareSavePlatformImages
        Write-Host ''
    }

    if (-not $script:SkipBuild) {
        Invoke-PrepareBuildWorkspace
        Write-Host ''
    }

    Invoke-PrepareWriteManifest
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ' Offline preparation complete' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Recommended next steps:' -ForegroundColor Cyan
    Write-Host '  .\scripts\manage.ps1 verify' -ForegroundColor White
    Write-Host '  Transfer the whole project directory to the offline server' -ForegroundColor White
    Write-Host '  # On the offline server:' -ForegroundColor DarkGray
    Write-Host '  .\scripts\manage.ps1 init' -ForegroundColor White
    Write-Host '  .\scripts\manage.ps1 ssl <TARGET_IP_OR_HOST>' -ForegroundColor White
    Write-Host '  .\scripts\manage.ps1 load' -ForegroundColor White
    Write-Host '  .\scripts\manage.ps1 up' -ForegroundColor White
}

# ─── verify (migrated from verify-offline.ps1) ────────────────────────────────

function Invoke-Verify {
    $manifestPath = Join-Path $ProjectRoot 'offline-manifest.json'
    if (-not (Test-Path $manifestPath)) {
        Write-Fail "offline-manifest.json is missing. Run '.\scripts\manage.ps1 prepare' first."
        exit 1
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $missing = [System.Collections.Generic.List[string]]::new()

    if ($script:RequireLlm -and -not $manifest.include_llm) {
        $missing.Add('Manifest does not include LiteLLM artifacts, but -RequireLlm was requested.')
    }

    $requiredFiles = @(
        (Join-Path $ConfigsDir 'ssl\ca.crt'),
        (Join-Path $ConfigsDir 'ssl\ca.key'),
        (Join-Path $ConfigsDir 'terraform-offline.rc'),
        (Join-Path $ConfigsDir 'versions.lock.env')
    )
    foreach ($path in $requiredFiles) {
        if (-not (Test-Path $path)) {
            $missing.Add([System.IO.Path]::GetRelativePath($ProjectRoot, $path))
        }
    }

    foreach ($image in $manifest.images) {
        $archivePath = Join-Path $ProjectRoot $image.archive
        if (-not (Test-Path $archivePath)) { $missing.Add($image.archive) }
    }

    foreach ($provider in $manifest.providers) {
        $archivePath = Join-Path $ProjectRoot $provider.archive
        if (-not (Test-Path $archivePath)) { $missing.Add($provider.archive) }
    }

    $caCert = Join-Path $ConfigsDir 'ssl\ca.crt'
    if ((Test-Path $caCert) -and $manifest.ca_sha256) {
        $currentHash = (Get-FileHash $caCert -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -ne $manifest.ca_sha256.ToLowerInvariant()) {
            $missing.Add("CA fingerprint mismatch: manifest=$($manifest.ca_sha256) current=$currentHash")
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host '[FAIL]  Offline bundle verification failed.' -ForegroundColor Red
        foreach ($item in $missing) { Write-Host "  - $item" -ForegroundColor Red }
        exit 1
    }

    Write-Host '[ OK ]  Offline bundle verification passed.' -ForegroundColor Green
    Write-Host "[INFO]  Manifest: $manifestPath" -ForegroundColor Cyan
    Write-Host "[INFO]  Images checked: $($manifest.images.Count)" -ForegroundColor Cyan
    Write-Host "[INFO]  Providers checked: $($manifest.providers.Count)" -ForegroundColor Cyan
}

# ─── refresh-versions (migrated from refresh-versions.ps1) ────────────────────

function Invoke-RefreshVersions {
    Assert-Docker
    if (-not (Test-Path $LockFile)) { Write-Fail "versions.lock.env not found: $LockFile"; exit 1 }

    $current = Read-KeyValueFile $LockFile
    $updated = @{}
    foreach ($entry in $current.GetEnumerator()) { $updated[$entry.Key] = $entry.Value }

    $imageTargets = @(
        @{ RefKey = 'CODER_IMAGE_REF';           TagKey = 'CODER_IMAGE_TAG' },
        @{ RefKey = 'POSTGRES_IMAGE_REF';         TagKey = 'POSTGRES_IMAGE_TAG' },
        @{ RefKey = 'NGINX_IMAGE_REF';            TagKey = 'NGINX_IMAGE_TAG' },
        @{ RefKey = 'LITELLM_IMAGE_REF';          TagKey = 'LITELLM_IMAGE_TAG' },
        @{ RefKey = 'CODE_SERVER_BASE_IMAGE_REF'; TagKey = 'CODE_SERVER_BASE_IMAGE_TAG' }
    )

    foreach ($target in $imageTargets) {
        $repository = ($current[$target.RefKey] -split '@')[0]
        $tag = $current[$target.TagKey]
        $tagRef = "${repository}:${tag}"
        Write-Info "Pulling $tagRef"
        docker pull $tagRef | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $tagRef"; exit 1 }
        $repoDigests = (docker image inspect $tagRef --format '{{json .RepoDigests}}' | ConvertFrom-Json)
        $resolved = $repoDigests | Where-Object { $_ -like "$repository@*" } | Select-Object -First 1
        if (-not $resolved) { $resolved = $repoDigests[0] }
        $updated[$target.RefKey] = $resolved
    }

    $updated['TF_PROVIDER_CODER_VERSION'] = (Invoke-RestMethod -Uri "https://registry.terraform.io/v1/providers/coder/coder/versions" -TimeoutSec 30).versions.version |
        Where-Object { $_ -match "^$([regex]::Escape(($current['TF_PROVIDER_CODER_VERSION'] -split '\.')[0]))\.\d+(?:\.\d+)*$" } |
        Sort-Object { [version]$_ } -Descending | Select-Object -First 1

    $updated['TF_PROVIDER_DOCKER_VERSION'] = (Invoke-RestMethod -Uri "https://registry.terraform.io/v1/providers/kreuzwerker/docker/versions" -TimeoutSec 30).versions.version |
        Where-Object { $_ -match "^$([regex]::Escape(($current['TF_PROVIDER_DOCKER_VERSION'] -split '\.')[0]))\.\d+(?:\.\d+)*$" } |
        Sort-Object { [version]$_ } -Descending | Select-Object -First 1

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

    if ($script:Apply) {
        $orderedKeys = @('CODER_IMAGE_REF','CODER_IMAGE_TAG','POSTGRES_IMAGE_REF','POSTGRES_IMAGE_TAG','NGINX_IMAGE_REF','NGINX_IMAGE_TAG','LITELLM_IMAGE_REF','LITELLM_IMAGE_TAG','CODE_SERVER_BASE_IMAGE_REF','CODE_SERVER_BASE_IMAGE_TAG','WORKSPACE_IMAGE','WORKSPACE_IMAGE_TAG','TF_PROVIDER_CODER_VERSION','TF_PROVIDER_DOCKER_VERSION')
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('# Locked versions and digests for reproducible offline bundles.')
        foreach ($key in $orderedKeys) { $lines.Add("$key=$($updated[$key])") }
        [System.IO.File]::WriteAllText($LockFile, ($lines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
        Write-OK "Updated $LockFile"
    } else {
        Write-Warn 'Dry run only. Re-run with -Apply to rewrite configs/versions.lock.env.'
    }
}

function Show-Help {
    $text = @(
        '',
        'Usage: .\scripts\manage.ps1 <command> [arg] [-Llm] [-Ldap] [flags]',
        '',
        'Platform lifecycle:',
        '  init                        Create docker/.env from defaults',
        '  ssl [host]                  Issue/update TLS leaf certificate',
        '  pull                        Pull pinned runtime and build-base images',
        '  build                       Build the workspace image (tag from versions.lock.env)',
        '  save                        Save deployment images into images/',
        '  load                        Load images from images/*.tar',
        '  up                          Start the platform (runs setup-coder on first boot)',
        '  down                        Stop the platform',
        '  status                      Show service status',
        '  logs [service]              Follow logs',
        '  shell <service>             Enter a service shell',
        '  setup-coder                 Create admin user and push initial template',
        '  push-template               Push/update template (platform must be running)',
        '  test-api                    Test Anthropic/LiteLLM API access',
        '  test-llm-backend            Test the internal LLM backend base URL',
        '  clean                       Clean Docker build cache',
        '',
        'Workspace image versioning:',
        '  update-workspace [-Tag v]   Build versioned workspace image, save tar, push template',
        '                              Auto-generates tag v<YYYYMMDD> when -Tag is omitted',
        '  load-workspace <tar>        (Offline server) Load workspace tar, update lock, push template',
        '',
        'In-place upgrade (preserve users + workspaces across code/image changes):',
        '  upgrade-backup [-Dest dir] [-Force]',
        '                              Snapshot the running platform: pg_dumpall, every named volume',
        '                              (postgres-data + each coder-*-home), docker/.env, configs/ssl/.',
        '                              Default destination: backups\snapshot-<timestamp>',
        '  upgrade-restore-config <dir> [-Force]',
        '                              After ''git checkout <new-ref>'', restore docker/.env and',
        '                              configs/ssl/ from a snapshot so the new code reuses the same',
        '                              POSTGRES_PASSWORD and root CA. See docs/upgrade-in-place.md.',
        '',
        'Offline bundle preparation (online machine):',
        '  prepare [-SkipImages] [-SkipBuild] [-Llm]',
        '                              Download VSIX + TF providers, pull/save images,',
        '                              build workspace image, write offline-manifest.json',
        '  verify [-RequireLlm]        Verify offline-manifest.json and all referenced files',
        '  refresh-versions [-Apply]   Check upstream for newer image digests / provider versions',
        '                              Add -Apply to rewrite configs/versions.lock.env',
        '',
        'Flags:',
        '  -Llm          Enable LiteLLM AI gateway (--profile llm)',
        '  -Ldap         Enable Dex OIDC + LDAP authentication (--profile ldap)',
        '                Requires DEX_LDAP_* and OIDC_CLIENT_SECRET in docker/.env',
        '  -Mineru       Enable MinerU GPU document-to-Markdown service (--profile mineru)',
        '                Requires nvidia-docker2 on host (runtime: nvidia, GPU 0)',
        '  -Doctools     Enable Pandoc Markdown->Word/PDF service (--profile doctools)',
        '                Uses pandoc --server (port 3030), supports mathml + xelatex',
        '  -Tag <v>      Workspace image tag for update-workspace',
        '  -Apply        Write changes to disk (refresh-versions)',
        '  -RequireLlm   Fail verify if LiteLLM image is absent',
        '  -SkipImages   Skip pulling/saving runtime images (prepare)',
        '  -SkipBuild    Skip building workspace image (prepare)',
        '',
        'Online preparation workflow:',
        '  .\scripts\manage.ps1 init',
        '  .\scripts\manage.ps1 ssl <offline-server-ip>',
        '  .\scripts\manage.ps1 prepare',
        '  .\scripts\manage.ps1 verify',
        '  # Transfer project directory to offline server',
        '',
        'Offline deployment workflow:',
        '  .\scripts\manage.ps1 init',
        '  .\scripts\manage.ps1 ssl <this-server-ip>',
        '  .\scripts\manage.ps1 load',
        '  .\scripts\manage.ps1 up',
        '',
        'Workspace update workflow:',
        '  # [Online] build and save new version',
        '  .\scripts\manage.ps1 update-workspace -Tag v20240324',
        '  # Transfer images\workspace-embedded_v20240324.tar + configs\versions.lock.env',
        '  # [Offline server] load image and push new template version',
        '  .\scripts\manage.ps1 load-workspace images\workspace-embedded_v20240324.tar',
        '  # Users stop and restart their workspaces to pick up the new image',
        '',
        'Notes:',
        '  Pinned image refs are stored in configs/versions.lock.env.',
        '  A new root CA requires one workspace rebuild. Later leaf rotations do not.',
        '  LiteLLM remains a gateway layer to existing internal model infrastructure.',
        '  Set TF_CLI_CONFIG_MOUNT=../configs/terraform.rc to allow connected Terraform fallback.'
    )
    Write-Host ($text -join "`n")
}

Write-Host '=== Coder Production Platform Management (Windows) ===' -ForegroundColor Blue
Write-Host ''

switch ($Command.ToLower()) {
    'init'             { Initialize-Dirs; Invoke-Init; break }
    'ssl'              { Initialize-Dirs; Invoke-GenSSL -ServerHost $Arg1; break }
    'pull'             { Invoke-Pull; break }
    'build'            { Invoke-Build; break }
    'save'             { Invoke-Save; break }
    'load'             { Invoke-Load; break }
    'up'               { Invoke-Up; break }
    'start'            { Invoke-Up; break }
    'down'             { Invoke-Down; break }
    'stop'             { Invoke-Down; break }
    'status'           { Invoke-Status; break }
    'ps'               { Invoke-Status; break }
    'logs'             { Invoke-Logs; break }
    'shell'            { Invoke-Shell; break }
    'setup-coder'      { Invoke-SetupCoder; break }
    'push-template'    { Invoke-CmdPushTemplate; break }
    'update-workspace'      { Invoke-UpdateWorkspace -Tag $Tag; break }
    'load-workspace'        { Invoke-LoadWorkspace -TarFile $Arg1; break }
    'upgrade-backup'        { Invoke-UpgradeBackup; break }
    'upgrade-restore-config'{ Invoke-UpgradeRestoreConfig -SnapshotDir $Arg1; break }
    'prepare'               { Invoke-Prepare; break }
    'verify'           { Invoke-Verify; break }
    'refresh-versions' { Invoke-RefreshVersions; break }
    'test-api'         { Invoke-TestApi; break }
    'test-llm-backend' { Invoke-TestLlmBackend; break }
    'clean'            { Invoke-Clean; break }
    default            { Show-Help }
}
