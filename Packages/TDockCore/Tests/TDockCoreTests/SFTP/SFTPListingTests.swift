import Foundation
import NIOCore
import XCTest
@testable import TDockCore

final class SFTPListingTests: XCTestCase {
    private func file(_ name: String, size: UInt64 = 0, mtime: UInt32 = 0) -> SFTPEntry {
        SFTPEntry(name: name, longName: "", attributes: SFTPAttributes(size: size, permissions: 0o100644, modifyTime: mtime))
    }

    private func dir(_ name: String, mtime: UInt32 = 0) -> SFTPEntry {
        SFTPEntry(name: name, longName: "", attributes: SFTPAttributes(size: 4096, permissions: 0o040755, modifyTime: mtime))
    }

    private var sample: [SFTPEntry] {
        [file("b.log", size: 10, mtime: 300), file(".env", size: 5, mtime: 100), dir("src", mtime: 50),
         file("a10.txt", size: 999, mtime: 200), file("a2.txt", size: 1, mtime: 400), dir(".ssh", mtime: 10)]
    }

    func testHiddenFilesAndDirectoriesFirst() {
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false).map(\.name), ["src", "a2.txt", "a10.txt", "b.log"])
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: true).map(\.name),
                       [".ssh", "src", ".env", "a2.txt", "a10.txt", "b.log"])
    }

    func testSortKeys() {
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false, sortBy: .size, ascending: false).map(\.name),
                       ["src", "a10.txt", "b.log", "a2.txt"])
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false, sortBy: .modified, ascending: false).map(\.name),
                       ["src", "a2.txt", "b.log", "a10.txt"])
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false, sortBy: .name, ascending: false).map(\.name),
                       ["src", "b.log", "a10.txt", "a2.txt"])
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false, sortBy: .modified).map(\.name),
                       ["src", "a10.txt", "b.log", "a2.txt"])
    }

    func testQueryFilter() {
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false, query: "TXT").map(\.name), ["a2.txt", "a10.txt"])
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: false, query: "env").map(\.name), [], "隐藏文件仍被隐藏")
        XCTAssertEqual(SFTPListing.arrange(sample, showHidden: true, query: "env").map(\.name), [".env"])
    }

    func testPaths() {
        XCTAssertEqual(SFTPPath.normalize("//home/./me/../you/"), "/home/you")
        XCTAssertEqual(SFTPPath.normalize("/.."), "/")
        XCTAssertEqual(SFTPPath.parent("/home/me"), "/home")
        XCTAssertEqual(SFTPPath.parent("/home"), "/")
        XCTAssertEqual(SFTPPath.parent("/"), "/")
        XCTAssertEqual(SFTPPath.join("/", "etc"), "/etc")
        XCTAssertEqual(SFTPPath.join("/etc", "hosts"), "/etc/hosts")
        XCTAssertEqual(SFTPPath.lastComponent("/var/log/"), "log")
        XCTAssertEqual(SFTPPath.lastComponent("/"), "/")
        XCTAssertEqual(SFTPPath.breadcrumbs("/home/me/a b").map(\.name), ["/", "home", "me", "a b"])
        XCTAssertEqual(SFTPPath.breadcrumbs("/home/me/a b").map(\.path), ["/", "/home", "/home/me", "/home/me/a b"])
        XCTAssertEqual(SFTPPath.breadcrumbs("/").map(\.path), ["/"])
    }

    func testResolveInput() {
        let home = "/home/me"
        XCTAssertEqual(SFTPPath.resolve("~", current: "/tmp", home: home), "/home/me")
        XCTAssertEqual(SFTPPath.resolve("~/.ssh", current: "/tmp", home: home), "/home/me/.ssh")
        XCTAssertEqual(SFTPPath.resolve("/var/log/", current: "/tmp", home: home), "/var/log")
        XCTAssertEqual(SFTPPath.resolve("../etc", current: "/tmp", home: home), "/etc")
        XCTAssertEqual(SFTPPath.resolve("sub", current: "/tmp", home: home), "/tmp/sub")
        XCTAssertEqual(SFTPPath.resolve("  ", current: "/tmp", home: home), "/tmp")
    }

    func testNamesAndPermissions() {
        XCTAssertNil(SFTPPath.validateName("新建文件夹"))
        XCTAssertNotNil(SFTPPath.validateName(" "))
        XCTAssertNotNil(SFTPPath.validateName("a/b"))
        XCTAssertNotNil(SFTPPath.validateName(".."))
        XCTAssertEqual(SFTPPermissions.octal(0o100755), "755")
        XCTAssertEqual(SFTPPermissions.octal(0o100600), "600")
        XCTAssertEqual(SFTPPermissions.octal(0o104755), "4755")
        XCTAssertEqual(SFTPPermissions.parse("644"), 0o644)
        XCTAssertEqual(SFTPPermissions.parse("0700"), 0o700)
        XCTAssertEqual(SFTPPermissions.parse("2755"), 0o2755)
        XCTAssertNil(SFTPPermissions.parse("888"))
        XCTAssertNil(SFTPPermissions.parse("75"))
        XCTAssertNil(SFTPPermissions.parse("rwx"))
        XCTAssertEqual(SFTPListing.previewLimit, 1_048_576)
    }

    func testPermissionsOnlyAttributesEncoding() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        SFTPAttributes(permissions: 0o644).write(to: &buffer)
        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 0x4, "只带 permissions 标志")
        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 0o644)
        XCTAssertEqual(buffer.readableBytes, 0)
    }
}
