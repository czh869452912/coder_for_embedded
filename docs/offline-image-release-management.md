# Offline Image Release Management

This runbook is for the operator who maintains an offline Coder deployment after
the first installation. After reading it, the operator should be able to publish
a new workspace image, activate it through a Coder template version, roll back to
an older image, and decide when multiple images or templates are needed.

## Release Model

There are two image classes:

- Platform images run the Coder control plane and supporting services.
- Workspace images run user development environments and are grouped into
  stable image families.

Treat them differently. Platform images are upgraded with an in-place upgrade
and database backup. Workspace image families are released more often and are
exposed through the Coder template image catalog, then activated by promoting a
Coder template version.

Never use `latest` for a workspace image in production. Use immutable, meaningful
tags such as:

```text
embedded-v20260607-r1
embedded-v20260607-r2
python-backend-v20260607-r1
agent-dev-v20260607-r1
```

The tag should describe the image purpose, release date, and rebuild number. The
same tag must not be rebuilt with different contents. If the image changes,
create a new tag.

## Version Sources

The deployment reads platform image and provider locks from
`configs/versions.lock.env`. Workspace image defaults for bundle preparation
also live there, but the runtime workspace image choices live in
`workspace-template/image-catalog.json`. That catalog is part of each Coder
template version.

The current template exposes these stable workspace image families:

| Profile | Image family | Release command family |
| --- | --- | --- |
| `embedded_stable` | `workspace-embedded` | `embedded` |
| `python_backend_stable` | `workspace-python-backend` | `python-backend` |
| `agent_dev_stable` | `workspace-agent-dev` | `agent-dev` |

`embedded_stable` remains the default profile. A full `prepare` builds and saves
all stable workspace profiles so the offline bundle contains every image a user
can choose in the template. A family release updates that stable profile key;
candidate or alternate image names can add their own profiles without taking
over the stable default.

The current platform lock tracks GitHub latest Coder `v2.33.6`, resolved to a
pinned digest, the Coder Terraform provider `2.18.0`, and workspace image tag
`embedded-v20260607-r1`. The provider mirror must contain the same provider
version before a strict offline deployment is started.

Use this rule for future updates:

- Update the Coder image tag and digest together.
- Update Terraform provider versions only after the mirror contains the matching
  provider archive and index.
- Update the selected workspace image family tag to an immutable release tag
  before preparing a production offline bundle.
- Push workspace image choices through a Coder template version instead of
  hard-coding the active image in the management scripts.
- Run the offline verification command before transferring a bundle.

## Standard Workspace Release

Use this flow when the workspace toolchain changes but Coder itself does not.

### 1. Build on the connected machine

Windows:

```powershell
.\scripts\manage.ps1 update-workspace -Family embedded -Tag embedded-v20260607-r2
.\scripts\manage.ps1 update-workspace -Family python-backend -Tag python-backend-v20260607-r1
.\scripts\manage.ps1 update-workspace -Family agent-dev -Tag agent-dev-v20260607-r1
```

Linux:

```bash
bash scripts/manage.sh update-workspace --family embedded --tag embedded-v20260607-r2
bash scripts/manage.sh update-workspace --family python-backend --tag python-backend-v20260607-r1
bash scripts/manage.sh update-workspace --family agent-dev --tag agent-dev-v20260607-r1
```

Choose one family per workspace-only release. The command builds that workspace
image, saves the image tarball, updates that family's tag in the version lock,
and records the stable profile in the template image catalog. The stable profile
key remains the same and only its image ref changes. It does not activate a
Coder template version.

### 2. Transfer to the offline server

Transfer the workspace image tarball, the updated version lock, and the template
image catalog. Do not replace the offline server's deployment secrets or TLS CA
during a workspace-only release.

Example:

```bash
scp images/workspace-embedded_embedded-v20260607-r1.tar offline:/deploy/images/
scp images/workspace-python-backend_python-backend-v20260607-r1.tar offline:/deploy/images/
scp images/workspace-agent-dev_agent-dev-v20260607-r1.tar offline:/deploy/images/
scp configs/versions.lock.env offline:/deploy/configs/
scp workspace-template/image-catalog.json offline:/deploy/workspace-template/
```

Transfer only the tarball for the family you released during a workspace-only
update. Transfer all three stable workspace tarballs when you are moving a fresh
`prepare` bundle.

### 3. Load on the offline server

Windows:

```powershell
.\scripts\manage.ps1 load-workspace images\workspace-embedded_embedded-v20260607-r1.tar
```

Linux:

