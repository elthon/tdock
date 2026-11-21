/// Mosh 线上消息：protobuf（手写编解码）、传输层指令、用户/主机消息、分片。
/// 字段编号与 mosh 源码中的 transportinstruction.proto / userinput.proto / hostinput.proto 一致。

// MARK: - Protobuf

struct ProtoWriter {
    var bytes: [UInt8] = []

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        rawVarint(value)
    }

    mutating func data(_ field: Int, _ value: [UInt8]) {
        key(field, wireType: 2)
        rawVarint(UInt64(value.count))
        bytes += value
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        rawVarint(UInt64(field) << 3 | wireType)
    }

    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }
}

struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case data([UInt8])
    }

    enum Failure: Error { case malformed }

    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// 下一个已知类型的字段；fixed32/fixed64 字段被跳过。
    mutating func next() throws -> (field: Int, value: Value)? {
        while index < bytes.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                return (field, .varint(try readVarint()))
            case 1:
                try skip(8)
            case 2:
                let length = Int(try readVarint())
                guard length >= 0, index + length <= bytes.count else { throw Failure.malformed }
                defer { index += length }
                return (field, .data(Array(bytes[index..<(index + length)])))
            case 5:
                try skip(4)
            default:
                throw Failure.malformed
            }
        }
        return nil
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw Failure.malformed }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func skip(_ count: Int) throws {
        guard index + count <= bytes.count else { throw Failure.malformed }
        index += count
    }
}

// MARK: - Transport instruction

struct MoshInstruction: Equatable {
    static let protocolVersion: UInt64 = 2

    var protocolVersion: UInt64 = MoshInstruction.protocolVersion
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff: [UInt8] = []

    func encoded() -> [UInt8] {
        var w = ProtoWriter()
        w.varint(1, protocolVersion)
        w.varint(2, oldNum)
        w.varint(3, newNum)
        w.varint(4, ackNum)
        w.varint(5, throwawayNum)
        if !diff.isEmpty { w.data(6, diff) }
        return w.bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> MoshInstruction {
        var r = ProtoReader(bytes)
        var inst = MoshInstruction(protocolVersion: 0)
        while let (field, value) = try r.next() {
            switch (field, value) {
            case (1, .varint(let v)): inst.protocolVersion = v
            case (2, .varint(let v)): inst.oldNum = v
            case (3, .varint(let v)): inst.newNum = v
            case (4, .varint(let v)): inst.ackNum = v
            case (5, .varint(let v)): inst.throwawayNum = v
            case (6, .data(let d)): inst.diff = d
            default: break // chaff 等
            }
        }
        return inst
    }
}

// MARK: - User / host messages

/// 客户端状态中的一个动作。服务器按“动作个数”计算状态差，每个字节是一个动作。
enum MoshUserAction: Equatable {
    case byte(UInt8)
    case resize(width: Int, height: Int)
}

enum MoshHostEvent: Equatable {
    case hostBytes([UInt8])
    case resize(width: Int, height: Int)
    case echoAck(UInt64)
}

enum MoshMessages {
    /// ClientBuffers.UserMessage：连续的按键字节合并为一条 Keystroke 指令。
    static func encodeUserMessage(_ actions: ArraySlice<MoshUserAction>) -> [UInt8] {
        var message = ProtoWriter()
        var pendingKeys: [UInt8] = []

        func flushKeys() {
            guard !pendingKeys.isEmpty else { return }
            var keystroke = ProtoWriter()
            keystroke.data(4, pendingKeys)
            var instruction = ProtoWriter()
            instruction.data(2, keystroke.bytes)
            message.data(1, instruction.bytes)
            pendingKeys = []
        }

        for action in actions {
            switch action {
            case .byte(let b):
                pendingKeys.append(b)
            case .resize(let width, let height):
                flushKeys()
                var resize = ProtoWriter()
                resize.varint(5, UInt64(width))
                resize.varint(6, UInt64(height))
                var instruction = ProtoWriter()
                instruction.data(3, resize.bytes)
                message.data(1, instruction.bytes)
            }
        }
        flushKeys()
        return message.bytes
    }

