---
name: dsh-cua-macos-signing
description: 在 macOS 上验证 F 的桌面操作权限、固定签名和隔离更新。
---

先加载 f-maintenance 并读取 ../../F_MAINTENANCE.md。使用固定 F Local Signing 和原 bundle identifier，保留辅助功能、屏幕录制及完整磁盘访问授权。构建到独立目录，不覆盖运行中的 F。

运行签名制品 `Contents/MacOS/F --computer-use`，从 stdin 传 `{"action":"state"}` 核对现有权限。桌面输入验证只操作临时测试窗口，运行 `ui/desktop/tests/run-computer-use-tests.py --app <隔离制品>`。不在用户窗口输入测试文字。

签名通过 `codesign --verify --strict` 核验。最终使用 prepare-update.py 的完整验收和延迟重启流程，不以 ad-hoc 签名绕过固定身份，不提前退出承载任务的进程。
