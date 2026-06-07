# ============================================================
# Coder Workspace 模板 - 嵌入式开发环境
#
# 每个 workspace 对应一个 Docker 容器，包含：
#   - code-server (VS Code Web IDE, --auth none)
#   - Claude Code CLI
#   - ARM 嵌入式开发工具链
#   - 持久化 home 目录（独立 Docker volume）
#
# 访问路径（单端口，无需通配符 DNS）：
#   https://<SERVER>:8443/@<username>/<workspace>.main/apps/code-server
#
# 离线要求：
#   - workspace_image 必须已通过 manage.sh build/load 加载到本地 Docker
#   - Terraform provider 通过 filesystem_mirror 离线加载（terraform.rc）
# ============================================================

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.1"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "coder" {}

provider "docker" {
  # 使用 Coder 容器内挂载的 Docker socket（连接到宿主机 Docker daemon）
  # workspace 容器由宿主机 Docker 创建，因此 host_path 均指宿主机路径
  host = "unix:///var/run/docker.sock"
}

# ============================================================
# 数据源
# ============================================================
data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  username       = data.coder_workspace_owner.me.name
  workspace_name = lower(data.coder_workspace.me.name)
  # 容器名称（Docker 命名规则：小写字母、数字、连字符）
  container_name = "coder-${local.username}-${local.workspace_name}"
}

# ============================================================
# workspace 参数（用户创建 workspace 时选择）
# ============================================================
data "coder_parameter" "cpu_cores" {
  name         = "cpu_cores"
  display_name = "CPU 核心数"
  type         = "number"
  default      = "4"
  mutable      = true
  icon         = "/emojis/1f5a5.png"
  order        = 1
  option {
    name  = "2 核"
    value = "2"
  }
  option {
    name  = "4 核"
    value = "4"
  }
  option {
    name  = "8 核"
    value = "8"
  }
}

data "coder_parameter" "memory_gb" {
  name         = "memory_gb"
  display_name = "内存大小"
  type         = "number"
  default      = "8"
  mutable      = true
  icon         = "/emojis/1f4be.png"
  order        = 2
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
  option {
    name  = "16 GB"
    value = "16"
  }
}

# ============================================================
# Coder Agent（在 workspace 容器内运行）
# ============================================================
resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # 传递给 workspace 容器的环境变量
  env = {
    # Claude Code API 配置（由管理员在模板中统一设置）
    ANTHROPIC_API_KEY   = var.anthropic_api_key
    ANTHROPIC_BASE_URL  = var.anthropic_base_url
    # OpenAI-compatible API 配置（Codex CLI / Kilo Code / OpenAI-format editor tools）
    OPENAI_API_KEY      = var.openai_api_key
    OPENAI_BASE_URL     = var.openai_base_url
    # Git 用户信息（自动从 Coder 用户资料获取）
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    # Skill Hub + PyPI Mirror（--skillhub profile 启用时为 "true"）
    SKILLHUB_ENABLED    = var.skillhub_enabled
  }

  # workspace 启动脚本（在 agent 连接成功后执行一次）
  # 功能：配置 Claude Code + 合并 VS Code 扩展 seed + 后台启动 code-server
  startup_script = <<-EOT
    set -e
    /opt/workspace-startup.sh
  EOT

  # 仪表盘显示的 workspace 指标
  metadata {
    display_name = "CPU 使用率"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "内存使用率"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "磁盘使用率"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  # 禁用 VS Code Desktop 集成（内网环境，用户无需安装 VS Code Desktop）
  # 保留 web_terminal（内置终端）和 port_forwarding_helper（端口转发）
  display_apps {
    vscode                 = false
    vscode_insiders        = false
    web_terminal           = true
    port_forwarding_helper = true
    ssh_helper             = false
  }
}

# ============================================================
# code-server 应用（VS Code Web IDE）
#
# 关键：subdomain = false
#   使用路径路由而非子域名路由，无需通配符 DNS 配置
#   访问地址：https://<SERVER>:8443/@<user>/<workspace>.main/apps/code-server
# ============================================================
resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  icon         = "/icon/code.svg"
  url          = "http://localhost:8080/?folder=/home/coder"
  # 路径路由（单端口关键配置，无需通配符 DNS）
  subdomain    = false
  share        = "owner"
  open_in      = "tab"

  healthcheck {
    url       = "http://localhost:8080/healthz"
    interval  = 5
    threshold = 10
  }
}

# ============================================================
# MinerU 文档转 Markdown（Gradio UI）
# 需要 manage.sh up --mineru 启用，否则链接返回 502
# ============================================================
resource "coder_app" "mineru" {
  count        = var.mineru_enabled == "true" ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "mineru"
  display_name = "MinerU 文档转 Markdown"
  icon         = "/icon/pdf.svg"
  url          = "https://${var.server_host}:${var.gateway_port}/mineru/"
  external     = true
}