    /// HostBuffers.HostMessage → 事件列表。
    static func decodeHostMessage(_ bytes: [UInt8]) throws -> [MoshHostEvent] {
        var events: [MoshHostEvent] = []
        var message = ProtoReader(bytes)
        while let (field, value) = try message.next() {
            guard field == 1, case .data(let instructionBytes) = value else { continue }
            var instruction = ProtoReader(instructionBytes)
            while let (extField, extValue) = try instruction.next() {
                guard case .data(let payload) = extValue else { continue }
                var inner = ProtoReader(payload)
                switch extField {
                case 2: // HostBytes
                    while let (f, v) = try inner.next() {
                        if f == 4, case .data(let s) = v { events.append(.hostBytes(s)) }
                    }
                case 3: // ResizeMessage
                    var width = 0, height = 0
                    while let (f, v) = try inner.next() {
                        if case .varint(let n) = v {
                            if f == 5 { width = Int(Int32(truncatingIfNeeded: n)) }
                            if f == 6 { height = Int(Int32(truncatingIfNeeded: n)) }
                        }
                    }
                    events.append(.resize(width: width, height: height))
                case 7: // EchoAck
                    while let (f, v) = try inner.next() {
                        if f == 8, case .varint(let n) = v { events.append(.echoAck(n)) }
                    }
                default:
                    break
                }
            }
        }
        return events
    }

    /// 测试用：构造 HostMessage。
    static func encodeHostMessage(_ events: [MoshHostEvent]) -> [UInt8] {
        var message = ProtoWriter()
        for event in events {
            var instruction = ProtoWriter()
            switch event {
            case .hostBytes(let s):
                var inner = ProtoWriter(); inner.data(4, s)
                instruction.data(2, inner.bytes)
            case .resize(let w, let h):
                var inner = ProtoWriter(); inner.varint(5, UInt64(w)); inner.varint(6, UInt64(h))
                instruction.data(3, inner.bytes)
            case .echoAck(let n):
                var inner = ProtoWriter(); inner.varint(8, n)
                instruction.data(7, inner.bytes)
            }
            message.data(1, instruction.bytes)
        }
        return message.bytes
    }
}

// MARK: - Fragments

struct MoshFragment: Equatable {
    static let headerLength = 10

    var id: UInt64
    var number: UInt16
    var isFinal: Bool
    var contents: [UInt8]

    func encoded() -> [UInt8] {
        var out: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: id >> (56 - 8 * UInt64($0))) }
        let combined = (isFinal ? 0x8000 : 0) | number
        out += [UInt8(combined >> 8), UInt8(combined & 0xFF)]
        return out + contents
    }

    static func decode(_ bytes: [UInt8]) -> MoshFragment? {
        guard bytes.count >= headerLength else { return nil }
        let id = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let combined = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return MoshFragment(id: id, number: combined & 0x7FFF, isFinal: combined & 0x8000 != 0,
                            contents: Array(bytes[headerLength...]))
    }

    /// 指令 → 压缩 → 按 MTU 切片。
    static func make(_ instruction: MoshInstruction, id: UInt64, maxContent: Int) -> [MoshFragment] {
        let payload = Zlib.compressStored(instruction.encoded())
        var fragments: [MoshFragment] = []
        var offset = 0
        var number: UInt16 = 0
        repeat {
            let end = min(offset + maxContent, payload.count)
            fragments.append(MoshFragment(id: id, number: number, isFinal: end == payload.count,
                                          contents: Array(payload[offset..<end])))
            offset = end
            number += 1
        } while offset < payload.count
        return fragments
    }
}

/// 分片重组（同 mosh 的 FragmentAssembly：新指令 ID 到来即丢弃未完成的旧指令）。
struct MoshFragmentAssembly {
    private var currentID: UInt64?
    private var parts: [UInt16: [UInt8]] = [:]
    private var total: Int?

    /// 收齐后返回解压前的完整负载。
    mutating func add(_ fragment: MoshFragment) -> [UInt8]? {
        if fragment.id != currentID {
            currentID = fragment.id
            parts = [:]
            total = nil
        }
        parts[fragment.number] = fragment.contents
        if fragment.isFinal { total = Int(fragment.number) + 1 }
        guard let total, parts.count == total else { return nil }
        var payload: [UInt8] = []
        for number in 0..<total {
            guard let part = parts[UInt16(number)] else { return nil }
            payload += part
        }
        parts = [:]
        self.total = nil
        return payload
    }
}
