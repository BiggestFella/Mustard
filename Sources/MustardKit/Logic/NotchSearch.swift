import Foundation

/// Anything the notch search box can filter (clips, shelf items, collection
/// contents). `searchText` is a pre-joined haystack: payload + app name + kind.
public protocol NotchSearchable {
    var uid: String { get }
    var searchText: String { get }
}

/// Case-insensitive fuzzy filter: substring hits rank first, then in-order
/// subsequence hits. Stable within each band (preserves input order, which
/// is newest-first at the call sites).
public enum NotchSearch {
    public static func filter<T: NotchSearchable>(_ items: [T], query: String) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        var substrings: [T] = []
        var subsequences: [T] = []
        for item in items {
            let haystack = item.searchText.lowercased()
            if haystack.contains(q) {
                substrings.append(item)
            } else if isSubsequence(q, of: haystack) {
                subsequences.append(item)
            }
        }
        return substrings + subsequences
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        for char in haystack {
            guard index < needle.endIndex else { return true }
            if char == needle[index] { index = needle.index(after: index) }
        }
        return index == needle.endIndex
    }
}
