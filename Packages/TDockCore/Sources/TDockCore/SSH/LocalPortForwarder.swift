import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

public enum PortForwardError: Error, LocalizedError, Equatable {
    case localPortUnavailable(Int, String)

    public var errorDescription: String? {
        switch self {
        case .localPortUnavailable(let port, let reason):
            return "无法监听本地端口 \(port)（可能已被占用）：\(reason)"
        }
    }
}

/// 本地端口转发：监听 127.0.0.1:localPort，每个入站 TCP 连接开一条 direct-tcpip 通道到 remoteHost:remotePort。
public final class LocalPortForwarder: @unchecked Sendable {
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int

    private let listener: Channel
    private let connections = NIOLockedValueBox(0)

    private init(listener: Channel, localPort: Int, remoteHost: String, remotePort: Int) {
        self.listener = listener
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    /// 开始转发。只绑定回环地址，不向局域网暴露端口。
    public static func start(
        client: SSHClient,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        onConnectionCountChange: (@Sendable (Int) -> Void)? = nil
    ) async throws -> LocalPortForwarder {
        let counter = NIOLockedValueBox(0)
        // 监听与入站连接都放在 SSH 连接自己的事件循环上：两端 glue 同线程，无需跨线程同步。
        let loop = client.channel.eventLoop
        let bootstrap = ServerBootstrap(group: loop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { inbound in
                let originator = inbound.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                let (local, remote) = GlueHandler.matchedPair()
                let type = SSHChannelType.directTCPIP(.init(
                    targetHost: remoteHost, targetPort: remotePort, originatorAddress: originator
                ))
                return inbound.pipeline.addHandler(local).flatMap {
                    client.createChildChannelFuture(type) { sshChild in
                        sshChild.eventLoop.makeCompletedFuture {
                            try sshChild.pipeline.syncOperations.addHandlers([SSHDataUnwrapper(), remote])
                        }
                    }
                }
                .map { sshChild in
                    let count = counter.withLockedValue { $0 += 1; return $0 }
                    onConnectionCountChange?(count)
                    inbound.closeFuture.whenComplete { _ in
                        sshChild.close(promise: nil)
                        let count = counter.withLockedValue { $0 -= 1; return $0 }
                        onConnectionCountChange?(count)
                    }
                }
                // 失败（如目标拒绝连接）时 NIO 会关闭该入站连接。
            }

        let listener: Channel
        do {
            listener = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        } catch {
            throw PortForwardError.localPortUnavailable(localPort, String(describing: error))
        }
        // SSH 连接断开时停止监听。
        client.onDisconnect { _ in listener.close(promise: nil) }
        return LocalPortForwarder(listener: listener, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }

    /// 实际绑定的端口（localPort 为 0 时由系统分配）。
    public var boundPort: Int { listener.localAddress?.port ?? localPort }

    public var isRunning: Bool { listener.isActive }

    public func stop() {
        listener.close(promise: nil)
    }

    /// 监听停止时回调。
    public func onStop(_ handler: @escaping @Sendable () -> Void) {
        listener.closeFuture.whenComplete { _ in handler() }
    }
}

/// SSH 子通道上 SSHChannelData ⇄ ByteBuffer 的转换。
private final class SSHDataUnwrapper: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let buffer) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// 把两条通道首尾相连，带写缓冲背压（对端不可写时暂停读取）。
/// 两端必须位于同一事件循环（LocalPortForwarder 保证这一点）。
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerClose() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool { partner?.context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClose()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            partner?.partnerClose()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
