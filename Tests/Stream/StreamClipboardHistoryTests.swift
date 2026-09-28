import Foundation
import Testing
@testable import OpenNOW

/// The clipboard history store: cap, dedupe, persistence and clear. Every test owns a temporary file
/// so parallel runs cannot stomp one another and nothing touches the reader's real history.
private func makeClipboardStore() -> StreamClipboardHistoryStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenNOWTests.Clipboard.\(UUID().uuidString)", isDirectory: true)
    return StreamClipboardHistoryStore(fileURL: directory.appendingPathComponent("ClipboardHistory.json"))
}

struct StreamClipboardHistoryTests {
    @Test func itFilesTheNewestEntryFirst() {
        let store = makeClipboardStore()
        let now = Date()
        store.append(text: "first", applicationID: "100", gameTitle: "Game", capturedAt: now)
        store.append(text: "second", applicationID: "100", gameTitle: "Game", capturedAt: now.addingTimeInterval(10))
        #expect(store.load().map(\.text) == ["second", "first"])
    }

    @Test func itReadsBackAcrossStoreInstances() {
        let store = makeClipboardStore()
        store.append(text: "persisted", applicationID: "100", gameTitle: "Game")
        let reopened = StreamClipboardHistoryStore(fileURL: store.fileURL)
        #expect(reopened.load().map(\.text) == ["persisted"])
    }

    @Test func identicalTextInsideTheWindowIsNotFiledTwice() {
        let store = makeClipboardStore()
        let now = Date()
        #expect(store.append(text: "same", applicationID: "100", gameTitle: "Game", capturedAt: now) != nil)
        #expect(store.append(text: "same", applicationID: "100", gameTitle: "Game", capturedAt: now.addingTimeInterval(10)) == nil)
        #expect(store.load().count == 1)
    }

    @Test func identicalTextOutsideTheWindowIsANewEntry() {
        let store = makeClipboardStore()
        let now = Date()
        store.append(text: "same", applicationID: "100", gameTitle: "Game", capturedAt: now)
        store.append(text: "same", applicationID: "100", gameTitle: "Game", capturedAt: now.addingTimeInterval(StreamClipboardHistoryStore.dedupeWindow + 1))
        #expect(store.load().count == 2)
    }

    @Test func theHistoryIsCappedAtOneHundredEntriesOldestFirst() {
        let store = makeClipboardStore()
        let now = Date()
        for index in 0..<(StreamClipboardHistoryStore.entryLimit + 5) {
            store.append(text: "entry-\(index)", applicationID: "100", gameTitle: "Game", capturedAt: now.addingTimeInterval(Double(index)))
        }
        let entries = store.load()
        #expect(entries.count == StreamClipboardHistoryStore.entryLimit)
        #expect(entries.first?.text == "entry-\(StreamClipboardHistoryStore.entryLimit + 4)")
        #expect(entries.last?.text == "entry-5")
    }

    @Test func replacingAnEntrysTextKeepsItsPlace() {
        let store = makeClipboardStore()
        let now = Date()
        store.append(text: "head \u{2026}", applicationID: "100", gameTitle: "Game", capturedAt: now)
        store.append(text: "newer", applicationID: "100", gameTitle: "Game", capturedAt: now.addingTimeInterval(10))
        let clipped = store.load().first { $0.text.hasSuffix("\u{2026}") }!
        #expect(store.replace(id: clipped.id, text: "head and tail") != nil)
        let entries = store.load()
        #expect(entries.count == 2)
        #expect(entries.first?.text == "newer")
        #expect(entries.last?.text == "head and tail")
        #expect(StreamClipboardHistoryStore(fileURL: store.fileURL).load().last?.text == "head and tail")
    }

    @Test func replacingAnUnknownEntryChangesNothing() {
        let store = makeClipboardStore()
        store.append(text: "kept", applicationID: "100", gameTitle: "Game")
        #expect(store.replace(id: UUID(), text: "ignored") == nil)
        #expect(store.load().map(\.text) == ["kept"])
    }

    @Test func removingOneEntryLeavesTheRest() {
        let store = makeClipboardStore()
        let now = Date()
        store.append(text: "first", applicationID: "100", gameTitle: "Game", capturedAt: now)
        store.append(text: "second", applicationID: "100", gameTitle: "Game", capturedAt: now.addingTimeInterval(10))
        let oldest = store.load().first { $0.text == "first" }!
        #expect(store.remove(id: oldest.id))
        #expect(store.load().map(\.text) == ["second"])
        #expect(StreamClipboardHistoryStore(fileURL: store.fileURL).load().map(\.text) == ["second"])
    }

    @Test func removingAnUnknownEntryChangesNothing() {
        let store = makeClipboardStore()
        store.append(text: "kept", applicationID: "100", gameTitle: "Game")
        #expect(!store.remove(id: UUID()))
        #expect(store.load().map(\.text) == ["kept"])
    }

    @Test func clearEmptiesTheHistoryAndSurvivesAReopen() {
        let store = makeClipboardStore()
        store.append(text: "gone", applicationID: "100", gameTitle: "Game")
        store.clear()
        #expect(store.load().isEmpty)
        #expect(StreamClipboardHistoryStore(fileURL: store.fileURL).load().isEmpty)
    }
}
