import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// SFTP v3 客户端，运行在 SSHClient 的一条 `sftp` 子系统通道上。所有方法线程安全。
public final class SFTPClient: @unchecked Sendable {
    /// 单次读写块大小与并发请求数（流水线化，减少往返等待）。
    static let chunkSize = 32 * 1024
    static let window = 16

    private struct State {
        var nextID: UInt32 = 1
        var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
        var framer = SFTPFramer()
        var versionReceived: EventLoopPromise<Void>?
        var closed = false
    }

    private var channel: Channel!
    private let state = NIOLockedValueBox(State())

    private init() {}

    deinit {
        // 通道关闭回调只持有弱引用；对象先释放时由这里完成所有挂起请求。
        failAll()
    }

    /// 在已连接的 SSHClient 上打开 SFTP 会话。
    static func open(on client: SSHClient) async throws -> SFTPClient {
        let sftp = SFTPClient()
        let handler = SessionChannelHandler { [weak sftp] isStdErr, buffer in
            if !isStdErr { sftp?.received(buffer) }
        }
        let channel = try await client.openSessionChannel(handler: handler)
        sftp.channel = channel
        channel.closeFuture.whenComplete { [weak sftp] _ in sftp?.failAll() }

        let version = channel.eventLoop.makePromise(of: Void.self)
        sftp.state.withLockedValue { $0.versionReceived = version }
        do {
            try await handler.request(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true), on: channel)
            var packet = channel.allocator.buffer(capacity: 9)
            packet.writeInteger(UInt8(SFTPPacketType.initialize.rawValue))
            packet.writeInteger(UInt32(3))
            sftp.write(packet)
            try await version.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw error is SSHSessionError ? SFTPError(code: SFTPError.Code.unsupported.rawValue, message: "服务器未启用 SFTP 子系统") : error
        }
        return sftp
    }

    public func close() {
        channel.close(promise: nil)
    }

    // MARK: - Operations

    /// 规范化路径（"." 得到登录目录）。
    public func realPath(_ path: String) async throws -> String {
        let response = try await request(.realpath) { $0.writeSFTPString(path) }
        guard case .name(let entries) = response, let first = entries.first else { throw try unexpected(response) }
        return first.name
    }

    public func stat(_ path: String) async throws -> SFTPAttributes {
        let response = try await request(.stat) { $0.writeSFTPString(path) }
        guard case .attrs(let attrs) = response else { throw try unexpected(response) }
        return attrs
    }

    /// 列出目录（不含 . 和 ..），目录在前、按名称排序。
    public func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        let handle = try await openHandle(.opendir) { $0.writeSFTPString(path) }
        defer { closeHandle(handle) }
        var entries: [SFTPEntry] = []
        while true {
            let response = try await request(.readdir) { $0.writeSFTPString(handle) }
            switch response {
            case .name(let batch):
                entries.append(contentsOf: batch.filter { $0.name != "." && $0.name != ".." })
            case .status(let code, _) where code == SFTPError.eof:
                return entries.sorted {
                    $0.isDirectory != $1.isDirectory
                        ? $0.isDirectory
                        : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            default:
                throw try unexpected(response)
            }
        }
    }

    /// 下载远程文件到本地路径。progress(已传输字节数, 总字节数?)。
    public func download(
        _ remotePath: String,
        to localURL: URL,
        progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        let total = try? await stat(remotePath).size
        let handle = try await openHandle(.open) {
            $0.writeSFTPString(remotePath)
            $0.writeInteger(SFTPOpenFlags.read.rawValue)
            SFTPAttributes().write(to: &$0)
        }
        defer { closeHandle(handle) }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }

        var inFlight: [(offset: UInt64, future: EventLoopFuture<SFTPResponse>)] = []
        var nextOffset: UInt64 = 0
        var written: UInt64 = 0
        var reachedEOF = false

        func issue() {
            let offset = nextOffset
            nextOffset += UInt64(Self.chunkSize)
            inFlight.append((offset, send(.read) {
                $0.writeSFTPString(handle)
                $0.writeInteger(offset)
                $0.writeInteger(UInt32(Self.chunkSize))
            }))
        }

        for _ in 0..<Self.window { issue() }
        while !inFlight.isEmpty {
            let (offset, future) = inFlight.removeFirst()
            let response = try await future.get()
            if reachedEOF { continue } // 排空 EOF 之后多发的请求
            switch response {
            case .data(var data):
                let count = data.readableBytes
                try file.write(contentsOf: data.readBytes(length: count) ?? [])
                written = offset + UInt64(count)
                // 短读（非 EOF）：按顺序补读缺口，保证文件连续。
                var gapOffset = written
                while gapOffset < offset + UInt64(Self.chunkSize) {
                    let gap = try await request(.read) {
                        $0.writeSFTPString(handle)
                        $0.writeInteger(gapOffset)
                        $0.writeInteger(UInt32(offset + UInt64(Self.chunkSize) - gapOffset))
                    }
                    guard case .data(var more) = gap else {
                        if case .status(let code, _) = gap, code == SFTPError.eof { reachedEOF = true; break }
                        throw try unexpected(gap)
                    }
                    let n = more.readableBytes
                    try file.write(contentsOf: more.readBytes(length: n) ?? [])
                    gapOffset += UInt64(n)
                    written = gapOffset
                }
                progress?(written, total)
                if !reachedEOF { issue() }
            case .status(let code, _) where code == SFTPError.eof:
                reachedEOF = true
            default:
                throw try unexpected(response)
            }
        }
        progress?(written, total)
    }

    /// 上传本地文件到远程路径（覆盖已存在的文件）。
    public func upload(
        _ localURL: URL,
        to remotePath: String,
        progress: (@Sendable (UInt64, UInt64?) -> Void)? = nil
    ) async throws {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value

        let handle = try await openHandle(.open) {
            $0.writeSFTPString(remotePath)
            $0.writeInteger((SFTPOpenFlags.write.union([.create, .truncate])).rawValue)
            SFTPAttributes(permissions: 0o644).write(to: &$0)
        }
        defer { closeHandle(handle) }

        var inFlight: [(end: UInt64, future: EventLoopFuture<SFTPResponse>)] = []
        var offset: UInt64 = 0
        var done = false
        while !done || !inFlight.isEmpty {
            while !done && inFlight.count < Self.window {
                let chunk = try file.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { done = true; break }
                let chunkOffset = offset
                offset += UInt64(chunk.count)
                inFlight.append((offset, send(.write) {
                    $0.writeSFTPString(handle)
                    $0.writeInteger(chunkOffset)
                    $0.writeSFTPString(bytes: chunk)
                }))
            }
            guard !inFlight.isEmpty else { break }
            let (end, future) = inFlight.removeFirst()
            try ensureOK(try await future.get())
            progress?(end, total)
        }
    }

    // MARK: - Plumbing

    private func openHandle(_ type: SFTPPacketType, _ body: (inout ByteBuffer) -> Void) async throws -> ByteBuffer {
        let response = try await request(type, body)
        guard case .handle(let handle) = response else { throw try unexpected(response) }
        return handle
    }

    private func closeHandle(_ handle: ByteBuffer) {
        _ = send(.close) { $0.writeSFTPString(handle) }
    }

    private func request(_ type: SFTPPacketType, _ body: (inout ByteBuffer) -> Void) async throws -> SFTPResponse {
        try await send(type, body).get()
    }

    /// 发送请求，返回应答 future（不等待，便于流水线）。
    private func send(_ type: SFTPPacketType, _ body: (inout ByteBuffer) -> Void) -> EventLoopFuture<SFTPResponse> {
        let promise = channel.eventLoop.makePromise(of: SFTPResponse.self)
        let id: UInt32? = state.withLockedValue { state in
            guard !state.closed else { return nil }
            let id = state.nextID
            state.nextID &+= 1
            state.pending[id] = promise
            return id
        }
        guard let id else {
            promise.fail(SFTPError.closed)
            return promise.futureResult
        }
        var payload = channel.allocator.buffer(capacity: 64)
        payload.writeInteger(type.rawValue)
        payload.writeInteger(id)
        body(&payload)
        write(payload)
        return promise.futureResult
    }

    private func write(_ payload: ByteBuffer) {
        var packet = channel.allocator.buffer(capacity: payload.readableBytes + 4)
        packet.writeInteger(UInt32(payload.readableBytes))
        packet.writeImmutableBuffer(payload)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(packet)), promise: nil)
    }

    /// 在事件循环上调用：切分报文并分发给等待方。
    private func received(_ bytes: ByteBuffer) {
        var completions: [(EventLoopPromise<SFTPResponse>, SFTPResponse)] = []
        var versionPromise: EventLoopPromise<Void>?
        var protocolError = false
        state.withLockedValue { state in
            state.framer.append(bytes)
            do {
                while var packet = try state.framer.next() {
                    let (id, response) = try SFTPResponse.parse(&packet)
                    if let id, let response, let promise = state.pending.removeValue(forKey: id) {
                        completions.append((promise, response))
                    } else if id == nil, let promise = state.versionReceived {
                        state.versionReceived = nil
                        versionPromise = promise
                    }
                }
            } catch {
                protocolError = true
            }
        }
        versionPromise?.succeed(())
        completions.forEach { $0.0.succeed($0.1) }
        if protocolError { channel.close(promise: nil) }
    }

    private func failAll() {
        let (pending, version) = state.withLockedValue { state in
            defer {
                state.pending = [:]
                state.versionReceived = nil
                state.closed = true
            }
            return (Array(state.pending.values), state.versionReceived)
        }
        pending.forEach { $0.fail(SFTPError.closed) }
        version?.fail(SFTPError.closed)
    }

    private func ensureOK(_ response: SFTPResponse) throws {
        guard case .status(let code, _) = response, code == 0 else { throw try unexpected(response) }
    }

    private func unexpected(_ response: SFTPResponse) throws -> Error {
        if case .status(let code, let message) = response {
            return SFTPError(code: code, message: message)
        }
        return SFTPError.malformed
    }
}

extension SSHClient {
    /// 打开 SFTP 会话（与终端共享同一条 SSH 连接）。
    public func openSFTP() async throws -> SFTPClient {
        try await SFTPClient.open(on: self)
    }
}
