#!/bin/bash

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_key_value_file() {
    local path="$1"
    local callback="$2"
    [ -f "$path" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        local trimmed key value first_char last_char
        trimmed="$(trim "$line")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        [[ "$trimmed" =~ ^([^=]+)=(.*)$ ]] || continue

        key="$(trim "${BASH_REMATCH[1]}")"
        value="${BASH_REMATCH[2]}"
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
        value="$(trim "$value")"

        if [ ${#value} -ge 2 ]; then
            first_char="${value:0:1}"
            last_char="${value: -1}"
            if [[ ( "$first_char" == '"' && "$last_char" == '"' ) || ( "$first_char" == "'" && "$last_char" == "'" ) ]]; then
                value="${value:1:${#value}-2}"
            fi
        fi

        "$callback" "$key" "$value"
    done < "$path"
}

__load_key_value_into_env_callback() {
    export "$1=$2"
}

load_key_value_into_env() {
    local path="$1"
    read_key_value_file "$path" __load_key_value_into_env_callback
}

get_version_lock_file() {
    local configs_dir="$1"
    printf '%s\n' "$configs_dir/versions.lock.env"
}

load_effective_config() {
    local configs_dir="$1"
    local env_file="$2"
    load_key_value_into_env "$env_file"
    load_key_value_into_env "$(get_version_lock_file "$configs_dir")"
}

ensure_env_defaults() {
    local env_file="$1"
    local configs_dir="$2"
    [ -f "$env_file" ] || return 0
    # Version/image lock values live in configs/versions.lock.env and are loaded
    # after docker/.env so stale keys in an old .env cannot override them.
    # Keep this hook for backwards-compatible callers, but do not copy lock keys
    # into .env anymore.
    :
}

get_openssl_command() {
    local candidate
    for candidate in openssl \
        "/usr/bin/openssl" \
        "/usr/local/bin/openssl"
    do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "openssl not found in PATH" >&2
    return 1
}

ensure_root_ca() {
    local ssl_dir="$1"
    local openssl_cmd conf_path

    ROOT_CA_CERT="$ssl_dir/ca.crt"
    ROOT_CA_KEY="$ssl_dir/ca.key"
    ROOT_CA_CREATED=false

    if [ -f "$ROOT_CA_CERT" ] && [ -f "$ROOT_CA_KEY" ]; then
        return 0
    fi

    mkdir -p "$ssl_dir"
    openssl_cmd="$(get_openssl_command)"
    conf_path="$ssl_dir/ca.cnf"

    cat > "$conf_path" <<'EOF'
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_ca

[dn]
C  = CN
ST = Beijing
L  = Beijing
O  = Coder Platform Internal CA
CN = coder-offline-root-ca

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, cRLSign, keyCertSign
EOF

    "$openssl_cmd" req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$ROOT_CA_KEY" \
        -out "$ROOT_CA_CERT" \
        -config "$conf_path" >/dev/null 2>&1
    rm -f "$conf_path"
    ROOT_CA_CREATED=true
}

get_leaf_alt_names() {
    local server_host="$1"
    local entries=()

    entries+=("DNS.1 = localhost")
    entries+=("DNS.2 = coder.local")
    entries+=("DNS.3 = host.docker.internal")
    entries+=("DNS.4 = provider-mirror")
    entries+=("IP.1  = 127.0.0.1")

    if [ -n "$server_host" ]; then
        if [[ "$server_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            entries+=("IP.2  = $server_host")
        elif [[ "$server_host" != "localhost" && "$server_host" != "coder.local" \
             && "$server_host" != "host.docker.internal" \
             && "$server_host" != "provider-mirror" ]]; then
            entries+=("DNS.5 = $server_host")
        fi
    fi

    printf '%s\n' "${entries[@]}"
}

issue_leaf_certificate() {
    local ssl_dir="$1"
    local server_host="${2:-localhost}"
    local openssl_cmd leaf_key leaf_csr leaf_crt leaf_conf

    mkdir -p "$ssl_dir"
    ensure_root_ca "$ssl_dir"
    openssl_cmd="$(get_openssl_command)"
    leaf_key="$ssl_dir/server.key"
    leaf_csr="$ssl_dir/server.csr"
    leaf_crt="$ssl_dir/server.crt"
    leaf_conf="$ssl_dir/server.cnf"

    {
        printf '%s\n' '[req]'
        printf '%s\n' 'default_bits       = 2048'
        printf '%s\n' 'prompt             = no'
        printf '%s\n' 'default_md         = sha256'
        printf '%s\n' 'distinguished_name = dn'
        printf '%s\n' 'req_extensions     = v3_req'
        printf '\n'
        printf '%s\n' '[dn]'
        printf '%s\n' 'C  = CN'
        printf '%s\n' 'ST = Beijing'
        printf '%s\n' 'L  = Beijing'
        printf '%s\n' 'O  = Coder Platform'
        printf 'CN = %s\n' "$server_host"
        printf '\n'
        printf '%s\n' '[v3_req]'
        printf '%s\n' 'subjectAltName      = @alt_names'
        printf '%s\n' 'keyUsage            = critical, digitalSignature, keyEncipherment'
        printf '%s\n' 'extendedKeyUsage    = serverAuth'
        printf '%s\n' 'basicConstraints    = CA:FALSE'
        printf '\n'
        printf '%s\n' '[alt_names]'
        get_leaf_alt_names "$server_host"
    } > "$leaf_conf"

    "$openssl_cmd" req -new -newkey rsa:2048 -nodes \
        -keyout "$leaf_key" \
        -out "$leaf_csr" \
        -config "$leaf_conf" >/dev/null 2>&1

    "$openssl_cmd" x509 -req \
        -in "$leaf_csr" \
        -CA "$ROOT_CA_CERT" \
        -CAkey "$ROOT_CA_KEY" \
        -CAcreateserial \
        -out "$leaf_crt" \
        -days 825 \
        -sha256 \
        -extfile "$leaf_conf" \
        -extensions v3_req >/dev/null 2>&1

    rm -f "$leaf_csr" "$leaf_conf"
}
