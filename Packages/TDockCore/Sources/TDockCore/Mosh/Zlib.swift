/// zlib（RFC 1950）解压：纯 Swift 实现的 DEFLATE（RFC 1951）解码器，支持 stored / 固定 / 动态 Huffman 块。
/// 压缩方向只需生成合法的 zlib 流，Mosh 的指令很小，直接使用 stored 块。
enum Zlib {
    enum Failure: Error {
        case invalidHeader
        case invalidData
        case checksumMismatch
        case tooLarge
    }

    /// 解压上限，防止恶意数据造成内存耗尽。
    static let maxOutput = 16 << 20

    static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 6 else { throw Failure.invalidHeader }
        let cmf = data[0], flg = data[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0 else {
            throw Failure.invalidHeader
        }
        var inflater = Inflater(input: data, start: 2)
        let output = try inflater.run()
        let end = inflater.bytePosition
        guard end + 4 <= data.count else { throw Failure.invalidData }
        let expected = data[end..<(end + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard adler32(output) == expected else { throw Failure.checksumMismatch }
        return output
    }

    /// 生成只含 stored 块的 zlib 流（无压缩，但任何 zlib 实现都能解）。
    static func compressStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let length = min(65535, data.count - offset)
            let final = offset + length == data.count
            out.append(final ? 1 : 0) // BFINAL + BTYPE=00，随后对齐到字节
            out += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)]
            out += data[offset..<(offset + length)]
            offset += length
        } while offset < data.count
        let checksum = adler32(data)
        out += [UInt8(checksum >> 24), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF)]
        return out
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var index = 0
        while index < data.count {
            let end = min(index + 5552, data.count) // 5552：保证 b 不溢出的最大块长
            while index < end {
                a += UInt32(data[index])
                b += a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }
}

/// DEFLATE 解码器（思路同 zlib 的 puff.c：规范 Huffman 码逐位解码）。
private struct Inflater {
    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths { count[length] += 1 }
            var left = 1
            for len in 1..<16 {
                left = (left << 1) - count[len]
                if left < 0 { throw Zlib.Failure.invalidData } // 过度订阅
            }
            var offsets = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offsets[len + 1] = offsets[len] + count[len] }
            for (sym, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = sym
                offsets[length] += 1
            }
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedTables: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return (try! Huffman(lengths: lengths), try! Huffman(lengths: [Int](repeating: 5, count: 30)))
    }()

    private let input: [UInt8]
    private var position: Int
    private var bitBuffer = 0
    private var bitCount = 0
    private var output: [UInt8] = []

    init(input: [UInt8], start: Int) {
        self.input = input
        position = start
    }

    /// 解码结束后（已丢弃剩余位）下一个字节的位置。
    var bytePosition: Int { position }

    mutating func run() throws -> [UInt8] {
        var last = false
        repeat {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Self.fixedTables.0, Self.fixedTables.1)
            case 2: try dynamic()
            default: throw Zlib.Failure.invalidData
            }
        } while !last
        bitBuffer = 0
        bitCount = 0
        return output
    }

    private mutating func bits(_ need: Int) throws -> Int {
        var value = bitBuffer
        while bitCount < need {
            guard position < input.count else { throw Zlib.Failure.invalidData }
            value |= Int(input[position]) << bitCount
            position += 1
            bitCount += 8
        }
        bitBuffer = value >> need
        bitCount -= need
        return value & ((1 << need) - 1)
    }

    private mutating func stored() throws {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw Zlib.Failure.invalidData }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard length == ~complement & 0xFFFF else { throw Zlib.Failure.invalidData }
        position += 4
        guard position + length <= input.count else { throw Zlib.Failure.invalidData }
        try ensureRoom(length)
        output += input[position..<(position + length)]
        position += length
    }

    private mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = h.count[len]
            if code - count < first { return h.symbol[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw Zlib.Failure.invalidData
    }

    private mutating func codes(_ lengthCode: Huffman, _ distCode: Huffman) throws {
        while true {
            let symbol = try decode(lengthCode)
            if symbol < 256 {
                try ensureRoom(1)
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let li = symbol - 257
                guard li < Self.lengthBase.count else { throw Zlib.Failure.invalidData }
                let length = Self.lengthBase[li] + (try bits(Self.lengthExtra[li]))
                let di = try decode(distCode)
                guard di < Self.distBase.count else { throw Zlib.Failure.invalidData }
                let distance = Self.distBase[di] + (try bits(Self.distExtra[di]))
                guard distance <= output.count else { throw Zlib.Failure.invalidData }
                try ensureRoom(length)
                let start = output.count - distance
                for i in 0..<length { output.append(output[start + i]) } // 可重叠复制
            }
        }
    }

    private mutating func dynamic() throws {
        let literalCount = try bits(5) + 257
        let distCount = try bits(5) + 1
        let codeCount = try bits(4) + 4
        guard literalCount <= 286, distCount <= 30 else { throw Zlib.Failure.invalidData }

        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<codeCount { codeLengths[Self.codeLengthOrder[i]] = try bits(3) }
        let lengthCode = try Huffman(lengths: codeLengths)

        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distCount)
        while lengths.count < literalCount + distCount {
            let symbol = try decode(lengthCode)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw Zlib.Failure.invalidData }
                lengths += repeatElement(previous, count: 3 + (try bits(2)))
            case 17:
                lengths += repeatElement(0, count: 3 + (try bits(3)))
            default:
                lengths += repeatElement(0, count: 11 + (try bits(7)))
            }
        }
        guard lengths.count == literalCount + distCount, lengths[256] != 0 else { throw Zlib.Failure.invalidData }
        try codes(Huffman(lengths: Array(lengths[..<literalCount])), Huffman(lengths: Array(lengths[literalCount...])))
    }

    private func ensureRoom(_ extra: Int) throws {
        if output.count + extra > Zlib.maxOutput { throw Zlib.Failure.tooLarge }
    }
}
