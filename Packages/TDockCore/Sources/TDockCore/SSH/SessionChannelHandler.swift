import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// session 类通道（shell / exec / 子系统）的通用 handler：
/// 转发收到的数据、按顺序匹配通道请求的应答、记录退出码。
final class SessionChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    /// (是否 stderr, 数据)，在事件循环线程上调用。
    private let onData: (Bool, ByteBuffer) -> Void
    /// 远端关闭输出（EOF）后是否主动关闭通道。
    var closeOnEOF = true

    // 以下仅在事件循环上访问。
    private var pendingReplies = CircularBuffer<EventLoopPromise<Void>>()
    private var context: ChannelHandlerContext?

    private let status = NIOLockedValueBox<(exit: Int?, error: Error?)>((nil, nil))
    var exitStatus: Int? { status.withLockedValue { $0.exit } }
    var error: Error? { status.withLockedValue { $0.error } }

    init(onData: @escaping (Bool, ByteBuffer) -> Void) {
        self.onData = onData
    }

    /// 发送一个 wantReply 的通道请求并等待服务器应答（SSH 规定同一通道的应答按请求顺序返回）。
    func request(_ event: Any, on channel: Channel) async throws {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            guard self.context != nil, channel.isActive else {
                promise.fail(SSHSessionError.connectionClosed)
                return
            }
            self.pendingReplies.append(promise)
            channel.triggerUserOutboundEvent(event).whenFailure { _ in
                // 写失败时关闭通道，channelInactive 会让所有挂起的应答失败。
                channel.close(promise: nil)
            }
        }
        try await promise.futureResult.get()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        onData(message.type == .stdErr, buffer)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingReplies.popFirst()?.succeed(())
        case is ChannelFailureEvent:
            pendingReplies.popFirst()?.fail(SSHSessionError.channelRequestFailed)
        case let exit as SSHChannelRequestEvent.ExitStatus:
            status.withLockedValue { $0.exit = exit.exitStatus }
        case let event as ChannelEvent where event == .inputClosed:
            if closeOnEOF { context.close(promise: nil) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        while let promise = pendingReplies.popFirst() {
            promise.fail(SSHSessionError.connectionClosed)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        status.withLockedValue { if $0.error == nil { $0.error = error } }
        context.close(promise: nil)
    }
}
