function Read-KeyValueFile {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $value = [regex]::Replace($value, '\s+#.*$', '')
            if ($value.Length -ge 2) {
                $first = $value.Substring(0, 1)
                $last = $value.Substring($value.Length - 1, 1)
                if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }
            $map[$key] = $value
        }
    }
    return $map
}

function Get-VersionLockFile {
    param([string]$ConfigsDir)
    return (Join-Path $ConfigsDir 'versions.lock.env')
}

function Get-EffectiveConfig {
    param(
        [string]$ConfigsDir,
        [string]$EnvFile
    )
    $config = @{}
    foreach ($entry in (Read-KeyValueFile (Get-VersionLockFile $ConfigsDir)).GetEnumerator()) {
        $config[$entry.Key] = $entry.Value
    }
    foreach ($entry in (Read-KeyValueFile $EnvFile).GetEnumerator()) {
        $config[$entry.Key] = $entry.Value
    }
    return $config
}

function Ensure-EnvDefaults {
    param(
        [string]$EnvFile,
        [string]$ConfigsDir
    )
    if (-not (Test-Path $EnvFile)) { return }
    $defaults = Read-KeyValueFile (Get-VersionLockFile $ConfigsDir)
    $existing = Read-KeyValueFile $EnvFile
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $defaults.GetEnumerator() | Sort-Object Key) {
        if (-not $existing.ContainsKey($entry.Key)) {
            $missing.Add("$($entry.Key)=$($entry.Value)")
        }
    }
    if ($missing.Count -eq 0) { return }
    $suffix = "`r`n# ---- Locked versions ----`r`n" + ($missing -join "`r`n") + "`r`n"
    [System.IO.File]::AppendAllText($EnvFile, $suffix, [System.Text.UTF8Encoding]::new($false))
}

function Get-OpenSSLCommand {
    foreach ($candidate in @(
        'openssl',
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files (x86)\Git\usr\bin\openssl.exe'
    )) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }
    throw 'openssl not found. Install Git for Windows or ensure openssl is in PATH.'
}

function Ensure-RootCA {
    param([string]$SslDir)
    $caCert = Join-Path $SslDir 'ca.crt'
    $caKey = Join-Path $SslDir 'ca.key'
    if ((Test-Path $caCert) -and (Test-Path $caKey)) {
        return @{ Cert = $caCert; Key = $caKey; Created = $false }
    }
    $opensslCmd = Get-OpenSSLCommand
    $confPath = Join-Path $SslDir 'ca.cnf'
    $conf = @(
        '[req]',
        'default_bits       = 4096',
        'prompt             = no',
        'default_md         = sha256',
        'distinguished_name = dn',
        'x509_extensions    = v3_ca',
        '',
        '[dn]',
        'C  = CN',
        'ST = Beijing',
        'L  = Beijing',
        'O  = Coder Platform Internal CA',
        'CN = coder-offline-root-ca',
        '',
        '[v3_ca]',
        'subjectKeyIdentifier = hash',
        'authorityKeyIdentifier = keyid:always,issuer',
        'basicConstraints = critical, CA:true, pathlen:0',
        'keyUsage = critical, cRLSign, keyCertSign'
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($confPath, $conf, [System.Text.Encoding]::ASCII)
    & $opensslCmd req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout $caKey -out $caCert -config $confPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to generate root CA' }
    Remove-Item $confPath -ErrorAction SilentlyContinue
    return @{ Cert = $caCert; Key = $caKey; Created = $true }
}

function Get-LeafAltNames {
    param([string]$ServerHost)
    $entries = [System.Collections.Generic.List[string]]::new()
    $entries.Add('DNS.1 = localhost')
    $entries.Add('DNS.2 = coder.local')
    $entries.Add('DNS.3 = host.docker.internal')
    $entries.Add('DNS.4 = provider-mirror')
    $entries.Add('IP.1  = 127.0.0.1')
    if ($ServerHost) {
        if ($ServerHost -match '^\d+\.\d+\.\d+\.\d+$') {
            $entries.Add("IP.2  = $ServerHost")
        } elseif ($ServerHost -notin @('localhost', 'coder.local', 'host.docker.internal', 'provider-mirror')) {
            $entries.Add("DNS.5 = $ServerHost")
        }
    }
    return ($entries -join [Environment]::NewLine)
}

function Issue-LeafCertificate {
    param(
        [string]$SslDir,
        [string]$ServerHost
    )
    New-Item -ItemType Directory -Path $SslDir -Force | Out-Null
    $opensslCmd = Get-OpenSSLCommand
    $ca = Ensure-RootCA $SslDir
    $serverName = if ($ServerHost) { $ServerHost } else { 'localhost' }
    $leafKey = Join-Path $SslDir 'server.key'
    $leafCsr = Join-Path $SslDir 'server.csr'
    $leafCrt = Join-Path $SslDir 'server.crt'
    $leafConf = Join-Path $SslDir 'server.cnf'
    $conf = @(
        '[req]',
        'default_bits       = 2048',
        'prompt             = no',
        'default_md         = sha256',
        'distinguished_name = dn',
        'req_extensions     = v3_req',
        '',
        '[dn]',
        'C  = CN',
        'ST = Beijing',
        'L  = Beijing',
        'O  = Coder Platform',
        "CN = $serverName",
        '',
        '[v3_req]',
        'subjectAltName      = @alt_names',
        'keyUsage            = critical, digitalSignature, keyEncipherment',
        'extendedKeyUsage    = serverAuth',
        'basicConstraints    = CA:FALSE',
        '',
        '[alt_names]',
        (Get-LeafAltNames $serverName)
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($leafConf, $conf, [System.Text.Encoding]::ASCII)
    & $opensslCmd req -new -newkey rsa:2048 -nodes -keyout $leafKey -out $leafCsr -config $leafConf | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to generate server CSR' }
    & $opensslCmd x509 -req -in $leafCsr -CA $ca.Cert -CAkey $ca.Key -CAcreateserial -out $leafCrt -days 825 -sha256 -extfile $leafConf -extensions v3_req | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to sign server certificate' }
    Remove-Item $leafCsr, $leafConf -ErrorAction SilentlyContinue
    return @{ CaCreated = $ca.Created; CaCert = $ca.Cert; ServerCert = $leafCrt; ServerKey = $leafKey }
}

function Import-RootCAToWindows {
    param([string]$CaCert)
    try {
        $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path $CaCert).Path)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::Root, [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($certObj)
        $store.Close()
        return $true
    } catch {
        return $false
    }
}