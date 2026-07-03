# DocAgent Docker 镜像实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 GitHub Actions 自动构建一个封装 cc-connect + Claude Code 的 Docker 镜像，部署时只需挂载 `/app/config` 即可启动。

**Architecture:** 基于 `debian:12-slim`，构建期下载 cc-connect 预编译二进制并通过官方 install.sh 安装 Claude Code 原生二进制；运行期 entrypoint.sh 做完整性检查、按 config.yaml 创建非 root 用户、软链配置文件到用户家目录、切用户后 exec cc-connect。GitHub Actions 在 push 到 main 时构建并推送 GHCR。

**Tech Stack:** Docker、Bash、GitHub Actions、Python3（YAML 解析）、cc-connect v1.4.x、Claude Code 原生二进制。

**Spec:** `docs/superpowers/specs/2026-07-03-docagent-docker-design.md`

**GitHub 仓库（待初始化）:** `git@github.com:AlwaysKing/dockeragent.git`

---

## 文件结构

新增：
- `Dockerfile` — 镜像构建定义
- `.dockerignore` — 构建上下文裁剪
- `.github/workflows/docker.yml` — GHCR 推送工作流
- `data/docs/.gitkeep` — 保留空目录
- `data/cache/.gitkeep` — 保留空目录
- `README.md` — 部署说明（简单版）

修改：
- `entrypoint.sh` — 按新设计重写（完整性检查 + 软链 + 用户切换）
- `config/cc-connect.toml` — 加注释说明各段
- `data/.claude/CLAUDE.md` — 改写为通用模板

不动：
- `config/claude.json` — 现状即可作为示例
- `config/config.yaml` — 现状即可作为示例

---

## Task 1：初始化 git 仓库并整理目录

**Files:**
- 创建：`/Users/alwaysking/AKProject/DocAgent/.gitignore`

- [ ] **Step 1: 删除 macOS 残留的 .DS_Store**

```bash
find /Users/alwaysking/AKProject/DocAgent -name ".DS_Store" -delete
```

- [ ] **Step 2: 创建 .gitignore**

写入 `/Users/alwaysking/AKProject/DocAgent/.gitignore`：

```gitignore
# macOS
.DS_Store

# 用户运行时数据（挂载覆盖时使用，不入库）
/data/**
!/data/.claude/
!/data/.claude/CLAUDE.md
!/data/docs/
!/data/docs/.gitkeep
!/data/cache/
!/data/cache/.gitkeep

# 本地 Claude 设置
/.claude/settings.local.json

# 设计与计划文档保留入库
!docs/
```

- [ ] **Step 3: 初始化仓库并首次提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git init -b main
git remote add origin git@github.com:AlwaysKing/dockeragent.git
git add .
git status   # 检查不会带入 .DS_Store
```

确认 status 后：
```bash
git commit -m "chore: initial commit with project structure and design docs"
```

> ⚠️ 暂不 push，等 Task 7 全部完成再 push 触发 Actions。

---

## Task 2：重写 entrypoint.sh

**Files:**
- 修改：`/Users/alwaysking/AKProject/DocAgent/entrypoint.sh`

- [ ] **Step 1: 完整重写 entrypoint.sh**

写入 `/Users/alwaysking/AKProject/DocAgent/entrypoint.sh`：

```bash
#!/bin/bash
set -e

# ============== 路径常量 ==============
CONFIG_DIR="/app/config"
CC_CONNECT_TOML="$CONFIG_DIR/cc-connect.toml"
CLAUDE_JSON="$CONFIG_DIR/claude.json"
CONFIG_YAML="$CONFIG_DIR/config.yaml"

# ============== 1. 完整性检查 ==============
echo "[1/5] 完整性检查..."

if [ ! -f "$CC_CONNECT_TOML" ]; then
    echo "错误: 缺少必需配置文件 $CC_CONNECT_TOML" >&2
    echo "请将宿主机配置目录挂载到 /app/config，并保证包含 cc-connect.toml" >&2
    exit 1
fi

if [ ! -f "$CLAUDE_JSON" ]; then
    echo "错误: 缺少必需配置文件 $CLAUDE_JSON" >&2
    echo "请将宿主机配置目录挂载到 /app/config，并保证包含 claude.json" >&2
    exit 1
