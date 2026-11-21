import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// 一条已认证的 SSH 连接。可在其上并发打开多条通道：交互式 shell、非交互 exec、
/// SFTP 子系统、direct-tcpip（端口转发）。同一主机的多个终端标签共享一个 SSHClient。
public final class SSHClient: @unchecked Sendable {
    /// 校验主机公钥：正常返回表示信任，抛出错误表示拒绝。
    public typealias HostKeyValidator = @Sendable (HostKeyInfo) async throws -> Void

    public let host: String
    public let port: Int
    public let username: String

    let channel: Channel
    private let state: ConnectionState

    private init(host: String, port: Int, username: String, channel: Channel, state: ConnectionState) {
        self.host = host
        self.port = port
        self.username = username
        self.channel = channel
        self.state = state
    }

    /// 连接并完成认证。返回即表示可以开通道。
    public static func connect(
        host: String,
        port: Int,
        username: String,
        credential: SSHCredential,
        connectTimeout: TimeAmount = .seconds(15),
        hostKeyValidator: @escaping HostKeyValidator
    ) async throws -> SSHClient {
        let state = ConnectionState()
        let userAuth = UserAuthDelegate(username: username, credential: credential, state: state)
        let hostAuth = HostKeyDelegate(validator: hostKeyValidator, state: state)

        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(connectTimeout)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                state.attach(channel)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                            role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        ),
                        ConnectionWatcher(state: state),
                    ])
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            state.connectionClosed() // 让认证 promise 完成，避免泄漏
            throw SSHSessionError.connectFailed(host: host, port: port, reason: String(describing: error))
        }
        do {
            try await state.authenticated.get()
        } catch {
            channel.close(promise: nil)
            throw state.failure ?? error
        }
        return SSHClient(host: host, port: port, username: username, channel: channel, state: state)
    }

    public var isActive: Bool { channel.isActive }

    /// 对端地址（Mosh 用它确定 UDP 目标 IP，与 SSH 实际连到的地址一致）。
    public var remoteAddress: SocketAddress? { channel.remoteAddress }

    /// 注册断线回调；若已断开则立即调用。
    public func onDisconnect(_ handler: @escaping @Sendable (Error?) -> Void) {
        state.addCloseHandler(handler)
    }

    public func close() {
        channel.close(promise: nil)
    }

    // MARK: - Channels

    /// 打开交互式终端：PTY + shell（command 为 nil）或 PTY + exec(command)。
    ///
    /// 回调在网络线程上调用；onClose 只在成功打开后、通道关闭时调用一次。
    public func openShell(
        cols: Int,
        rows: Int,
        command: String? = nil,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onClose: @escaping @Sendable (SSHShellChannel.CloseReason) -> Void
    ) async throws -> SSHShellChannel {
        let handler = SessionChannelHandler { _, buffer in
            if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                onOutput(bytes)
            }
        }
        let child = try await openSessionChannel(handler: handler)
        do {
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: max(cols, 1),
                terminalRowHeight: max(rows, 1),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            try await handler.request(pty, on: child)
            for (name, value) in environment {
                // 服务器多半只接受 AcceptEnv 白名单中的变量，失败不影响会话。
                let env = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
                child.triggerUserOutboundEvent(env, promise: nil)
            }
            if let command {
                try await handler.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), on: child)
            } else {
                try await handler.request(SSHChannelRequestEvent.ShellRequest(wantReply: true), on: child)
            }
        } catch {
            child.close(promise: nil)
            throw error
        }
        child.closeFuture.whenComplete { _ in
            onClose(.init(exitStatus: handler.exitStatus, error: handler.error))
        }
        return SSHShellChannel(channel: child)
    }

    /// 执行非交互命令，收集全部输出。
    public func exec(_ command: String, timeout: TimeAmount = .seconds(20)) async throws -> SSHExecResult {
        let output = NIOLockedValueBox((out: [UInt8](), err: [UInt8]()))
        let handler = SessionChannelHandler { isStdErr, buffer in
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            output.withLockedValue { isStdErr ? $0.err.append(contentsOf: bytes) : $0.out.append(contentsOf: bytes) }
        }
        handler.closeOnEOF = true
        let child = try await openSessionChannel(handler: handler)
        let timedOut = NIOLockedValueBox(false)
        let timer = child.eventLoop.scheduleTask(in: timeout) {
            timedOut.withLockedValue { $0 = true }
            child.close(promise: nil)
        }
        defer { timer.cancel() }
        do {
            try await handler.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), on: child)
        } catch {
            child.close(promise: nil)
            throw timedOut.withLockedValue { $0 } ? SSHSessionError.timeout : error
        }
        try? await child.closeFuture.get()
        if timedOut.withLockedValue({ $0 }) { throw SSHSessionError.timeout }
        let (out, err) = output.withLockedValue { ($0.out, $0.err) }
        return SSHExecResult(
            exitStatus: handler.exitStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    /// 打开一条 session 通道并装上给定 handler（供 shell / exec / 子系统使用）。
    func openSessionChannel(handler: SessionChannelHandler) async throws -> Channel {
        try await createChildChannel(.session) { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(handler) }
            }
        }
    }

    func createChildChannel(
        _ type: SSHChannelType,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        try await createChildChannelFuture(type, initializer: initializer).get()
    }

    func createChildChannelFuture(
        _ type: SSHChannelType,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let parent = channel
        guard parent.isActive else { return parent.eventLoop.makeFailedFuture(SSHSessionError.connectionClosed) }
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        // 父连接若在通道打开前断开，确保等待方不会挂起（已完成的 promise 再次完成会被忽略）。
        parent.closeFuture.whenComplete { _ in opened.fail(SSHSessionError.connectionClosed) }
        parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                opened.fail(error)
            case .success(let ssh):
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete { opened.completeWith($0) }
                ssh.createChannel(promise, channelType: type) { child, _ in initializer(child) }
            }
        }
        return opened.futureResult
    }
}

