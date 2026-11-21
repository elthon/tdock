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

**MVP 不做**（已移入第二阶段，见第 7 节）：多标签/多会话、SFTP、端口转发、Mosh、iCloud 同步、主题/字体设置、密钥生成、Face ID 解锁、后台保活。

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

## 7. 第二阶段

范围：下列 11 项。**明确不做：RSA 私钥支持。** 原则不变：逻辑尽量下沉到 TDockCore（可在 macOS/Linux 上 `swift test`），App 层只做界面与系统集成；密码/私钥只存本机 Keychain。

### 7.1 架构调整：一条连接，多条通道

MVP 的 `SSHShellSession`（一个连接 = 一个 shell）拆为：

- `SSHClient`：一条已认证的 SSH 连接，可在其上并发打开多条通道：
  - `openShell(size:command:)`：PTY + shell，或 PTY + exec（用于 `tmux new -A`）；
  - `exec(_:)`：非交互命令，返回 stdout / stderr / 退出码（tmux 管理、mosh 引导、环境检测）；
  - `openSFTP()`：`sftp` 子系统；
  - `openDirectTCPIP(...)`：端口转发用的 `direct-tcpip` 通道。
- 同一主机的多个标签**共享一条 SSH 连接**，新开标签只需开一条通道（毫秒级，不重复握手/认证）。
- 所有连接共用 `MultiThreadedEventLoopGroup.singleton`，不再每个会话建线程池；开启 `TCP_NODELAY` 与 `SO_KEEPALIVE`。

App 层新增全局 `SessionManager`：持有每台主机的 `HostConnection`（共享 `SSHClient`、端口转发）和所有打开的终端标签。终端不再随页面销毁，返回列表后仍在后台保持，可从主机详情页的 “Terminal Activity” 回到它。

### 7.2 各项方案

| # | 功能 | 方案 | 代码位置 |
|---|---|---|---|
| 1 | 多标签/多会话 | 每台主机一个工作区，顶部标签栏切换；`+` 新开标签（共享连接）；硬件键盘 ⌘T 新建、⌘W 关闭、⌘1…9 切换 | Core: `SSHClient`；App: `SessionManager`、`TerminalWorkspaceView` |
| 2 | SFTP | 自实现 SFTP v3 客户端（OPENDIR/READDIR/STAT/REALPATH/OPEN/READ/WRITE/CLOSE），读写按 32 KB 分块并流水线化；界面可浏览目录、上传（文件选择器）、下载（分享/存储到"文件"） | Core: `SFTPClient`；App: `SFTPBrowserView` |
| 3 | 端口转发 | 本地转发：在 `127.0.0.1:<本地端口>` 监听，每个入站连接开一条 `direct-tcpip` 通道到 `<内网主机>:<端口>`；规则随服务器配置保存，在主机详情页启停 | Core: `LocalPortForwarder`；App: `PortForwardsSection` |
| 4 | iCloud 同步 | `NSUbiquitousKeyValueStore` 同步服务器配置（含端口转发规则、连接方式），按 `updatedAt` 后写者胜，删除用墓碑记录；**密码/私钥不同步**，新设备上首次连接时提示补填 | Core: `ServerSync`（合并逻辑）；App: `CloudSync` |
| 5 | 主题/字体 | 内置若干终端配色（前景/背景/光标 + 16 色 ANSI）、字号 9–24，实时作用到所有打开的终端 | Core: `TerminalTheme`；App: `SettingsView` |
| 6 | 密钥生成 | App 内生成 Ed25519，编码为 OpenSSH 私钥格式存 Keychain；公钥（`ssh-ed25519 AAAA… 注释`）可复制/分享；服务器配置可选择"密钥库中的密钥" | Core: `OpenSSHKeyGenerator`；App: `KeyLibrary`、`KeysView` |
| 7 | Face ID | `LocalAuthentication`（Face ID，失败可回退设备密码）；设置中开关；启动及从后台返回时加锁遮罩 | App: `AppLock` |
| 8 | 后台保活 | 见 7.3 | Core: keepalive；App: `BackgroundKeeper` |
| 9 | tmux | 连接时先执行 `command -v tmux` 检测；未安装时在界面明确提示原因与安装命令（apt/dnf/yum/apk/pacman/brew）。主机详情页两个列表：**Terminal Activity**（当前打开的终端卡片：名称、`tmux · 会话名`、创建时间）与 **tmux Sessions**（`tmux list-sessions` 全部会话：名称、创建时间、`In use` 徽标）；支持新建、切换（`tmux new-session -A -s` 附加）、重命名、删除 | Core: `TmuxCommands`（命令构造/输出解析）；App: `HostDetailView` |
| 10 | Mosh | 见 7.4 | Core: `Mosh*`；App: 终端会话的 Mosh 传输 |
| 11 | 快捷栏 | 自定义 `inputAccessoryView` 替换 SwiftTerm 默认栏：默认页 Esc、Tab、Ctrl、Alt、←↑↓→；**长按 Ctrl** 弹出组合键菜单（Ctrl+C/D/Z/L/R/A/E/K/U）；分页横向滑动切换；设置中可增删、排序每页按键；独立 **Agent 抽屉**（Esc、Tab 补全、Ctrl+C 中断、↑/↓ 历史）。Ctrl/Alt 为单次锁定修饰键（作用于下一次按键），方向键按终端当前光标模式发送。不使用手势代替按键。外接键盘由 SwiftTerm 处理 Ctrl/Option(Meta)，⌘ 组合用于 App 快捷键与复制粘贴 | Core: `ShortcutLayout`（按键模型/编码）；App: `ShortcutBar` |

