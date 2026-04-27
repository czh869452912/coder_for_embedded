# Coder 平台原地升级指南（保留用户与工作区数据）

如果你已经部署了一套 Coder 平台，但代码版本落后于当前仓库（例如早期没有 workspace 镜像版本管理、没有 LDAP、没有 Skill Hub 等功能），现在想把整个平台按最新代码重新启动，同时**不丢失现有用户的账号密码和已激活的工作区**，请按本指南操作。

> 如果你只是要在同一台服务器上更新 workspace 里的工具（例如加了新的 GCC 工具链），不需要走完整升级流程，直接用 `manage.sh update-workspace` / `manage.ps1 update-workspace` 即可。

---

## 1. 什么时候需要走这套流程

适合的场景：
- 旧部署使用 `manage.sh up` 启动，但那是很多个 commit 之前的老代码。
- 旧部署的 `workspace-embedded` 镜像没有版本 tag，全部是 `latest`。
- 旧部署没有 `versions.lock.env` 锁定版本概念。
- 旧部署的 `docker/.env` 和 `configs/ssl/` 中有些关键配置（密码、CA）不能变。
- 旧部署已有 10-20 个活跃用户，已经创建了 workspace，里面存有实际代码。

**不**适合的场景（直接重建即可）：
- 从零开始的新机器。
- 可以接受所有用户重新注册、所有 workspace 重新创建。

---

## 2. 数据会保留什么、会改什么

### 绝对保留（前提是你按步骤做）

| 数据 | 存在哪里 | 说明 |
|------|---------|------|
| 所有用户账号和密码哈希 | Postgres `coder` 数据库 | 密码哈希不会泄露，登录方式不变 |
| 所有 workspace 元数据 | Postgres `coder` 数据库 | 名称、参数、状态、模板版本 |
| 每个用户的代码和配置 | Docker named volume `coder-<id>-home` | workspace 容器重建时 volume 不动 |
| 根 CA (`ca.crt` / `ca.key`) | `configs/ssl/` | 换 CA 会让所有旧 workspace 不再信任证书 |
| `POSTGRES_PASSWORD` | `docker/.env` | 改了它 coder 就连不上旧 DB |

### 会变更的部分

- Coder 服务本身升级到 `versions.lock.env` 中锁定的新版本（自动 schema migration）。
- Nginx、Postgres 等运行时也同步升级到新锁定的版本。
- Dex（LDAP 桥接）在启用 `--ldap` 后新增为可选组件，不影响已有密码登录。
- Workspace 容器镜像最终需要切换到新版本（用户**主动重启** workspace 时才触发）。

---

## 3. 升级前准备（在仍在运行的旧平台上执行）

### 3.1 通知用户

在维护窗口期（建议选非工作时间），提前通知用户：
1. 把当前未提交的代码 **push 到 Git** 或提交到本地仓库。
2. 把在 workspace 里手动下载/修改的重要文件同步到持久目录（如 `~/workspace/` 下）。
3. 升级期间平台会短暂停止服务，预计 10-30 分钟（取决于备份数据量）。

### 3.2 执行自动快照

在旧平台仍然运行的时候执行：

**Linux:**
```bash
bash scripts/manage.sh upgrade-backup
```

**Windows:**
```powershell
.\scripts\manage.ps1 upgrade-backup
```

这会创建 `backups/snapshot-YYYYMMDD-HHMMSS/`，内部包含：

```text
backups/snapshot-20240427-143052/
├── coder.sql                     # pg_dumpall（完整热备份）
├── env.bak                       # docker/.env
├── ssl/
│   ├── ca.crt
│   ├── ca.key
│   └── server.crt / server.key   # 当前使用的叶子证书
├── versions.lock.env.bak         # 旧版本锁定文件（如存在）
├── setup-done.bak                # 首启动标记（跳过重复创建 admin）
├── volumes/
│   ├── postgres-data.tgz         # Postgres data volume
│   ├── coder-abc123-home.tgz     # 用户 A 的 home volume
│   ├── coder-def456-home.tgz     # 用户 B 的 home volume
│   └── ...                       # 其余 workspace home
└── meta.json                     # 快照元数据（git commit、镜像 tag、volume 数量）
```

