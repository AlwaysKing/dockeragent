# claude.json 说明

此文件作为 Claude Code 用户级 settings.json 的示例，运行时会被软链到 `~/.claude/settings.json`。

字段说明：
- `env.ANTHROPIC_AUTH_TOKEN`: Claude API Token（必填）
- `env.ANTHROPIC_BASE_URL`: 自定义 API 端点（可选，用于中转）
- `env.ANTHROPIC_MODEL`: 默认模型名（可选）
- `env.ANTHROPIC_REASONING_MODEL`: 推理模型名（可选）

完整字段参考：https://code.claude.com/docs/en/settings
