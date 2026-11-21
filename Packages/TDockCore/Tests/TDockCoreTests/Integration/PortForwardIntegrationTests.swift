import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import TDockCore

final class PortForwardIntegrationTests: XCTestCase {
    func testForwardsEchoTraffic() async throws {
        let config = try IntegrationConfig.load()
        let echo = try await EchoServer.start()
        defer { echo.close(promise: nil) }

        let client = try await config.connect()
        defer { client.close() }
        let counts = NIOLockedValueBox<[Int]>([])
        let forwarder = try await LocalPortForwarder.start(
            client: client, localPort: 0, remoteHost: "127.0.0.1", remotePort: echo.localAddress!.port!
        ) { count in counts.withLockedValue { $0.append(count) } }
        defer { forwarder.stop() }

        // 三个并发连接，各发 256 KB（超过 SSH 窗口，覆盖背压路径）。
        try await withThrowingTaskGroup(of: Void.self) { group in
            for seed in 0..<3 {
                group.addTask {
                    let payload = (0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }
                    let received = try await TCPProbe.roundTrip(port: forwarder.boundPort, payload: payload)
                    XCTAssertEqual(received, payload)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(counts.withLockedValue { $0.max() }.map { $0 >= 1 }, true)
    }

    func testUnreachableTargetClosesConnection() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let forwarder = try await LocalPortForwarder.start(client: client, localPort: 0, remoteHost: "127.0.0.1", remotePort: 1)
        defer { forwarder.stop() }
        let received = try await TCPProbe.roundTrip(port: forwarder.boundPort, payload: Array("hi".utf8))
        XCTAssertEqual(received, [], "目标拒绝时本地连接应被关闭")
        XCTAssertTrue(client.isActive)
    }

    func testPortInUse() async throws {
        let config = try IntegrationConfig.load()
        let client = try await config.connect()
        defer { client.close() }
        let first = try await LocalPortForwarder.start(client: client, localPort: 0, remoteHost: "127.0.0.1", remotePort: 22)
        defer { first.stop() }
        do {
            _ = try await LocalPortForwarder.start(client: client, localPort: first.boundPort, remoteHost: "127.0.0.1", remotePort: 22)
            XCTFail("端口占用时应失败")
        } catch let error as PortForwardError {
            guard case .localPortUnavailable(let port, _) = error else { return XCTFail() }
            XCTAssertEqual(port, first.boundPort)
        }
    }
}

/// 测试用 TCP 回显服务器。
enum EchoServer {
    static func start() async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.write(data, promise: nil)
        }
        func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }
    }
}

/// 连接到本地端口、发送数据、读回同样长度（或直到对端关闭）。
enum TCPProbe {
    static func roundTrip(port: Int, payload: [UInt8], timeout: TimeAmount = .seconds(15)) async throws -> [UInt8] {
        let done = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: [UInt8].self)
        let collector = Collector(expected: payload.count, done: done)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: port).get()
        let timer = channel.eventLoop.scheduleTask(in: timeout) { done.fail(SSHSessionError.timeout) }
        defer { timer.cancel() }
        try await channel.writeAndFlush(ByteBuffer(bytes: payload)).get()
        let result = try await done.futureResult.get()
        channel.close(promise: nil)
        return result
    }

    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private var bytes: [UInt8] = []
        private let expected: Int
        private let done: EventLoopPromise<[UInt8]>

        init(expected: Int, done: EventLoopPromise<[UInt8]>) {
            self.expected = expected
            self.done = done
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
            if bytes.count >= expected { done.succeed(bytes) }
        }

        func channelInactive(context: ChannelHandlerContext) {
            done.succeed(bytes)
        }
    }
}
