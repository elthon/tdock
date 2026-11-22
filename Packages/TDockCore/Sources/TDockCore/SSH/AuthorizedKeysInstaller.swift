import Foundation

/// 内置 ssh-copy-id：构造把公钥幂等地追加到服务器 authorized_keys 的脚本。
///
/// 公钥只接受单行 `ssh-ed25519` / `ecdsa-sha2-nistp{256,384,521}` + base64（注释只保留安全字符），
/// 并且整体经单引号转义后用 `sh -c` 执行，杜绝命令注入。
public enum AuthorizedKeysInstaller {
    public enum InstallError: Error, LocalizedError, Equatable {
        case invalidPublicKey
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPublicKey: return "公钥格式不正确（只支持 Ed25519 / ECDSA 公钥）"
            case .failed(let message): return "部署公钥失败：\(message)"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// 已追加到 authorized_keys
        case installed
        /// 公钥已存在，未重复追加
        case alreadyPresent
    }

    static let allowedTypes: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
    static let installedMarker = "TDOCK_KEY_INSTALLED"
    static let presentMarker = "TDOCK_KEY_PRESENT"

    /// 注释只保留字母数字与 `._@-+`，其余字符（空格、引号、换行等）去掉。
    public static func sanitizeComment(_ comment: String) -> String {
        String(comment.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._@-+".unicodeScalars.contains($0))
        }.map(Character.init))
    }

    /// 校验并规范化公钥行，返回 (密钥部分 `type base64`, 完整行)。
    public static func normalize(publicKey: String) throws -> (body: String, line: String) {
        let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { throw InstallError.invalidPublicKey }
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, allowedTypes.contains(String(parts[0])) else { throw InstallError.invalidPublicKey }
        let base64 = String(parts[1])
        let base64Chars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard base64.unicodeScalars.allSatisfy(base64Chars.contains),
              let blob = Data(base64Encoded: base64), !blob.isEmpty
        else { throw InstallError.invalidPublicKey }
        let body = "\(parts[0]) \(base64)"
        let comment = parts.count > 2 ? sanitizeComment(String(parts[2])) : ""
        return (body, comment.isEmpty ? body : "\(body) \(comment)")
    }

    /// 生成在服务器上执行的命令。
    /// - Parameter authorizedKeysPath: 默认 `~/.ssh/authorized_keys`；sshd 配置了其他 AuthorizedKeysFile 时可指定绝对路径。
    public static func command(publicKey: String, authorizedKeysPath: String? = nil) throws -> String {
        let (body, line) = try normalize(publicKey: publicKey)
        let file = authorizedKeysPath.map(ShellQuote.quote) ?? "\"$HOME/.ssh/authorized_keys\""
        // 默认位置才收紧 ~/.ssh 目录权限（StrictModes 要求）；自定义路径不改其目录权限。
        let tightenDir = authorizedKeysPath == nil ? "chmod 700 \"$D\" || exit 1; " : ""
        let script = """
        umask 077; F=\(file); D=$(dirname "$F"); \
        mkdir -p "$D" || exit 1; \(tightenDir)\
        [ -f "$F" ] || : > "$F" || exit 1; chmod 600 "$F" || exit 1; \
        if grep -qF \(ShellQuote.quote(body)) "$F"; then echo \(presentMarker); exit 0; fi; \
        if [ -s "$F" ] && [ -n "$(tail -c 1 "$F")" ]; then echo >> "$F"; fi; \
        printf '%s\\n' \(ShellQuote.quote(line)) >> "$F" || exit 1; echo \(installedMarker)
        """
        return ShellQuote.script(script)
    }

    /// 解析执行结果。
    public static func outcome(of result: SSHExecResult) throws -> Outcome {
        if result.succeeded && result.stdout.contains(presentMarker) { return .alreadyPresent }
        if result.succeeded && result.stdout.contains(installedMarker) { return .installed }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw InstallError.failed(message.isEmpty ? "退出码 \(result.exitStatus.map(String.init) ?? "未知")" : message)
    }

    /// 在已登录的连接上执行部署。
    public static func install(publicKey: String, on client: SSHClient, authorizedKeysPath: String? = nil) async throws -> Outcome {
        let result = try await client.exec(try command(publicKey: publicKey, authorizedKeysPath: authorizedKeysPath))
        return try outcome(of: result)
    }
}
