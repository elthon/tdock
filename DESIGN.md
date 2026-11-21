# tdock 设计文档（MVP）

> 状态：草案，等待评审。范围仅限 MVP：**在 iPhone 上通过 SSH 登录服务器并打开可交互终端**。

## 1. 技术选型

| 领域 | 选型 | 理由 |
| --- | --- | --- |
| UI | **SwiftUI**（iOS 16+，`NavigationStack`） | 原生、声明式；终端视图本身是 UIKit，用 `UIViewRepresentable` 包一层 |
| 终端模拟 | **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** 1.99.x（SPM） | 成熟的 VT100/xterm 模拟器，自带 iOS `TerminalView`（键盘输入、辅助按键栏、选择、滚动缓冲），MIT 许可 |
| SSH | **[SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)** 0.12.x（SPM） | Apple 维护、纯 Swift、无 C 依赖（不需要交叉编译 OpenSSL/libssh2）；支持 PTY / shell / window-change 请求；SwiftTerm 官方 iOS 示例也用它 |
| 私钥解析 | 自写 OpenSSH 私钥格式解析器（`openssh-key-v1`） | NIO SSH 不自带 PEM/OpenSSH 文件解析；格式简单，几十行可完成 |
| 密钥存储 | **iOS Keychain**（`kSecClassGenericPassword`，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`） | 密码和私钥**只**存 Keychain，不同步 iCloud、不进备份迁移；代码与文档中不含任何凭据 |
| 非敏感配置 | JSON 文件（Application Support） | 服务器列表（名称/主机/端口/用户名/认证方式）及已信任主机指纹，均不含秘密 |
| 工程生成 | **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**（`project.yml`） | 工程描述可读、可 diff，避免手写/冲突 `project.pbxproj`；`.xcodeproj` 不入库 |

### SSH 认证支持范围（MVP）

- 密码认证。
- 私钥认证：OpenSSH 格式、**未加密**的 **Ed25519**、**ECDSA（P-256/P-384/P-521）**。
- 不支持（MVP 外）：RSA 私钥（NIO SSH 不支持 RSA 用户密钥，后续可换 Citadel 或自行补签名算法）、带 passphrase 的私钥、keyboard-interactive、ssh-agent、跳板机。

### 主机密钥校验

不做"全部接受"。采用 TOFU（首次信任）：首次连接时弹窗显示主机密钥 SHA256 指纹，用户确认后记录；之后指纹变化则**拒绝连接**并提示。这是安全登录的必要部分，不算额外功能。

## 2. 架构

```
SwiftUI Views ──► SessionController (@MainActor, ObservableObject)
                     │  ├─ SwiftTerm TerminalView  (输入 → SSH，SSH 输出 → feed)
                     │  └─ HostKeyPrompt (TOFU 弹窗)
                     ▼
               TDockCore.SSHShellSession   (SwiftNIO SSH：连接、认证、PTY、shell、resize)
                     ▲
     KeychainStore（密码/私钥） ServerStore / KnownHostsStore（JSON）
```

- **TDockCore**（本地 Swift Package）：纯逻辑，不依赖 UIKit/Keychain —— 数据模型、OpenSSH 私钥解析、SSH 会话。可在 macOS/Linux 上 `swift build` / `swift test`。
- **TDock**（iOS App target）：SwiftUI 界面、Keychain、SwiftTerm 集成、持久化。

## 3. 目录结构

```
tdock/
├── DESIGN.md
├── project.yml                     # XcodeGen 工程描述
├── TDock/                          # iOS App
│   ├── App/TDockApp.swift
│   ├── Storage/
│   │   ├── KeychainStore.swift     # 密码/私钥 → Keychain
│   │   ├── ServerStore.swift       # 服务器列表 JSON
│   │   └── KnownHostsStore.swift   # 已信任主机指纹 JSON
│   ├── Session/SessionController.swift
│   ├── Views/
│   │   ├── ServerListView.swift
│   │   ├── ServerEditView.swift
│   │   ├── TerminalScreen.swift
│   │   └── SwiftTermView.swift     # UIViewRepresentable
│   └── Resources/                  # Info.plist, Assets.xcassets
└── Packages/TDockCore/
    ├── Package.swift
    ├── Sources/TDockCore/
    │   ├── ServerProfile.swift
    │   ├── OpenSSHPrivateKey.swift
    │   └── SSHShellSession.swift
    └── Tests/TDockCoreTests/
```

## 4. MVP 功能清单

1. 服务器配置：新增 / 编辑 / 删除；字段：名称、主机、端口（默认 22）、用户名、认证方式（密码 | 私钥）。
2. 凭据：密码或粘贴的私钥文本保存到 Keychain，按服务器 ID 关联；删除服务器时一并删除。
3. SSH 登录：TCP 连接 → 主机密钥 TOFU 校验 → 密码或私钥认证。
4. 终端：申请 PTY（`xterm-256color`）+ shell；双向收发；屏幕尺寸变化（旋转、键盘弹出）时发送 window-change；远端退出或断线时提示。
5. 错误提示：连接失败、认证失败、私钥格式不支持、主机指纹不匹配。

**明确不做**：多标签/多会话、SFTP、端口转发、Mosh、iCloud 同步、主题/字体设置、密钥生成、Face ID 解锁、后台保活。

## 5. 构建

需要 Xcode 26+（SwiftTerm 1.99 要求 Swift tools 6.2）。

```sh
brew install xcodegen
xcodegen generate        # 生成 TDock.xcodeproj
open TDock.xcodeproj     # 在 Signing 中选择自己的开发团队后运行
```

核心逻辑测试：`cd Packages/TDockCore && swift test`（macOS / Linux 均可）。

## 6. 验证状态

- TDockCore：单元测试通过（私钥解析用运行时生成的密钥，仓库内不含任何密钥）；并已对真实 OpenSSH 10.0 sshd 做过端到端验证：Ed25519 / ECDSA P-256 / P-521 登录、PTY + `xterm-256color`、窗口尺寸变更、`exit` 后正常关闭；以及认证失败、服务器不支持该认证方式、主机指纹不匹配、端口拒绝连接的错误路径。
- iOS App 层（SwiftUI / Keychain / SwiftTerm 集成）：已按 SwiftTerm 当前源码核对接口，但尚未在 Xcode / 真机上编译运行。
- 密码认证：代码路径已覆盖，但测试环境的非 root sshd 无法启用密码登录，尚未对真实服务器验证。