#### 自定义存放位置

如果 `/backups` 所在磁盘空间不足，可以指定别的目录：

```bash
bash scripts/manage.sh upgrade-backup --dest /mnt/nas/coder-snapshot-2024-04
```

如果该目录已存在，会报错；加 `--force` 可以覆盖：

```bash
bash scripts/manage.sh upgrade-backup --dest /mnt/nas/coder-snapshot --force
```

### 3.3 验证快照完整性

快照做完后，确认几个关键文件非空：

```bash
du -sh backups/snapshot-*/coder.sql          # 应 > 0（通常几百 KB 到几十 MB）
du -sh backups/snapshot-*/volumes/postgres-data.tgz   # 应 > 0
du -sh backups/snapshot-*/volumes/coder-*-home.tgz    # 每个用户一个
```

> **关键提醒**：把快照目录复制到**平台所在服务器之外**的存储（NAS、另一台机器、S3 等）。如果升级失败需要回滚，快照是唯一的救命稻草。

---

## 4. 升级步骤

### Step 1：停止旧平台

```bash
bash scripts/manage.sh down
```

> **绝不要**加 `-v` 或 `--volumes`。加了会删除 `postgres-data` 和所有 home volume。

### Step 2：切换到新代码

```bash
git fetch
git checkout <new-branch-or-tag>
# 或者 git pull origin master
```

> `docker/.env` 和 `configs/ssl/` 在 `.gitignore` 中，git checkout **不会**覆盖它们。但如果你是从一台全新机器上 clone 的，这些文件就不存在，需要 Step 3 还原。

### Step 3：还原配置（关键）

```bash
bash scripts/manage.sh upgrade-restore-config backups/snapshot-YYYYMMDD-HHMMSS
```

这个命令会：
1. 把快照中的 `env.bak` 复制为 `docker/.env`（保留旧密码）。
2. 把快照中的 `ssl/` 复制为 `configs/ssl/`（保留旧 CA）。
3. 自动追加 `versions.lock.env` 中缺失的新默认值（如 `MINERU_IMAGE_REF` 等）。
4. 保留旧的 `.setup-done` 标记，避免重复创建 admin。

如果当前目录已经存在 `docker/.env` 或 `configs/ssl/`，命令会**拒绝覆盖**以保护现有配置。你可以加 `--force`，旧文件会被重命名为 `.env.before-restore` 和 `ssl.before-restore`：

```bash
bash scripts/manage.sh upgrade-restore-config backups/snapshot-20240427-143052 --force
```

### Step 4：加载新镜像

新代码可能带有新的服务组件（Dex、MinerU、Gitea 等）。先加载所有基础镜像：

```bash
bash scripts/manage.sh load
```

如果你计划在新平台启用 `--ldap`、 `--skillhub`、 `--mineru` 等，也要在 `load` 时带上对应标志，确保这些镜像被加载：

```bash
bash scripts/manage.sh load --ldap --skillhub
```

### Step 5：启动平台

```bash
bash scripts/manage.sh up
# 或启用附加服务：
# bash scripts/manage.sh up --ldap --skillhub
```

启动时会发生的事情：

1. Postgres 容器启动，复用旧的 `postgres-data` volume。
2. 新的 Coder 容器启动，连接到同一个 Postgres。
3. Coder 自动运行 schema migration，把旧数据库结构升级到当前版本。**这是安全的向前迁移，Coder 会保证兼容性。**
4. `setup-coder` 逻辑检测到已有用户（`/api/v2/users/first` 返回非 404），**不会**重复创建 admin，而是直接拿 session token 并 push 新的 workspace template。

### Step 6：验证核心功能

1. **打开 Web UI**，确认能正常访问 `https://<SERVER_HOST>:<GATEWAY_PORT>/`。
2. **用旧账号密码登录**一个普通用户（不是 admin），确认能进 Dashboard。
3. **查看 workspace 列表**，确认所有 workspace 名称和状态都在。
4. 让一个用户**启动**自己的 workspace（点击 Start）：
   - 容器使用旧的 `workspace-embedded:latest` 镜像（因为 template 里的 `workspace_image_tag` 可能还是 `latest`）。
   - 容器重建，但 `coder-<id>-home` volume 保持不变，用户代码和 `.bashrc` 全在。

