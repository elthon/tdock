import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHSessionError: Error, LocalizedError {
    case connectFailed(host: String, port: Int, reason: String)
    case authenticationFailed
    case noSupportedAuthMethod
    case hostKeyRejected
    case hostKeyMismatch(expected: String, actual: String)
    case channelRequestFailed
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let host, let port, let reason):
            return "无法连接到 \(host):\(port)，请检查地址、端口和网络。\n(\(reason))"
        case .authenticationFailed:
            return "认证失败：用户名、密码或私钥不正确"
        case .noSupportedAuthMethod:
            return "服务器不接受当前的认证方式"
        case .hostKeyRejected:
            return "已拒绝信任该主机"
        case .hostKeyMismatch(let expected, let actual):
            return "主机密钥与之前记录的不一致，可能存在中间人攻击，已中止连接。\n记录：\(expected)\n当前：\(actual)"
        case .channelRequestFailed:
            return "服务器拒绝了终端（PTY/shell）请求"
        case .connectionClosed:
            return "连接已被服务器关闭"
        }
    }
}

/// 服务器主机公钥信息，用于 TOFU 校验。
public struct HostKeyInfo: Sendable, Equatable {
    /// 例如 `ssh-ed25519`
    public let keyType: String
    /// OpenSSH 风格指纹，例如 `SHA256:abc...`
    public let fingerprint: String

    init(_ key: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: key)
        let parts = openSSH.split(separator: " ")
        keyType = parts.first.map(String.init) ?? "unknown"
        let blob = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data() : Data()
        fingerprint = HostKeyInfo.fingerprint(ofKeyBlob: blob)
    }

    public init(keyType: String, fingerprint: String) {
        self.keyType = keyType
        self.fingerprint = fingerprint
    }

    static func fingerprint(ofKeyBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

/// 一个带 PTY 的交互式 SSH shell 会话。
///
/// 使用方式：设置 `onOutput` / `onClose` 后调用 `start()`；
/// 用 `send(_:)` 发送键盘输入，用 `resize(cols:rows:)` 同步终端尺寸。
/// 回调在 NIO 事件循环线程上调用，UI 层需自行切回主线程。
public final class SSHShellSession: @unchecked Sendable {
    public enum Credential {
        case password(String)
        case privateKey(NIOSSHPrivateKey)
    }

    /// 校验主机公钥：正常返回表示信任，抛出错误表示拒绝。
    public typealias HostKeyValidator = @Sendable (HostKeyInfo) async throws -> Void

    public var onOutput: (@Sendable ([UInt8]) -> Void)?
    /// 会话结束时调用一次；正常退出时 error 为 nil。
    public var onClose: (@Sendable (Error?) -> Void)?

    private let host: String
    private let port: Int
    private let username: String
    private let credential: Credential
    private let hostKeyValidator: HostKeyValidator
    private let initialSize: (cols: Int, rows: Int)

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let failure = NIOLockedValueBox<Error?>(nil)
    private struct State {
        var connection: Channel?
        var shell: Channel?
        var started = false
        var closed = false
    }

    private let state = NIOLockedValueBox(State())

    public init(
        host: String,
        port: Int,
        username: String,
        credential: Credential,
        initialSize: (cols: Int, rows: Int),
        hostKeyValidator: @escaping HostKeyValidator
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.initialSize = initialSize
        self.hostKeyValidator = hostKeyValidator
    }

    deinit {
        group.shutdownGracefully { _ in }
    }

    /// 连接、认证并打开 shell。返回即表示终端可用。
    public func start() async throws {
        do {
            try await connectAndOpenShell()
        } catch {
            let reported = recordFailure(error)
            let connection = state.withLockedValue { state -> Channel? in
                state.closed = true
                state.shell = nil
                return state.connection
            }
            connection?.close(promise: nil)
            throw reported
        }
        let closedEarly = state.withLockedValue { state -> Bool in
            state.started = true
            return state.closed
        }
        // 远端在 start() 返回前就关闭了会话（例如登录后立即退出）。
        if closedEarly { onClose?(failure.withLockedValue { $0 }) }
    }

    public func send(_ bytes: [UInt8]) {
        guard let shell = state.withLockedValue({ $0.shell }) else { return }
        var buffer = shell.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let shell = state.withLockedValue({ $0.shell }) else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        shell.triggerUserOutboundEvent(request, promise: nil)
    }

    /// 主动断开。
    public func close() {
        let connection = state.withLockedValue { $0.connection }
        connection?.close(promise: nil)
    }

    // MARK: - Internals

    private func connectAndOpenShell() async throws {
        let userAuth = UserAuthDelegate(username: username, credential: credential, session: self)
        let hostAuth = HostKeyDelegate(validator: hostKeyValidator, session: self)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { [weak self] channel in
                self?.state.withLockedValue { $0.connection = channel }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                            role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        ),
                        ErrorCaptureHandler { error in self?.recordFailure(error) },
                    ])
                }
            }

        let connection: Channel
        do {
            connection = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw SSHSessionError.connectFailed(host: host, port: port, reason: String(describing: error))
        }

        // NIOSSH 会在认证完成后才真正打开子通道；若认证或主机校验失败导致连接关闭，
        // 待创建的子通道 promise 不会被完成，所以由连接关闭事件兜底让它失败。
        let shellReady = connection.eventLoop.makePromise(of: Channel.self)
        let shellSettled = NIOLockedValueBox(false)
        let settle: @Sendable (Result<Channel, Error>) -> Void = { result in
            let first = shellSettled.withLockedValue { settled -> Bool in
                defer { settled = true }
                return !settled
            }
            if first { shellReady.completeWith(result) }
        }
        connection.closeFuture.whenComplete { [weak self] _ in
            let error = self?.failure.withLockedValue { $0 }
            settle(.failure(error ?? SSHSessionError.connectionClosed))
            self?.finish(error: error)
        }

        connection.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                settle(.failure(error))
            case .success(let ssh):
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                promise.futureResult.whenComplete(settle)
                ssh.createChannel(promise) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHSessionError.channelRequestFailed)
                    }
                    return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(
                                ShellChannelHandler(
                                    onOutput: { self?.onOutput?($0) },
                                    onFailure: { self?.recordFailure($0) }
                                )
                            )
                        }
                    }
                }
            }
        }
        let shell = try await shellReady.futureResult.get()
        state.withLockedValue { $0.shell = shell }
        shell.closeFuture.whenComplete { _ in connection.close(promise: nil) }

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: initialSize.cols,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await shell.triggerUserOutboundEvent(pty).get()
        try await shell.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
    }

    /// 记录首个具体错误（如认证失败），后续的通用 NIO 错误不覆盖它。返回应报告给上层的错误。
    @discardableResult
    fileprivate func recordFailure(_ error: Error) -> Error {
        failure.withLockedValue { stored in
            if stored == nil || (error is SSHSessionError && !(stored is SSHSessionError)) {
                stored = error
            }
            return stored!
        }
    }

    /// 连接关闭时调用。仅当 start() 已成功返回时才通知 onClose，否则错误由 start() 抛出。
    private func finish(error: Error?) {
        let shouldNotify = state.withLockedValue { state -> Bool in
            defer { state.closed = true; state.shell = nil }
            return state.started && !state.closed
        }
        if shouldNotify { onClose?(error) }
    }
}

