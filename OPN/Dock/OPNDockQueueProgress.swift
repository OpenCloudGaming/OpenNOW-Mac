import Foundation

/// How far a wait for a seat has got, as the Dock tile can draw it.
///
/// The vendor reports a queue position and never a fraction, so the fraction is measured against the
/// position the wait started at: the wait is over when the seat is granted, which is the position
/// reaching zero. A wait that starts at the front of the queue has nothing to measure against and
/// reads as an empty bar until it ends — honest, rather than a bar that invents movement.
///
/// The same reasoning as `OPNMenuBarQueueEstimate`, which turns the same positions into a time
/// projection for the status item: one surface shows how long is left, this one shows how much is
/// behind.
struct OPNDockQueueProgress: Equatable, Sendable {
    /// Where the queue was when this wait started. Cleared when there is nothing queued.
    private(set) var entryPosition: Int?

    /// Takes a reported position and answers the fraction to draw, or nil when nothing is queued.
    mutating func observe(position: Int) -> Double? {
        guard position > 0 else {
            reset()
            return nil
        }
        guard let entryPosition else {
            // The wait starts here, so it starts empty. `entryPosition` is kept rather than replaced:
            // a position that moves backwards later is the same wait having advanced.
            self.entryPosition = position
            return 0
        }
        // A queue can grow as well as shrink — the vendor re-queues, and a position can come back
        // higher than it was. That is not progress, so the bar holds at the start rather than
        // running backwards.
        let cleared = Double(entryPosition - position)
        let total = Double(max(1, entryPosition - 1))
        return min(1, max(0, cleared / total))
    }

    mutating func reset() {
        entryPosition = nil
    }
}
