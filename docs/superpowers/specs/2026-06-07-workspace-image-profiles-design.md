# Workspace Image Profiles Design

## Reader And Action

The reader is the engineer who will implement and operate the next workspace
image expansion. After reading this design, they should be able to add the
Python backend and agent development images without changing the existing
embedded workspace contract or weakening offline release controls.

## Goal

Add two development environments alongside the current embedded development
image:

- Python backend development
- Interactive agent development

The environments should be exposed through the existing workspace image
selection parameter when they share the same workspace contract. A separate
Coder template should be introduced only for agent workspaces that are meant to
run automated Coder Agents rather than interactive developers.

## Official Coder Guidance

Coder's image management guidance recommends a small base image, a small number
of general-purpose golden images, and Dev Containers for project-specific
customization. It explicitly warns that large multi-purpose images become hard
to maintain and suggests keeping general-purpose golden images to a minimum,
usually two or three, with clear scope:

- Image management:
  https://coder.com/docs/admin/templates/managing-templates/image-management
- Template management:
  https://coder.com/docs/admin/templates/managing-templates
- Template change management:
  https://coder.com/docs/admin/templates/managing-templates/change-management
- Build parameters:
  https://coder.com/docs/admin/templates/extending-templates/parameters

Coder Agents are a different operating mode from normal interactive
workspaces. Coder's agent documentation focuses on controlling and optimizing
templates for agent execution, which supports treating automated agent
workspaces as a separate template contract when they need different startup,
permissions, tools, or UI assumptions:

- Coder Agents:
  https://coder.com/docs/ai-coder/agents
- Agent template optimization:
  https://coder.com/docs/ai-coder/agents/platform-controls/template-optimization

## Design Decision

Use one Coder template with multiple image profiles for the three interactive
developer environments:

- `embedded_stable`: existing embedded C/C++ development image
- `python_backend_stable`: Python backend development image
- `agent_dev_stable`: interactive agent development image

Keep `embedded_stable` as the default profile so existing users keep the same
behavior unless they choose another image.

Do not merge all toolchains into the existing embedded image. Each new profile
gets its own workspace image build definition so Python backend users do not
inherit embedded cross-compilers and embedded users do not inherit unrelated
backend or agent tooling.

## Image Scopes

### Embedded Stable

The existing image remains the embedded C/C++ golden path. It keeps the current
code-server workspace behavior, embedded toolchains, C/C++ test tools, AI CLIs,
and configured startup flow.

### Python Backend Stable

This image should target common backend service work:

- Python runtime and virtual environment tooling
- package and dependency tools such as `uv` and `pipx`
- linting and formatting such as Ruff
- testing such as pytest and coverage
- common backend framework support such as FastAPI
- database/client utilities for PostgreSQL and Redis
- the same Coder agent, code-server, CA trust, Git identity, and model gateway
  environment contract as the embedded image

Project-specific dependencies should live in the project repository through
Dev Containers or normal project dependency files, not in the golden image.

### Agent Dev Stable

This image should target humans building agent systems, MCP servers, tools, and
agent-enabled applications:

- Python and Node.js development tooling
- Claude Code, OpenAI Codex, Kilo Code, Pi, and related command-line tools
- MCP and agent framework development utilities
- Playwright or browser automation dependencies when needed for agent testing
- code-server extension seeds useful for agent and API development
- the same Coder agent, code-server, CA trust, Git identity, and model gateway
  environment contract as the embedded image

This profile is for interactive developers. It is not the final answer for
automated Coder Agents.

## Automated Agent Template Boundary

If the desired "agent development image" becomes an execution environment for
Coder Agents that run tasks automatically, create a separate Coder template
rather than only another image profile.

The separate agent template can remove developer-only assumptions, such as a
full IDE extension seed, and can apply tighter defaults for:

- startup scripts
- workspace apps
- resource sizing
- allowed network destinations
- injected credentials
- task-specific repositories or bootstrap commands

This keeps the interactive developer template stable while allowing agent
execution to be optimized and governed separately.

## Release Model

The current release model remains:

- workspace image choices live in the template image catalog
- users select a profile through the existing workspace image parameter
- image changes are staged by pushing a new Coder template version
- activation is performed by promoting the desired template version
- existing workspace containers move to the selected image only after stop/start

The new image profiles should use immutable tags:

- `python-backend-vYYYYMMDD-rN`
- `agent-dev-vYYYYMMDD-rN`

The default embedded stable tag format remains unchanged.

## Implementation Shape

Add separate build definitions for the new images and keep shared workspace
behavior factored so all images can reuse:

- code-server base image selection
- platform root CA trust
- workspace startup script
- Git and model gateway environment contract
- code-server user settings and extension seed handling

The image catalog gains stable profile entries for Python backend and
interactive agent development. The existing template image parameter can keep
using a dropdown because it already models this kind of build parameter.

Management scripts should learn how to build, save, load, and register a
workspace image by image family. The existing stable embedded behavior should
continue to update only `embedded_stable`. Python backend and agent development
stable releases should update their matching stable profile keys instead of
creating a new profile per tag.

## Testing And Verification

Automated checks should cover:

- the image catalog contains all three stable profile keys
- the default profile remains `embedded_stable`
- loading a Python backend tarball registers or updates
  `python_backend_stable`
- loading an agent development tarball registers or updates
  `agent_dev_stable`
- existing embedded release behavior remains unchanged
- template dropdown options are generated from the catalog

Operational pilot checks should verify:

- code-server opens for each profile
- the Coder agent connects
- the selected image reference matches the chosen profile
- expected CLIs are present inside each image
- model gateway environment variables are available when LiteLLM mode is used

## Non-Goals

This design does not add project-specific dependency stacks for every backend
service or every agent framework. Those belong in project repositories through
Dev Containers or project dependency files.

This design does not replace the existing embedded image, change the default
workspace profile, or force existing users to migrate.

This design does not yet implement a separate automated Coder Agents template.
It defines the boundary for when that template should be introduced.
