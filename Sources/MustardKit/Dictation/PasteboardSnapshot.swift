import Foundation

/// Every type/data pair of one pasteboard item — enough to rebuild it exactly.
public struct PasteboardItemSnapshot: Equatable, Sendable {
    public var types: [String: Data]

    public init(types: [String: Data]) {
        self.types = types
    }
}

/// A lossless capture of the whole pasteboard (Dictation Task 3, BAK-289),
/// taken before the paste fallback writes the transcript and restored only
/// while the pasteboard still holds Mustard's write — a newer external
/// clipboard change is never overwritten.
public struct PasteboardSnapshot: Equatable, Sendable {
    public var items: [PasteboardItemSnapshot]
    /// The pasteboard's changeCount at capture time.
    public var changeCount: Int

    public init(items: [PasteboardItemSnapshot], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }

    /// The one restoration rule: restore only when the current changeCount is
    /// still the one Mustard's transcript write produced.
    public static func shouldRestore(currentCount: Int, mustardWriteCount: Int) -> Bool {
        currentCount == mustardWriteCount
    }
}

#if os(macOS)
import AppKit

extension PasteboardSnapshot {
    /// Capture every item's full type/data set from `pasteboard`.
    public static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(types: Dictionary(uniqueKeysWithValues:
                item.types.compactMap { type in
                    item.data(forType: type).map { (type.rawValue, $0) }
                }))
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    /// Write the transcript for the ⌘V fallback; returns the resulting
    /// changeCount (the token `shouldRestore` compares against).
    @discardableResult
    public static func write(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Rebuild the captured items exactly.
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let rebuilt = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.types {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(rebuilt)
    }
}
#endif
