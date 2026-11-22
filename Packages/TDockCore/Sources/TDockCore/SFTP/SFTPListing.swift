import Foundation

/// SFTP 浏览器的列表处理：隐藏文件、搜索过滤、排序（纯逻辑，便于测试）。
public enum SFTPListing {
    public enum SortKey: String, CaseIterable, Sendable {
        case name
        case modified
        case size

        public var title: String {
            switch self {
            case .name: return "名称"
            case .modified: return "修改时间"
            case .size: return "大小"
            }
        }
    }

    /// 点击文件时直接预览的大小上限；超过时先确认再下载。
    public static let previewLimit: UInt64 = 1024 * 1024

    /// 过滤与排序。目录始终排在文件前；名称比较按 Finder 风格（数字自然排序、忽略大小写）。
    /// ascending = false 时：名称 Z→A、最新的在前、最大的在前。
    public static func arrange(
        _ entries: [SFTPEntry],
        showHidden: Bool,
        query: String = "",
        sortBy key: SortKey = .name,
        ascending: Bool = true
    ) -> [SFTPEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let filtered = entries.filter { entry in
            (showHidden || !entry.name.hasPrefix("."))
                && (trimmed.isEmpty || entry.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.name.localizedStandardCompare(b.name)
            case .modified:
                order = compare(a.attributes.modifyTime ?? 0, b.attributes.modifyTime ?? 0)
            case .size:
                order = compare(a.attributes.size ?? 0, b.attributes.size ?? 0)
            }
            // 主键相同时按名称升序，保证顺序稳定。
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}

/// 远程（POSIX）路径工具。
public enum SFTPPath {
    public struct Crumb: Equatable, Hashable, Sendable {
        public var name: String
        public var path: String
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/", let slash = normalized.lastIndex(of: "/") else { return "/" }
        let parent = String(normalized[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(_ path: String) -> String {
        let normalized = normalize(path)
        return normalized == "/" ? "/" : String(normalized.split(separator: "/").last ?? "/")
    }

    /// 折叠多余的 /、`.`、`..`；结果总是绝对路径（输入应为绝对路径）。
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 面包屑：`/home/me/a` → `/`、`home`、`me`、`a`，每级带完整路径。
    public static func breadcrumbs(_ path: String) -> [Crumb] {
        var crumbs = [Crumb(name: "/", path: "/")]
        var current = ""
        for part in normalize(path).split(separator: "/") {
            current += "/" + part
            crumbs.append(Crumb(name: String(part), path: current))
        }
        return crumbs
    }

    /// 解析用户输入的跳转路径：支持绝对路径、`~`、`~/…`，其余视为相对当前目录。
    public static func resolve(_ input: String, current: String, home: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return normalize(current) }
        if trimmed == "~" { return normalize(home) }
        if trimmed.hasPrefix("~/") { return normalize(join(home, String(trimmed.dropFirst(2)))) }
        if trimmed.hasPrefix("/") { return normalize(trimmed) }
        return normalize(join(current, trimmed))
    }

    /// 校验新文件名（重命名 / 新建文件夹）：非空、不含 /、不是 . 或 ..。
    public static func validateName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "名称不能为空" }
        if trimmed.contains("/") { return "名称不能包含 /" }
        if trimmed == "." || trimmed == ".." { return "名称无效" }
        return nil
    }
}

/// 权限位与八进制文本互转（chmod）。
public enum SFTPPermissions {
    /// 例如 0o100755 → "755"；带 setuid/setgid/sticky 时为 4 位。
    public static func octal(_ permissions: UInt32) -> String {
        let bits = permissions & 0o7777
        return bits > 0o777 ? String(bits, radix: 8) : String(format: "%03o", bits)
    }

    /// 解析 "755" / "0755" / "4755"；不合法时返回 nil。
    public static func parse(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), trimmed.allSatisfy({ ("0"..."7").contains($0) }),
              let value = UInt32(trimmed, radix: 8) else { return nil }
        return value
    }
}
