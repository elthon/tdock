import Combine
import SwiftUI
import TDockCore
import UIKit

/// 查找当前场景与最上层的页面（包括 sheet），用于弹出与页面层级无关的系统级提示。
@MainActor
enum TopPresenter {
    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// 应用的主窗口（不含安全遮罩窗口）。
    static var mainWindows: [UIWindow] {
        activeScene?.windows.filter { !($0 is SecurityOverlayWindow) } ?? []
    }

    static func topViewController() -> UIViewController? {
        let window = mainWindows.first { $0.isKeyWindow } ?? mainWindows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// 首次连接主机时的指纹确认框。
/// 用 UIKit 从最上层页面弹出，因此在 sheet 中发起的连接（例如“部署公钥”）也能弹出确认，不会卡住。
@MainActor
final class HostKeyPromptPresenter {
    private weak var alert: UIAlertController?
    private var shownID: UUID?

    func show(_ prompt: SessionManager.HostKeyPrompt?, answer: @escaping (Bool) -> Void) {
        guard let prompt else {
            alert?.dismiss(animated: true)
            shownID = nil
            return
        }
        guard prompt.id != shownID else { return }
        shownID = prompt.id
        let controller = UIAlertController(
            title: "首次连接此主机",
            message: """
            \(prompt.host):\(prompt.port) 的主机密钥尚未记录。
            请核对指纹后再确认：

            \(prompt.key.keyType)
            \(prompt.key.fingerprint)
            """,
            preferredStyle: .alert
        )
        controller.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in answer(false) })
        controller.addAction(UIAlertAction(title: "信任并连接", style: .default) { _ in answer(true) })
        guard let top = TopPresenter.topViewController() else { return answer(false) }
        top.present(controller, animated: true)
        alert = controller
    }
}

/// 安全遮罩专用窗口：层级高于所有页面（包括 sheet），用于锁屏与多任务切换器隐私遮罩。
final class SecurityOverlayWindow: UIWindow {}

/// 根据 AppLock 状态显示/隐藏安全遮罩窗口。窗口从不成为 key window，不抢终端的焦点。
@MainActor
final class SecurityOverlayController {
    private var window: SecurityOverlayWindow?
    private var cancellable: AnyCancellable?

    func start(lock: AppLock) {
        guard cancellable == nil else { return }
        cancellable = lock.$isLocked.combineLatest(lock.$isObscured)
            .sink { [weak self] locked, obscured in
                self?.update(locked: locked, obscured: obscured, lock: lock)
            }
    }

    private func update(locked: Bool, obscured: Bool, lock: AppLock) {
        guard locked || obscured else {
            window?.isHidden = true
            return
        }
        if window == nil, let scene = TopPresenter.activeScene {
            let window = SecurityOverlayWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: SecurityOverlayView().environmentObject(lock))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.backgroundColor = .clear
            self.window = window
        }
        if locked {
            // 锁定时收起键盘：键盘窗口层级更高，否则会浮在锁屏之上并把输入送进后面的终端。
            TopPresenter.mainWindows.forEach { $0.endEditing(true) }
        }
        window?.isHidden = false
    }
}

/// 遮罩内容：锁定时显示解锁界面；仅隐私遮罩时显示毛玻璃。
private struct SecurityOverlayView: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        if lock.isLocked {
            LockScreen()
        } else {
            ZStack {
                Rectangle().fill(.thickMaterial).ignoresSafeArea()
                Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        }
    }
}
