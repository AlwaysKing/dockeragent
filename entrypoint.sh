#!/bin/bash
set -e

# 配置文件路径
CONFIG_FILE="/app/config.yaml"

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# 使用 Python 解析 YAML（如果没有 yq，用 Python 最可靠）
parse_yaml() {
    python3 -c "
import yaml
import sys
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = yaml.safe_load(f)
    user_name = config.get('USER', {}).get('NAME', 'Server')
    user_id = config.get('USER', {}).get('ID', 2000)
    group_name = config.get('GROUP', {}).get('NAME', 'Server')
    group_id = config.get('GROUP', {}).get('ID', 2000)
    print(f'{user_name}|{user_id}|{group_name}|{group_id}')
except Exception as e:
    print(f'ERROR|{e}', file=sys.stderr)
    sys.exit(1)
"
}

# 解析配置
CONFIG_DATA=$(parse_yaml)
if [ $? -ne 0 ] || [ -z "$CONFIG_DATA" ]; then
    echo "错误: 解析配置文件失败"
    exit 1
fi

# 提取配置值
USER_NAME=$(echo "$CONFIG_DATA" | cut -d'|' -f1)
USER_ID=$(echo "$CONFIG_DATA" | cut -d'|' -f2)
GROUP_NAME=$(echo "$CONFIG_DATA" | cut -d'|' -f3)
GROUP_ID=$(echo "$CONFIG_DATA" | cut -d'|' -f4)

echo "配置信息:"
echo "  用户名: $USER_NAME (UID: $USER_ID)"
echo "  组名: $GROUP_NAME (GID: $GROUP_ID)"

# 创建用户组（如果不存在）
if ! getent group "$GROUP_NAME" > /dev/null 2>&1; then
    echo "创建用户组: $GROUP_NAME (GID: $GROUP_ID)"
    groupadd -g "$GROUP_ID" "$GROUP_NAME"
else
    echo "用户组 $GROUP_NAME 已存在"
fi

# 创建用户（如果不存在）
if ! getent passwd "$USER_NAME" > /dev/null 2>&1; then
    echo "创建用户: $USER_NAME (UID: $USER_ID)"
    useradd -u "$USER_ID" -g "$GROUP_ID" -m -d "/home/$USER_NAME" -s /bin/bash "$USER_NAME"
else
    echo "用户 $USER_NAME 已存在"
    # 确保用户的 UID 和 GID 正确
    usermod -u "$USER_ID" -g "$GROUP_ID" "$USER_NAME" 2>/dev/null || true
fi

# 确保家目录存在
USER_HOME="/home/$USER_NAME"
if [ ! -d "$USER_HOME" ]; then
    echo "创建家目录: $USER_HOME"
    mkdir -p "$USER_HOME"
    chown "$USER_NAME":"$GROUP_NAME" "$USER_HOME"
fi

# 创建软连接
echo "创建软连接..."

# .cc-connect 软连接
if [ -L "$USER_HOME/.cc-connect" ]; then
    echo "  移除已存在的软连接: $USER_HOME/.cc-connect"
    rm -f "$USER_HOME/.cc-connect"
fi
if [ ! -L "$USER_HOME/.cc-connect" ]; then
    echo "  创建: $USER_HOME/.cc-connect -> /data/cc-connect/"
    ln -sf /data/cc-connect/ "$USER_HOME/.cc-connect"
    chown -h "$USER_NAME":"$GROUP_NAME" "$USER_HOME/.cc-connect"
fi

# .claude 软连接
if [ -L "$USER_HOME/.claude" ]; then
    echo "  移除已存在的软连接: $USER_HOME/.claude"
    rm -f "$USER_HOME/.claude"
fi
if [ ! -L "$USER_HOME/.claude" ]; then
    echo "  创建: $USER_HOME/.claude -> /data/claude"
    ln -sf /data/claude "$USER_HOME/.claude"
    chown -h "$USER_NAME":"$GROUP_NAME" "$USER_HOME/.claude"
fi

# 确保 /data 目录权限正确
if [ -d "/data" ]; then
    echo "设置 /data 目录权限..."
    chown -R "$USER_NAME":"$GROUP_NAME" /data 2>/dev/null || true
fi

# 确保用户有 sudo 权限（如果需要）
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USER_NAME"
chmod 440 /etc/sudoers.d/"$USER_NAME"

echo "配置完成！"

# 切换到目标用户并运行 cc-connect
echo "切换到用户 $USER_NAME 并启动 cc-connect..."
exec su - "$USER_NAME" -c "cc-connect"