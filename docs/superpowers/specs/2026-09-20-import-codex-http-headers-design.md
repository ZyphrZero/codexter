# 修复 Codex 导入下游 MCP HTTP 请求头

## 目标

修复 Codexter 从 `~/.codex/config.toml` 导入下游 MCP 时丢失 HTTP 请求头的问题。导入后的 streamable HTTP MCP 必须保留 Codex 配置中的 `http_headers` 和 `env_http_headers`，使需要自定义认证头的服务（例如 Apipost MCP）能够完成 JSON 请求和鉴权。

## 方案

### 数据流

1. `CapabilityManager.scanCodexMcps()` 读取 Codex TOML。
2. `_McpDraft` 解析服务器段、`http_headers` 段和 `env_http_headers` 段。
3. `ScannedMcp.transport` 将解析出的请求头放入 `headers` 字段。
4. `mcp_manage_page.dart` 现有导入流程把 transport 原样写入 `DownstreamMcpEntry`。
5. `DownstreamClient._httpRequest()` 已通过 `entry.headers` 注入请求头，因此无需改动传输层。

### 配置语义

- `http_headers` 的值是直接发送的 Header 值。
- `env_http_headers` 的值是环境变量名；导入时从当前进程环境读取对应值。
- 缺失的环境变量不生成空 Header，避免发送无效认证值。
- 仅 URL 类型 MCP 使用 HTTP Header；stdio 的现有 `env` 解析保持不变。

### 错误处理与安全

- Header 值只保存在本地 Hive transport 配置中，不写入连接日志、错误摘要或 URL。
- 解析失败的 TOML 行继续按当前宽容策略忽略，不影响其他 MCP 导入。
- 现有 HTTP 连接和重连逻辑保持不变，避免扩大行为变化范围。

### 测试

- 增加 `CapabilityManager` 导入解析测试，覆盖直接 Header、环境变量 Header、缺失环境变量和 URL MCP。
- 保留现有下游 MCP 传输测试，确保解析出的 Header 最终能发送到 HTTP 服务。
- 运行 `dart test`（或仓库可用的等价 Flutter 测试命令）验证全量回归。

## Review Notes

- 已确认当前 `DownstreamMcpEntry` 和 `DownstreamClient` 已支持 `headers`，缺陷集中在 Codex TOML 导入器。
- 已确认当前 Apipost MCP 配置使用 `http_headers.api-token`，与本方案直接对应。
- 不在本次 PR 中增加手动编辑 Header 的 UI；这属于独立的产品能力，避免扩大修复范围。

## Implementation Summary

已实现：

- `CapabilityManager` 支持注入测试用 Codex 目录，并解析 `http_headers` / `env_http_headers`。
- 导入的 URL MCP 将 Header 写入 transport，复用既有 `DownstreamClient` 注入逻辑。
- 增加直接 Header、环境变量 Header、缺失环境变量和 stdio 环境变量回归测试。
- 增加真实本地 HTTP 服务断言，确认 Header 会随下游 MCP 请求发送。