# ============================================================
# Pandoc docconv Markdown→Word/PDF 转换
# 需要 manage.sh up --doctools 启用，否则链接返回 502
# ============================================================
resource "coder_app" "docconv" {
  count        = var.doctools_enabled == "true" ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "docconv"
  display_name = "Pandoc Markdown→Word"
  icon         = "/icon/markdown.svg"
  url          = "https://${var.server_host}:${var.gateway_port}/docconv/"
  external     = true
}

# ============================================================
# Gitea Skill Hub（Claude Code slash command 市场）
# 需要 manage.sh up --skillhub 启用，否则链接返回 502
# ============================================================
resource "coder_app" "skill_hub" {
  count        = var.skillhub_enabled == "true" ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "skill-hub"
  display_name = "Gitea (Skills)"
  icon         = "/icon/git.svg"
  url          = "https://${var.server_host}:${var.gateway_port}/gitea/"
  external     = true
}

# ============================================================
# 持久化 home 目录（每个 workspace 独立 volume）
# workspace 停止/删除后 volume 保留，数据不丢失
# ============================================================
resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  # 防止因 workspace rename 等属性变更触发 volume 重建（数据丢失）
  lifecycle {
    ignore_changes = all
  }
  # Docker labels：用于识别孤儿 volume（workspace 已删除但 volume 残留）
  labels {
    label = "coder.owner"
    value = local.username
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

# ============================================================
# workspace 容器
# start_count = 0（已停止）或 1（运行中）
# workspace 停止时容器被销毁，home volume 保留
# ============================================================
resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = "${var.workspace_image}:${var.workspace_image_tag}"
  name     = local.container_name
  hostname = local.workspace_name

  # 容器入口：执行 Coder 生成的 init_script
  # init_script 负责：下载 coder agent 二进制 → 启动 agent
  # agent 启动后连接 Coder 服务器，执行 startup_script（启动 code-server）
  #
  # replace() 处理：将原有的外部访问 URL 替换为内网 Coder 服务 URL，
  # 确保在 coderplatform 内部网络中下载 coder agent CLI 的行为不再绕行外部网关。
  entrypoint = ["sh", "-c", replace(
    coder_agent.main.init_script,
    data.coder_workspace.me.access_url,
    "http://coder:7080"
  )]

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_URL=http://coder:7080"
  ]

  # 将 workspace 容器附加到预先创建好的 coderplatform 网络中
  # 这允许容器内通过 llm-gateway:4000 等 Docker DNS 别名直接访问
  network_mode = "coderplatform"

  # 资源限制
  memory     = data.coder_parameter.memory_gb.value * 1024
  cpu_shares = data.coder_parameter.cpu_cores.value * 256

  # 持久化 home 目录
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  # Docker labels：用于识别孤儿容器
  labels {
    label = "coder.owner"
    value = local.username
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

# ============================================================
# 模板变量（由管理员在推送模板时通过 --var 参数设置）
# ============================================================

# workspace 镜像名称（使用本地 tag 或内网 registry 地址）
variable "workspace_image" {
  description = "workspace Docker 镜像名称（本地 tag 或内网 registry）"
  default     = "workspace-embedded"
}

variable "workspace_image_tag" {
  description = "workspace Docker 镜像 tag"
  default     = "latest"
}

# Claude Code API 配置（统一为所有用户设置，或留空让用户自行登录）
variable "anthropic_api_key" {
  description = "Anthropic API Key（Claude Code 使用，统一设置或留空）"
  default     = ""
  sensitive   = true
}

variable "anthropic_base_url" {
  description = "Anthropic API Base URL（内网代理地址，留空使用官方 API）"
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI-compatible API Key（Codex/Kilo Code 使用，统一设置或留空）"
  default     = ""
  sensitive   = true
}

variable "openai_base_url" {
  description = "OpenAI-compatible Base URL（LiteLLM 建议 http://llm-gateway:4000/v1；留空使用官方 API）"
  default     = ""
}

# 平台网关地址（用于生成内网服务快捷链接）
variable "server_host" {
  description = "平台服务器 IP 或主机名（与 docker/.env SERVER_HOST 一致）"
  default     = "localhost"
}

variable "gateway_port" {
  description = "HTTPS 网关端口（与 docker/.env GATEWAY_PORT 一致）"
  default     = "8443"
}

variable "mineru_enabled" {
  description = "是否启用 MinerU 文档转 Markdown 服务（manage.sh up --mineru 时设为 true）"
  default     = "false"
}

variable "doctools_enabled" {
  description = "是否启用 Pandoc Markdown→Word/PDF 服务（manage.sh up --doctools 时设为 true）"
  default     = "false"
}

variable "skillhub_enabled" {
  description = "是否启用 Skill Hub + PyPI Mirror（manage.sh up --skillhub 时设为 true）"
  default     = "false"
}
