# Coder for Embedded Development — Multi-User Web IDE Platform

A production-ready deployment of [Coder](https://github.com/coder/coder) tailored for embedded software teams, providing a browser-accessible VS Code environment with a full ARM/QEMU embedded toolchain, Claude Code AI assistant, and multi-user management — all behind a single IP and port.

## Features

| Feature | Details |
|---------|---------|
| **Multi-user management** | Coder built-in RBAC: users, organizations, permissions |
| **Single IP, single port** | All services (admin dashboard + per-user IDE + LiteLLM) served from one `IP:8443` |
| **Fully offline deployable** | Docker image tarballs + Terraform provider local cache; no internet required at runtime |
| **Embedded toolchain** | ARM GNU Toolchain, Clang/LLVM, OpenOCD, QEMU — full embedded C/C++ dev environment |
| **Claude Code** | Every workspace ships Claude Code CLI + VS Code extension pre-installed |
| **Persistent workspaces** | Each user's `home` directory is a Docker volume; data survives container stop/restart |

## Architecture

```
[Browser]  HTTPS :8443 (single port)
     │
[Nginx :8443]  TLS termination
     ├── /          ──► [Coder :7080]   admin dashboard + workspace app proxy
     └── /llm/      ──► [LiteLLM :4000] AI gateway (optional, --profile llm)

[Coder] ──/var/run/docker.sock──► [Docker Engine]
                                     ├── coder-<user1>-<ws>  (code-server :8080)
                                     ├── coder-<user2>-<ws>  (code-server :8080)
                                     └── ...

Workspace access (no wildcard DNS needed):
  Admin:    https://IP:8443/
  User IDE: https://IP:8443/@<username>/<workspace>.main/apps/code-server
```

## Quick Start

### Prerequisites

- Docker Desktop (Windows) or Docker Engine + Compose v2 (Linux)
- Git for Windows (provides `openssl` on Windows)
- Internet access for first run (downloads Terraform providers and Coder agent binary)

### Windows (PowerShell)

```powershell
# 1. Allow script execution (first time only)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. Create configuration
.\scripts\manage.ps1 init

# 3. Generate SSL certificate (use actual server IP for LAN access)
.\scripts\manage.ps1 ssl 192.168.1.100

# 4. Build workspace image (~20-40 min, full embedded toolchain)
.\scripts\manage.ps1 build

# 5. Start platform (auto-initializes Coder on first run)
.\scripts\manage.ps1 up

# With LiteLLM AI gateway:
.\scripts\manage.ps1 up -Llm
```

### Linux / macOS (Bash)

```bash
# 1. Create configuration
bash scripts/manage.sh init

# 2. Generate SSL certificate
bash scripts/manage.sh ssl 192.168.1.100

# 3. Build workspace image
bash scripts/manage.sh build

# 4. Start platform
bash scripts/manage.sh up

# With LiteLLM AI gateway:
bash scripts/manage.sh up --llm
```

After startup, open `https://<IP>:8443/` in your browser.

## Offline Deployment

### Step 1 — Prepare resources on an internet-connected machine

```powershell
# Windows
.\scripts\prepare-offline.ps1

# Linux
bash scripts/prepare-offline.sh
```

This downloads:
- Terraform provider zips → `configs/terraform-providers/`
- Platform Docker images → `images/*.tar`
- Builds and saves workspace image → `images/workspace-embedded_latest.tar`

### Step 2 — Transfer to the air-gapped server

Copy the following to the target server:
```
images/                         # Docker image tarballs
configs/terraform-providers/    # Terraform provider zips
configs/vsix/                   # (optional) VS Code extension .vsix files
```

### Step 3 — Deploy on the air-gapped server

```bash
# Load Docker images
bash scripts/manage.sh load          # or: .\scripts\manage.ps1 load

# Initialize config
bash scripts/manage.sh init

# Generate SSL cert for the server IP
bash scripts/manage.sh ssl 10.0.1.50

# Rebuild workspace image with the correct cert baked in
bash scripts/manage.sh build

# Start platform
bash scripts/manage.sh up
```

## Configuration

### `docker/.env` key variables

| Variable | Description |
|----------|-------------|
| `SERVER_HOST` | Server IP or hostname (used in SSL cert SAN and `CODER_ACCESS_URL`) |
| `GATEWAY_PORT` | External port, default `8443` |
| `CODER_ADMIN_EMAIL` | First admin account email (created automatically on first start) |
| `CODER_ADMIN_PASSWORD` | First admin account password |
| `ANTHROPIC_API_KEY` | Claude Code API key (shared across all workspaces) |
| `ANTHROPIC_BASE_URL` | Internal LLM proxy URL (optional) |

When `SERVER_HOST=localhost`, the workspace container still downloads the Coder agent from `https://host.docker.internal:8443`, so the generated TLS certificate must also include `host.docker.internal` in its SAN list.

### Claude Code API options

| Option | Use case | Config |
|--------|----------|--------|
| A — Official API | Internet access available | `ANTHROPIC_API_KEY=sk-ant-...` |
| B — Internal proxy | Intranet Anthropic-compatible proxy | `ANTHROPIC_BASE_URL=http://10.x.x.x:8000` |
| C — LiteLLM | OpenAI-compatible internal API | `up --llm`, `ANTHROPIC_BASE_URL=https://IP:8443/llm` |
| D — Manual login | Testing / temporary use | Leave blank; run `claude` inside workspace to authenticate |

### LiteLLM AI Gateway (Option C)

```bash
cp configs/litellm_config.yaml.example configs/litellm_config.yaml
# Edit: set internal API base URL and model names
bash scripts/manage.sh up --llm    # or: .\scripts\manage.ps1 up -Llm
```

## Management Commands

### Windows PowerShell

```powershell
.\scripts\manage.ps1 init              # Create docker\.env
.\scripts\manage.ps1 ssl [IP]          # Generate SSL certificate
.\scripts\manage.ps1 build             # Build workspace image
.\scripts\manage.ps1 up [-Llm]         # Start platform
.\scripts\manage.ps1 down              # Stop platform
.\scripts\manage.ps1 status            # Container status
.\scripts\manage.ps1 logs [service]    # Stream logs (coder/gateway/postgres/llm-gateway)
.\scripts\manage.ps1 shell <service>   # Enter container shell
.\scripts\manage.ps1 setup-coder       # Re-run first-time init (admin account + template push)
.\scripts\manage.ps1 save              # Export all images to images\*.tar
.\scripts\manage.ps1 load              # Load images from images\*.tar
.\scripts\manage.ps1 test-api          # Test LLM API connectivity
```

### Linux / macOS Bash

```bash
bash scripts/manage.sh <command>    # same commands; use --llm instead of -Llm
```

## User Workflow

1. Admin logs in at `https://IP:8443/` and creates user accounts
2. User logs in → clicks **New Workspace** → selects `embedded-dev` template
3. Select CPU/RAM, create workspace (~30 seconds)
4. Click the **VS Code** icon → full browser IDE with embedded toolchain
5. Workspace data persists on stop; work continues on next start

## Project Structure

```
coder_production/
├── docker/
│   ├── docker-compose.yml       # Platform services: nginx + coder + postgres [+ litellm]
│   ├── Dockerfile.workspace     # Workspace image: code-server + embedded toolchain
│   └── .env                     # Instance config (gitignored — created by init)
├── configs/
│   ├── nginx.conf               # Single-port TLS reverse proxy config
│   ├── terraform.rc             # Terraform filesystem_mirror (offline provider cache)
│   ├── terraform-providers/     # Offline Terraform provider zips (populated by prepare-offline)
│   ├── ssl/                     # TLS certificates (gitignored — created by ssl command)
│   ├── settings.json            # VS Code default settings for all workspaces
│   ├── litellm_config.yaml.example
│   └── vsix/                    # Offline VS Code extensions (.vsix files)
├── workspace-template/
│   └── main.tf                  # Coder Terraform workspace template
├── scripts/
│   ├── manage.ps1               # Windows PowerShell management script
│   ├── manage.sh                # Linux/macOS Bash management script
│   ├── workspace-startup.sh     # Workspace container init (Claude Code config + code-server)
│   ├── setup-coder.sh           # First-run Coder setup (admin account + template push)
│   ├── prepare-offline.ps1      # Windows: download all offline resources
│   └── prepare-offline.sh       # Linux: download all offline resources
├── images/                      # Docker image tarballs (gitignored)
└── .env.example                 # Config template
```

## Troubleshooting

**Workspace shows "Unreachable"**
- Check `.\manage.ps1 logs gateway` for nginx errors
- Confirm `SERVER_HOST` in `.env` matches the URL you use to access Coder
- Verify `proxy_read_timeout 86400s` is in `nginx.conf`

**SSL certificate errors / workspace agent fails to connect**
- The SSL cert must be baked into the workspace image *after* running `ssl <IP>`
- Re-run `build` after generating/changing the SSL cert
- Verify build output contains "Coder server SSL cert trusted"
- If the workspace log shows `curl: (60)` and `no alternative certificate subject name matches target host name 'host.docker.internal'`, regenerate the cert with the updated `ssl` command and rebuild the workspace image
- After updating the cert/image, restart the affected workspace so it retries the agent download with the corrected certificate

**Terraform provider not found**
- Connected environment: providers download automatically (internet fallback is enabled)
- Air-gapped environment: run `prepare-offline.ps1` / `prepare-offline.sh` first, then `load`

**Template push failed / first-time init incomplete**
```powershell
# Delete the completion marker and re-run
Remove-Item docker\.setup-done
.\scripts\manage.ps1 setup-coder
```

**Docker socket permission denied (Linux)**
```bash
sudo chmod 666 /var/run/docker.sock
```

**`manage.ps1` blocked by execution policy**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## CI/CD Offline Build Integration

To build the workspace image in an air-gapped CI pipeline, replace online downloads in `docker/Dockerfile.workspace` with pre-staged artifacts:

| Step | Online | Offline replacement |
|------|--------|---------------------|
| ARM GNU Toolchain | `wget https://developer.arm.com/...` | `COPY build-artifacts/arm-gnu-toolchain.tar.xz` |
| Node.js | `curl nodesource.com \| bash` | Internal apt mirror or `COPY build-artifacts/nodejs.deb` |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` | `COPY build-artifacts/claude-code.tgz` + `npm install -g` |

```bash
# CI pipeline example:
# 1. Fetch build-artifacts/ from internal artifact registry
# 2. Build and tag workspace image
docker build -f docker/Dockerfile.workspace -t workspace-embedded:${CI_COMMIT_SHA} .
# 3. Push to internal registry
docker push registry.internal/workspace-embedded:${CI_COMMIT_SHA}
# 4. Update WORKSPACE_IMAGE_TAG in docker/.env on the deployment server
```
