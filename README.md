# Coder for Embedded Development

A single-port Coder deployment for embedded software teams. The platform provides browser-based VS Code workspaces, a full embedded C/C++ toolchain, an optional LiteLLM gateway that adapts existing internal model infrastructure for Claude Code and other editor tools, optional LDAP authentication via Dex OIDC, GPU-accelerated document-to-Markdown conversion via MinerU, and Markdown-to-Word/PDF conversion via Pandoc.

## What This Repository Guarantees

- Single external entrypoint: `https://<host>:8443/`
- Multi-user Coder platform with per-user workspaces
- Path-based workspace apps, no wildcard DNS required
- Offline deployment after an online preparation step
- Reproducible deployment images pinned in `configs/versions.lock.env`
- Workspace image versioning: build and push new workspace versions without redeploying the platform

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
  -> /llm/        -> LiteLLM :4000   (optional, --llm)
  -> /dex/        -> Dex OIDC :5556  (optional, --ldap)
  -> /mineru/     -> MinerU :7860    (optional, --mineru, GPU required)
  -> /docconv/    -> Pandoc :3030    (optional, --doctools)

Coder
  -> Docker socket
  -> creates one workspace container per user/workspace

Workspace app path
  -> /@<username>/<workspace>.main/apps/code-server

Internal network (coderplatform, 172.28.0.0/16)
  Workspace containers -> http://llm-gateway:4000  (direct, no SSL overhead)
  Workspace containers -> http://mineru:7860        (direct access to MinerU)
  Workspace containers -> http://docconv:3030       (direct access to Pandoc)
  Dex -> PostgreSQL :5432  (shared postgres, separate 'dex' database)

Authentication
  Built-in password  (always available, used for initial admin)
  LDAP via Dex OIDC  (optional, --ldap mode)
```

## Prerequisites

- Windows: Docker Desktop, PowerShell 7 recommended, Git for Windows (`openssl`)
- Linux: Docker Engine + Compose v2, `bash`, `openssl`, `curl`, `python3`
- Internet is required only for online preparation and explicit version refresh operations.

**For MinerU GPU service (`--mineru`) only:**

- NVIDIA GPU (RTX series recommended; MinerU uses vLLM for layout analysis)
- `nvidia-docker2` package installed on the Linux host
- Docker 18.09+ with `runtime: nvidia` support (note: `--gpus` syntax requires Docker 19.03+; this platform uses `runtime: nvidia` for compatibility)
- `docker-compose` ≥ 1.28 for `profiles:` support (upgrade the standalone binary independently of Docker Engine if needed)

Verify GPU runtime availability before starting MinerU:
```bash
docker run --runtime=nvidia --rm nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi
```

## Script Entry Points

All operations go through a single entry point:

| Platform | Script |
|----------|--------|
| Windows  | `.\scripts\manage.ps1 <command> [flags]` |
| Linux    | `bash scripts/manage.sh <command> [flags]` |

Legacy standalone scripts (`prepare-offline.sh/ps1`, `verify-offline.sh/ps1`, `refresh-versions.sh/ps1`, `setup-coder.sh`) are preserved as thin shims that delegate to `manage.sh`/`manage.ps1` for backward compatibility.

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

# Enable LDAP authentication (configure DEX_LDAP_* in docker/.env first)
.\scripts\manage.ps1 up -Ldap

# Enable MinerU GPU document conversion (requires nvidia-docker2 on host)
.\scripts\manage.ps1 up -Mineru

# Enable Pandoc Markdown->Word/PDF conversion
.\scripts\manage.ps1 up -Doctools

# Enable everything
.\scripts\manage.ps1 up -Llm -Ldap -Mineru -Doctools
```

### Linux

```bash
bash scripts/manage.sh init
bash scripts/manage.sh ssl 192.168.1.100
bash scripts/manage.sh build
bash scripts/manage.sh up

# Enable LiteLLM gateway mode
bash scripts/manage.sh up --llm

# Enable LDAP authentication (configure DEX_LDAP_* in docker/.env first)
bash scripts/manage.sh up --ldap

# Enable MinerU GPU document conversion (requires nvidia-docker2 on host)
bash scripts/manage.sh up --mineru

# Enable Pandoc Markdown->Word/PDF conversion
bash scripts/manage.sh up --doctools

# Enable everything
bash scripts/manage.sh up --llm --ldap --mineru --doctools
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
.\scripts\manage.ps1 prepare
.\scripts\manage.ps1 verify
```

