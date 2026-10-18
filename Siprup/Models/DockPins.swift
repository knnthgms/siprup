import Foundation

/// The four drinks pinned to the home-screen dock, stored as comma-separated type IDs.
enum DockPins {
    static let slotCount = 4
    static let defaultKeys = ["water", "coffee", "tea", "juice"]

    /// Resolves stored IDs to exactly four distinct visible types, filling gaps with sensible defaults.
    static func resolve(_ raw: String, types: [DrinkType]) -> [DrinkType] {
        let visible = types.filter { !$0.isHidden }
        var result: [DrinkType] = []
        for id in raw.split(separator: ",").map(String.init) {
            if let t = visible.first(where: { $0.id.uuidString == id }), !result.contains(where: { $0.id == t.id }) {
                result.append(t)
            }
        }
        let fill = defaultKeys.compactMap { key in visible.first { $0.key == key } } + visible
        for t in fill where result.count < slotCount && !result.contains(where: { $0.id == t.id }) {
            result.append(t)
        }
        return Array(result.prefix(slotCount))
    }

    /// Puts `type` in `slot`; if it was already pinned elsewhere, the two swap.
    static func setting(_ type: DrinkType, slot: Int, in current: [DrinkType]) -> String {
        var ids = current.map(\.id)
        guard ids.indices.contains(slot) else { return ids.map(\.uuidString).joined(separator: ",") }
        if let existing = ids.firstIndex(of: type.id) {
            ids.swapAt(existing, slot)
        } else {
            ids[slot] = type.id
        }
        return ids.map(\.uuidString).joined(separator: ",")
    }
}
