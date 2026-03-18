# Coder for Embedded Development

A single-port Coder deployment for embedded software teams. The platform provides browser-based VS Code workspaces, a full embedded C/C++ toolchain, and an optional LiteLLM gateway that adapts existing internal model infrastructure for Claude Code and other editor tools.

## What This Repository Guarantees

- Single external entrypoint: `https://<host>:8443/`
- Multi-user Coder platform with per-user workspaces
- Path-based workspace apps, no wildcard DNS required
- Offline deployment after an online preparation step
- Reproducible deployment images pinned in `configs/versions.lock.env`

## What LiteLLM Means Here

LiteLLM is used as a unified internal model gateway.
It is not used to download or host local models in this repository.

That means:

- The Coder platform itself can run fully inside an offline intranet.
- AI features still depend on an internal model API that LiteLLM can reach.
- If no internal model backend exists, Coder, workspaces, terminal, and code-server still work; only AI features are unavailable.

## Architecture

```text
Browser
  -> https://<host>:8443/

Nginx :8443
  -> /            -> Coder :7080
  -> /llm/        -> LiteLLM :4000 (optional)

Coder
  -> Docker socket
  -> creates one workspace container per user/workspace

Workspace app path
  -> /@<username>/<workspace>.main/apps/code-server
```

## Prerequisites

- Windows: Docker Desktop, PowerShell 7 recommended, Git for Windows (`openssl`)
- Linux: Docker Engine + Compose v2, `bash`, `openssl`, `curl`, `python3`
- Internet is required only for online preparation and explicit version refresh operations.

## Quick Start

### Windows

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\scripts\manage.ps1 init
.\scripts\manage.ps1 ssl 192.168.1.100
.\scripts\manage.ps1 build
.\scripts\manage.ps1 up

# Enable LiteLLM gateway mode
.\scripts\manage.ps1 up -Llm
```

### Linux

```bash
bash scripts/manage.sh init
bash scripts/manage.sh ssl 192.168.1.100
bash scripts/manage.sh build
bash scripts/manage.sh up