Linux:

```bash
bash scripts/manage.sh prepare
bash scripts/manage.sh verify
```

The preparation step:

- Downloads VS Code extensions (`.vsix`) into `configs/vsix/`
- Downloads Terraform providers into `configs/provider-mirror/` and `configs/terraform-providers/`
- Pulls pinned runtime images and saves them into `images/`
- Builds the workspace image and saves it into `images/`
- Generates a root CA in `configs/ssl/` if one does not already exist
- Writes `offline-manifest.json`

Skip flags: `-SkipImages` / `--skip-images` skips pulling runtime images; `-SkipBuild` / `--skip-build` skips building the workspace image. Running `verify` after a partial prepare will fail until all artifacts are present.

Optional flags:

- `-Llm` / `--llm` also saves the LiteLLM image
- `-Mineru` / `--mineru` also saves the MinerU image (large: ~20 GB compressed)
- `-Doctools` / `--doctools` also saves the Pandoc image (~2 GB compressed)

### Step 2: Transfer to the Offline Server

Transfer the entire project directory, including at least:

- `images/`
- `configs/ssl/`
- `configs/terraform-providers/`
- `configs/provider-mirror/`
- `configs/vsix/`
- `offline-manifest.json`

Important: Keep `configs/ssl/ca.crt` and `configs/ssl/ca.key` from the prepared bundle. The offline target should reuse that CA and only reissue the leaf certificate.

### Step 3: Deploy on the Offline Server

Windows:

```powershell
.\scripts\manage.ps1 verify
.\scripts\manage.ps1 init
.\scripts\manage.ps1 ssl 10.0.1.50
.\scripts\manage.ps1 load
.\scripts\manage.ps1 up
```

Linux:

```bash
bash scripts/manage.sh verify
bash scripts/manage.sh init
bash scripts/manage.sh ssl 10.0.1.50
bash scripts/manage.sh load
bash scripts/manage.sh up
```

Notes:

- `up` will auto-run first-time Coder initialization if `docker/.setup-done` does not exist.
- If the offline target accidentally generates a new CA instead of reusing the transferred CA, rebuild the workspace image once.
- In strict offline mode, `up` will fail fast if the provider cache is incomplete.

## Workspace Image Versioning

Each `manage.sh prepare` / `manage.ps1 prepare` builds the workspace image with the tag stored in `configs/versions.lock.env` (`WORKSPACE_IMAGE_TAG`). When you need to update the workspace toolchain on a running offline deployment, use the update workflow below.

### Update Workflow

**Step 1 — Build a new version on a connected machine**

Windows:

```powershell
# Auto-generates tag v<YYYYMMDD>, or supply your own with -Tag
.\scripts\manage.ps1 update-workspace
.\scripts\manage.ps1 update-workspace -Tag v20240324
```

Linux:

```bash
bash scripts/manage.sh update-workspace
bash scripts/manage.sh update-workspace --tag v20240324
```

This:
- Builds `workspace-embedded:<tag>` using the current `Dockerfile.workspace`
- Saves it to `images/workspace-embedded_<tag>.tar`
- Updates `WORKSPACE_IMAGE_TAG` in `configs/versions.lock.env`
- Pushes a new template version to Coder if the platform is currently running

**Step 2 — Transfer to the offline server**

```bash
scp images/workspace-embedded_v20240324.tar  offline-server:/deploy/images/
scp configs/versions.lock.env                offline-server:/deploy/configs/
```

**Step 3 — Load and activate on the offline server**

Windows:

```powershell
.\scripts\manage.ps1 load-workspace images\workspace-embedded_v20240324.tar
```

Linux:

```bash
bash scripts/manage.sh load-workspace images/workspace-embedded_v20240324.tar
```

