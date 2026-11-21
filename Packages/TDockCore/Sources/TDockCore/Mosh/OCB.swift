/// AES-128-OCB3（RFC 7253），128 位标签、96 位 nonce——与 Mosh 的加密层一致。
struct AESOCB {
    enum Failure: Error {
        case authenticationFailed
        case invalidInput
    }

    static let tagLength = 16

    private let aes: AES128
    private let lStar: [UInt8]
    private let lDollar: [UInt8]
    private var lTable: [[UInt8]]

    init(key: [UInt8]) {
        aes = AES128(key: key)
        lStar = aes.encrypt([UInt8](repeating: 0, count: 16))
        lDollar = Self.double(lStar)
        var table = [Self.double(lDollar)]
        for _ in 1..<32 { table.append(Self.double(table[table.count - 1])) }
        lTable = table
    }

    /// 返回 密文 || 标签。
    func seal(_ plaintext: [UInt8], nonce: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        var offset = try initialOffset(nonce)
        var checksum = [UInt8](repeating: 0, count: 16)
        var output = [UInt8]()
        output.reserveCapacity(plaintext.count + Self.tagLength)

        let fullBlocks = plaintext.count / 16
        for i in 0..<fullBlocks {
            let block = Array(plaintext[(i * 16)..<(i * 16 + 16)])
            Self.xorInPlace(&offset, lTable[(i + 1).trailingZeroBitCount])
            output += Self.xor(offset, aes.encrypt(Self.xor(block, offset)))
            Self.xorInPlace(&checksum, block)
        }
        let rest = Array(plaintext[(fullBlocks * 16)...])
        if !rest.isEmpty {
            Self.xorInPlace(&offset, lStar)
            let pad = aes.encrypt(offset)
            output += zip(rest, pad).map { $0 ^ $1 }
            Self.xorInPlace(&checksum, Self.padded(rest))
        }
        let tag = Self.xor(aes.encrypt(Self.xor(Self.xor(checksum, offset), lDollar)), hash(associatedData))
        return output + tag
    }

    /// 输入 密文 || 标签，验证通过后返回明文。
    func open(_ sealed: [UInt8], nonce: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        guard sealed.count >= Self.tagLength else { throw Failure.invalidInput }
        let ciphertext = Array(sealed[..<(sealed.count - Self.tagLength)])
        let tag = Array(sealed[(sealed.count - Self.tagLength)...])

        var offset = try initialOffset(nonce)
        var checksum = [UInt8](repeating: 0, count: 16)
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(ciphertext.count)

        let fullBlocks = ciphertext.count / 16
        for i in 0..<fullBlocks {
            let block = Array(ciphertext[(i * 16)..<(i * 16 + 16)])
            Self.xorInPlace(&offset, lTable[(i + 1).trailingZeroBitCount])
            let p = Self.xor(offset, aes.decrypt(Self.xor(block, offset)))
            plaintext += p
            Self.xorInPlace(&checksum, p)
        }
        let rest = Array(ciphertext[(fullBlocks * 16)...])
        if !rest.isEmpty {
            Self.xorInPlace(&offset, lStar)
            let pad = aes.encrypt(offset)
            let p = zip(rest, pad).map { $0 ^ $1 }
            plaintext += p
            Self.xorInPlace(&checksum, Self.padded(p))
        }
        let expected = Self.xor(aes.encrypt(Self.xor(Self.xor(checksum, offset), lDollar)), hash(associatedData))
        // 常数时间比较
        guard zip(expected, tag).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw Failure.authenticationFailed
        }
        return plaintext
    }

    // MARK: - Internals

    private func initialOffset(_ nonce: [UInt8]) throws -> [UInt8] {
        guard nonce.count == 12 else { throw Failure.invalidInput }
        // Nonce = num2str(TAGLEN mod 128, 7) || zeros || 1 || N；TAGLEN = 128 时前 31 位为 0。
        var block: [UInt8] = [0, 0, 0, 1] + nonce
        let bottom = Int(block[15] & 0x3F)
        block[15] &= 0xC0
        let ktop = aes.encrypt(block)
        let stretch = ktop + (0..<8).map { ktop[$0] ^ ktop[$0 + 1] }
        let byteShift = bottom / 8, bitShift = bottom % 8
        return (0..<16).map { i in
            let hi = stretch[i + byteShift]
            guard bitShift > 0 else { return hi }
            return (hi << bitShift) | (stretch[i + byteShift + 1] >> (8 - bitShift))
        }
    }

    private func hash(_ data: [UInt8]) -> [UInt8] {
        var sum = [UInt8](repeating: 0, count: 16)
        var offset = [UInt8](repeating: 0, count: 16)
        let fullBlocks = data.count / 16
        for i in 0..<fullBlocks {
            Self.xorInPlace(&offset, lTable[(i + 1).trailingZeroBitCount])
            Self.xorInPlace(&sum, aes.encrypt(Self.xor(Array(data[(i * 16)..<(i * 16 + 16)]), offset)))
        }
        let rest = Array(data[(fullBlocks * 16)...])
        if !rest.isEmpty {
            Self.xorInPlace(&offset, lStar)
            Self.xorInPlace(&sum, aes.encrypt(Self.xor(Self.padded(rest), offset)))
        }
        return sum
    }

    /// 部分块补齐：data || 0x80 || 0…
    private static func padded(_ data: [UInt8]) -> [UInt8] {
        var block = data
        block.append(0x80)
        while block.count < 16 { block.append(0) }
        return block
    }

    private static func double(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            result[i] = block[i] << 1 | (i < 15 ? block[i + 1] >> 7 : 0)
        }
        if block[0] & 0x80 != 0 { result[15] ^= 0x87 }
        return result
    }

    @inline(__always)
    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = a
        for i in 0..<out.count { out[i] ^= b[i] }
        return out
    }

    @inline(__always)
    private static func xorInPlace(_ a: inout [UInt8], _ b: [UInt8]) {
        for i in 0..<a.count { a[i] ^= b[i] }
    }
}