# Enable LiteLLM gateway mode
bash scripts/manage.sh up --llm
```

## TLS Model

The platform uses a root CA plus target-specific leaf certificates.

- The workspace image trusts `configs/ssl/ca.crt`.
- `ssl <host>` issues or rotates `server.crt` and `server.key` for the deployment target.
- If only the leaf certificate changes, you do not need to rebuild the workspace image.
- If the root CA changes, rebuild the workspace image once.

This removes the old requirement to rebuild the workspace image on every offline target.

## Terraform Modes

There are two Terraform CLI configs:

- `configs/terraform-offline.rc`: strict offline mode, no registry fallback
- `configs/terraform.rc`: connected mode, filesystem mirror first and registry fallback allowed

Default behavior is strict offline mode.

`docker/.env` contains:

```env
TF_CLI_CONFIG_MOUNT=../configs/terraform-offline.rc
```

If you want connected fallback for maintenance or experimentation, change it to:

```env
TF_CLI_CONFIG_MOUNT=../configs/terraform.rc
```

## Offline Deployment

### Step 1: Prepare on an Internet-Connected Machine

Windows:

```powershell
.\scripts\prepare-offline.ps1
.\scripts\verify-offline.ps1
```

Linux:

```bash
bash scripts/prepare-offline.sh
bash scripts/verify-offline.sh
```

The preparation step:

- Downloads Terraform providers into `configs/terraform-providers/`
- Pulls pinned runtime images and saves them into `images/`
- Builds the workspace image and saves it into `images/`
- Generates a root CA in `configs/ssl/` if one does not already exist
- Writes `offline-manifest.json`

If you intentionally run `prepare-offline.ps1 -SkipBuild` or `prepare-offline.sh --skip-build`, `verify-offline` will fail until the workspace image tarball has also been produced.

### Step 2: Transfer to the Offline Server

Transfer the entire project directory, including at least:

- `images/`
- `configs/ssl/`
- `configs/terraform-providers/`
- `offline-manifest.json`
- `configs/vsix/` if you use offline VSIX packages

Important:
Keep `configs/ssl/ca.crt` and `configs/ssl/ca.key` from the prepared bundle. The offline target should reuse that CA and only reissue the leaf certificate.

### Step 3: Deploy on the Offline Server

Windows:

```powershell
.\scripts\verify-offline.ps1
.\scripts\manage.ps1 load
.\scripts\manage.ps1 init
.\scripts\manage.ps1 ssl 10.0.1.50
.\scripts\manage.ps1 up
```

Linux:

```bash
bash scripts/verify-offline.sh
bash scripts/manage.sh load
bash scripts/manage.sh init
bash scripts/manage.sh ssl 10.0.1.50
bash scripts/manage.sh up
```

Notes:

- `up` will auto-run first-time Coder initialization if `docker/.setup-done` does not exist.
- If the offline target accidentally generates a new CA instead of reusing the transferred CA, rebuild the workspace image once.
- In strict offline mode, `up` will fail fast if the provider cache is incomplete.

## Version Locking

Deployment reads pinned refs from `configs/versions.lock.env`.

Current pinned items include:

- Coder runtime image
- PostgreSQL image
- Nginx image
- LiteLLM image
- code-server base image used to build the workspace image
- Terraform provider versions

Runtime scripts read `docker/.env` for deployment-specific values and `configs/versions.lock.env` for locked image/provider versions.

## Refreshing to the Latest Stable Versions

Version refresh is an explicit maintenance step. It does not happen during deployment.

Windows dry run:

```powershell
.\scripts\refresh-versions.ps1
```

Windows apply:

```powershell
.\scripts\refresh-versions.ps1 -Apply
```

Linux dry run:

```bash
bash scripts/refresh-versions.sh
```

Linux apply:

```bash
bash scripts/refresh-versions.sh --apply
```

The refresh scripts:

- Pull the tagged upstream images you have chosen to track
- Resolve their current digests
- Query the newest stable provider versions within the current locked major versions
- Rewrite `configs/versions.lock.env` only when you explicitly apply

## AI Gateway Setup

1. Copy the example config:

```bash
cp configs/litellm_config.yaml.example configs/litellm_config.yaml
```

2. Replace `YOUR_INTERNAL_MODEL` and set the real internal API endpoint and key in `docker/.env`.

3. Start with LiteLLM enabled:

Windows:

```powershell
.\scripts\manage.ps1 up -Llm
```

Linux:

```bash
bash scripts/manage.sh up --llm
```

Helpful checks:

- Windows: `.\scripts\manage.ps1 test-llm-backend`
- Linux: `bash scripts/manage.sh test-llm-backend`

## Common Commands

### Windows

```powershell
.\scripts\manage.ps1 init
.\scripts\manage.ps1 ssl [host]
.\scripts\manage.ps1 pull
.\scripts\manage.ps1 build
.\scripts\manage.ps1 save
.\scripts\manage.ps1 load
.\scripts\manage.ps1 up [-Llm]
.\scripts\manage.ps1 down
.\scripts\manage.ps1 status
.\scripts\manage.ps1 logs [service]
.\scripts\manage.ps1 shell <service>
.\scripts\manage.ps1 setup-coder
.\scripts\manage.ps1 test-api
.\scripts\manage.ps1 test-llm-backend
.\scripts\refresh-versions.ps1 [-Apply]
.\scripts\verify-offline.ps1
```

### Linux

```bash
bash scripts/manage.sh <command> [--llm]
bash scripts/refresh-versions.sh [--apply]
bash scripts/verify-offline.sh [--require-llm]
```

## Key Files

- `docker/docker-compose.yml`: platform services
- `docker/Dockerfile.workspace`: workspace image build
- `configs/versions.lock.env`: pinned deployment versions
- `configs/terraform-offline.rc`: strict offline Terraform config
- `configs/terraform.rc`: connected Terraform config with fallback
- `configs/litellm_config.yaml.example`: LiteLLM gateway template
- `workspace-template/main.tf`: Coder template that provisions workspace containers
- `scripts/manage.ps1`: Windows entrypoint
- `scripts/manage.sh`: Linux entrypoint
- `scripts/prepare-offline.ps1`: Windows offline preparation
- `scripts/prepare-offline.sh`: Linux offline preparation
- `scripts/refresh-versions.ps1`: Windows version refresh tool
- `scripts/refresh-versions.sh`: Linux version refresh tool
- `scripts/verify-offline.ps1`: Windows offline bundle verification
- `scripts/verify-offline.sh`: Linux offline bundle verification
- `offline-manifest.json`: expected offline bundle contents

## Windows Smoke Test

The following Windows paths have been exercised successfully in this repository:

- `.\scripts\refresh-versions.ps1` dry run
- `.\scripts\prepare-offline.ps1 -SkipBuild`
- `.\scripts\manage.ps1 ssl localhost`
- `.\scripts\manage.ps1 build`
- `.\scripts\manage.ps1 save`
- `.\scripts\verify-offline.ps1`
- `.\scripts\manage.ps1 up`
- `.\scripts\manage.ps1 status`
- `http://localhost:7080/healthz`
- `.\scripts\manage.ps1 down`

The gateway container also reached `healthy` state during startup verification.

## Troubleshooting

### Workspace says the agent has not connected

Check the workspace container logs first.

Typical causes:

- The workspace image does not trust the correct root CA.
- The deployment target reissued the CA instead of only reissuing the leaf certificate.
- The certificate SANs do not include `host.docker.internal` or the actual target host.

If only the leaf certificate changed:

1. Run `ssl <host>` again.
2. Restart the affected workspace.

If the CA changed:

1. Run `ssl <host>`.
2. Rebuild the workspace image.
3. Restart the platform or reload the new workspace image.
4. Restart affected workspaces.

### Terraform provider not found

The offline bundle is incomplete, or strict offline mode is active without a full provider cache.

Run `prepare-offline.ps1` or `prepare-offline.sh` again on a connected machine, then run `verify-offline` before deployment.

If you intentionally want registry fallback in a connected environment, set:

```env
TF_CLI_CONFIG_MOUNT=../configs/terraform.rc
```

### LiteLLM does not start

Check all of the following:

- `configs/litellm_config.yaml` exists
- `INTERNAL_API_BASE` is set
- `INTERNAL_API_KEY` is set
- `YOUR_INTERNAL_MODEL` placeholders are replaced

### Re-run first-time setup

Windows:

```powershell
Remove-Item docker\.setup-done
.\scripts\manage.ps1 setup-coder
```

Linux:

```bash
rm -f docker/.setup-done
bash scripts/manage.sh setup-coder
```
