import SwiftTerm
import TDockCore
import UIKit

/// Mosh 会话作为终端传输：按键立即发包；带本地回显预测覆盖层；回到前台/网络切换时重建 socket。
@MainActor
final class MoshTerminalTransport: ResumableTransport {
    private let session: MoshSession
    private var predictor = MoshPredictor()
    private let overlay: PredictionOverlay
    private var expiryTimer: Timer?

    init(session: MoshSession, terminalView: TerminalView) {
        self.session = session
        overlay = PredictionOverlay(terminalView: terminalView)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.predictor.expire(now: MoshClock.now())
                self?.refreshOverlay()
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        predictor.userInput(bytes, now: MoshClock.now())
        refreshOverlay()
        session.send(bytes) { [weak self] stateNum in
            Task { @MainActor in self?.predictor.assign(stateNum: stateNum) }
        }
    }

    func resize(cols: Int, rows: Int) {
        predictor.reset()
        refreshOverlay()
        session.resize(cols: cols, rows: rows)
    }

    func resume() {
        session.resume()
    }

    func close() {
        expiryTimer?.invalidate()
        overlay.remove()
        session.close()
    }

    /// 服务器输出到达（终端内容已由 feedSender 直接送入，这里只更新预测状态）。
    func hostOutput(_ bytes: [UInt8]) {
        predictor.hostOutput(bytes)
        refreshOverlay()
    }

    func echoAcked(_ num: UInt64) {
        predictor.echoAcked(num)
        refreshOverlay()
    }

    private func refreshOverlay() {
        overlay.show(predictor.displayText(rtt: session.roundTripTime))
    }
}

/// 预测文本覆盖层：绘制在光标处，带下划线，不修改终端状态。
@MainActor
final class PredictionOverlay {
    private weak var terminalView: TerminalView?
    private let label = UILabel()

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        label.isUserInteractionEnabled = false
        label.isHidden = true
        terminalView.addSubview(label)
    }

    func show(_ text: String) {
        guard let terminalView else { return }
        guard !text.isEmpty else {
            label.isHidden = true
            return
        }
        let caret = terminalView.caretFrame
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: terminalView.font,
            .foregroundColor: terminalView.nativeForegroundColor.withAlphaComponent(0.75),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: terminalView.nativeBackgroundColor,
        ])
        label.sizeToFit()
        label.frame.origin = caret.origin
        label.frame.size.height = caret.height
        label.isHidden = false
        terminalView.bringSubviewToFront(label)
    }

    func remove() {
        label.removeFromSuperview()
    }
}

enum MoshClock {
    static func now() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
