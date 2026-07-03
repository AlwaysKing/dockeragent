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

# 此时仍是 root 身份，禁用 ~ 与 $HOME，统一用 $USER_HOME
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

# 提取所有 [[projects.platforms]] 块及其子表 [projects.platforms.options] 等。
# lookahead 只在遇到下一个 [[ 数组表时截止；[xxx] 子表属于当前 platform。
blocks = re.findall(
    r'\[\[projects\.platforms\]\][\s\S]*?(?=\n\[\[|\Z)',
    text,
)
if not blocks:
    print("错误: cc-connect.toml 中未找到 [[projects.platforms]] 段", file=sys.stderr)
    sys.exit(1)

# 至少一个 platform 的 bot_id / bot_secret 非空即可
ok_count = 0
for i, block in enumerate(blocks):
    values = {}
    for key in ('bot_id', 'bot_secret'):
        km = re.search(rf'^\s*{key}\s*=\s*"([^"]*)"', block, re.M)
        values[key] = km.group(1).strip() if km else ''
    if all(values.values()):
        print(f"  platforms[{i}].bot_id: OK")
        print(f"  platforms[{i}].bot_secret: OK")
        ok_count += 1
    else:
        for k, v in values.items():
            print(f"  platforms[{i}].{k}: '{v}'" if v else f"  platforms[{i}].{k}: 空", file=sys.stderr)

if ok_count == 0:
    print("错误: 所有 [[projects.platforms]] 的 bot_id/bot_secret 均为空或缺失", file=sys.stderr)
    sys.exit(1)
PY

echo ""
echo "==================== 二进制可访问性预检 ===================="
# 切换用户前验证 claude 和 cc-connect 都能被非 root 用户访问 + 真正能 exec
for bin in /usr/local/bin/claude /usr/local/bin/cc-connect; do
    if [ ! -e "$bin" ]; then
        echo "警告: $bin 不存在" >&2
        continue
    fi
    ls -la "$bin"
    REAL=$(readlink -f "$bin")
    echo "  实际路径: $REAL"
    if [ "$IS_ROOT" = "0" ]; then
        # 真正用目标用户 exec 验证（比 test -x 严格，能捕捉到缺库、interpreter 缺失等）
        if su -s /bin/bash "$USER_NAME" -c "'$REAL' --version >/dev/null 2>&1"; then
            echo "  $USER_NAME exec $REAL: OK"
        else
            RC=$?
            echo "错误: $USER_NAME exec $REAL 失败 (exit=$RC)" >&2
            echo "--- 诊断信息 ---" >&2
            echo "ldd 输出:" >&2
            ldd "$REAL" >&2 2>&1 || true
            echo "file 输出:" >&2
            file "$REAL" 2>&1 >&2 || true
            exit 1
        fi
    fi
done

echo ""
echo "==================== 启动 cc-connect ===================="
if [ "$IS_ROOT" = "1" ]; then
    exec cc-connect
else
    exec su - "$USER_NAME" -c "cc-connect"
fi
