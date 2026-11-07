# 安装与存储

源码安装保留十个一级目录。运行 `bash ui/desktop/build.sh`，然后打开 `ui/desktop/F.app`。构建脚本按锁文件安装缺失的 Node 和依赖。需要 macOS 13.5 及 Apple Command Line Tools。项目、历史会话、画板和已有凭据仍使用原位置；源码中的兼容入口不复制用户数据。

DMG 安装将 F 拖到 Applications。运行代码、Node 与依赖位于 `F.app/Contents/Resources`；会话、画板、模型凭据位于 `~/Library/Application Support/F`，缓存位于 `~/Library/Caches/F`，偏好设置交给 macOS 管理。既有数据和自定义画板目录优先，不因安装方式改变而迁移或覆盖。

选择 DP 时，缺少凭据会打开终端隐藏输入 API key，验证后保存到 `agent/auth.json`，权限为 0600。GPT 使用浏览器授权，CBC、CBI 使用官方 CLI 登录终端。CodeBuddy 账户继续使用官方的 `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth` 存储。登录失败或取消不会删除原凭据。

发布包由 `scripts/package-dmg.py --app <已验证的F.app> --output <输出目录> --version <版本>` 生成，排除用户数据、缓存与密钥。当前发布为 Apple Silicon 包，使用本地签名，未进行 Apple 公证；首次打开可能需要在系统设置的隐私与安全性页面确认。源码可在 Intel Mac 上自行构建。