如果以上全部通过，说明平台核心数据无损升级成功。

---

## 5. 迁移 workspace 镜像到新版本

旧用户的工作区此时还在用旧镜像（可能是 `latest`）。为了让他们用上最新的工具链，你需要：

### 5.1 构建一个带版本 tag 的新镜像

```bash
bash scripts/manage.sh update-workspace --tag v$(date +%Y%m%d)
```

这会自动：
- 用当前的 `Dockerfile.workspace` 构建新镜像（例如 `workspace-embedded:v20260427`）。
- 保存为 `images/workspace-embedded_v20260427.tar`。
- 更新 `configs/versions.lock.env` 中的 `WORKSPACE_IMAGE_TAG`。
- 向运行中的 Coder push 一个新的 template version（默认激活）。

### 5.2 通知用户重启 workspace

在 Coder UI 中，用户只需要：
1. **Stop** 自己的工作区。
2. **Start** 自己的工作区。

Terraform 会重新 evaluate template，使用新的 `workspace-embedded:v20260427` 镜像创建容器，但**仍然挂载原来的 home volume**。用户的所有文件和配置不受影响，只是容器内的系统工具（GCC、Claude Code、VS Code Server 等）变成了新版本。

### 5.3 保留旧镜像直到全员迁移

在用户还没有全部重启 workspace 之前，**不要删除**旧的 `workspace-embedded:latest`（或旧的未打 tag 镜像）。如果有人还在运行旧容器，删除镜像不会立即破坏运行中的容器，但 Docker 会在他们下次启动 workspace 时找不到镜像而报错。

等确认所有用户都至少重启过一次后，可以安全清理：

```bash
docker rmi workspace-embedded:latest   # 或其他旧 tag
```

---

## 6. LDAP / OIDC 的接入（可选）

**不要在升级当天就开启 LDAP**。建议分两步：

### Phase A：升级当天只走密码登录

确保 `docker/.env` 中：
```env
OIDC_CLIENT_SECRET=
```

留空。启动时不带 `--ldap`。此时只有内置密码登录生效，老用户照常使用。

### Phase B：稳定后再接入 LDAP

1. 在 `.env` 中填写 `OIDC_CLIENT_SECRET`、所有 `DEX_LDAP_*` 变量。
2. 重启平台：
   ```bash
   bash scripts/manage.sh down
   bash scripts/manage.sh up --ldap
   ```
3. Coder OSS 支持**双轨认证**：既有密码登录，又有 OIDC/LDAP 登录。老用户可以继续用密码；新用户点 "Sign in with 企业 LDAP" 按钮走域账号登录。
4. 如果某个老用户也想切到 LDAP，让他先用 LDAP 登录一次（会创建新账号），然后 admin 可以在 Coder UI 里把旧账号的数据迁移到新账号；或者直接在 `.env` 里保留双轨，长期并行即可。

> **首次开启 `--ldap` 的注意事项**：如果旧 Postgres 中没有 `dex` 数据库，会自动通过 `configs/postgres/init-dex.sql` 创建（该脚本在 postgres volume 首次初始化时运行）。由于你的 Postgres volume 是旧的，这个 init 脚本**不会**再次执行。你需要手动创建：
> ```bash
> docker exec coder-postgres psql -U coder -c "CREATE DATABASE dex OWNER coder;"
> docker compose --profile ldap restart dex
> ```

---

## 7. 回滚方案（最坏情况）

如果升级后发现问题，需要回退到旧代码 + 旧平台状态：

### 7.1 仅回退配置（最快的办法）

如果你还没运行 `manage.sh clean` 或删除旧 Docker 镜像：

```bash
bash scripts/manage.sh down
git checkout <old-branch-or-commit>
bash scripts/manage.sh upgrade-restore-config backups/snapshot-YYYYMMDD-HHMMSS --force
bash scripts/manage.sh up
```

