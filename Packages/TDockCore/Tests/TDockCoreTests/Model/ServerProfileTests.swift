import Foundation
import XCTest
@testable import TDockCore

final class ServerProfileTests: XCTestCase {
    /// MVP 版本保存的 JSON（没有后来新增的字段）仍能读取。
    func testDecodesMVPData() throws {
        let json = #"[{"id":"7B1B2D2E-7A4F-4C2B-9D4B-1C2D3E4F5A6B","name":"web","host":"example.com","port":2222,"username":"me","authMethod":"privateKey"}]"#
        let profiles = try JSONDecoder().decode([ServerProfile].self, from: Data(json.utf8))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].port, 2222)
        XCTAssertEqual(profiles[0].transport, .ssh)
        XCTAssertNil(profiles[0].keyID)
        XCTAssertEqual(profiles[0].portForwards, [])
        XCTAssertEqual(profiles[0].updatedAt, Date(timeIntervalSince1970: 0))
    }

    func testRoundTrip() throws {
        let profile = ServerProfile(
            name: "db", host: "10.0.0.2", username: "ops", authMethod: .privateKey, keyID: UUID(),
            transport: .mosh, portForwards: [PortForwardRule(localPort: 15432, remoteHost: "db.internal", remotePort: 5432)]
        )
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testPortForwardValidation() {
        XCTAssertNil(PortForwardRule(localPort: 8080, remoteHost: "10.0.0.5", remotePort: 80).validationError())
        XCTAssertNotNil(PortForwardRule(localPort: 80, remoteHost: "10.0.0.5", remotePort: 80).validationError())
        XCTAssertNotNil(PortForwardRule(localPort: 8080, remoteHost: " ", remotePort: 80).validationError())
        var profile = ServerProfile(host: "h", username: "u")
        profile.portForwards = [PortForwardRule(localPort: 8080, remoteHost: "x", remotePort: 0)]
        XCTAssertNotNil(profile.validationError())
    }
}
