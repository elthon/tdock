import LocalAuthentication
import SwiftUI

/// Face ID 锁：开启后，启动 App 及从后台返回时需要验证（失败可回退设备密码）。
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private var authenticating = false
    private var returningFromBackground = true // 冷启动视同从后台返回

    init(settings: AppSettings) {
        self.settings = settings
        isLocked = settings.faceIDEnabled
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "设备密码"
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if settings.faceIDEnabled { isLocked = true }
            returningFromBackground = true
        case .active:
            // 只在从后台返回时自动弹出验证；用户取消后不再反复弹出，可点按钮重试。
            if isLocked && returningFromBackground { unlock() }
            returningFromBackground = false
        default:
            break
        }
    }

    func unlock() {
        guard isLocked, !authenticating else { return }
        Task {
            if await authenticate(reason: "解锁 tdock") {
                isLocked = false
            }
        }
    }

    /// 开关 Face ID 锁。开启与关闭都需要先通过验证。
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.faceIDEnabled else { return }
        Task {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                lastError = "此设备未设置 Face ID 或密码：\(error?.localizedDescription ?? "")"
                return
            }
            if await authenticate(reason: enabled ? "开启 Face ID 锁" : "关闭 Face ID 锁") {
                settings.faceIDEnabled = enabled
                lastError = nil
            }
        }
    }

    private func authenticate(reason: String) async -> Bool {
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

/// 锁定遮罩：完全遮挡内容（包括多任务切换器中的快照）。
struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("tdock 已锁定").font(.title3.weight(.semibold))
                Button {
                    lock.unlock()
                } label: {
                    Label("使用 \(lock.biometryName) 解锁", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                if let error = lock.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .transition(.opacity)
    }
}
