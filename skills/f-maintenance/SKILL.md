---
name: f-maintenance
description: 修改、重构或测试 F 自身时使用。保留现有功能和用户数据，隔离构建与全功能回归通过后提交延迟更新。
---

先读取本技能资源根下的 ../../F_MAINTENANCE.md，并遵守完整流程。该文件是自维护规则的唯一来源。

开始前备份受影响源码与数据至 F 的 maintenance 目录；保持正在运行的 F 和 Agent 存活。
实现后运行 harness 测试、现有全部原生回归和 cbi DeepSeek v4 flash 的真实模型工具链测试。
模型测试使用隔离项目与会话，记录实际模型 ID、工具结果、失败和退出码；不得把未执行的功能标为通过。
清理只移除已验证无调用者的重复代码和临时制品；保留用户数据、凭据及磁盘/网络/安装边界的必要错误处理。
最后运行 gui-mac/scripts/prepare-update.py，成功发布后只回复与 announcement 一致的百字以内中文公告，不再启动工具。
