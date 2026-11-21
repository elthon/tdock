import Foundation
import NIOCore

/// SFTP v3（draft-ietf-secsh-filexfer-02）报文编解码。
enum SFTPPacketType: UInt8 {
    case initialize = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6
    case lstat = 7, fstat = 8
    case opendir = 11, readdir = 12
    case realpath = 16, stat = 17
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
}

public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = SFTPOpenFlags(rawValue: 0x01)
    public static let write = SFTPOpenFlags(rawValue: 0x02)
    public static let append = SFTPOpenFlags(rawValue: 0x04)
    public static let create = SFTPOpenFlags(rawValue: 0x08)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

public struct SFTPAttributes: Sendable, Equatable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modifyTime: UInt32?

    public init(size: UInt64? = nil, permissions: UInt32? = nil, modifyTime: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
        self.modifyTime = modifyTime
    }

    private static let fileTypeMask: UInt32 = 0o170000
    public var isDirectory: Bool { permissions.map { $0 & Self.fileTypeMask == 0o040000 } ?? false }
    public var isSymlink: Bool { permissions.map { $0 & Self.fileTypeMask == 0o120000 } ?? false }
    public var isRegularFile: Bool { permissions.map { $0 & Self.fileTypeMask == 0o100000 } ?? false }
    public var modificationDate: Date? { modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// 例如 `drwxr-xr-x`
    public var permissionString: String {
        guard let p = permissions else { return "" }
        let type: Character = isDirectory ? "d" : isSymlink ? "l" : "-"
        let bits: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
            (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(type) + String(bits.map { p & $0.0 != 0 ? $0.1 : "-" })
    }

    func write(to buffer: inout ByteBuffer) {
        var flags: UInt32 = 0
        if size != nil { flags |= 0x1 }
        if uid != nil && gid != nil { flags |= 0x2 }
        if permissions != nil { flags |= 0x4 }
        if accessTime != nil && modifyTime != nil { flags |= 0x8 }
        buffer.writeInteger(flags)
        if let size { buffer.writeInteger(size) }
        if let uid, let gid { buffer.writeInteger(uid); buffer.writeInteger(gid) }
        if let permissions { buffer.writeInteger(permissions) }
        if let accessTime, let modifyTime { buffer.writeInteger(accessTime); buffer.writeInteger(modifyTime) }
    }

    static func read(from buffer: inout ByteBuffer) throws -> SFTPAttributes {
        var attrs = SFTPAttributes()
        let flags: UInt32 = try buffer.readSFTPInteger()
        if flags & 0x1 != 0 { attrs.size = try buffer.readSFTPInteger() }
        if flags & 0x2 != 0 {
            attrs.uid = try buffer.readSFTPInteger()
            attrs.gid = try buffer.readSFTPInteger()
        }
        if flags & 0x4 != 0 { attrs.permissions = try buffer.readSFTPInteger() }
        if flags & 0x8 != 0 {
            attrs.accessTime = try buffer.readSFTPInteger()
            attrs.modifyTime = try buffer.readSFTPInteger()
        }
        if flags & 0x8000_0000 != 0 {
            let count: UInt32 = try buffer.readSFTPInteger()
            for _ in 0..<count {
                _ = try buffer.readSFTPString()
                _ = try buffer.readSFTPString()
            }
        }
        return attrs
    }
}

public struct SFTPEntry: Sendable, Equatable, Identifiable {
    public var name: String
    public var longName: String
    public var attributes: SFTPAttributes
    public var id: String { name }

    public var isDirectory: Bool { attributes.isDirectory }
}

public struct SFTPError: Error, LocalizedError, Equatable {
    public enum Code: UInt32, Sendable {
        case ok = 0, eof, noSuchFile, permissionDenied, failure, badMessage, noConnection, connectionLost, unsupported
    }

    public var code: UInt32
    public var message: String

    public static let eof: UInt32 = 1
    public static let malformed = SFTPError(code: Code.badMessage.rawValue, message: "SFTP 报文格式错误")
    public static let closed = SFTPError(code: Code.connectionLost.rawValue, message: "SFTP 通道已关闭")

    public var errorDescription: String? {
        switch Code(rawValue: code) {
        case .noSuchFile: return "文件或目录不存在"
        case .permissionDenied: return "没有权限"
        case .unsupported: return "服务器不支持该操作"
        case .connectionLost, .noConnection: return "SFTP 连接已断开"
        default: return message.isEmpty ? "SFTP 错误（\(code)）" : message
        }
    }
}

/// 服务器的应答。
enum SFTPResponse {
    case status(code: UInt32, message: String)
    case handle(ByteBuffer)
    case data(ByteBuffer)
    case name([SFTPEntry])
    case attrs(SFTPAttributes)

    /// 解析一个完整报文（不含长度前缀），返回 (请求 ID, 应答)。VERSION 报文返回 nil 的 ID。
    static func parse(_ packet: inout ByteBuffer) throws -> (UInt32?, SFTPResponse?) {
        let rawType: UInt8 = try packet.readSFTPInteger()
        guard let type = SFTPPacketType(rawValue: rawType) else { return (nil, nil) }
        if type == .version { return (nil, nil) }
        let id: UInt32 = try packet.readSFTPInteger()
        switch type {
        case .status:
            let code: UInt32 = try packet.readSFTPInteger()
            // 部分实现省略 message/lang 字段。
            let message = packet.readableBytes >= 4 ? (try? packet.readSFTPStringUTF8()) ?? "" : ""
            return (id, .status(code: code, message: message))
        case .handle:
            return (id, .handle(try packet.readSFTPString()))
        case .data:
            return (id, .data(try packet.readSFTPString()))
        case .name:
            let count: UInt32 = try packet.readSFTPInteger()
            var entries: [SFTPEntry] = []
            entries.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let name = try packet.readSFTPStringUTF8()
                let longName = try packet.readSFTPStringUTF8()
                let attrs = try SFTPAttributes.read(from: &packet)
                entries.append(SFTPEntry(name: name, longName: longName, attributes: attrs))
            }
            return (id, .name(entries))
        case .attrs:
            return (id, .attrs(try SFTPAttributes.read(from: &packet)))
        default:
            return (id, nil)
        }
    }
}

