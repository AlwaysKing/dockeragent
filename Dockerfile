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
# Release 提供 tar.gz 包，需要解压后取出二进制
ARG CC_CONNECT_VERSION=latest
RUN set -eux; \
    if [ "$CC_CONNECT_VERSION" = "latest" ]; then \
        URL=$(curl -fsSL https://api.github.com/repos/chenhg5/cc-connect/releases/latest \
              | grep -oE 'https://[^"]*linux-amd64\.tar\.gz' | head -1); \
    else \
        URL="https://github.com/chenhg5/cc-connect/releases/download/${CC_CONNECT_VERSION}/cc-connect-${CC_CONNECT_VERSION}-linux-amd64.tar.gz"; \
    fi; \
    echo "Downloading: $URL"; \
    curl -fsSL -o /tmp/cc-connect.tar.gz "$URL"; \
    tar -xzf /tmp/cc-connect.tar.gz -C /tmp; \
    mv "$(find /tmp -maxdepth 2 -type f -name cc-connect | head -1)" /usr/local/bin/cc-connect; \
    chmod +x /usr/local/bin/cc-connect; \
    rm -rf /tmp/cc-connect*; \
    cc-connect --version || true

# 应用目录结构
WORKDIR /app

# 拷贝示例配置（用户挂载 /app/config 时会被覆盖）
COPY config/        /app/config/
COPY entrypoint.sh  /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 项目数据目录（work_dir）；内置示例，用户可挂载覆盖
COPY data/          /app/data/

# 验证二进制就位且可执行（不能只 which，要真跑一下）
# 用 ELF magic 检测，避免依赖 --version 的 exit code 行为
RUN set -eux; \
    which cc-connect claude python3 git rg; \
    head -c 4 /usr/local/bin/cc-connect | od -c | head -1 | grep -q '177   E   L   F' \
        || { echo "cc-connect 不是 ELF 文件（可能是 tar.gz 未解压）"; exit 1; }; \
    cc-connect --version || echo "cc-connect --version 不可用（忽略）"; \
    claude --version

ENTRYPOINT ["/app/entrypoint.sh"]
