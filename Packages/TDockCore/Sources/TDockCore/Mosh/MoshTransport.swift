import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Mosh 的 UDP 传输与状态同步协议（SSP）客户端实现。
///
/// - 加密：AES-128-OCB3，nonce = 4 个 0 字节 + 64 位（方向位 | 序列号）。
/// - 客户端状态 = 按键/尺寸动作序列，每次发送“自服务器已确认状态以来”的增量。
/// - 服务器状态以终端差量字节流下发。客户端只保留一份屏幕状态：基于其他旧状态的差量会被丢弃，
///   服务器在其重传超时后会改发基于已确认状态的差量（丢包时最多约一个 RTO 的延迟）。
/// 所有可变状态都只在 `loop` 上访问。
final class MoshTransport: @unchecked Sendable {
    struct Callbacks {
        var hostBytes: ([UInt8]) -> Void
        var echoAck: (UInt64) -> Void
        var firstContact: () -> Void
        /// error 为 nil 表示服务器正常结束会话。
        var closed: (Error?) -> Void
    }

    static let directionToClient: UInt64 = 1 << 63
    static let heartbeatInterval: UInt64 = 3000
    static let maxFragmentContent = 1200
    static let shutdownNum = UInt64.max

    let loop: EventLoop
    private let ocb: AESOCB
    private let target: SocketAddress
    private let callbacks: Callbacks

    private var channel: Channel?
    private var rebindPending = false
    private var timer: RepeatedTask?
    private var closed = false

    // 网络层
    private var nextSeq: UInt64 = 0
    private var expectedReceiverSeq: UInt64 = 0
    private var savedTimestamp: UInt16?
    private var savedTimestampAt: UInt64 = 0
    private var srtt: Double = 1000
    private var rttvar: Double = 500
    private var haveRTT = false
    private let publishedRTT = NIOLockedValueBox<Double>(0)
    private var heardFromServer = false
    private var nextFragmentID: UInt64 = 0
    private var assembly = MoshFragmentAssembly()

    // 客户端状态（发送方）
    private var actions: [MoshUserAction] = [] // 已确认状态之后的动作
    private var stateCounts: [(num: UInt64, count: Int)] = [(0, 0)] // 状态号 → 绝对动作数
    private var currentNum: UInt64 = 0
    private var ackedNum: UInt64 = 0
    private var ackedCount = 0
    private var lastSendAt: UInt64 = 0
    private var lastNewStateSentAt: UInt64 = 0
    private var shuttingDown = false

    // 服务器状态（接收方）
    private var remoteNum: UInt64 = 0

    init(key: [UInt8], target: SocketAddress, callbacks: Callbacks) {
        loop = MultiThreadedEventLoopGroup.singleton.next()
        ocb = AESOCB(key: key)
        self.target = target
        self.callbacks = callbacks
    }

    // MARK: - Public (thread-safe)

    func start(cols: Int, rows: Int) {
        loop.execute { [self] in
            bind()
            addActions([.resize(width: cols, height: rows)])
            timer = loop.scheduleRepeatedTask(initialDelay: .milliseconds(50), delay: .milliseconds(50)) { [weak self] _ in
                self?.tick()
            }
        }
    }

    /// 发送按键（立即发包，不攒批）。completion 回调本次按键所在的客户端状态号（用于本地回显确认）。
    func send(_ bytes: [UInt8], completion: ((UInt64) -> Void)? = nil) {
        guard !bytes.isEmpty else { return }
        loop.execute { [self] in
            addActions(bytes.map { .byte($0) })
            completion?(currentNum)
        }
    }

    func resize(cols: Int, rows: Int) {
        loop.execute { [self] in addActions([.resize(width: cols, height: rows)]) }
    }

    /// 网络切换或回到前台后调用：重建 socket 并立即发包，让服务器学习新地址。
    func resume() {
        loop.execute { [self] in
            guard !closed else { return }
            rebind()
            transmit()
        }
    }