fi

echo "  cc-connect.toml: OK"
echo "  claude.json:     OK"

# ============== 2. 解析用户/组 ==============
echo "[2/5] 解析用户/组..."

if [ -f "$CONFIG_YAML" ]; then
    CONFIG_DATA=$(python3 -c "
import yaml, sys
try:
    with open('$CONFIG_YAML') as f:
        c = yaml.safe_load(f)
    uname = (c.get('USER') or {}).get('NAME', 'root')
    uid   = (c.get('USER') or {}).get('ID', 0)
    gname = (c.get('GROUP') or {}).get('NAME', 'root')
    gid   = (c.get('GROUP') or {}).get('ID', 0)
    print(f'{uname}|{uid}|{gname}|{gid}')
except Exception as e:
    print(f'ERROR|{e}', file=sys.stderr); sys.exit(1)
") || { echo "错误: 解析 config.yaml 失败" >&2; exit 1; }

    USER_NAME=$(echo "$CONFIG_DATA" | cut -d'|' -f1)
    USER_ID=$(echo "$CONFIG_DATA" | cut -d'|' -f2)
    GROUP_NAME=$(echo "$CONFIG_DATA" | cut -d'|' -f3)
    GROUP_ID=$(echo "$CONFIG_DATA" | cut -d'|' -f4)
else
    echo "  config.yaml 不存在，使用默认 root:root"
    USER_NAME="root"; USER_ID=0
    GROUP_NAME="root"; GROUP_ID=0
fi

echo "  用户: $USER_NAME (UID=$USER_ID)  组: $GROUP_NAME (GID=$GROUP_ID)"

# ============== 3. 创建用户/组 ==============
echo "[3/5] 创建用户/组..."

IS_ROOT=0
if [ "$USER_ID" = "0" ]; then
    IS_ROOT=1
    USER_HOME="/root"
    echo "  以 root 运行，跳过用户创建"
else
    USER_HOME="/home/$USER_NAME"

    if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
        groupadd -g "$GROUP_ID" "$GROUP_NAME"
        echo "  创建组: $GROUP_NAME (GID=$GROUP_ID)"
    fi

    if ! getent passwd "$USER_NAME" >/dev/null 2>&1; then
        useradd -u "$USER_ID" -g "$GROUP_ID" -m -d "$USER_HOME" -s /bin/bash "$USER_NAME"
        echo "  创建用户: $USER_NAME (UID=$USER_ID)"
    fi

    # 免密 sudo（运维便利）
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"
    chmod 440 "/etc/sudoers.d/$USER_NAME"
fi

# ============== 4. 创建软连接 ==============
echo "[4/5] 创建软连接..."

# ⚠️ 此时仍是 root 身份，禁用 ~ 与 $HOME，统一用 $USER_HOME
mkdir -p "$USER_HOME/.cc-connect"
mkdir -p "$USER_HOME/.claude"

# 清理可能存在的旧软链/文件
rm -f "$USER_HOME/.cc-connect/config.toml"
rm -f "$USER_HOME/.claude/settings.json"

ln -sf "$CC_CONNECT_TOML" "$USER_HOME/.cc-connect/config.toml"
ln -sf "$CLAUDE_JSON"     "$USER_HOME/.claude/settings.json"

echo "  $USER_HOME/.cc-connect/config.toml -> $CC_CONNECT_TOML"
echo "  $USER_HOME/.claude/settings.json   -> $CLAUDE_JSON"

# 权限：非 root 时把目录、软链、挂载点都 chown 给目标用户
if [ "$IS_ROOT" = "0" ]; then
    chown -h "$USER_NAME":"$GROUP_NAME" \
        "$USER_HOME/.cc-connect" "$USER_HOME/.cc-connect/config.toml" \
        "$USER_HOME/.claude"     "$USER_HOME/.claude/settings.json"
    chown -R "$USER_NAME":"$GROUP_NAME" "$USER_HOME/.cc-connect" "$USER_HOME/.claude"
    chown -R "$USER_NAME":"$GROUP_NAME" /app/config /app/data 2>/dev/null || true
fi

# ============== 5. cc-connect 配置完整性检查 ==============
echo "[5/5] cc-connect platforms 检查..."

python3 - <<'PY' || exit 1
import re, sys
text = open('/app/config/cc-connect.toml').read()

# 提取 [[projects.platforms]] 块（粗略匹配到下一个 [[ 或 [ 段或文件末尾）
m = re.search(r'\[\[projects\.platforms\]\]\s*(.*?)(?=\n\[\[|\n\[|\Z)', text, re.S)
if not m:
    print("错误: cc-connect.toml 中未找到 [[projects.platforms]] 段", file=sys.stderr)
    sys.exit(1)

block = m.group(1)
for key in ('bot_id', 'bot_secret'):
    km = re.search(rf'^\s*{key}\s*=\s*"([^"]*)"', block, re.M)
    if not km or not km.group(1).strip():
        print(f"错误: cc-connect.toml 中 platforms.{key} 为空或缺失", file=sys.stderr)
        sys.exit(1)
    print(f"  platforms.{key}: OK")
PY

echo ""
echo "==================== 启动 cc-connect ===================="
if [ "$IS_ROOT" = "1" ]; then
    exec cc-connect
else
    exec su - "$USER_NAME" -c "cc-connect"
fi
```

- [ ] **Step 2: 加可执行权限**

```bash
chmod +x /Users/alwaysking/AKProject/DocAgent/entrypoint.sh
```

- [ ] **Step 3: 用 bash -n 语法检查**

```bash
bash -n /Users/alwaysking/AKProject/DocAgent/entrypoint.sh && echo "syntax OK"
```

预期输出：`syntax OK`

- [ ] **Step 4: 提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git add entrypoint.sh
git commit -m "feat: rewrite entrypoint.sh with integrity check, user creation and symlinks"
```

---

## Task 3：完善 config/ 示例文件注释

**Files:**
- 修改：`/Users/alwaysking/AKProject/DocAgent/config/cc-connect.toml`
- 修改：`/Users/alwaysking/AKProject/DocAgent/config/claude.json`
- 修改：`/Users/alwaysking/AKProject/DocAgent/config/config.yaml`

- [ ] **Step 1: 重写 cc-connect.toml 加注释**

写入：

```toml
# cc-connect 配置示例
# 完整模板见 https://github.com/chenhg5/cc-connect/blob/main/config.example.toml

language = "zh"

[display]
mode = "quiet"

[[projects]]
name = "dockeragent"
show_context_indicator = false
reply_footer = false
quiet = true

[projects.display]
mode = "quiet"

[projects.agent]
type = "claudecode"

[projects.agent.options]
# 项目工作目录（容器内路径）
work_dir = "/app/data"
mode = "yolo"

# ====== 以下 platforms 段必填，bot_id / bot_secret 不能为空 ======
[[projects.platforms]]
type = ""        # 平台类型：feishu / dingtalk / slack / telegram / discord / line ...

[projects.platforms.options]
mode = ""        # 平台模式
bot_id = ""      # 平台 Bot ID（必填）
bot_secret = ""  # 平台 Bot Secret（必填）
allow_from = "*"
```

- [ ] **Step 2: claude.json 加注释说明（JSON 不支持注释，用文件名 README 代替）**

写入 `/Users/alwaysking/AKProject/DocAgent/config/claude.README.md`：

```markdown
# claude.json 说明

此文件作为 Claude Code 用户级 settings.json 的示例，运行时会被软链到 `~/.claude/settings.json`。

字段说明：
- `env.ANTHROPIC_AUTH_TOKEN`: Claude API Token（必填）
- `env.ANTHROPIC_BASE_URL`: 自定义 API 端点（可选，用于中转）
- `env.ANTHROPIC_MODEL`: 默认模型名（可选）
- `env.ANTHROPIC_REASONING_MODEL`: 推理模型名（可选）

完整字段参考：https://code.claude.com/docs/en/settings
```

- [ ] **Step 3: config.yaml 加注释**

写入 `/Users/alwaysking/AKProject/DocAgent/config/config.yaml`：

```yaml
# 容器运行用户/组定义
# 缺失或省略时默认使用 root:root
USER:
    ID: 2000
    NAME: Server
GROUP:
    ID: 2000
    NAME: Server
```

- [ ] **Step 4: 提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git add config/
git commit -m "docs: add comments to example config files"
```

---

## Task 4：改写 data/.claude/CLAUDE.md 为通用模板

**Files:**
- 修改：`/Users/alwaysking/AKProject/DocAgent/data/.claude/CLAUDE.md`
- 新增：`/Users/alwaysking/AKProject/DocAgent/data/docs/.gitkeep`
- 新增：`/Users/alwaysking/AKProject/DocAgent/data/cache/.gitkeep`

- [ ] **Step 1: 重写 CLAUDE.md 为通用模板**

写入 `/Users/alwaysking/AKProject/DocAgent/data/.claude/CLAUDE.md`：

```markdown
---
name: project-info
description: 项目约定与注意事项
metadata:
  type: project
---

## 项目信息
- **项目名称**: <请填写>
- **工作目录**: /app/data
- **文档目录**: /app/data/docs

## 身份设定

<请填写：你希望 Claude 扮演什么角色，回答风格如何。>

## 核心原则

- 回答必须基于事实，不要编造信息。不确定时先查阅文档或上网搜索，再给出回答。

## 文件操作规则

### docs/ 目录（共享知识库）

- `docs/` 是与其他项目共用的知识库文档，**未经明确要求，禁止修改其中的任何文件**。
- 唯一例外是 `docs/问题处理/` 目录，你应主动维护该目录的内容。

### docs/问题处理/ 目录（运维知识维护）

- 当用户要求记录某个问题及处置方案时，在 `docs/问题处理/` 下维护文档。
- 大部分情况是新建文档，也包括对已有内容的更新。
- 文档应结构清晰，包含：问题描述、环境信息、原因分析、解决步骤、注意事项等。
- 若解决方案涉及策略的修改，必须将相关策略的当前详情、修改依据、具体修改步骤（含命令、控制台路径、API 参数等）以及修改后的预期结果写入文档。
- 编辑完文档之后要检查文档的用户和用户组，确保其与容器 USER:GROUP 一致。

### cache/ 目录（加速笔记）

- 可以在项目 `cache/` 目录下自行维护笔记文档，用于加速常见问题的响应。
- 笔记应简洁实用，便于快速检索。

## docs/ 目录结构说明

`docs/` 目录采用 **md 文件 + 同名子目录** 的嵌套组织方式：

    docs/
    ├── public/                  # 顶层索引文档引用的资源
    │   └── {uuid}/              # UUID 命名文件夹，防止文件名冲突
    │       └── image.png        # 实际资源文件（图片等）
    ├── 某主题.md                 # 文档主体
    └── 某主题/                   # 与 md 同名的目录，存放子文档
        ├── public/
        │   └── {uuid}/
        │       └── screenshot.png
        └── 子主题.md

### 结构规则

- **md 文件**：即文档本身，一个 md 文件就是一个知识条目。
- **同名目录**：如果某个 md 文档存在子内容，会在同目录下有一个去掉 `.md` 后缀的同名文件夹。
- **public 目录**：每个 md 文档或同名目录旁边都可能存在 `public/`，存放该文档引用的资源文件。
- **UUID 文件夹**：`public/` 下的资源以 UUID 命名文件夹隔离，避免文件名冲突。

### 注意事项

- 浏览文档时只关注 `.md` 文件，`public/` 目录无需主动查看。
- 不要修改任何 `public/` 目录下的内容。
```

- [ ] **Step 2: 创建占位 .gitkeep**

```bash
touch /Users/alwaysking/AKProject/DocAgent/data/docs/.gitkeep
touch /Users/alwaysking/AKProject/DocAgent/data/cache/.gitkeep
```

- [ ] **Step 3: 删除现有 cache/运维笔记（如不需要）**

```bash
ls /Users/alwaysking/AKProject/DocAgent/data/cache/
```

如果有用户具体内容，确认后删除（这版是 example）：
```bash
rm -f /Users/alwaysking/AKProject/DocAgent/data/cache/运维笔记
```

- [ ] **Step 4: 提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git add data/
git commit -m "docs: rewrite CLAUDE.md as generic template, add .gitkeep placeholders"
```

---

## Task 5：编写 Dockerfile

**Files:**
- 新增：`/Users/alwaysking/AKProject/DocAgent/Dockerfile`
- 新增：`/Users/alwaysking/AKProject/DocAgent/.dockerignore`

- [ ] **Step 1: 写 Dockerfile**

写入 `/Users/alwaysking/AKProject/DocAgent/Dockerfile`：

```dockerfile
FROM debian:12-slim

# 基础工具：Claude Code 调用需要 git/ripgrep 等；python3-yaml 给 entrypoint 解析 YAML
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        ripgrep \
        bash \
        sudo \
        procps \
        python3 \
        python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# 安装 Claude Code 原生二进制（不需要 Node.js）
# install.sh 默认装到 $HOME/.local/bin/claude，构建期 HOME=/root
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp /root/.local/bin/claude /usr/local/bin/claude \
    && chmod +x /usr/local/bin/claude \
    && rm -rf /root/.local/bin/claude

# 安装 cc-connect 预编译二进制
# 用变量便于版本升级；此处用 latest，由 SHA 自动决定
ARG CC_CONNECT_VERSION=latest
RUN set -eux; \
    if [ "$CC_CONNECT_VERSION" = "latest" ]; then \
        URL=$(curl -fsSL https://api.github.com/repos/chenhg5/cc-connect/releases/latest \
              | grep -oE 'https://[^"]*linux-amd64[^"]*' | head -1); \
    else \
        URL="https://github.com/chenhg5/cc-connect/releases/download/${CC_CONNECT_VERSION}/cc-connect-linux-amd64"; \
    fi; \
    echo "Downloading: $URL"; \
    curl -fsSL -o /usr/local/bin/cc-connect "$URL"; \
    chmod +x /usr/local/bin/cc-connect; \
    cc-connect --version || true

# 应用目录结构
WORKDIR /app

# 拷贝示例配置（用户挂载 /app/config 时会被覆盖）
COPY config/        /app/config/
COPY entrypoint.sh  /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 项目数据目录（work_dir）；内置示例，用户可挂载覆盖
COPY data/          /app/data/

# 验证二进制就位
RUN which cc-connect && which claude && which python3 && which git && which rg

ENTRYPOINT ["/app/entrypoint.sh"]
```

- [ ] **Step 2: 写 .dockerignore**

写入 `/Users/alwaysking/AKProject/DocAgent/.dockerignore`：

```
.git
.github
docs/
*.md
!data/.claude/CLAUDE.md
.DS_Store
.gitignore
.dockerignore
.claude/
```

- [ ] **Step 3: 本地构建验证**

```bash
cd /Users/alwaysking/AKProject/DocAgent
docker build -t dockeragent:local .
```

预期：构建成功，最后一行 `Step X/Y : RUN which cc-connect && ...` 输出三个路径。

如果网络问题导致 Claude install.sh 或 GitHub Releases 拉取失败，重试 1-2 次；若持续失败需排查镜像源。

- [ ] **Step 4: 镜像内二进制验证**

```bash
docker run --rm --entrypoint /bin/bash dockeragent:local -c '
  echo "cc-connect: $(which cc-connect)";
  echo "claude:     $(which claude)";
  echo "python3:    $(which python3)";
  echo "git:        $(which git)";
  echo "rg:         $(which rg)";
  ls -la /app/
'
```

预期：所有命令都有路径输出，`/app/` 下有 `config/`、`data/`、`entrypoint.sh`。

- [ ] **Step 5: 提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git add Dockerfile .dockerignore
git commit -m "feat: add Dockerfile based on debian:12-slim with cc-connect and claude code"
```

---

## Task 6：本地端到端冒烟测试

**Files:** （无新增/修改，仅运行测试）

- [ ] **Step 1: 准备临时配置目录**

```bash
mkdir -p /tmp/docagent-test/config
mkdir -p /tmp/docagent-test/data

cp /Users/alwaysking/AKProject/DocAgent/config/cc-connect.toml /tmp/docagent-test/config/
cp /Users/alwaysking/AKProject/DocAgent/config/claude.json     /tmp/docagent-test/config/
cp /Users/alwaysking/AKProject/DocAgent/config/config.yaml     /tmp/docagent-test/config/
```

- [ ] **Step 2: 测试 1：缺少 cc-connect.toml 应报错退出**

```bash
mkdir -p /tmp/docagent-empty
docker run --rm -v /tmp/docagent-empty:/app/config dockeragent:local
echo "exit=$?"
```

预期：容器输出 `错误: 缺少必需配置文件 /app/config/cc-connect.toml`，退出码非 0。

- [ ] **Step 3: 测试 2：bot_id 为空应报错退出**

先用默认 cc-connect.toml（bot_id 是空串）跑：
```bash
docker run --rm -v /tmp/docagent-test/config:/app/config dockeragent:local
echo "exit=$?"
```

预期：进入第 5 步检查后输出 `错误: cc-connect.toml 中 platforms.bot_id 为空或缺失`，退出码非 0。

- [ ] **Step 4: 测试 3：填上 bot_id/bot_secret，验证用户创建和软链**

```bash
# 改配置
sed -i.bak 's/^bot_id = ""/bot_id = "test_id"/'     /tmp/docagent-test/config/cc-connect.toml
sed -i.bak 's/^bot_secret = ""/bot_secret = "test_s"/' /tmp/docagent-test/config/cc-connect.toml

# 跑起来，但 cc-connect 会因为 bot 无效而失败 —— 我们只验证前面的逻辑
docker run --rm -v /tmp/docagent-test/config:/app/config dockeragent:local 2>&1 | head -40
```

预期前 40 行能看到：
- `[1/5]` `[2/5]` `[3/5]` `[4/5]` `[5/5]` 全部跑过
- `创建用户: Server (UID=2000)`
- `Server@...:~/.cc-connect/config.toml -> /app/config/cc-connect.toml`
- `Server@...:~/.claude/settings.json   -> /app/config/claude.json`
- `platforms.bot_id: OK` / `platforms.bot_secret: OK`
- 之后 cc-connect 因为 token 无效报错是正常的

- [ ] **Step 5: 测试 4：用 root 用户（删除 config.yaml）验证默认路径**

```bash
rm /tmp/docagent-test/config/config.yaml
docker run --rm -v /tmp/docagent-test/config:/app/config dockeragent:local 2>&1 | head -20
```

预期：看到 `config.yaml 不存在，使用默认 root:root`、`以 root 运行，跳过用户创建`、`USER_HOME=/root`。

恢复：
```bash
cp /Users/alwaysking/AKProject/DocAgent/config/config.yaml /tmp/docagent-test/config/
```

- [ ] **Step 6: 测试 5：用真实容器命令直接验证软链**

```bash
docker run --rm \
  -v /tmp/docagent-test/config:/app/config \
  --entrypoint /bin/bash \
  dockeragent:local \
  -c '/app/entrypoint.sh 2>&1 || true; echo "---"; ls -la /home/Server/.cc-connect/ /home/Server/.claude/'
```

预期看到：
```
lrwxrwxrwx ... config.toml -> /app/config/cc-connect.toml
lrwxrwxrwx ... settings.json -> /app/config/claude.json
```
且 owner 是 `Server Server`。

- [ ] **Step 7: 清理临时文件**

```bash
rm -rf /tmp/docagent-test /tmp/docagent-empty
```

---

## Task 7：编写 GitHub Actions workflow

**Files:**
- 新增：`/Users/alwaysking/AKProject/DocAgent/.github/workflows/docker.yml`

- [ ] **Step 1: 写 workflow**

写入 `/Users/alwaysking/AKProject/DocAgent/.github/workflows/docker.yml`：

```yaml
name: Build and Push Docker Image

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  IMAGE_NAME: dockeragent

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute short SHA
        id: sha
        run: echo "short=$(echo -n ${GITHUB_SHA::7})" >> $GITHUB_OUTPUT

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          platforms: linux/amd64
          push: true
          tags: |
            ghcr.io/alwaysking/dockeragent:latest
            ghcr.io/alwaysking/dockeragent:${{ steps.sha.outputs.short }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: 提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git add .github/
git commit -m "ci: add GitHub Actions workflow to build and push image to GHCR"
```

---

## Task 8：编写 README 部署说明

**Files:**
- 新增：`/Users/alwaysking/AKProject/DocAgent/README.md`

- [ ] **Step 1: 写 README**

写入 `/Users/alwaysking/AKProject/DocAgent/README.md`：

```markdown
# dockeragent

封装 [cc-connect](https://github.com/chenhg5/cc-connect) + Claude Code 的 Docker 镜像，部署时只需挂载配置目录即可启动。

## 镜像

```
ghcr.io/alwaysking/dockeragent:latest
```

## 快速开始

### 1. 准备配置目录

```
my-config/
├── cc-connect.toml    # 必需
├── claude.json        # 必需
└── config.yaml        # 可选（缺省则用 root 运行）
```

参考 `config/` 下的示例文件。`cc-connect.toml` 的 `[[projects.platforms]]` 段 `bot_id` / `bot_secret` 必填。

### 2. 运行

```bash
docker run -d \
  --name docagent \
  -v $(pwd)/my-config:/app/config \
  -v $(pwd)/my-data:/app/data \
  ghcr.io/alwaysking/dockeragent:latest
```

## 目录约定

| 容器路径 | 用途 | 是否必需 |
|---|---|---|
| `/app/config/cc-connect.toml` | cc-connect 完整配置 | ✅ |
| `/app/config/claude.json` | Claude Code settings.json | ✅ |
| `/app/config/config.yaml` | 用户/组定义 | 可选 |
| `/app/data` | 项目工作目录（work_dir） | 可选（不带则用镜像内置示例） |

## 启动流程

1. 完整性检查（必需文件存在性）
2. 解析 `config.yaml` 创建用户/组（无则 root）
3. 软链 `/app/config/cc-connect.toml` → `~/.cc-connect/config.toml`、`/app/config/claude.json` → `~/.claude/settings.json`
4. 校验 `bot_id` / `bot_secret` 非空
5. 切用户后 `exec cc-connect`

## CI

push 到 `main` 分支自动构建并推送：
- `ghcr.io/alwaysking/dockeragent:latest`
- `ghcr.io/alwaysking/dockeragent:<short-sha>`

详见 `.github/workflows/docker.yml`。
```

- [ ] **Step 2: 提交**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git add README.md
git commit -m "docs: add README with deployment guide"
```

---

## Task 9：最终验证与推送

- [ ] **Step 1: 本地最终构建**

```bash
cd /Users/alwaysking/AKProject/DocAgent
docker build -t dockeragent:final .
docker run --rm --entrypoint /bin/bash dockeragent:final -c 'ls -la /app && which cc-connect claude'
```

- [ ] **Step 2: 复查 git log**

```bash
git log --oneline
```

预期看到 8 个 commit（init / entrypoint / configs / CLAUDE.md / Dockerfile / workflow / README，加上可能的合并）。

- [ ] **Step 3: 确认 .DS_Store 等没入库**

```bash
git ls-files | grep -E '\.DS_Store|settings.local' || echo "clean"
```

预期输出 `clean`。

- [ ] **Step 4: 推送到 GitHub（首次推送，会触发 Actions 构建）**

```bash
cd /Users/alwaysking/AKProject/DocAgent
git push -u origin main
```

- [ ] **Step 5: 监控 Actions**

```bash
gh run list --repo AlwaysKing/dockeragent --limit 3
gh run watch --repo AlwaysKing/dockeragent <run-id>
```

或在浏览器打开 `https://github.com/AlwaysKing/dockeragent/actions`。

预期：构建并推送成功。

- [ ] **Step 6: 验证 GHCR 镜像可拉取**

```bash
docker pull ghcr.io/alwaysking/dockeragent:latest
docker image inspect ghcr.io/alwaysking/dockeragent:latest | head -20
```

---

## 验收标准

- [ ] push 到 main 自动触发 Actions 并成功
- [ ] GHCR 中能 pull 到 `:latest` 镜像
- [ ] 用一个空目录挂载到 `/app/config` 时，容器报错退出（缺文件）
- [ ] 用带 bot_id/bot_secret 的配置挂载时，容器进入 cc-connect 启动流程
- [ ] 不挂载 config.yaml 时，容器以 root 运行
- [ ] 挂载 config.yaml 时，容器以指定用户运行，家目录软链正确
