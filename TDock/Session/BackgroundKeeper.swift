import SwiftUI
import UIKit

/// 后台保活（在 iOS 允许的范围内）：
/// 1. 切到后台时申请后台任务（约 30 秒），期间连接照常收发；
/// 2. 回到前台时探测每条 SSH 连接（3 秒内无应答视为已断），并自动重连断开的标签：
///    tmux 标签重新附加到原会话（内容完整恢复），普通 shell 重开并提示；
/// 3. Mosh 会话在服务器端持续存在，回到前台后重建 UDP socket 即可继续。
@MainActor
final class BackgroundKeeper: ObservableObject {
    private let manager: SessionManager
    private var task: UIBackgroundTaskIdentifier = .invalid

    init(manager: SessionManager) {
        self.manager = manager
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            beginBackgroundTask()
        case .active:
            endBackgroundTask()
            Task { await manager.resumeAfterForeground() }
        default:
            break
        }
    }

    private func beginBackgroundTask() {
        guard task == .invalid, !manager.terminals.isEmpty || manager.allConnections.contains(where: { $0.hasActiveForwards }) else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "tdock.keepalive") { [weak self] in
            // 系统即将挂起：结束任务（连接可能随后被系统断开，回到前台时自动恢复）。
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

extension SessionManager {
    /// 回到前台：探测连接是否仍存活，重连断开的终端，并让 Mosh 会话重建 socket。
    func resumeAfterForeground() async {
        await withTaskGroup(of: Void.self) { group in
            for connection in allConnections where connection.isConnected {
                group.addTask { await connection.verifyAlive() }
            }
        }
        for session in terminals {
            session.resumeAfterForeground()
        }
    }
}

extension HostConnection {
    /// 长时间挂起后 TCP 可能已“半死”（isActive 仍为 true）：用一条轻量命令探测，超时则断开以触发重连。
    func verifyAlive() async {
        guard let client = try? await client() else { return }
        do {
            _ = try await client.exec("true", timeout: .seconds(3))
        } catch {
            client.close()
        }
    }
}
