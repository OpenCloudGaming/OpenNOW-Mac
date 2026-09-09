import Foundation
import Testing
@testable import OpenNOW

/// `0x0110` carries the seat's cursor *shape*, and the whole risk in reading it is that a shape
/// push looks like "there is a pointer" while the game is holding the cursor captive for mouselook.
/// These pin both halves: what the payload yields, and the fact that it can only ever confirm a
/// pointer that is already on screen.
@Suite struct NvstRemoteCursorBitmapTests {
    private func bitmapCommand(id: UInt32, size: UInt32, trailing: Int = 0) -> NvstControlCommand {
        var writer = NvstByteWriter(capacity: 8 + trailing)
        writer.u32LE(id)
        writer.u32LE(size)
        writer.zeroes(trailing)
        return NvstControlCommand(code: NvstRemoteCursor.bitmapCursorCode, payload: writer.data)
    }

    /// The id/size pair the official handler logs, in the order it logs them.
    @Test func aBitmapCursorYieldsTheIdAndSizeTheOfficialHandlerLogs() throws {
        let cursor = try #require(NvstRemoteCursor.from(bitmapCommand(id: 7, size: 4096, trailing: 64)))
        #expect(cursor.source == .bitmapCursor)
        #expect(cursor.bitmap == NvstRemoteCursor.Bitmap(id: 7, byteCount: 4096))
        #expect(cursor.summary == "bitmap id=7 size=4096")
    }

    /// Bitmap id 0 is a real shape, unlike system cursor id 0 which is the "no cursor" shape.
    @Test func aBitmapCursorWithIdZeroIsStillACursor() throws {
        let cursor = try #require(NvstRemoteCursor.from(bitmapCommand(id: 0, size: 1024)))
        #expect(cursor.source == .bitmapCursor)
        #expect(cursor.bitmap?.id == 0)
        #expect(cursor.isVisible)
    }

    /// Nothing shorter than the pair is claimed to be understood: it keeps flowing to the unparsed
    /// log, which is where a capture that settles the layout would arrive.
    @Test func aBitmapPayloadTooShortForThePairIsNotParsed() {
        #expect(NvstRemoteCursor.from(NvstControlCommand(code: 0x0110, payload: Data())) == nil)
        #expect(NvstRemoteCursor.from(NvstControlCommand(code: 0x0110, payload: Data(repeating: 0, count: 7))) == nil)
    }

    /// The load-bearing invariant. The seat keeps pushing shapes throughout mouselook, so a bitmap
    /// notification must never raise a pointer the game has hidden — nor invent one before any
    /// `0x010f` has said what the game wants.
    @Test func aBitmapPushCannotUnhideThePointer() throws {
        let bitmap = try #require(NvstRemoteCursor.from(bitmapCommand(id: 3, size: 256)))
        #expect(bitmap.visibility(following: false) == false)
        #expect(bitmap.visibility(following: nil) == nil)
        // It may confirm a pointer that is already on screen.
        #expect(bitmap.visibility(following: true) == true)
    }

    /// The system cursor keeps its authority: it states the state rather than confirming one.
    @Test func aSystemCursorNotificationStillDecidesVisibility() throws {
        let hidden = try #require(NvstRemoteCursor.from(NvstControlCommand(code: 0x010f, payload: Data(repeating: 0, count: 4))))
        #expect(hidden.visibility(following: true) == false)
        let shown = try #require(NvstRemoteCursor.from(NvstControlCommand(code: 0x010f, payload: Data([0, 0, 0, 2]))))
        #expect(shown.visibility(following: false) == true)
        #expect(shown.summary == "system visible")
    }
}
