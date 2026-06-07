# VS Code 扩展离线安装说明

将 `.vsix` 文件放置到此目录，`manage.sh build` 构建镜像时会自动安装到扩展种子目录。

## 推荐下载的扩展

### anthropic.claude-code（Claude Code 官方扩展）

1. **从 VS Code Marketplace 下载**（在联网机器上）：
   ```bash
   # 方法 1: 使用 code CLI
   code --install-extension anthropic.claude-code
   # 找到安装位置，复制 .vsix 文件

   # 方法 2: 直接从 Marketplace 下载页面
   # https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code
   # 点击 "Download Extension" 按钮
   ```

2. **从已安装的 VS Code 中提取**：
   ```bash
   ls ~/.vscode/extensions/anthropic.claude-code-*/
   # 将整个目录打包为 .vsix
   ```

### openai.chatgpt（OpenAI Codex / ChatGPT 官方扩展）

该扩展通常来自 VS Code Marketplace。code-server 默认使用 Open VSX；如果构建时无法直接安装，请在联网机器下载 `.vsix` 后放入本目录。

- Marketplace: https://marketplace.visualstudio.com/items?itemName=OpenAI.chatgpt
- 建议文件名：`openai.chatgpt-<version>.vsix`

### kilocode.kilo-code（Kilo Code）

Kilo Code 可从 Open VSX 或 VS Code Marketplace 获取。联网构建会尝试通过 `kilocode.kilo-code` 自动安装；离线构建时可把 `.vsix` 放入本目录作为兜底。

- Open VSX: https://open-vsx.org/extension/kilocode/kilo-code
- Marketplace: https://marketplace.visualstudio.com/items?itemName=kilocode.kilo-code
- 建议文件名：`kilocode.kilo-code-<version>.vsix`

### ms-vscode.cpptools（Microsoft C/C++ 扩展）

该扩展不在 Open VSX 上，需要从 Marketplace 手动下载：
- https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools

## 文件命名约定

`.vsix` 文件名格式通常为：`<publisher>.<name>-<version>.vsix`

例如：
- `anthropic.claude-code-1.2.3.vsix`
- `openai.chatgpt-1.2.3.vsix`
- `kilocode.kilo-code-1.2.3.vsix`
- `ms-vscode.cpptools-1.22.11.vsix`

## 自动安装

构建镜像时，`Dockerfile.workspace` 中的以下代码会自动安装所有 `.vsix` 文件：

```dockerfile
COPY configs/vsix/ /tmp/vsix/
RUN if ls /tmp/vsix/*.vsix 1>/dev/null 2>&1; then \
        for vsix in /tmp/vsix/*.vsix; do \
            code-server --extensions-dir ${CODE_SERVER_EXTENSIONS_SEED} \
                --install-extension "$vsix"; \
        done; \
    fi
```
