# tdock

iOS SSH 终端（SwiftUI + SwiftTerm，XcodeGen 生成工程）。设计与各阶段决策见 `DESIGN.md`。

## 环境与测试

- iOS App 层（`TDock/`）只能在 Mac 上用 Xcode 编译；Linux 上改了 App 层代码，至少做语法检查（`swiftc -parse`）并对照 SwiftTerm 源码（版本见 `project.yml`）核对接口，且注意 iOS 16 部署目标（如 `View.monospaced()` 需要 16.4）。
- 纯逻辑放 `Packages/TDockCore`，在 Linux 上可测试。新 Linux 环境先执行一次：
  ```
  Scripts/setup-linux.sh            # 安装 Swift 6.0.3 与 sshd/sftp-server/tmux/mosh，生成 ~/.tdock-dev/env.sh
  source ~/.tdock-dev/env.sh
  Scripts/integration-test.sh       # 全部测试（含集成测试）
  ```
  只跑单元测试：`cd Packages/TDockCore && swift test`（集成测试会自动跳过）。

## 硬性约束

- 密码/私钥只存 iOS Keychain，绝不写入代码、测试数据或文档；集成测试的密钥在临时目录现场生成。
- 不做 RSA 私钥支持。
- 保持轻量顺滑：只重绘变化区域、按键直接发送不攒批、快速启动/重连、滚动缓冲有上限。
- `PROMPT*.md` 和 `start-claude.sh` 不提交。
