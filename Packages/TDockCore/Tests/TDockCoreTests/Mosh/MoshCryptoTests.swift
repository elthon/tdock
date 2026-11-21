import XCTest
@testable import TDockCore

/// 向量来自 FIPS-197、RFC 7253，以及用 Python cryptography (AESOCB3) 生成的 Mosh 风格 nonce 用例。
final class MoshCryptoTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            bytes.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    func testAESFIPS197() {
        let aes = AES128(key: Array(0..<16))
        let pt = hex("00112233445566778899aabbccddeeff")
        let ct = aes.encrypt(pt)
        XCTAssertEqual(ct, hex("69c4e0d86a7b0430d8cdb78070b4c55a"))
        XCTAssertEqual(aes.decrypt(ct), pt)
    }

    func testSboxKnownValues() {
        XCTAssertEqual(AES128.sbox[0x00], 0x63)
        XCTAssertEqual(AES128.sbox[0x53], 0xED)
        XCTAssertEqual(AES128.invSbox[0x63], 0x00)
    }

    func testOCBRFC7253() throws {
        let ocb = AESOCB(key: Array(0..<16))
        let cases: [(nonce: String, ad: String, pt: String, ct: String)] = [
            ("BBAA99887766554433221100", "", "", "785407bfffc8ad9edcc5520ac9111ee6"),
            ("BBAA99887766554433221101", "0001020304050607", "0001020304050607",
             "6820b3657b6f615a5725bda0d3b4eb3a257c9af1f8f03009"),
            ("BBAA99887766554433221103", "", "0001020304050607",
             "45dd69f8f5aae72414054cd1f35d82760b2cd00d2f99bfa9"),
        ]
        for c in cases {
            let sealed = try ocb.seal(hex(c.pt), nonce: hex(c.nonce), associatedData: hex(c.ad))
            XCTAssertEqual(sealed, hex(c.ct), c.nonce)
            XCTAssertEqual(try ocb.open(sealed, nonce: hex(c.nonce), associatedData: hex(c.ad)), hex(c.pt))
        }
    }

    func testOCBMoshStyleNonces() throws {
        let ocb = AESOCB(key: hex("a54dca182530bb1d6d132cded6237b2e"))
        let cases: [(String, String, String)] = [
            ("000000006cad4a268d116ece", "", "45ec55ddb882938274f41e38514b9f8e"),
            ("000000001fb17c2390c192cf", "72", "2565e8e0bc99508035575788e8b73bbc5e"),
            ("00000000658cda1495e60af5", "1971174494d6493c9d5c3460be3120", "516ef4dee6a5fc275487ecd2bee9f3e78d628c823c6b0470e38e88837e8823"),
            ("000000000f4205b4907a70c3", "69fedaa0eee8b9997f5c7c2999fdafe5", "39fb8ef7aee2cfb37afedb615ff874c2d31e43e323e3ab5c05be269d48e595d8"),
            ("0000000012bd4acefaecbd38", "3cd654af4dfad71427a0aeb3fee9232f8a", "0247bf877337a1e8add331eedf98b67f9571f138bcfc6c2176021fd4d357b755d8"),
            ("0000000010a3d6b2aa05e11a", "1f9ee491c5b10becb5563bfc1e6f93427ecbc8fe2955e5cd8e46dc8ed4b7c2", "ab408cfa80b18f273dfe5ac2e609caa48df33bb582b1f59da8084eaef651360e88d50591f012b2abc6aeef6b947f20"),
            ("000000003b1287fff52ddf5d", "4d2a5a4d767706f85d8690024ad6bda3401be9c8cbccc935f6cd1f61226ae153", "f6bce76291a3eff7932815cad161c40dacf7f9398c2ac0c9051ef02e9d121145214755004996d9d8e912817da3d0e796"),
            ("00000000570dc1951c2442f9", "1a34004d33ba0d246ac04c81b1baf23e3bf9eef5f79f2b4934af87f5520b69b94b", "226af246406eb176cbdafc22109a3bc6a042b75f7900b8cfe4fbe5c7914a9fea6ffa638c363e73654b0f7f6e9842c4bbc3"),
        ]
        for (nonce, pt, ct) in cases {
            let sealed = try ocb.seal(hex(pt), nonce: hex(nonce))
            XCTAssertEqual(sealed, hex(ct), "len \(pt.count / 2)")
            XCTAssertEqual(try ocb.open(hex(ct), nonce: hex(nonce)), hex(pt))
        }
    }

    func testOCBRejectsTampering() throws {
        let ocb = AESOCB(key: Array(0..<16))
        let nonce = Array(repeating: UInt8(7), count: 12)
        var sealed = try ocb.seal(Array("hello mosh".utf8), nonce: nonce)
        sealed[3] ^= 1
        XCTAssertThrowsError(try ocb.open(sealed, nonce: nonce))
        XCTAssertThrowsError(try ocb.open([1, 2, 3], nonce: nonce))
    }
}
