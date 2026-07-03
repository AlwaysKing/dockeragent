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
