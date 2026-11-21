import XCTest
@testable import TDockCore

final class MoshWireTests: XCTestCase {
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

    // 向量由 Python zlib 生成。
    func testInflateFixedHuffman() throws {
        XCTAssertEqual(try Zlib.decompress(hex("78dacb48cdc9c957c8402273f38b33140168030875")), Array("hello hello hello mosh!".utf8))
    }

    func testInflateStoredAndEmpty() throws {
        XCTAssertEqual(try Zlib.decompress(hex("7801011100eeff73746f72656420626c6f636b20646174613bcd0677")), Array("stored block data".utf8))
        XCTAssertEqual(try Zlib.decompress(hex("789c030000000001")), [])
    }

    func testInflateLongFixed() throws {
        let compressed = hex("78da0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb293c9bdaffac77fbf3592dcf164f7dd1b9e979f784e7dd3b5e6cdffc627ffb935d6dcfda273def9efeb8a1892b64d4d05143470d1d3574d4d05143293714006168644e")
        let expected = Array(String(repeating: "The quick brown fox jumps over the lazy dog. 敏捷的棕色狐狸跳过了懒狗。\n", count: 20).utf8)
        XCTAssertEqual(try Zlib.decompress(compressed), expected)
    }

    func testInflateDynamicHuffman() throws {
        // 2458 字节的终端风格文本，压缩为动态 Huffman 块；adler32 在解压时校验。
        let output = try Zlib.decompress(hex("78da6d56316edc400cec05e80569f8011b39c75daa0076e91469531de2183070f201d29d9de7676786bbe4ae0c1c04495c0ec9e190baebf6779da77932bbfadd3cade7f3c57e3dfe78787abc5d9ee74996bb83dd9c8e665f7e7f5d70374fe9c8b6feb172c04196e3ebdbedf6f1fa726916e0c2fdb499e1b9f912f0f0fddbfdc2f73fcfef061722f14e908c4a6b80275718805d102ee7cbf164a84877a76d9e8a854511b443d099bb83aaae716aa102d799e7f5e3df7a835f0628c8020df33c211ba52dd0289650f324445d9519e27a743efbc14280784bd1150f65057382c241450471fd097427e7a8fc126c67cdefcdaa285c1ab9bdad5f6a6be4e1d197eeb457ecc5a910b64e45121d2fa4c382a77664c2d99acc5ce94013479778d41ebdecb5397850277b8950564a50ba57b8148926d691fdfa5899d196993307b18646f0544a474caf934f8c020785df89b80fa732d4e471583183058f47d45616308cb3e2048999271fd434c431b3e1c1770ae085b471f3de7d4a4aaaacee1a8776aabc5c12ce18fbc2e1a391820e3357882d4bc748df208280a67e15b67d649c4b5e1207e4991ec872107f268bbaab3b6967e0a5ce12904880551255a0686d5c402cd625a36348986971c7e7290bcd8a8d628e2181314de7081b1baa5345f88703cf4759b913dc1811cb1b8a4c7673c917d23d1bdebe5260ba19bdf94e09cb46639528c01980c7639873dbab7accbb376ef6b67808040c8f05a9e47ca3fe6249fe6d2976e3ab5e3258fbd4fafecbe7b2ca8d6b29c8f0816ce4c5b696368a477c18ba7dd8c64e7ce66c734569ed06071d7bf1c52233881aab8054d363547bc96c504b292c8da62b3b74377c0dd5786fb608f1e1f7d049c7b17d86ad5042ecc6ffd3bf09c31f9f089332ae935abb9279d87d11fbb59f93f80f3956bbf3"))
        XCTAssertEqual(output.count, 2458)
        XCTAssertEqual(Zlib.adler32(output), 0x3956bbf3)
    }

    func testInflateRejectsCorruption() {
        var bad = hex("78dacb48cdc9c957c8402273f38b33140168030875")
        bad[bad.count - 1] ^= 0xFF
        XCTAssertThrowsError(try Zlib.decompress(bad))
        XCTAssertThrowsError(try Zlib.decompress([0x78, 0x01, 0xFF]))
    }

    func testStoredRoundTrip() throws {
        for size in [0, 1, 100, 65535, 65536, 140_000] {
            let data = (0..<size).map { UInt8(truncatingIfNeeded: $0 * 7) }
            XCTAssertEqual(try Zlib.decompress(Zlib.compressStored(data)), data, "size \(size)")
        }
    }

    func testInstructionRoundTrip() throws {
        let inst = MoshInstruction(oldNum: 3, newNum: 300, ackNum: 1 << 40, throwawayNum: 2, diff: [1, 2, 3])
        XCTAssertEqual(try MoshInstruction.decode(inst.encoded()), inst)
        // 与 protoc 输出一致：字段 1 = 2 编码为 08 02
        XCTAssertEqual(Array(MoshInstruction(oldNum: 0, newNum: 1).encoded().prefix(2)), [0x08, 0x02])
    }

    func testUserMessageEncoding() throws {
        let bytes = MoshMessages.encodeUserMessage([.resize(width: 80, height: 24), .byte(0x61), .byte(0x62)][...])
        // UserMessage{instruction{resize{5:80,6:24}}, instruction{keystroke{4:"ab"}}}
        XCTAssertEqual(bytes, [0x0A, 0x06, 0x1A, 0x04, 0x28, 0x50, 0x30, 0x18,
                               0x0A, 0x06, 0x12, 0x04, 0x22, 0x02, 0x61, 0x62])
    }

    func testHostMessageDecoding() throws {
        let events: [MoshHostEvent] = [.echoAck(7), .resize(width: 100, height: 30), .hostBytes(Array("\u{1b}[H hi".utf8))]
        XCTAssertEqual(try MoshMessages.decodeHostMessage(MoshMessages.encodeHostMessage(events)), events)
    }

    func testFragmentationAndAssembly() {
        let inst = MoshInstruction(oldNum: 1, newNum: 2, diff: (0..<3000).map { UInt8(truncatingIfNeeded: $0) })
        let fragments = MoshFragment.make(inst, id: 42, maxContent: 1000)
        XCTAssertEqual(fragments.count, 4)
        XCTAssertEqual(fragments.filter(\.isFinal).count, 1)
        XCTAssertEqual(MoshFragment.decode(fragments[1].encoded()), fragments[1])

        var assembly = MoshFragmentAssembly()
        // 乱序到达
        for fragment in [fragments[2], fragments[0], fragments[3]] { XCTAssertNil(assembly.add(fragment)) }
        let payload = assembly.add(fragments[1])
        XCTAssertNotNil(payload)
        XCTAssertEqual(try MoshInstruction.decode(Zlib.decompress(payload!)), inst)
    }
}