extension ByteBuffer {
    mutating func readSFTPInteger<T: FixedWidthInteger>() throws -> T {
        guard let value: T = readInteger() else { throw SFTPError.malformed }
        return value
    }

    mutating func readSFTPString() throws -> ByteBuffer {
        let length: UInt32 = try readSFTPInteger()
        guard let slice = readSlice(length: Int(length)) else { throw SFTPError.malformed }
        return slice
    }

    mutating func readSFTPStringUTF8() throws -> String {
        var slice = try readSFTPString()
        // 文件名不一定是合法 UTF-8，宽松解码。
        let bytes = slice.readBytes(length: slice.readableBytes) ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func writeSFTPString(_ string: String) {
        let bytes = Array(string.utf8)
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func writeSFTPString(_ buffer: ByteBuffer) {
        writeInteger(UInt32(buffer.readableBytes))
        writeImmutableBuffer(buffer)
    }

    mutating func writeSFTPString<C: Collection>(bytes: C) where C.Element == UInt8 {
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }
}

/// 将接收到的字节流切分为完整的 SFTP 报文。
struct SFTPFramer {
    private var buffer = ByteBuffer()
    static let maxPacket = 1 << 20

    mutating func append(_ bytes: ByteBuffer) {
        var bytes = bytes
        buffer.writeBuffer(&bytes)
    }

    /// 取出下一个完整报文（不含长度前缀）。
    mutating func next() throws -> ByteBuffer? {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return nil }
        guard length <= Self.maxPacket else { throw SFTPError.malformed }
        guard buffer.readableBytes >= 4 + Int(length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        let packet = buffer.readSlice(length: Int(length))
        if buffer.readableBytes == 0 { buffer.clear() } else if buffer.readerIndex > 1 << 16 { buffer.discardReadBytes() }
        return packet
    }
}