### 7.3 后台保活（iOS 限制说明）

iOS 不允许普通 App 在后台无限期保持 TCP 连接，不使用"静音音频/定位"这类会被拒审的手段。策略：

1. 切后台时申请 `beginBackgroundTask`（约 30 秒），期间连接照常收发；SSH 层开启 TCP keepalive。
2. 回到前台时检查每条连接：仍存活则无感继续；已断开则**自动重连**——tmux 标签重新附加到原会话（屏幕内容完整恢复），普通 shell 标签重开 shell 并提示。
3. 需要真正"锁屏、切网不断"的场景使用 Mosh（UDP，服务器端会话持续存在，回到前台后重建 UDP socket 即续上）。

### 7.4 Mosh

纯 Swift 实现 Mosh 客户端协议，无 C 依赖：

- **引导**：通过 SSH exec 先检测 `command -v mosh-server`，再运行 `mosh-server new -s -c 256 -l LANG=…`（可选 `-- tmux new-session -A -s 名称`），解析 `MOSH CONNECT <端口> <密钥>`。密钥只在内存中，不落盘。
- **传输**：UDP 数据报，AES-128-OCB3（RFC 7253）加解密，带方向位的 64 位序列号作 nonce；分片重组；指令体为 protobuf（手写编解码）+ zlib（自实现 inflate，发送端用 stored 块）。
- **状态同步（SSP）**：客户端状态 = 按键/尺寸事件序列，发送"自服务器已确认状态以来"的增量；服务器状态以终端差量字节流下发，直接送入 SwiftTerm。客户端只保留一份屏幕状态：基于其他旧状态的差量被丢弃，由服务器的重传超时机制自动改发基于已确认状态的差量（实现简单，代价是丢包时最多一个 RTO 的延迟）。
- **检测与报错**：mosh-server 未安装 → 提示 `sudo apt install mosh` 等；启动后 5 秒内收不到 UDP 回包 → 提示 UDP 端口不可达，需放行 `UDP 60000–61000`（含云厂商安全组）。
- **漫游与断线**：socket 不绑定本地地址，网络切换（WiFi↔5G）后继续发送即可被服务器识别；发送失败或回到前台时重建 socket；每 3 秒心跳。
- **本地回显**：RTT > 30 ms 时，可打印字符立即以下划线样式显示在光标处（覆盖层，不改动终端状态），服务器回显确认（`echo_ack`）后移除；遇到回车/控制键/方向键即清空预测。只有在当前行已观察到服务器真实回显后才显示预测，因此密码提示等不回显的输入永远不会被画到屏幕上。
- Mosh 会话内可直接使用 tmux（引导命令带 tmux 附加）。

### 7.5 性能约束

