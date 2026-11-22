import SwiftTerm
import SwiftUI
import UIKit

/// 捏合时显示的字号与终端尺寸。
struct ZoomHUD: Equatable {
    var fontSize: Int
    var cols: Int
    var rows: Int
}

/// 双指捏合缩放字号：
/// - 捏合过程中只改当前终端（按 1pt 整数步进，9–24），步进变化时才重排，避免每帧重绘与频繁的窗口尺寸通知；
/// - 松手后写入全局设置，所有打开的终端同步为该字号；
/// - 过程中通过 `onHUD` 报告 字号 / 列 × 行，用于屏幕中央的 HUD（对照 htop 等排版）。
@MainActor
final class PinchZoomController: NSObject {
    private weak var terminalView: TerminalView?
    private weak var settings: AppSettings?
    private let onHUD: (ZoomHUD?) -> Void
    private var startSize: Double = 0
    private var currentSize: Double = 0
    private var hideWork: DispatchWorkItem?
    private let haptics = UISelectionFeedbackGenerator()

    init(terminalView: TerminalView, settings: AppSettings, onHUD: @escaping (ZoomHUD?) -> Void) {
        self.terminalView = terminalView
        self.settings = settings
        self.onHUD = onHUD
        super.init()
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        terminalView.addGestureRecognizer(pinch)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let view = terminalView else { return }
        switch gesture.state {
        case .began:
            hideWork?.cancel()
            startSize = Double(view.font.pointSize)
            currentSize = startSize
            haptics.prepare()
            report()
        case .changed:
            let size = AppSettings.clampFontSize(startSize * Double(gesture.scale))
            if size != currentSize {
                currentSize = size
                view.font = AppSettings.terminalFont(size: size)
                haptics.selectionChanged()
                report()
            }
        case .ended, .cancelled, .failed:
            settings?.fontSize = currentSize
            report()
            let work = DispatchWorkItem { [weak self] in self?.onHUD(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
        default:
            break
        }
    }

    private func report() {
        guard let view = terminalView else { return }
        let dims = view.terminalDimensions
        onHUD(ZoomHUD(fontSize: Int(currentSize), cols: dims.cols, rows: dims.rows))
    }
}

/// 屏幕中央的字号 / 尺寸提示，不拦截触摸。
struct PinchHUD: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let hud = session.zoomHUD {
            VStack(spacing: 4) {
                Text("\(hud.fontSize) pt").font(.title2.weight(.bold).monospacedDigit())
                Text("\(hud.cols) × \(hud.rows)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
