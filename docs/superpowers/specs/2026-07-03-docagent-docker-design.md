# DocAgent Docker 镜像设计

- 日期：2026-07-03
- 项目：DocAgent (`/Users/alwaysking/AKProject/DocAgent`)
- GitHub 仓库：`git@github.com:AlwaysKing/dockeragent.git`
- 镜像名：`dockeragent`（与仓库名一致）
- 目标：通过 GitHub Actions 自动构建 Docker 镜像，封装 cc-connect + Claude Code，部署时只需挂载一个配置目录即可启动

## 1. 目标与非目标

### 目标
- push 到 main 分支自动构建并推送到 GHCR
- 镜像内已预装 Claude Code 与 cc-connect，无需用户再装
- 部署时只需 `-v host_dir:/app/config` 挂载三个配置文件即可启动
- 项目工作目录 `/app/data` 内置示例内容，用户也可挂载覆盖

### 非目标
- 不支持多架构（仅 amd64）
- 不做版本号 tag（只用 `:latest` 与 `:<short-sha>`）
- 不推 Docker Hub

## 2. 镜像结构

基础镜像：`debian:12-slim`

预装工具：`git ripgrep curl ca-certificates procps bash sudo python3 python3-yaml`（python3 用于 entrypoint 解析 YAML；ripgrep/git 给 Claude Code 调用）。

二进制安装：
- **Claude Code**：`curl -fsSL https://claude.ai/install.sh | bash`（原生二进制，不需要 Node.js）
- **cc-connect**：从 `https://github.com/chenhg5/cc-connect/releases/latest/download/` 下载 linux-amd64 二进制到 `/usr/local/bin/cc-connect` 并赋予执行权限

镜像内目录布局：
```
/usr/local/bin/
├── cc-connect
└── claude                 # install.sh 默认放到 ~/.local/bin，构建时统一复制或软链到 /usr/local/bin

/app/
├── entrypoint.sh          # 启动脚本（chmod +x）
├── config/                # 内置示例，用户可挂载覆盖
│   ├── config.yaml        # USER/GROUP 定义（可选）
│   ├── cc-connect.toml    # 完整 cc-connect 配置（含 platforms）
│   └── claude.json        # Claude Code 用户级 settings.json
└── data/                  # 项目工作目录（work_dir = /app/data）
    ├── .claude/CLAUDE.md  # 项目级 CLAUDE.md 示例
    ├── docs/.gitkeep
    └── cache/.gitkeep
```

## 3. 配置文件约定

### `/app/config/config.yaml`（可选）
```yaml
USER:
    ID: 2000
    NAME: Server
GROUP:
    ID: 2000
    NAME: Server
```
缺失时使用默认 `root:root`。

### `/app/config/cc-connect.toml`（必需）
完整 cc-connect 配置。关键段落：
- `[projects.agent.options]` 中 `work_dir = "/app/data"`
- `[[projects.platforms]]` 中 `bot_id` / `bot_secret` 启动前会被检查非空

### `/app/config/claude.json`（必需）
Claude Code 用户级 settings.json，含 `env` 段：
```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "",
    "ANTHROPIC_BASE_URL": "",
    "ANTHROPIC_MODEL": "",
    "ANTHROPIC_REASONING_MODEL": ""
  }
}
```

## 4. entrypoint.sh 启动流程

1. **完整性检查**
   - `/app/config/cc-connect.toml` 不存在 → 报错退出
   - `/app/config/claude.json` 不存在 → 报错退出
   - `/app/config/config.yaml` 不存在 → 使用默认 root:root

2. **解析用户/组**
   - 若 config.yaml 存在，用 python3 解析出 `USER.NAME/ID, GROUP.NAME/ID`
   - 否则 `USER_NAME=root, USER_ID=0, GROUP_NAME=root, GROUP_ID=0`

3. **创建用户/组**（仅非 root 时）
   - `groupadd -g <GID> <GROUP_NAME>`（若已存在则跳过）
   - `useradd -u <UID> -g <GID> -m -d /home/<USER_NAME> -s /bin/bash <USER_NAME>`（若已存在则跳过）
   - `USER_HOME=/home/<USER_NAME>`（root 时为 `/root`）

