import NIOCore
import XCTest
@testable import TDockCore

final class SFTPMessageTests: XCTestCase {
    func testFramerSplitsAcrossChunks() throws {
        var framer = SFTPFramer()
        var wire = ByteBuffer()
        for payload in [[UInt8](repeating: 7, count: 5), [1, 2, 3]] {
            wire.writeInteger(UInt32(payload.count))
            wire.writeBytes(payload)
        }
        // 逐字节送入，模拟任意分片。
        var packets: [[UInt8]] = []
        while let byte: UInt8 = wire.readInteger() {
            framer.append(ByteBuffer(bytes: [byte]))
            while var packet = try framer.next() {
                packets.append(packet.readBytes(length: packet.readableBytes)!)
            }
        }
        XCTAssertEqual(packets, [[7, 7, 7, 7, 7], [1, 2, 3]])
    }

    func testFramerRejectsHugePacket() {
        var framer = SFTPFramer()
        var wire = ByteBuffer()
        wire.writeInteger(UInt32(SFTPFramer.maxPacket + 1))
        framer.append(wire)
        XCTAssertThrowsError(try framer.next())
    }

    func testAttributesRoundTrip() throws {
        var attrs = SFTPAttributes(size: 123_456, permissions: 0o040755, modifyTime: 1_700_000_000)
        attrs.uid = 1000
        attrs.gid = 1000
        attrs.accessTime = 1_700_000_001
        var buffer = ByteBuffer()
        attrs.write(to: &buffer)
        let decoded = try SFTPAttributes.read(from: &buffer)
        XCTAssertEqual(decoded, attrs)
        XCTAssertTrue(decoded.isDirectory)
        XCTAssertEqual(decoded.permissionString, "drwxr-xr-x")
    }

    func testParsesNameResponse() throws {
        var packet = ByteBuffer()
        packet.writeInteger(UInt8(104)) // NAME
        packet.writeInteger(UInt32(9))  // id
        packet.writeInteger(UInt32(1))  // count
        packet.writeSFTPString("notes.txt")
        packet.writeSFTPString("-rw-r--r-- 1 u g 5 notes.txt")
        SFTPAttributes(size: 5, permissions: 0o100644).write(to: &packet)
        let (id, response) = try SFTPResponse.parse(&packet)
        XCTAssertEqual(id, 9)
        guard case .name(let entries) = response else { return XCTFail() }
        XCTAssertEqual(entries.first?.name, "notes.txt")
        XCTAssertEqual(entries.first?.attributes.size, 5)
        XCTAssertTrue(entries.first?.attributes.isRegularFile == true)
    }

    func testParsesStatusWithoutMessage() throws {
        var packet = ByteBuffer()
        packet.writeInteger(UInt8(101))
        packet.writeInteger(UInt32(3))
        packet.writeInteger(UInt32(1))
        let (_, response) = try SFTPResponse.parse(&packet)
        guard case .status(let code, let message) = response else { return XCTFail() }
        XCTAssertEqual(code, 1)
        XCTAssertEqual(message, "")
    }
}
