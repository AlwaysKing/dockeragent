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
| `/app/config/cc-connect.toml` | cc-connect 完整配置 | 必需 |
| `/app/config/claude.json` | Claude Code settings.json | 必需 |
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