4. **创建软连接**

   > ⚠️ **关键坑**：此时脚本仍以 root 身份执行，**绝对不能使用 `~` 或 `$HOME`**，因为它们会展开为 `/root`。必须用第 3 步显式定义的 `$USER_HOME` 变量（解析自 config.yaml 的目标用户家目录）。

   - `mkdir -p "$USER_HOME/.cc-connect"`
   - `ln -sf /app/config/cc-connect.toml "$USER_HOME/.cc-connect/config.toml"`
   - `mkdir -p "$USER_HOME/.claude"`
   - `ln -sf /app/config/claude.json "$USER_HOME/.claude/settings.json"`
   - `chown -h <USER>:<GROUP> "$USER_HOME/.cc-connect" "$USER_HOME/.cc-connect/config.toml" "$USER_HOME/.claude" "$USER_HOME/.claude/settings.json"`（root 时跳过 chown）
   - `chown -R <USER>:<GROUP> /app/config /app/data`（root 时跳过 chown）
   - 软链目标 `/app/config/*` 必须保证目标用户可读（`/app/config` 整体 chown 给目标用户，或保证最小 `o+r` 权限）

5. **配置完整性检查**
   - 在 cc-connect.toml 中找到 `[[projects.platforms]]` 块的 `bot_id` 和 `bot_secret`，若为空字符串或缺失 → 报错退出
   - 实现用 grep/python 简单解析

6. **切换并启动**
   - root：`exec cc-connect`
   - 非 root：`exec su - "$USER_NAME" -c "cc-connect"`

## 5. GitHub Actions Workflow

文件：`.github/workflows/docker.yml`

触发：`push` 到 `main` 分支，以及 `workflow_dispatch` 手动触发。

作业：
- 检出代码
- `docker/login-action` 登录 GHCR（用内置 `GITHUB_TOKEN`，权限 `packages: write`）
- `docker/build-push-action@v5` 构建并推送，tag 列表：
  - `ghcr.io/alwaysking/dockeragent:latest`
  - `ghcr.io/alwaysking/dockeragent:<short_sha>`
- 单架构 linux/amd64

镜像通过 `image: ghcr.io/<owner>/docagent:latest` 拉取。

## 6. 示例 data/ 内容

`data/.claude/CLAUDE.md` 改写为通用模板（去掉 DLPPlus 特定内容），保留结构：
- 项目名称、工作目录、文档目录占位符
- docs/ 目录结构说明（与原版相同，通用）
- 文件操作规则示例
- 用户填空提示

`data/docs/` 和 `data/cache/` 用 `.gitkeep` 占位保留空目录。

## 7. 文件清单（要新增/修改）

新增：
- `Dockerfile`
- `.github/workflows/docker.yml`
- `.dockerignore`

修改：
- `entrypoint.sh`（按本文档第 4 节重写）
- `config/cc-connect.toml`（保留现状作为示例，仅补充注释说明 work_dir 和 platforms 的位置）
- `config/claude.json`（保留现状作为示例）
- `config/config.yaml`（保留现状）
- `data/.claude/CLAUDE.md`（改写为通用模板）

## 8. 部署示例

```bash
# 准备配置目录
mkdir -p ~/docagent/config
cat > ~/docagent/config/cc-connect.toml <<EOF
[[projects.platforms]]
type = "feishu"
[projects.platforms.options]
mode = "..."
bot_id = "cli_xxx"
bot_secret = "xxx"
allow_from = "*"
EOF
# ... claude.json, config.yaml 同理

# 准备数据目录（可选，不挂载则用镜像内置示例）
mkdir -p ~/docagent/data

# 运行
docker run -d \
  -v ~/docagent/config:/app/config \
  -v ~/docagent/data:/app/data \
  ghcr.io/alwaysking/dockeragent:latest
```

## 9. 风险与权衡

- **Claude Code 二进制兼容性**：官方原生二进制针对 glibc 编译，debian:12-slim 是 glibc 环境，兼容良好。不选 alpine 即为此。
- **GHCR 镜像可见性**：默认继承仓库可见性。若仓库 public 则镜像 public，无需额外配置。
- **配置完整性检查的局限**：bot_id/bot_secret 仅检查非空，不验证有效性。用户填错仍需运行时排查。
- **不挂载 /app/config 启动会失败**：这是设计意图（强制用户提供配置）。镜像内置示例仅作为演示，被空挂载覆盖时会触发完整性检查失败。