- 终端重绘：SwiftTerm 只重绘变化的行区域；数据经线程安全的 `feedSender` 直接从网络线程送入，不经主线程中转。
- 按键：每次按键立即写入并 flush（SSH）/ 立即发包（Mosh），不攒批。
- 启动/重连：共享事件循环与连接；同主机新标签复用连接；重连不重复弹指纹确认。
- 滚动缓冲上限 5000 行（`TerminalOptions.scrollback`）。

### 7.6 目录结构（第二阶段后）

```
TDock/
├── App/        TDockApp（根视图、全局主机指纹确认、锁屏遮罩）
├── Session/    SessionManager（含 HostConnection）、TerminalSession、CredentialProvider、BackgroundKeeper
├── Terminal/   TerminalWorkspaceView（标签栏）、ShortcutBar（快捷栏）、MoshTerminalTransport（含预测覆盖层）
├── Security/   AppLock（Face ID）、KeyLibrary（密钥库）
├── Sync/       CloudSync（iCloud 键值存储）
├── Settings/   AppSettings、SettingsView、ShortcutEditorView
├── Storage/    KeychainStore、ServerStore（含墓碑）、KnownHostsStore
└── Views/      ServerListView、ServerEditView、HostDetailView、TmuxSessionsSection、PortForwardsSection、
                SFTPBrowserView、KeysView、SwiftTermView
Packages/TDockCore/Sources/TDockCore/
├── SSH/        SSHClient、SessionChannelHandler、SSHTypes、LocalPortForwarder
├── SFTP/       SFTPClient、SFTPMessages
├── Mosh/       AES128、OCB、Zlib、MoshMessages（protobuf/指令/分片）、MoshTransport、MoshSession、MoshPredictor
├── Tmux/       TmuxCommands（含 TmuxManager、ShellQuote）
└── Model/      ServerProfile、ServerSync、TerminalTheme、ShortcutLayout、OpenSSHPrivateKey、OpenSSHKeyGenerator
Scripts/integration-test.sh   临时 sshd + 集成测试
```

### 7.7 测试

- 单元测试：私钥生成/解析往返、SFTP 报文编解码、tmux 输出解析、同步合并、AES（FIPS-197 向量）、OCB3（RFC 7253 向量）、inflate、protobuf、快捷键编码。
- 集成测试（`TDOCK_IT_*` 环境变量启用，默认跳过）：`Scripts/integration-test.sh` 在临时目录启动非 root 的 sshd（及 sftp-server），临时生成密钥，运行 shell/exec/SFTP/端口转发/tmux/Mosh 端到端用例，结束后清理。仓库中不包含任何密钥。

### 7.8 第二阶段验证状态

- `Scripts/integration-test.sh` 下 TDockCore 共 83 个测试全部通过（Linux，Swift 6.0.3；服务器端为 OpenSSH 10.0、sftp-server、tmux 3.5a、mosh-server 1.4.0），其中端到端覆盖：
  - 一条连接上并发多个 shell / exec 通道，退出码，各类认证/指纹/连接失败；
  - SFTP 上传/下载 ~300 KB 随机文件逐字节一致、空文件、目录排序、不存在路径；
  - 端口转发 3 个并发连接各 256 KB 回显（含背压）、目标不可达、本地端口占用；
  - App 内生成的 Ed25519 密钥：`ssh-keygen -y/-l` 结果一致，且可登录 sshd；
  - tmux 新建/列表/附加后 In use/重命名/删除/重名报错，含中文与空格的会话名；
  - Mosh：经 SSH 启动 mosh-server → UDP 交互、尺寸同步、重建 socket（模拟漫游）后继续、远端 exit 正常结束、Mosh 内运行 tmux、mosh-server 未安装、UDP 不可达。
- 加密与编码：AES（FIPS-197）、OCB3（RFC 7253 及 Python cryptography 生成的向量）、zlib（Python 生成的 stored/固定/动态 Huffman 向量）。
- **未验证**：iOS App 层（SwiftUI、SwiftTerm 集成、快捷栏、Face ID、iCloud、后台任务）尚未在 Xcode / 真机上编译运行；接口已对照 SwiftTerm 1.99.3 源码核对。
- 已知限制：后台保活受 iOS 限制（见 7.3）；Mosh 客户端只保留一份屏幕状态，丢包时可能有最多约 1 秒的画面停顿后自动恢复（见 7.4）；端口转发仅在 App 运行期间有效。