This:
- Loads the image into Docker
- Parses the tag from the filename (`workspace-embedded_v20240324.tar` → tag `v20240324`)
- Updates `WORKSPACE_IMAGE_TAG` in `configs/versions.lock.env`
- Pushes a new template version to Coder (the platform must be running)

**Step 4 — Users restart their workspaces**

In the Coder UI, stop then restart each workspace. Coder will rebuild the container using the new image.

### Push Template Only

If you need to push a template update without rebuilding the image (e.g., after changing template variables):

Windows:

```powershell
.\scripts\manage.ps1 push-template
```

Linux:

```bash
bash scripts/manage.sh push-template
```

## In-Place Upgrade (Preserve Users and Workspaces)

If you have an existing deployment that is several commits behind this repository and you want to move to the latest code without losing user accounts, workspace metadata, or home-directory data, use the in-place upgrade workflow.

The platform stores all user identity and workspace state in the PostgreSQL database and each workspace's home volume. As long as the `docker_postgres-data` volume and every `coder-<id>-home` volume are preserved, a full code and image upgrade is safe.

For a detailed step-by-step runbook covering:

- Pre-upgrade snapshot (`upgrade-backup`)
- Switching to new code and restoring config (`upgrade-restore-config`)
- Verifying the migration before users restart workspaces
- Rolling back if something goes wrong
- Adding LDAP/OIDC after the platform is already running

See **[docs/upgrade-in-place.md](docs/upgrade-in-place.md)** (written in Chinese for the primary audience, with English summaries for key commands).

Quick commands:

```bash
# Before switching code — take a snapshot while Postgres is still running
bash scripts/manage.sh upgrade-backup [--dest <dir>]

# After git checkout <new-ref> — restore .env and ssl from snapshot
bash scripts/manage.sh upgrade-restore-config <snapshot-dir>
```

**Critical reminders:**

- Never run `docker compose down -v` during an upgrade — the `-v` flag deletes named volumes.
- Always preserve `POSTGRES_PASSWORD` and `configs/ssl/ca.key`.
- Existing workspaces will keep running on their old image until users explicitly stop and restart them in the UI.

## Version Locking

Deployment reads pinned refs from `configs/versions.lock.env`.

Current pinned items include:

- Coder runtime image
- PostgreSQL image
- Nginx image
- LiteLLM image (used with `--llm`)
- Dex OIDC image (used with `--ldap`)
- MinerU image (used with `--mineru`)
- Pandoc image (used with `--doctools`)
- code-server base image used to build the workspace image
- Workspace image tag (`WORKSPACE_IMAGE_TAG`)
- Terraform provider versions

Runtime scripts read `docker/.env` for deployment-specific values and `configs/versions.lock.env` for locked image/provider versions.

## Refreshing to the Latest Stable Versions

Version refresh is an explicit maintenance step. It does not happen during deployment.

Windows dry run:

```powershell
.\scripts\manage.ps1 refresh-versions
```

Windows apply:

```powershell
.\scripts\manage.ps1 refresh-versions -Apply
```

Linux dry run:

```bash
bash scripts/manage.sh refresh-versions
```

Linux apply:

```bash
bash scripts/manage.sh refresh-versions --apply
```

The refresh command:

- Pulls the tagged upstream images you have chosen to track
- Resolves their current digests
- Queries the newest stable provider versions within the current locked major versions
- Rewrites `configs/versions.lock.env` only when you explicitly apply

## AI Gateway Setup

1. Copy the example config:

```bash
cp configs/litellm_config.yaml.example configs/litellm_config.yaml
```

2. Replace `YOUR_INTERNAL_MODEL` and set the real internal API endpoint and key in `docker/.env`:

```env
INTERNAL_API_BASE=https://api.your-model-provider.com/v1
INTERNAL_API_KEY=your-key
LITELLM_MASTER_KEY=sk-devenv
```

3. Set the Claude Code API variables so workspace containers reach LiteLLM directly over the internal Docker network:

```env
ANTHROPIC_API_KEY=sk-devenv          # must match LITELLM_MASTER_KEY
ANTHROPIC_BASE_URL=http://llm-gateway:4000
```

