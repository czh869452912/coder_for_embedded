#Requires -Version 5.1

param(
    [Parameter(Position=0)]
    [string]$Command = "help",
    [Parameter(Position=1)]
    [string]$Arg1 = "",
    [switch]$Llm
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
$script:UseLlm = $Llm.IsPresent

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
    if ($script:UseLlm) {
        $images.Add($cfg['LITELLM_IMAGE_REF'])
    }

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
    if ($script:UseLlm) {
        $images.Add($cfg['LITELLM_IMAGE_REF'])
    }

    # Build a digest-ref -> name:tag fallback map in case the digest ref is no longer cached
    # (e.g. after pulling a newer version of the tag via refresh-versions without -Apply).
    $refTagFallback = @{}
    foreach ($entry in @(
        @{ Ref = 'CODER_IMAGE_REF';           Tag = 'CODER_IMAGE_TAG' },
        @{ Ref = 'POSTGRES_IMAGE_REF';         Tag = 'POSTGRES_IMAGE_TAG' },
        @{ Ref = 'NGINX_IMAGE_REF';            Tag = 'NGINX_IMAGE_TAG' },
        @{ Ref = 'LITELLM_IMAGE_REF';          Tag = 'LITELLM_IMAGE_TAG' },
        @{ Ref = 'CODE_SERVER_BASE_IMAGE_REF'; Tag = 'CODE_SERVER_BASE_IMAGE_TAG' }
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
        @{ Ref = 'CODE_SERVER_BASE_IMAGE_REF'; Tag = 'CODE_SERVER_BASE_IMAGE_TAG' }
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

    $providerRoot = Join-Path $ConfigsDir 'terraform-providers\registry.terraform.io'
    $offlineTerraformMode = ([System.IO.Path]::GetFileName($terraformConfigHostPath) -ieq 'terraform-offline.rc')
    if (-not (Test-Path $providerRoot)) {
        if ($offlineTerraformMode) {
            Write-Fail 'Offline Terraform mode is active but the provider cache is missing.'
            exit 1
        }
        Write-Warn 'Connected Terraform mode is active and the provider cache is missing. Terraform will fall back to the public registry.'
    } elseif (-not $offlineTerraformMode) {
        Write-Info 'Connected Terraform mode is active. Local providers will be used first, then registry fallback is allowed.'
    }

    # In offline/loaded mode Docker cannot resolve digest refs against the registry.
    # Override image ref env vars to use name:tag format before invoking compose,
    # so compose resolves against the locally loaded (and retagged) images.
    $requiredImages = [System.Collections.Generic.List[string]]@()
    foreach ($mapping in @(
        @{ Ref = 'CODER_IMAGE_REF';    Tag = 'CODER_IMAGE_TAG'    },
        @{ Ref = 'POSTGRES_IMAGE_REF'; Tag = 'POSTGRES_IMAGE_TAG' },
        @{ Ref = 'NGINX_IMAGE_REF';    Tag = 'NGINX_IMAGE_TAG'    },
        @{ Ref = 'LITELLM_IMAGE_REF';  Tag = 'LITELLM_IMAGE_TAG'  }
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
        if (-not $script:UseLlm -and $img -match 'litellm') { continue }
        docker image inspect $img 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $missingImages.Add($img) }
    }
    $ErrorActionPreference = $eapPf
    if ($missingImages.Count -gt 0) {
        Write-Fail "The following images are not available locally. Run 'load' (with the correct flags) first:"
        $missingImages | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }

    $composeArgs = if ($script:UseLlm) { @('--profile', 'llm', 'up', '-d') } else { @('up', '-d') }
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
    Push-Location $DockerDir
    if ($script:UseLlm) {
        docker compose --profile llm down
    } else {
        docker compose down
    }
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
    $workspaceImageName = if ($cfg['WORKSPACE_IMAGE']) { $cfg['WORKSPACE_IMAGE'] } else { 'workspace-embedded' }
    $workspaceImageTag = if ($cfg['WORKSPACE_IMAGE_TAG']) { $cfg['WORKSPACE_IMAGE_TAG'] } else { 'latest' }
    $anthropicKey = if ($cfg['ANTHROPIC_API_KEY']) { $cfg['ANTHROPIC_API_KEY'] } else { '' }
    $anthropicUrl = if ($cfg['ANTHROPIC_BASE_URL']) { $cfg['ANTHROPIC_BASE_URL'] } else { '' }

    if ($script:UseLlm) {
        Assert-LlmConfig
        if (-not $anthropicKey -and $cfg['LITELLM_MASTER_KEY']) {
            $anthropicKey = $cfg['LITELLM_MASTER_KEY']
        }
        if (-not $anthropicUrl) {
            $anthropicUrl = Get-LlmGatewayUrl -Config $cfg
        }
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

    $templateDir = Join-Path $ProjectRoot 'workspace-template'
    Write-Info 'Pushing workspace template...'
    docker exec coder-server sh -c "rm -rf /tmp/template-push && mkdir -p /tmp/template-push" | Out-Null
    docker cp "$templateDir/." "coder-server:/tmp/template-push/"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Failed to copy template into coder-server.'
        exit 1
    }

    $pushCommand = "CODER_URL=http://localhost:7080 CODER_SESSION_TOKEN=$sessionToken /opt/coder templates push embedded-dev --directory /tmp/template-push --yes --activate --var workspace_image=$workspaceImageName --var workspace_image_tag=$workspaceImageTag --var anthropic_api_key='$anthropicKey' --var anthropic_base_url='$anthropicUrl' ; rm -rf /tmp/template-push"
    docker exec coder-server sh -c $pushCommand
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Template push failed.'
        exit 1
    }
    Write-OK 'Workspace template pushed.'

    Get-Date | Set-Content $SetupDone
    Show-AccessInfo
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

function Show-Help {
    $text = @(
        '',
        'Usage: .\scripts\manage.ps1 <command> [arg] [-Llm]',
        '',
        'Commands:',
        '  init                  Create docker/.env',
        '  ssl [host]            Issue/update TLS leaf certificate',
        '  pull                  Pull pinned runtime and build-base images',
        '  build                 Build the workspace image',
        '  save                  Save deployment images into images/',
        '  load                  Load images from images/*.tar',
        '  up                    Start the platform',
        '  down                  Stop the platform',
        '  status                Show service status',
        '  logs [service]        Follow logs',
        '  shell <service>       Enter a service shell',
        '  setup-coder           Create admin and push template',
        '  test-api              Test Anthropic/LiteLLM API access',
        '  test-llm-backend      Test the internal LLM backend base URL',
        '  clean                 Clean Docker build cache',
        '',
        'Notes:',
        '  Deployment uses pinned image refs from configs/versions.lock.env.',
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
    'test-api'         { Invoke-TestApi; break }
    'test-llm-backend' { Invoke-TestLlmBackend; break }
    'clean'            { Invoke-Clean; break }
    default            { Show-Help }
}