    /// 通知服务器结束会话并关闭。
    func shutdown() {
        loop.execute { [self] in
            guard !closed else { return }
            shuttingDown = true
            for _ in 0..<3 { transmit() }
            loop.scheduleTask(in: .milliseconds(300)) { [weak self] in self?.finish(error: nil, notify: false) }
        }
    }

    /// 平滑 RTT（毫秒），尚无样本时为 0。可在任意线程读取。
    var smoothedRTT: Double { publishedRTT.withLockedValue { $0 } }

    // MARK: - Socket

    private func bind() {
        let isIPv6: Bool
        if case .v6 = target { isIPv6 = true } else { isIPv6 = false }
        DatagramBootstrap(group: loop)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(DatagramHandler(transport: self))
                }
            }
            .bind(host: isIPv6 ? "::" : "0.0.0.0", port: 0)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let channel):
                    if self.closed { channel.close(promise: nil); return }
                    self.channel = channel
                    self.rebindPending = false
                    self.transmit()
                case .failure:
                    self.rebindPending = true // 网络不可用：下个 tick 重试
                }
            }
    }

    private func rebind() {
        channel?.close(promise: nil)
        channel = nil
        rebindPending = true
        bind()
    }

    // MARK: - Sending

    private func addActions(_ new: [MoshUserAction]) {
        guard !closed else { return }
        actions += new
        currentNum += 1
        stateCounts.append((currentNum, ackedCount + actions.count))
        transmit()
    }

    private func tick() {
        guard !closed else { return }
        let now = Self.now()
        if channel == nil {
            if rebindPending { bind() }
            return
        }
        let unacked = ackedNum < currentNum
        if unacked && now - lastNewStateSentAt > UInt64(rto) {
            transmit() // 重传
        } else if now - lastSendAt > Self.heartbeatInterval {
            transmit() // 心跳：保持 NAT 映射，漫游后让服务器得知新地址
        }
    }

    /// 发送当前状态（相对服务器已确认状态的增量），同时携带对服务器状态的确认。
    private func transmit() {
        guard let channel else { return }
        let newNum = shuttingDown ? Self.shutdownNum : currentNum
        let diff = MoshMessages.encodeUserMessage(actions[...])
        let instruction = MoshInstruction(
            oldNum: ackedNum, newNum: newNum, ackNum: remoteNum, throwawayNum: ackedNum, diff: diff
        )
        let now = Self.now()
        for fragment in MoshFragment.make(instruction, id: nextFragmentID, maxContent: Self.maxFragmentContent) {
            guard let datagram = try? seal(fragment.encoded(), now: now) else { continue }
            var buffer = channel.allocator.buffer(capacity: datagram.count)
            buffer.writeBytes(datagram)
            channel.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buffer)).whenFailure { [weak self] _ in
                // 发送失败（如网络切换中）：重建 socket。
                self?.loop.execute { self?.rebindPending = true; self?.channel = nil }
            }
        }
        nextFragmentID += 1
        lastSendAt = now
        if ackedNum < currentNum { lastNewStateSentAt = now }
    }

    private func seal(_ payload: [UInt8], now: UInt64) throws -> [UInt8] {
        let seq = nextSeq & ~Self.directionToClient // 方向位 0 = 发往服务器
        nextSeq += 1
        var timestampReply: UInt16 = 0xFFFF
        if let saved = savedTimestamp, now - savedTimestampAt < 1000 {
            timestampReply = saved &+ UInt16(truncatingIfNeeded: now - savedTimestampAt)
            savedTimestamp = nil
        }
        let ts = UInt16(truncatingIfNeeded: now)
        let plaintext = [UInt8(ts >> 8), UInt8(ts & 0xFF), UInt8(timestampReply >> 8), UInt8(timestampReply & 0xFF)] + payload
        let seqBytes = (0..<8).map { UInt8(truncatingIfNeeded: seq >> (56 - 8 * UInt64($0))) }
        return seqBytes + (try ocb.seal(plaintext, nonce: [0, 0, 0, 0] + seqBytes))
    }

    // MARK: - Receiving

    fileprivate func received(_ datagram: [UInt8]) {
        guard !closed, datagram.count >= 8 + AESOCB.tagLength + 4 else { return }
        let seqBytes = Array(datagram[0..<8])
        guard let plaintext = try? ocb.open(Array(datagram[8...]), nonce: [0, 0, 0, 0] + seqBytes) else { return }
        let value = seqBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard value & Self.directionToClient != 0 else { return } // 方向不符
        let seq = value & ~Self.directionToClient
        let now = Self.now()

        if seq >= expectedReceiverSeq {
            expectedReceiverSeq = seq + 1
            let timestamp = UInt16(plaintext[0]) << 8 | UInt16(plaintext[1])
            let reply = UInt16(plaintext[2]) << 8 | UInt16(plaintext[3])
            if reply != 0xFFFF {
                let sample = Double(UInt16(truncatingIfNeeded: now) &- reply)
                if sample < 5000 { updateRTT(sample) }
            }
            savedTimestamp = timestamp
            savedTimestampAt = now
        }
        if !heardFromServer {
            heardFromServer = true
            callbacks.firstContact()
        }

        guard let fragment = MoshFragment.decode(Array(plaintext[4...])),
              let compressed = assembly.add(fragment),
              let inflated = try? Zlib.decompress(compressed),
              let instruction = try? MoshInstruction.decode(inflated)
        else { return }
        handle(instruction)
    }

    private func handle(_ instruction: MoshInstruction) {
        guard instruction.protocolVersion == MoshInstruction.protocolVersion else {
            return finish(error: MoshError.protocolMismatch, notify: true)
        }
        processAck(instruction.ackNum)

        if instruction.newNum == Self.shutdownNum {
            // 服务器结束会话（远端 shell 退出）：确认后关闭。
            remoteNum = Self.shutdownNum
            transmit()
            return finish(error: nil, notify: true)
        }
        if shuttingDown, instruction.ackNum == Self.shutdownNum {
            return finish(error: nil, notify: false)
        }
        guard instruction.newNum > remoteNum else { return } // 重复
        guard instruction.oldNum == remoteNum else {
            transmit() // 基于我们没有的状态：丢弃，并立即确认当前状态
            return
        }
        guard let events = try? MoshMessages.decodeHostMessage(instruction.diff) else { return }
        remoteNum = instruction.newNum
        for event in events {
            switch event {
            case .hostBytes(let bytes): callbacks.hostBytes(bytes)
            case .echoAck(let num): callbacks.echoAck(num)
            case .resize: break // 终端尺寸由本地视图决定
            }
        }
        transmit() // 立即确认，减少服务器基于旧状态发差量的情况
    }

    private func processAck(_ num: UInt64) {
        guard num > ackedNum, num <= currentNum,
              let entry = stateCounts.first(where: { $0.num == num }) else { return }
        actions.removeFirst(entry.count - ackedCount)
        ackedNum = num
        ackedCount = entry.count
        stateCounts.removeAll { $0.num < num }
    }

    private func updateRTT(_ sample: Double) {
        if !haveRTT {
            srtt = sample
            rttvar = sample / 2
            haveRTT = true
        } else {
            rttvar = 0.75 * rttvar + 0.25 * abs(srtt - sample)
            srtt = 0.875 * srtt + 0.125 * sample
        }
        let value = srtt
        publishedRTT.withLockedValue { $0 = value }
    }

    /// 重传超时（毫秒），同 mosh：限制在 50–1000 ms。
    private var rto: Double {
        min(max(srtt + 4 * rttvar, 50), 1000)
    }

    fileprivate func finish(error: Error?, notify: Bool) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        channel?.close(promise: nil)
        channel = nil
        if notify { callbacks.closed(error) }
    }

    static func now() -> UInt64 {
        NIODeadline.now().uptimeNanoseconds / 1_000_000
    }
}

private final class DatagramHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private weak var transport: MoshTransport?

    init(transport: MoshTransport?) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        if let bytes = envelope.data.readBytes(length: envelope.data.readableBytes) {
            transport?.received(bytes)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // UDP 上的 ICMP 错误等不致命，忽略；发送失败由写回调处理。
    }
}