/// 交互式终端通道。所有方法线程安全。
public final class SSHShellChannel: @unchecked Sendable {
    public struct CloseReason: Sendable {
        public var exitStatus: Int?
        public var error: Error?
    }

    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    /// 立即写出并 flush（按键不攒批）。
    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    public var isActive: Bool { channel.isActive }

    public func close() {
        channel.close(promise: nil)
    }
}

// MARK: - Connection internals

/// 连接级共享状态：首个具体错误、认证完成信号、断线回调。
final class ConnectionState: @unchecked Sendable {
    private struct Inner {
        var channel: Channel?
        var authPromise: EventLoopPromise<Void>?
        var authFuture: EventLoopFuture<Void>?
        var failure: Error?
        var closed = false
        var closeHandlers: [@Sendable (Error?) -> Void] = []
    }

    private let inner = NIOLockedValueBox(Inner())

    /// 每次尝试连接（可能对多个解析地址依次尝试）都会调用；认证 promise 只创建一次。
    func attach(_ channel: Channel) {
        // NIOSSHHandler 不向后续 handler 转发 channelInactive，所以用 closeFuture 感知断开。
        channel.closeFuture.whenComplete { [weak self] _ in self?.connectionClosed() }
        inner.withLockedValue {
            $0.channel = channel
            if $0.authFuture == nil {
                let promise = channel.eventLoop.makePromise(of: Void.self)
                $0.authPromise = promise
                $0.authFuture = promise.futureResult
            }
        }
    }

    var authenticated: EventLoopFuture<Void> {
        inner.withLockedValue { $0.authFuture }!
    }

    var failure: Error? { inner.withLockedValue { $0.failure } }

    /// 记录首个具体错误（如认证失败），后续的通用 NIO 错误不覆盖它。
    func record(_ error: Error) {
        inner.withLockedValue { state in
            if state.failure == nil || (error is SSHSessionError && !(state.failure is SSHSessionError)) {
                state.failure = error
            }
        }
    }

    func authSucceeded() {
        let promise = inner.withLockedValue { state -> EventLoopPromise<Void>? in
            defer { state.authPromise = nil }
            return state.authPromise
        }
        promise?.succeed(())
    }

    func closeConnection() {
        inner.withLockedValue { $0.channel }?.close(promise: nil)
    }

    func connectionClosed() {
        let (promise, handlers, failure) = inner.withLockedValue { state in
            defer {
                state.authPromise = nil
                state.closed = true
                state.closeHandlers = []
            }
            return (state.authPromise, state.closeHandlers, state.failure)
        }
        promise?.fail(failure ?? SSHSessionError.connectionClosed)
        handlers.forEach { $0(failure) }
    }

    func addCloseHandler(_ handler: @escaping @Sendable (Error?) -> Void) {
        let alreadyClosed = inner.withLockedValue { state -> Error?? in
            if state.closed { return .some(state.failure) }
            state.closeHandlers.append(handler)
            return .none
        }
        if case .some(let error) = alreadyClosed { handler(error) }
    }
}

private final class ConnectionWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let state: ConnectionState

    init(state: ConnectionState) {
        self.state = state
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            state.authSucceeded()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.record(error)
        context.close(promise: nil)
    }

}

// 两个 delegate 只在单个连接的事件循环上被调用。
private final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let credential: SSHCredential
    private let state: ConnectionState
    private var attempted = false

    init(username: String, credential: SSHCredential, state: ConnectionState) {
        self.username = username
        self.credential = credential
        self.state = state
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // 只尝试一次用户配置的方式；再次被询问说明认证被拒绝。
        guard !attempted else {
            // 首次询问时服务器尚未告知可用方式；被拒后若列表中已没有我们的方式，说明服务器不支持它。
            let supported: Bool
            switch credential {
            case .password: supported = availableMethods.contains(.password)
            case .privateKey: supported = availableMethods.contains(.publicKey)
            }
            return fail(nextChallengePromise, supported ? .authenticationFailed : .noSupportedAuthMethod)
        }
        attempted = true

        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                return fail(nextChallengePromise, .noSupportedAuthMethod)
            }
            nextChallengePromise.succeed(.init(
                username: username, serviceName: "", offer: .password(.init(password: password))
            ))
        case .privateKey(let key):
            guard availableMethods.contains(.publicKey) else {
                return fail(nextChallengePromise, .noSupportedAuthMethod)
            }
            nextChallengePromise.succeed(.init(
                username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))
            ))
        }
    }

    /// 放弃认证。NIOSSH 在没有更多认证方式时不会主动断开，需要自己关闭连接。
    private func fail(_ promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>, _ error: SSHSessionError) {
        state.record(error)
        promise.succeed(nil)
        state.closeConnection()
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let validator: SSHClient.HostKeyValidator
    private let state: ConnectionState

    init(validator: @escaping SSHClient.HostKeyValidator, state: ConnectionState) {
        self.validator = validator
        self.state = state
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(hostKey)
        let validator = self.validator
        let state = self.state
        Task {
            do {
                try await validator(info)
                validationCompletePromise.succeed(())
            } catch {
                state.record(error)
                validationCompletePromise.fail(error)
            }
        }
    }
}