因为 `postgres-data` volume 和 `coder-*-home` volumes 始终没有被删除，数据还是旧状态。只要 Coder 版本回退到兼容旧 schema 的版本，就能直接启动。

### 7.2 完全回滚（从 pg_dumpall 恢复）

如果新旧 Coder 版本跨度太大，向前迁移后再向后回退可能出现 schema 不兼容。此时只能用快照中的 SQL 恢复。

```bash
bash scripts/manage.sh down

# 删除现有 postgres-data（危险！）
docker volume rm docker_postgres-data

# 重新创建同名空 volume
docker volume create docker_postgres-data

# 用旧 Postgres 镜像启动一个临时容器来恢复数据
# （假设旧版本是 postgres:15-alpine；如果你的快照 meta.json 里有版本信息，按实际版本）
docker run --rm \
    -v docker_postgres-data:/var/lib/postgresql/data \
    -v $(pwd)/backups/snapshot-YYYYMMDD-HHMMSS:/backup:ro \
    postgres:15-alpine \
    bash -c "initdb -D /var/lib/postgresql/data -U coder --auth-local=trust && pg_ctl -D /var/lib/postgresql/data -o '-c listen_addresses=''' start && psql -U postgres -c \"CREATE USER coder WITH SUPERUSER PASSWORD '$(grep POSTGRES_PASSWORD docker/.env | cut -d= -f2)';\" && psql -U coder -d coder -f /backup/coder.sql"
```

> 这是一个**手动应急**流程，不是自动化命令。建议先在测试环境演练一次。

---

## 8. 常见坑与排错

### "POSTGRES_PASSWORD 不匹配，coder 连不上数据库"

原因：`docker/.env` 被覆盖或重新生成了密码。
解决：用 `upgrade-restore-config` 从快照恢复旧 `.env`。

### "用户 workspace 启动失败，提示找不到镜像"

原因：旧镜像（`latest`）被 `docker system prune` 或 `manage.sh clean` 删掉了。
解决：重新构建旧镜像或让那个用户不要重启，直接构建新版本后统一切。

### "SSL 证书错误，workspace agent 连不上 Coder"

原因：`configs/ssl/` 被新 CA 覆盖，旧 workspace 容器不信任新 CA。
解决：
1. 用快照恢复旧 `ssl/`（包含同一个 `ca.key` 和 `ca.crt`）。
2. 如果旧 CA 确实丢了，必须重建 workspace 镜像（新镜像内嵌新 CA），然后让用户全部重启。

### "workspace 重启后代码丢了"

原因：直接删掉了 `coder-*-home` volume（例如用了 `docker compose down -v`）。
解决：**升级流程里绝不要加 `-v`**。如果已经误删，只能从快照的 `volumes/coder-xxx-home.tgz` 中恢复。

### "升级后 admin 账号被要求重新注册"

原因：`docker/.setup-done` 文件丢失，导致 `setup-coder` 误以为这是首次启动。
解决：快照中保存了 `setup-done.bak`，`upgrade-restore-config` 会自动恢复它。如果手动部署时忘了恢复，可以：
```bash
# 直接用旧的 admin 邮箱密码获取 token，然后 push template
bash scripts/manage.sh push-template
```
（因为用户已经在 DB 里了，不需要再创建。）

---

## 9. 命令速查表

| 步骤 | Linux | Windows |
|------|-------|---------|
| 拍快照 | `manage.sh upgrade-backup` | `manage.ps1 upgrade-backup` |
| 还原配置 | `manage.sh upgrade-restore-config <dir>` | `manage.ps1 upgrade-restore-config <dir>` |
| 停止平台 | `manage.sh down` | `manage.ps1 down` |
| 加载镜像 | `manage.sh load [--ldap …]` | `manage.ps1 load [-Ldap …]` |
| 启动平台 | `manage.sh up [--ldap …]` | `manage.ps1 up [-Ldap …]` |
| 构建新 workspace 镜像 | `manage.sh update-workspace --tag v20260427` | `manage.ps1 update-workspace -Tag v20260427` |
