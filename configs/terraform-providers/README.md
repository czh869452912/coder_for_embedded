# Terraform Provider 离线缓存

此目录存放离线 Terraform provider zip 包，用于内网无法访问 `registry.terraform.io` 时使用。

## 目录结构

```
registry.terraform.io/
├── coder/coder/<VERSION>/linux_amd64/
│   └── terraform-provider-coder_<VERSION>_linux_amd64.zip
└── kreuzwerker/docker/<VERSION>/linux_amd64/
    └── terraform-provider-docker_<VERSION>_linux_amd64.zip
```

## 下载 Provider

运行以下命令在联网环境下载 provider（与 `workspace-template/main.tf` 中的版本一致）：

```bash
bash scripts/prepare-offline.sh
```

或手动下载：

```bash
# coder provider
TF_PROVIDER_CODER_VERSION=2.1.3
mkdir -p registry.terraform.io/coder/coder/${TF_PROVIDER_CODER_VERSION}/linux_amd64/
curl -fL "$(curl -sf https://registry.terraform.io/v1/providers/coder/coder/${TF_PROVIDER_CODER_VERSION}/download/linux/amd64 | python3 -c "import sys,json; print(json.load(sys.stdin)['download_url'])")" \
  -o "registry.terraform.io/coder/coder/${TF_PROVIDER_CODER_VERSION}/linux_amd64/terraform-provider-coder_${TF_PROVIDER_CODER_VERSION}_linux_amd64.zip"

# docker provider
TF_PROVIDER_DOCKER_VERSION=3.0.2
mkdir -p registry.terraform.io/kreuzwerker/docker/${TF_PROVIDER_DOCKER_VERSION}/linux_amd64/
curl -fL "$(curl -sf https://registry.terraform.io/v1/providers/kreuzwerker/docker/${TF_PROVIDER_DOCKER_VERSION}/download/linux/amd64 | python3 -c "import sys,json; print(json.load(sys.stdin)['download_url'])")" \
  -o "registry.terraform.io/kreuzwerker/docker/${TF_PROVIDER_DOCKER_VERSION}/linux_amd64/terraform-provider-docker_${TF_PROVIDER_DOCKER_VERSION}_linux_amd64.zip"
```

## 版本说明

provider 版本必须与 `workspace-template/main.tf` 中声明的 `version` 约束一致：

```hcl
coder = {
  source  = "coder/coder"
  version = "~> 2.1"   # 此处限制了版本范围，缓存中的 zip 必须满足此约束
}
docker = {
  source  = "kreuzwerker/docker"
  version = "~> 3.0"
}
```

## CI 流水线集成

将 provider zip 存入内网制品库（Nexus/Artifactory），构建流水线从制品库获取后放置到此目录。
