import SwiftTerm
import SwiftUI

/// 把 SessionController 持有的 TerminalView 嵌入 SwiftUI。
/// TerminalView 由 controller 持有，视图重建时不会丢失终端内容。
struct SwiftTermView: UIViewRepresentable {
    let terminalView: TerminalView

    func makeUIView(context: Context) -> TerminalView {
        terminalView
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
