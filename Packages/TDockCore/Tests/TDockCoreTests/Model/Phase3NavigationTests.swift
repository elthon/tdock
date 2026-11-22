import Foundation
import XCTest
@testable import TDockCore

final class Phase3NavigationTests: XCTestCase {
    private func server(_ name: String, host: String = "h", group: String = "", pinned: Bool = false) -> ServerProfile {
        ServerProfile(name: name, host: host, username: "root", group: group, pinned: pinned)
    }

    func testOldDataDecodesWithoutGroupPinnedAndRuleName() throws {
        let json = """
        {"id":"\(UUID().uuidString)","host":"example.com","username":"me",
         "portForwards":[{"id":"\(UUID().uuidString)","localPort":8080,"remoteHost":"127.0.0.1","remotePort":80}]}
        """
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.group, "")
        XCTAssertFalse(profile.pinned)
        XCTAssertEqual(profile.portForwards.first?.name, "")
        XCTAssertEqual(profile.portForwards.first?.displayName, "localhost:8080 → 127.0.0.1:80")
    }

    func testNewFieldsRoundTrip() throws {
        var profile = server("web", group: "生产", pinned: true)
        profile.portForwards = [PortForwardRule(localPort: 9000, remoteHost: "10.0.0.2", remotePort: 3000, name: "远程面板")]
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.portForwards[0].displayName, "远程面板")
        XCTAssertEqual(decoded.portForwards[0].localURL.absoluteString, "http://127.0.0.1:9000")
        XCTAssertEqual(decoded.portForwards[0].localAddress, "127.0.0.1:9000")
    }

    func testSectionsOrderPinnedGroupsUngrouped() {
        let servers = [
            server("a"), server("b", group: "测试"), server("c", pinned: true), server("d", group: "Alpha"),
            server("e", group: " 测试 "), server("f", group: "Alpha", pinned: true),
        ]
        let sections = ServerListOrganizer.sections(servers)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .group("Alpha"), .group("测试"), .ungrouped])
        XCTAssertEqual(sections[0].servers.map(\.name), ["c", "f"])
        XCTAssertEqual(sections[1].servers.map(\.name), ["d"])
        XCTAssertEqual(sections[2].servers.map(\.name), ["b", "e"])
        XCTAssertEqual(sections[3].servers.map(\.name), ["a"])
        XCTAssertNil(sections[3].title)
        XCTAssertEqual(ServerListOrganizer.groupNames(servers), ["Alpha", "测试"])
    }

    func testSearchMatchesAllTerms() {
        let servers = [
            server("Web Prod", host: "10.0.0.1", group: "生产"),
            server("db", host: "db.example.com"),
            server("café", host: "x"),
        ]
        XCTAssertEqual(ServerListOrganizer.sections(servers, query: "prod").flatMap(\.servers).map(\.name), ["Web Prod"])
        XCTAssertEqual(ServerListOrganizer.sections(servers, query: "生产 10.0").flatMap(\.servers).map(\.name), ["Web Prod"])
        XCTAssertEqual(ServerListOrganizer.sections(servers, query: "EXAMPLE").flatMap(\.servers).map(\.name), ["db"])
        XCTAssertEqual(ServerListOrganizer.sections(servers, query: "cafe").flatMap(\.servers).map(\.name), ["café"])
        XCTAssertEqual(ServerListOrganizer.sections(servers, query: "root@db").flatMap(\.servers).map(\.name), ["db"])
        XCTAssertTrue(ServerListOrganizer.sections(servers, query: "prod db").isEmpty)
        XCTAssertEqual(ServerListOrganizer.sections(servers, query: "  ").flatMap(\.servers).count, 3)
    }

    func testKnownHostEntryParsing() {
        let entry = KnownHostEntry(key: "[example.com]:2222", value: "ssh-ed25519 SHA256:abc+/def")
        XCTAssertEqual(entry, KnownHostEntry(host: "example.com", port: 2222, keyType: "ssh-ed25519", fingerprint: "SHA256:abc+/def"))
        XCTAssertEqual(entry?.id, "[example.com]:2222")
        XCTAssertEqual(entry?.value, "ssh-ed25519 SHA256:abc+/def")
        // IPv6 主机名中含冒号
        XCTAssertEqual(KnownHostEntry(key: "[fe80::1]:22", value: "ecdsa-sha2-nistp256 SHA256:x")?.host, "fe80::1")
        XCTAssertNil(KnownHostEntry(key: "example.com:22", value: "a b"))
        XCTAssertNil(KnownHostEntry(key: "[]:22", value: "a b"))
        XCTAssertNil(KnownHostEntry(key: "[h]:x", value: "a b"))
        XCTAssertNil(KnownHostEntry(key: "[h]:22", value: "nospace"))
        XCTAssertEqual(KnownHostEntry.key(host: "Example.COM", port: 22), "[example.com]:22")

        let list = KnownHostEntry.list([
            "[b]:22": "t f", "[a]:2222": "t f", "[a]:22": "t f", "bad": "t f",
        ])
        XCTAssertEqual(list.map(\.id), ["[a]:22", "[a]:2222", "[b]:22"])
    }

    func testReconnectPolicy() {
        let policy = ReconnectPolicy.default
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual((1...3).compactMap(policy.delay(beforeAttempt:)), [1, 2, 4])
        XCTAssertNil(policy.delay(beforeAttempt: 0))
        XCTAssertNil(policy.delay(beforeAttempt: 4))
    }
}