// MARK: - Delegates & handlers

// 只在单个连接的事件循环上被调用。
private final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let credential: SSHShellSession.Credential
    private weak var session: SSHShellSession?
    private var attempted = false

    init(username: String, credential: SSHShellSession.Credential, session: SSHShellSession) {
        self.username = username
        self.credential = credential
        self.session = session
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
                return fail(nextChallengePromise, SSHSessionError.noSupportedAuthMethod)
            }
            nextChallengePromise.succeed(.init(
                username: username, serviceName: "", offer: .password(.init(password: password))
            ))
        case .privateKey(let key):
            guard availableMethods.contains(.publicKey) else {
                return fail(nextChallengePromise, SSHSessionError.noSupportedAuthMethod)
            }
            nextChallengePromise.succeed(.init(
                username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))
            ))
        }
    }

    /// 放弃认证。NIOSSH 在没有更多认证方式时不会主动断开，需要自己关闭连接。
    private func fail(_ promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>, _ error: SSHSessionError) {
        session?.recordFailure(error)
        promise.succeed(nil)
        session?.close()
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let validator: SSHShellSession.HostKeyValidator
    private weak var session: SSHShellSession?

    init(validator: @escaping SSHShellSession.HostKeyValidator, session: SSHShellSession) {
        self.validator = validator
        self.session = session
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(hostKey)
        let validator = self.validator
        let session = self.session
        Task {
            do {
                try await validator(info)
                validationCompletePromise.succeed(())
            } catch {
                session?.recordFailure(error)
                validationCompletePromise.fail(error)
            }
        }
    }
}

private final class ShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let onOutput: ([UInt8]) -> Void
    private let onFailure: (Error) -> Void

    init(onOutput: @escaping ([UInt8]) -> Void, onFailure: @escaping (Error) -> Void) {
        self.onOutput = onOutput
        self.onFailure = onFailure
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        // stdout 与 stderr 都输出到终端。
        guard case .byteBuffer(let buffer) = message.data,
              let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes)
        else { return }
        onOutput(bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as ChannelEvent where event == .inputClosed:
            // 远端关闭输出（例如执行了 exit）。
            context.close(promise: nil)
        case is ChannelFailureEvent:
            onFailure(SSHSessionError.channelRequestFailed)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onFailure(error)
        context.close(promise: nil)
    }
}

private final class ErrorCaptureHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}
