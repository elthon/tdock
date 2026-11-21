import SwiftUI
import TDockCore

struct TerminalScreen: View {
    @StateObject private var controller: SessionController
    @Environment(\.dismiss) private var dismiss

    init(profile: ServerProfile) {
        _controller = StateObject(wrappedValue: SessionController(profile: profile))
    }

    var body: some View {
        SwiftTermView(terminalView: controller.terminalView)
            .background(Color.black)
            .overlay { statusOverlay }
            .navigationTitle(controller.profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { controller.connect() }
            .onDisappear { controller.disconnect() }
            .alert(
                "首次连接此主机",
                isPresented: hostKeyAlertBinding,
                presenting: controller.hostKeyPrompt
            ) { _ in
                Button("信任并连接") { controller.answerHostKeyPrompt(trust: true) }
                Button("取消", role: .cancel) { controller.answerHostKeyPrompt(trust: false) }
            } message: { prompt in
                Text("""
                \(prompt.host):\(String(prompt.port)) 的主机密钥尚未记录。
                请核对指纹后再确认：

                \(prompt.key.keyType)
                \(prompt.key.fingerprint)
                """)
            }
    }

    private var hostKeyAlertBinding: Binding<Bool> {
        Binding(
            get: { controller.hostKeyPrompt != nil },
            set: { presented in
                if !presented, controller.hostKeyPrompt != nil {
                    controller.answerHostKeyPrompt(trust: false)
                }
            }
        )
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.phase {
        case .idle, .connected:
            EmptyView()
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("正在连接 \(controller.profile.host)…")
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
        case .ended(let message):
            VStack(spacing: 16) {
                Image(systemName: message == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(message == nil ? Color.green : Color.yellow)
                Text(message ?? "会话已结束")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Button("返回") { dismiss() }
                        .buttonStyle(.bordered)
                    Button("重新连接") { controller.connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
            .padding()
        }
    }
}
