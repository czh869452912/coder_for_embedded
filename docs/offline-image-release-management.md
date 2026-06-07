# Offline Image Release Management

This runbook is for the operator who maintains an offline Coder deployment after
the first installation. After reading it, the operator should be able to publish
a new workspace image, activate it through a Coder template version, roll back to
an older image, and decide when multiple images or templates are needed.

## Release Model

There are two image families:

- Platform images run the Coder control plane and supporting services.
- Workspace images run user development environments.

Treat them differently. Platform images are upgraded with an in-place upgrade
and database backup. Workspace images are released more often and are activated
by pushing a new template version.

Never use `latest` for a workspace image in production. Use immutable, meaningful
tags such as:

```text
embedded-v20260607-r1
embedded-v20260607-r2
ai-v20260607-r1
```

The tag should describe the image purpose, release date, and rebuild number. The
same tag must not be rebuilt with different contents. If the image changes,
create a new tag.

## Version Sources

The deployment reads image and provider locks from `configs/versions.lock.env`.

The current platform lock tracks GitHub latest Coder `v2.33.6`, resolved to a
pinned digest, the Coder Terraform provider `2.18.0`, and workspace image tag
`embedded-v20260607-r1`. The provider mirror must contain the same provider
version before a strict offline deployment is started.

Use this rule for future updates:

- Update the Coder image tag and digest together.
- Update Terraform provider versions only after the mirror contains the matching
  provider archive and index.
- Update the workspace image tag to an immutable release tag before preparing a
  production offline bundle.
- Run the offline verification command before transferring a bundle.

## Standard Workspace Release

Use this flow when the workspace toolchain changes but Coder itself does not.

### 1. Build on the connected machine

Windows:

```powershell
.\scripts\manage.ps1 update-workspace -Tag embedded-v20260607-r1
```

Linux:

```bash
bash scripts/manage.sh update-workspace --tag embedded-v20260607-r1
```

This builds a workspace image, saves the image tarball, updates the workspace
image tag in the version lock, and pushes the template if the local Coder service
is running.

### 2. Transfer to the offline server

Transfer the workspace image tarball and the updated version lock. Do not replace
the offline server's deployment secrets or TLS CA during a workspace-only release.

Example:

```bash
scp images/workspace-embedded_embedded-v20260607-r1.tar offline:/deploy/images/
scp configs/versions.lock.env offline:/deploy/configs/
```

### 3. Load and activate on the offline server

Windows:

```powershell
.\scripts\manage.ps1 load-workspace images\workspace-embedded_embedded-v20260607-r1.tar
```

Linux:

```bash
bash scripts/manage.sh load-workspace images/workspace-embedded_embedded-v20260607-r1.tar
```

The command loads the image, updates the active workspace image tag, and pushes a
new Coder template version.

### 4. Restart workspaces

Existing workspace containers keep running on the old image until users stop and
start them again. Ask a small pilot group to restart first. After the pilot is
healthy, ask the remaining users to restart.

## Rollback

Rollback is a template activation, not a data restore.

1. Keep at least the previous two workspace image tarballs on the offline server.
2. Load the older tarball if it is not already present.
3. Run `load-workspace` with the older tarball.
4. Ask affected users to stop and restart their workspaces.

The home volumes are independent of the workspace image. A rollback changes the
container image used on the next start, but it does not delete user data.

## Multi-Image Strategy

Use one workspace image when users need the same toolchain and only resource
sizes differ. Resource choices already belong in template parameters.

Use multiple tags of the same image when you need release channels for the same
template:

- `embedded-stable-v20260607-r1`
- `embedded-candidate-v20260607-r1`

Use multiple Coder templates when the user experience or toolchain contract is
different:

- Embedded C/C++ development
- AI-heavy development with extra model tooling
- Documentation conversion and publishing
- Minimal terminal-only workspaces

For now, this repository supports one active template and one active workspace
image tag. Multiple templates should be added as a planned script extension so
each template can carry its own image name, image tag, variables, and release
history.

## Release Checklist

Before release:

- Pick a new immutable tag.
- Build the image on a connected machine.
- Save the image tarball.
- Check that the version lock points at the new tag.
- Transfer only the release artifacts needed by the offline server.

During release:

- Load the image on the offline server.
- Push the template version.
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
`load-workspace`, and `push-template`.

The next useful extension is a workspace image release command group:

- `workspace-images list` shows local tags and saved tarballs.
- `workspace-images build --tag <tag>` builds and records a release.
- `workspace-images activate --tag <tag>` updates the version lock and pushes the
  template.
- `workspace-images rollback` activates the previous recorded tag.

Add these commands only after the release record format is agreed. The release
record should become the source of truth for rollback.
