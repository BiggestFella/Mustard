import Foundation
import SwiftData

/// A user-named bucket of clips (the Supaste "+" tabs: Prompts, Colors, …).
/// Deleting a collection unfiles its items (nullify), never deletes them.
@Model
public final class ClipCollection {
    public var uid: String = UUID().uuidString
    public var name: String = ""
    public var sortOrder: Int = 0
    public var createdAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \ClipItem.collection)
    public var items: [ClipItem]? = []

    public init(name: String = "", sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }
}
