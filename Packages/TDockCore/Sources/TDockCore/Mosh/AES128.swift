/// AES-128 分组加解密（FIPS-197），供 OCB 模式使用。纯 Swift、无平台依赖。
struct AES128 {
    typealias Block = [UInt8] // 16 字节

    private let roundKeys: [UInt8] // 11 × 16 字节

    init(key: [UInt8]) {
        precondition(key.count == 16, "AES-128 需要 16 字节密钥")
        var w = key
        w.reserveCapacity(176)
        var rcon: UInt8 = 1
        for i in stride(from: 16, to: 176, by: 4) {
            var t = Array(w[(i - 4)..<i])
            if i % 16 == 0 {
                t = [Self.sbox[Int(t[1])] ^ rcon, Self.sbox[Int(t[2])], Self.sbox[Int(t[3])], Self.sbox[Int(t[0])]]
                rcon = Self.xtime(rcon)
            }
            for j in 0..<4 { w.append(w[i - 16 + j] ^ t[j]) }
        }
        roundKeys = w
    }

    func encrypt(_ input: Block) -> Block {
        var s = input
        addRoundKey(&s, 0)
        for round in 1..<10 {
            subBytes(&s, Self.sbox)
            shiftRows(&s)
            mixColumns(&s)
            addRoundKey(&s, round)
        }
        subBytes(&s, Self.sbox)
        shiftRows(&s)
        addRoundKey(&s, 10)
        return s
    }

    func decrypt(_ input: Block) -> Block {
        var s = input
        addRoundKey(&s, 10)
        for round in stride(from: 9, through: 1, by: -1) {
            invShiftRows(&s)
            subBytes(&s, Self.invSbox)
            addRoundKey(&s, round)
            invMixColumns(&s)
        }
        invShiftRows(&s)
        subBytes(&s, Self.invSbox)
        addRoundKey(&s, 0)
        return s
    }

    // MARK: - Round operations（状态按列存放：s[row + 4*col]）

    private func addRoundKey(_ s: inout Block, _ round: Int) {
        let base = round * 16
        for i in 0..<16 { s[i] ^= roundKeys[base + i] }
    }

    private func subBytes(_ s: inout Block, _ box: [UInt8]) {
        for i in 0..<16 { s[i] = box[Int(s[i])] }
    }

    private func shiftRows(_ s: inout Block) {
        let t = s
        for row in 1..<4 {
            for col in 0..<4 { s[row + 4 * col] = t[row + 4 * ((col + row) % 4)] }
        }
    }

    private func invShiftRows(_ s: inout Block) {
        let t = s
        for row in 1..<4 {
            for col in 0..<4 { s[row + 4 * ((col + row) % 4)] = t[row + 4 * col] }
        }
    }

    private func mixColumns(_ s: inout Block) {
        for c in 0..<4 {
            let i = 4 * c
            let a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3]
            let all = a0 ^ a1 ^ a2 ^ a3
            s[i] ^= all ^ Self.xtime(a0 ^ a1)
            s[i + 1] ^= all ^ Self.xtime(a1 ^ a2)
            s[i + 2] ^= all ^ Self.xtime(a2 ^ a3)
            s[i + 3] ^= all ^ Self.xtime(a3 ^ a0)
        }
    }

    private func invMixColumns(_ s: inout Block) {
        for c in 0..<4 {
            let i = 4 * c
            let a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3]
            s[i] = Self.mul(a0, 14) ^ Self.mul(a1, 11) ^ Self.mul(a2, 13) ^ Self.mul(a3, 9)
            s[i + 1] = Self.mul(a0, 9) ^ Self.mul(a1, 14) ^ Self.mul(a2, 11) ^ Self.mul(a3, 13)
            s[i + 2] = Self.mul(a0, 13) ^ Self.mul(a1, 9) ^ Self.mul(a2, 14) ^ Self.mul(a3, 11)
            s[i + 3] = Self.mul(a0, 11) ^ Self.mul(a1, 13) ^ Self.mul(a2, 9) ^ Self.mul(a3, 14)
        }
    }

    // MARK: - GF(2^8)

    @inline(__always)
    static func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0)
    }

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, result: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { result ^= a }
            a = xtime(a)
            b >>= 1
        }
        return result
    }

    /// S 盒由 GF(2^8) 求逆 + 仿射变换生成，避免手抄表格出错。
    static let sbox: [UInt8] = {
        var box = [UInt8](repeating: 0, count: 256)
        for x in 0..<256 {
            var inverse: UInt8 = 0
            if x != 0 {
                for y in 1..<256 where mul(UInt8(x), UInt8(y)) == 1 {
                    inverse = UInt8(y)
                    break
                }
            }
            var b = inverse
            var result = b
            for _ in 0..<4 {
                b = (b << 1) | (b >> 7)
                result ^= b
            }
            box[x] = result ^ 0x63
        }
        return box
    }()

    static let invSbox: [UInt8] = {
        var box = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { box[Int(v)] = UInt8(i) }
        return box
    }()
}
