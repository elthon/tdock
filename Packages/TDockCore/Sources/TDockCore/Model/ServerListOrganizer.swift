import Foundation

/// 服务器列表的搜索、分组与置顶排序（纯逻辑，便于测试）。
public enum ServerListOrganizer {
    public struct Section: Equatable, Identifiable, Sendable {
        public enum Kind: Hashable, Sendable {
            case pinned
            case group(String)
            case ungrouped
        }

        public var kind: Kind
        public var servers: [ServerProfile]

        public var id: Kind { kind }

        public var title: String? {
            switch kind {
            case .pinned: return "置顶"
            case .group(let name): return name
            case .ungrouped: return nil
            }
        }
    }

    /// 是否匹配搜索词：名称、主机、用户名、分组，忽略大小写与变音符；多个词需全部命中。
    public static func matches(_ server: ServerProfile, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = [server.displayName, server.host, server.username, server.groupName,
                        "\(server.username)@\(server.host)"]
        return terms.allSatisfy { term in
            haystack.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// 分区：置顶 → 各分组（按名称）→ 未分组。分区内保持原有顺序；空分区不返回。
    /// 没有任何分组时，未分组分区不显示标题（与普通列表一致）。
    public static func sections(_ servers: [ServerProfile], query: String = "") -> [Section] {
        let filtered = servers.filter { matches($0, query: query) }
        var result: [Section] = []
        let pinned = filtered.filter(\.pinned)
        if !pinned.isEmpty { result.append(Section(kind: .pinned, servers: pinned)) }

        let rest = filtered.filter { !$0.pinned }
        let groups = Set(rest.map(\.groupName)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for group in groups {
            result.append(Section(kind: .group(group), servers: rest.filter { $0.groupName == group }))
        }
        let ungrouped = rest.filter { $0.groupName.isEmpty }
        if !ungrouped.isEmpty { result.append(Section(kind: .ungrouped, servers: ungrouped)) }
        return result
    }

    /// 已使用过的分组名（编辑服务器时作为候选）。
    public static func groupNames(_ servers: [ServerProfile]) -> [String] {
        Set(servers.map(\.groupName)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
