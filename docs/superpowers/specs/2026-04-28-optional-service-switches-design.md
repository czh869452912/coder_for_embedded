# Optional Service Switches Unified Design

## Goal

Make optional service switches mean the same thing across preparation, loading, startup, template publishing, documentation, and tests.

## Current Problem

The repository currently treats optional services inconsistently:

- `pull` and `save` honor optional service switches.
- `prepare` honors most optional service switches but omits LDAP/Dex.
- `load` loads every `images/*.tar` file regardless of switches.
- `up` and `down` honor Docker Compose profiles.
- `workspace-template/main.tf` always exposes app links for some optional services.
- Bash has SkillHub preparation and first-start initialization, while PowerShell only has partial SkillHub support.
- Documentation describes `load --ldap --skillhub` semantics that the scripts do not implement.

This creates surprising behavior, bloated offline loads, and failed offline deployments when a requested optional service image was not prepared.

## Unified Semantics

A service switch means: "include this optional service in the current command's service set."

The base service set is always:

- Coder
- Postgres
- Nginx gateway/provider mirror
- Workspace image where applicable
- Code-server base image where a build is performed

Optional services are:

- `llm`: LiteLLM gateway image and Compose profile
- `ldap`: Dex image and Compose profile
- `mineru`: MinerU image and Compose profile
- `doctools`: docconv/Pandoc image and Compose profile
- `skillhub`: Gitea and pypiserver images, Compose profile, package/repo preparation, and Gitea initialization

## Command Responsibilities

`pull`

- Pull base runtime/build images.
- Pull optional service images selected by flags.

`save`

- Save base deployment images.
- Save optional service images selected by flags.
- Retain existing digest-to-tag fallback behavior.

`prepare`

- Download VSIX and Terraform provider artifacts.
- Pull and save base deployment images.
- Pull and save optional service images selected by flags, including LDAP/Dex.
- Build and save the workspace image unless skipped.
- Write `offline-manifest.json` containing the base image entries and only selected optional image entries.
- Write explicit include flags for every optional service: `include_llm`, `include_ldap`, `include_mineru`, `include_doctools`, `include_skillhub`.

`verify`

- Continue validating files listed in `offline-manifest.json`.
- Keep `-RequireLlm` / `--require-llm`.
- Optionally support future `-Require*` flags, but this design only requires preserving the existing LLM check.

`load`

- Load base images by default.
- Load optional service images only when their switches are passed.
- Prefer `offline-manifest.json` to resolve exact archive paths.
- Fall back to version-lock-derived filenames if no manifest exists.
- Retag digest-saved images to `name:tag` after load, as today.
- Do not blindly load every tarball in `images/`.

`up` / `down`

- Continue passing Compose profiles only for selected optional services.
- Preflight only the base images and selected optional images.
- Keep digest-to-tag environment overrides before invoking Compose.

`push-template`, `setup-coder`, `update-workspace`, and `load-workspace`

- Pass template variables for selected optional services.
- Preserve the existing LiteLLM behavior: when `-Llm` / `--llm` is selected, default agent API variables to the internal LiteLLM gateway if explicit values are absent.

`refresh-versions`

- Resolve digest refs for all images tracked in `configs/versions.lock.env`, including Dex.
- Preserve optional image lock lines only when already present.

## Template Behavior

The workspace template should expose optional app links only when their matching switches are selected during template publishing.

Add template variables:

- `mineru_enabled`
- `doctools_enabled`
- `skillhub_enabled` already exists and should remain

Use `count` on optional `coder_app` resources so disabled services do not appear in the Coder UI as broken links.

LDAP and LiteLLM do not need workspace app links.

## SkillHub Parity

Bash already has:

- `skillhub-prepare`
- `skillhub-refresh`
- Gitea initialization on first `up --skillhub`

PowerShell should either implement equivalent behavior or stop advertising full SkillHub support. The intended repair is to implement PowerShell parity:

- Add `skillhub-prepare` and `skillhub-refresh` commands.
- Pull/save Gitea and pypiserver images.
- Mirror configured seed repositories into `configs/gitea/seeds`.
- Download Python packages into `configs/pypi/packages` when `pip` is available.
- Initialize Gitea on first `up -SkillHub`.

## Documentation Requirements

Update README, upgrade runbook, and script help text so they all state the same rule:

- Use the same optional service flags during `prepare`, `load`, `up`, and `push-template` when that service should be available offline and visible in workspaces.
- `load` no longer means "load every tar in images".
- LDAP/Dex is included by `-Ldap` / `--ldap` during preparation.
- SkillHub on Windows is supported only after PowerShell parity is implemented.

## Testing Requirements

Extend the existing static regression tests in `tests/upgrade-scripts.tests.ps1` to catch the current mismatches:

- PowerShell and Bash `prepare` include Dex when LDAP is selected.
- PowerShell and Bash `prepare` manifest includes `include_ldap`.
- PowerShell and Bash `load` use a selected image list rather than blindly iterating every tarball.
- PowerShell and Bash optional service image maps include the same services.
- PowerShell exposes SkillHub prepare/refresh commands if documentation advertises them.
- Workspace template gates MinerU, docconv, and SkillHub apps with enable variables.
- README and upgrade runbook no longer claim fake `load` flag behavior.

Also keep existing syntax and regression checks:

- `powershell -NoProfile -ExecutionPolicy Bypass -File tests\upgrade-scripts.tests.ps1`
- PowerShell parser checks for `scripts/manage.ps1` and `scripts/lib/offline-common.ps1`
- `bash -n scripts/manage.sh`

## Out Of Scope

- Running Docker pulls, builds, saves, loads, or Compose startup during this repair.
- Changing the actual Docker service definitions except where required for script/template compatibility.
- Redesigning SkillHub product behavior beyond matching the currently documented Gitea and pypiserver workflow.
- Adding new optional service categories.

## Acceptance Criteria

- `prepare -Ldap` and `prepare --ldap` include Dex image entries and set `include_ldap`.
- `load` without optional flags does not load optional service tarballs.
- `load -Mineru` / `load --mineru` loads the MinerU tarball when present in the manifest or expected image filename.
- `up` preflight and Compose profile selection still match selected switches.
- Windows and Bash scripts expose equivalent optional service commands where documented.
- Optional workspace app links only appear when the corresponding service flag was used while publishing the template.
- Existing tests and syntax checks pass.