```bash
bash scripts/manage.sh load-workspace images/workspace-embedded_embedded-v20260607-r1.tar
```

The command loads the image into Docker and records it in the template image
catalog. It does not change the active Coder template version.

### 4. Stage and activate a Coder template version

Windows:

```powershell
.\scripts\manage.ps1 push-template -Name workspace-embedded-v20260607-r1
```

Linux:

```bash
bash scripts/manage.sh push-template --name workspace-embedded-v20260607-r1
```

The first command creates a staged Coder template version with
`--activate=false`. After the pilot workspace validates the image, activate the
version with the Coder UI or the Coder CLI promote command:

```bash
coder templates versions promote --template=embedded-dev --template-version=workspace-embedded-v20260607-r1
```

Use `-Apply` / `--apply` on `push-template` only when you intentionally want that
push to become active immediately.

### 5. Restart workspaces

Existing workspace containers keep running on the old image until users stop and
start them again. Ask a small pilot group to restart first. After the pilot is
healthy, ask the remaining users to restart.

## Rollback

Rollback is a Coder template version promotion, not a data restore.

1. Keep at least the previous two workspace image tarballs on the offline server.
2. Load the older tarball if it is not already present.
3. Promote the older Coder template version, or push a new version whose image
   catalog default points to the older image and activate that version.
4. Ask affected users to stop and restart their workspaces.

The home volumes are independent of the workspace image. A rollback changes the
container image used on the next start, but it does not delete user data.

## Multi-Image Strategy

Use one workspace image when users need the same toolchain and only resource
sizes differ. Resource choices already belong in template parameters.

Use the existing stable profiles in the same Coder template when the workspace
contract is one of the supported families:

- Embedded C/C++ development: `embedded_stable`
- Python backend services: `python_backend_stable`
- Interactive agent development: `agent_dev_stable`

Add more image profiles in the same Coder template when you need release
channels for an existing workspace contract:

- `embedded_stable`
- `embedded-candidate-v20260607-r1`

Use multiple Coder templates when the user experience or toolchain contract is
different enough that a separate template history is clearer:

- Documentation conversion and publishing
- Minimal terminal-only workspaces

This repository supports one Coder template with an image catalog and a workspace
image parameter. Multiple templates should be added only when another image
profile would make the operator and user experience harder to reason about.

## Release Checklist

Before release:

- Pick a new immutable tag.
- Build the selected image family on a connected machine.
- Save the image tarball.
- Check that the selected family lock points at the new tag.
- Transfer only the release artifacts needed by the offline server.

During release:

- Load the image on the offline server.
- Push a staged template version.
- Activate or promote the template version after pilot validation.
- Restart one pilot workspace.
- Verify code-server opens and the Coder agent connects.
- Verify the expected CLI/toolchain changes inside the pilot workspace.

After release:

- Keep the previous image tarball for rollback.
- Record the active tag, release date, author, reason, and known issues.
- Ask users to restart workspaces only after the pilot check passes.

## Suggested Release Record

Keep a small release record in your operations notes:

```text
Tag: embedded-v20260607-r1
Date: 2026-06-07
Built by: <operator>
Reason: Coder v2.33.6 platform refresh and workspace toolchain rebuild
Artifacts:
  workspace image tar: workspace-embedded_embedded-v20260607-r1.tar
  version lock: versions.lock.env
Pilot:
  user/workspace:
  result:
Rollback tag:
  embedded-v20260523-r1
Notes:
```

## Platform Image Upgrade

Use platform upgrades only when Coder, PostgreSQL, Nginx, provider versions, or
optional service images change. Platform upgrades should go through the in-place
upgrade runbook because Coder can migrate database schema on startup.

Recommended order:

1. Back up the running deployment.
2. Update version locks on a connected machine.
3. Prepare and verify the offline bundle.
4. Transfer the bundle.
5. Restore deployment-specific config and TLS CA.
6. Start the platform and let Coder run migrations.
7. Push the workspace template.
8. Run a pilot workspace restart.

Do not use `docker compose down -v` during a platform upgrade.

## Future Script Extensions

The current scripts already support the critical path through `update-workspace`,
`load-workspace`, and `push-template`, while leaving template version activation
to Coder-native version management.

The next useful extension is a workspace image release command group:

- `workspace-images list` shows local tags and saved tarballs.
- `workspace-images build --tag <tag>` builds and records a release.
- `workspace-images stage --tag <tag>` pushes a non-active template version.
- `workspace-images promote --version <name>` wraps Coder's template version
  promotion.

Add these commands only after the release record format is agreed. The release
record should become the source of truth for rollback.