> **Note:** Do not use `https://<host>:8443/llm` as `ANTHROPIC_BASE_URL`. Workspace containers are on the `coderplatform` Docker network and resolve `localhost` as themselves, not as the host or Nginx. The direct internal URL `http://llm-gateway:4000` is the correct address. The `/llm/` Nginx path is for external browser/tool access only.

4. Start with LiteLLM enabled:

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

## MinerU Document-to-Markdown Service

MinerU converts PDF, Word, PowerPoint, and image files to Markdown with GPU-accelerated OCR and layout analysis. It is served as a Gradio web UI accessible at `https://<host>:8443/mineru/`.

**Host prerequisites:** `nvidia-docker2` installed, GPU runtime verified (see [Prerequisites](#prerequisites)).

**GPU allocation:** MinerU binds to GPU 0 (`CUDA_VISIBLE_DEVICES=0`). If LiteLLM workloads also use a GPU, configure them on GPU 1 to avoid VRAM contention. Each RTX A6000 provides 48 GB VRAM.

**Model weights:** On first startup, MinerU downloads its model weights (~5–10 GB) and caches them in the `mineru-models` Docker volume. Subsequent restarts are fast. In fully offline deployments, pre-populate the volume before disconnecting from the network.

1. Start with MinerU enabled:

Linux:

```bash
bash scripts/manage.sh up --mineru
```

Windows:

```powershell
.\scripts\manage.ps1 up -Mineru
```

2. Access the Gradio UI at `https://<host>:8443/mineru/`

3. Include in offline bundle preparation:

```bash
bash scripts/manage.sh prepare --mineru
bash scripts/manage.sh verify
# Windows: .\scripts\manage.ps1 prepare -Mineru
```

**Gradio WebSocket note:** The Nginx location for `/mineru/` proxies WebSocket connections required by Gradio's real-time progress updates. No additional client-side configuration is needed.

**docker-compose profile:** `mineru` — only active when started with `--mineru` / `-Mineru`.

## Pandoc Markdown-to-Word/PDF Service

Pandoc converts Markdown to Word (`.docx`) or PDF with full math formula support. It is served via `pandoc --server` (Pandoc 3.x built-in HTTP server) on port 3030, accessible at `https://<host>:8443/docconv/`.

**Formula support:**

- DOCX output: uses `--mathml` — Word 2016+ renders MathML equations natively
- PDF output: uses `--pdf-engine=xelatex` — the `pandoc/latex` image includes a full TeX Live distribution

**API usage** (from workspace terminal or any HTTP client):

```bash
# Markdown -> DOCX with math
curl -k -X POST https://<host>:8443/docconv/ \
  -H "Content-Type: application/json" \
  -d '{"text":"# Title\n\n$$E=mc^2$$\n","from":"markdown+tex_math_dollars","to":"docx","options":{"mathml":true}}' \
  -o output.docx

# Markdown -> PDF (requires xelatex, slower)
curl -k -X POST https://<host>:8443/docconv/ \
  -H "Content-Type: application/json" \
  -d '{"text":"# Title\n\n$$E=mc^2$$\n","from":"markdown+tex_math_dollars","to":"pdf","options":{"pdf-engine":"xelatex"}}' \
  -o output.pdf
```

Or directly from workspace containers via the internal Docker DNS:

```bash
curl -s -X POST http://docconv:3030/ \
  -H "Content-Type: application/json" \
  -d '{"text":"# Hello\n\n$$F=ma$$","from":"markdown+tex_math_dollars","to":"docx","options":{"mathml":true}}' \
  -o output.docx
```

1. Start with docconv enabled:

Linux:

```bash
bash scripts/manage.sh up --doctools
```

Windows:

```powershell
.\scripts\manage.ps1 up -Doctools
```

2. Include in offline bundle preparation:

```bash
bash scripts/manage.sh prepare --doctools
# Windows: .\scripts\manage.ps1 prepare -Doctools
```

**docker-compose profile:** `doctools` — only active when started with `--doctools` / `-Doctools`.

## LDAP Authentication Setup

LDAP authentication uses Dex as an OIDC bridge. Coder OSS supports OIDC natively; Dex connects to your LDAP server and exposes an OIDC interface to Coder.

1. Add the following to `docker/.env`:

```env
# Shared secret between Dex and Coder. Generate with: openssl rand -hex 32
OIDC_CLIENT_SECRET=your-random-secret

# Restrict to your email domain, or use * for all
OIDC_EMAIL_DOMAIN=company.local
OIDC_ALLOW_SIGNUPS=true

# LDAP server (plain: host:389, TLS: ldaps://host:636)
DEX_LDAP_HOST=ldap.company.local:389

# Service account for user search (read-only recommended)
DEX_LDAP_BIND_DN=cn=svc-coder,ou=serviceaccounts,dc=company,dc=local
DEX_LDAP_BIND_PW=bind-password

# Search base DNs
DEX_LDAP_USER_BASE_DN=ou=users,dc=company,dc=local
DEX_LDAP_GROUP_BASE_DN=ou=groups,dc=company,dc=local
```

2. Adjust LDAP attribute mapping if needed in `configs/dex/config.yaml` (default uses `uid`/`mail`/`displayName`, suitable for standard OpenLDAP).

3. Start with LDAP enabled:

Windows:

```powershell
.\scripts\manage.ps1 up -Ldap
```

Linux:

```bash
bash scripts/manage.sh up --ldap
```

4. Verify Dex is running:

```bash
curl -sk https://<host>:8443/dex/.well-known/openid-configuration | python3 -m json.tool
```

The Coder login page will show a "Sign in with 企业 LDAP" button alongside the built-in password form.

> **First deployment note:** The `dex` PostgreSQL database is created automatically via `configs/postgres/init-dex.sql` on first container start. If the `postgres-data` volume already exists from a previous deployment, create it manually:
> ```bash
> docker exec coder-postgres psql -U coder -c "CREATE DATABASE dex OWNER coder;"
> docker compose --profile ldap restart dex
> ```

> **Offline preparation:** Include the Dex image with:
> ```bash
> bash scripts/manage.sh prepare --ldap
> # Windows: .\scripts\manage.ps1 prepare -Ldap
> ```

## Common Commands

### Windows

```powershell
# Platform lifecycle
.\scripts\manage.ps1 init
.\scripts\manage.ps1 ssl [host]
.\scripts\manage.ps1 pull [-Llm] [-Ldap] [-Mineru] [-Doctools]
.\scripts\manage.ps1 build
.\scripts\manage.ps1 save [-Llm] [-Ldap] [-Mineru] [-Doctools]
.\scripts\manage.ps1 load
.\scripts\manage.ps1 up [-Llm] [-Ldap] [-Mineru] [-Doctools]
.\scripts\manage.ps1 down [-Llm] [-Ldap] [-Mineru] [-Doctools]
.\scripts\manage.ps1 status
.\scripts\manage.ps1 logs [service]
.\scripts\manage.ps1 shell <service>
.\scripts\manage.ps1 setup-coder
.\scripts\manage.ps1 push-template
.\scripts\manage.ps1 test-api
.\scripts\manage.ps1 test-llm-backend

# Workspace image versioning
.\scripts\manage.ps1 update-workspace [-Tag v20240324]
.\scripts\manage.ps1 load-workspace images\workspace-embedded_v20240324.tar

# In-place upgrade (preserve users and workspaces across code changes)
.\scripts\manage.ps1 upgrade-backup [-Dest dir] [-Force]
.\scripts\manage.ps1 upgrade-restore-config <snapshot-dir> [-Force]

# Offline bundle preparation (connected machine)
.\scripts\manage.ps1 prepare [-SkipImages] [-SkipBuild] [-Llm] [-Mineru] [-Doctools]
.\scripts\manage.ps1 verify [-RequireLlm]
.\scripts\manage.ps1 refresh-versions [-Apply]
```

### Linux

```bash
# Platform lifecycle
bash scripts/manage.sh <command> [--llm] [--ldap] [--mineru] [--doctools]

# Workspace image versioning
bash scripts/manage.sh update-workspace [--tag v20240324]
bash scripts/manage.sh load-workspace images/workspace-embedded_v20240324.tar

# In-place upgrade (preserve users and workspaces across code changes)
bash scripts/manage.sh upgrade-backup [--dest <dir>] [--force]
bash scripts/manage.sh upgrade-restore-config <snapshot-dir> [--force]

# Offline bundle preparation (connected machine)
bash scripts/manage.sh prepare [--skip-images] [--skip-build] [--llm] [--mineru] [--doctools]
bash scripts/manage.sh verify [--require-llm]
bash scripts/manage.sh refresh-versions [--apply]
```

## Key Files

- `docker/docker-compose.yml`: platform services (gateway, coder, postgres, llm-gateway, dex)
- `docker/Dockerfile.workspace`: workspace image build
- `configs/versions.lock.env`: pinned deployment versions and workspace image tag
- `configs/nginx.conf`: Nginx gateway routing (`/`, `/llm/`, `/dex/`)
- `configs/terraform-offline.rc`: strict offline Terraform config
- `configs/terraform.rc`: connected Terraform config with fallback
- `configs/litellm_config.yaml.example`: LiteLLM gateway template
- `configs/dex/config.yaml`: Dex OIDC + LDAP connector config (--ldap mode)
- `configs/postgres/init-dex.sql`: auto-creates `dex` database on first postgres start
- `workspace-template/main.tf`: Coder template that provisions workspace containers
- `docs/upgrade-in-place.md`: runbook for upgrading an existing deployment without losing users or workspace data
- `scripts/manage.ps1`: **Windows entry point** — all commands
- `scripts/manage.sh`: **Linux entry point** — all commands
- `scripts/prepare-offline.ps1`: shim → `manage.ps1 prepare`
- `scripts/prepare-offline.sh`: shim → `manage.sh prepare`
- `scripts/verify-offline.ps1`: shim → `manage.ps1 verify`
- `scripts/verify-offline.sh`: shim → `manage.sh verify`
- `scripts/refresh-versions.ps1`: shim → `manage.ps1 refresh-versions`
- `scripts/refresh-versions.sh`: shim → `manage.sh refresh-versions`
- `scripts/setup-coder.sh`: shim → `manage.sh setup-coder`
- `scripts/lib/offline-common.sh`: shared Bash library (SSL, config, env parsing)
- `scripts/lib/offline-common.ps1`: shared PowerShell library
- `offline-manifest.json`: expected offline bundle contents (written by `prepare`)

## Windows Smoke Test

The following Windows paths have been exercised successfully in this repository:

- `.\scripts\manage.ps1 refresh-versions` dry run
- `.\scripts\manage.ps1 prepare -SkipBuild`
- `.\scripts\manage.ps1 ssl localhost`
- `.\scripts\manage.ps1 build`
- `.\scripts\manage.ps1 save`
- `.\scripts\manage.ps1 verify`
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

Run `manage.ps1 prepare` or `manage.sh prepare` again on a connected machine, then run `manage.sh verify` before deployment.

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

### Claude Code cannot reach LiteLLM from inside workspace

Confirm `ANTHROPIC_BASE_URL=http://llm-gateway:4000` in `docker/.env`. The internal Docker DNS name `llm-gateway` resolves correctly from workspace containers on the `coderplatform` network. Using `https://localhost:8443/llm` will fail because `localhost` inside a container refers to the container itself.

### Workspace did not pick up the new image after load-workspace

Coder only applies the new template version to workspaces when they are restarted. In the Coder UI, stop the workspace and then start it again. The new image will be used for the fresh container.

### Dex does not start (LDAP mode)

Check all of the following:

- Started with `--ldap` / `-Ldap` flag
- `OIDC_CLIENT_SECRET` is non-empty in `docker/.env`
- All `DEX_LDAP_*` variables are filled in
- The `dex` database exists in PostgreSQL (see First deployment note above)
- `configs/dex/config.yaml` is present

To check Dex logs:

```bash
docker logs coder-dex
```

To verify the OIDC discovery endpoint:

```bash
curl -sk https://<host>:8443/dex/.well-known/openid-configuration
```

### Coder login page does not show LDAP button

- Confirm `OIDC_CLIENT_SECRET` is non-empty — if empty, Coder skips OIDC entirely
- Restart the coder container after changing OIDC env vars: `docker restart coder-server`
- Check Coder logs for OIDC initialization errors: `docker logs coder-server`

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
