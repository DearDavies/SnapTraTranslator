import AppKit
import Foundation

@MainActor
final class PasteboardCoordinator {
    struct Lease: Equatable {
        fileprivate let id: UUID
    }

    struct Snapshot {
        let changeCount: Int
        fileprivate let items: [[NSPasteboard.PasteboardType: Data]]
    }

    struct WriteResult {
        let succeeded: Bool
        let changeCount: Int
    }

    static let shared = PasteboardCoordinator()

    private let pasteboard: NSPasteboard
    private var activeLeaseID: UUID?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func acquire() -> Lease? {
        guard activeLeaseID == nil else { return nil }
        let lease = Lease(id: UUID())
        activeLeaseID = lease.id
        return lease
    }

    func release(_ lease: Lease) {
        guard activeLeaseID == lease.id else { return }
        activeLeaseID = nil
    }

    func capture(using lease: Lease) -> Snapshot? {
        guard owns(lease) else { return nil }
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in pasteboardItem.types {
                if let data = pasteboardItem.data(forType: type) {
                    itemData[type] = data
                }
            }
            items.append(itemData)
        }
        return Snapshot(changeCount: pasteboard.changeCount, items: items)
    }

    func write(
        _ text: String,
        using lease: Lease,
        expectedChangeCount: Int
    ) -> WriteResult? {
        guard owns(lease) else { return nil }
        guard pasteboard.changeCount == expectedChangeCount else { return nil }
        pasteboard.clearContents()
        let succeeded = pasteboard.setString(text, forType: .string)
        return WriteResult(succeeded: succeeded, changeCount: pasteboard.changeCount)
    }

    @discardableResult
    func restore(
        _ snapshot: Snapshot,
        using lease: Lease,
        ifChangeCount expectedChangeCount: Int
    ) -> Bool {
        guard owns(lease) else { return false }
        guard SelectedTextReplacementPolicy.shouldRestorePasteboard(
            currentChangeCount: pasteboard.changeCount,
            ownedChangeCount: expectedChangeCount
        ) else {
            return false
        }

        pasteboard.clearContents()
        let items = snapshot.items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        return true
    }

    private func owns(_ lease: Lease) -> Bool {
        activeLeaseID == lease.id
    }
}
