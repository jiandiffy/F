# MCP 服务

F 复用 Pi 的 MCP 客户端，支持 stdio 和 Streamable HTTP。配置在 `../configs/servers.json`，也可用 `F_MCP_CONFIG` 指定本机文件。每项只有 `enabled: true` 才注册。禁用及退出由宿主关闭进程与连接。

配置中的命令会在本机执行，只加入已审阅的服务器。令牌使用环境变量或 Pi 的认证存储，不写进版本库。该版本客户端协商 MCP 2025-11-25，兼容 2025-06-18、2025-03-26 和 2024-11-05，不宣称支持更新协议。

传输及生命周期参照 [MCP 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)。
