//
//  The scroll wheel: accumulating AppKit's continuous scrolling into the notch counts the wire
//  carries, and keeping the sideways axis to gestures that are actually sideways.
//

import AppKit

/// Decides, once per trackpad gesture, whether that gesture is allowed to speak on the horizontal
/// axis at all.
///
/// An ordinary two-finger vertical scroll carries a small nonzero `scrollingDeltaX` on nearly every
/// event, and keeps carrying it through the momentum tail. A free-running sideways carry sums that
/// noise until it crosses a detent and ships a horizontal packet nobody asked for — and the
/// horizontal packet's wire meaning is still an unverified reading of word 0 of the type-10 body,
/// so the most common gesture in the client would be the one shipping guessed bytes to the seat.
///
/// Comparing `|dx|` against `|dy|` on the event in hand is not enough to stop that: at the start of
/// a gesture, before the fingers have travelled, and again in the tail as `dy` decays towards zero,
/// individual events legitimately arrive with `|dx| >= |dy|` while the gesture as a whole is
/// plainly vertical. The judgement therefore has to be latched once, from travel accumulated across
/// events, and held for the rest of the gesture including its momentum.
///
/// Horizontal needs positive evidence, not merely the absence of vertical evidence: nothing is
/// emitted sideways until the sideways travel dominates, which is exactly what a deliberate swipe
/// or a shift-scroll produces on its first event or two.
struct NativeWebRTCScrollAxisFilter: Equatable, Sendable {
    /// Where an event sits in AppKit's gesture lifecycle. A wheel produces no phase at all, which
    /// is `.none` and is deliberately left unscoped.
    enum Phase: Equatable, Sendable {
        case began
        case gesture
        case momentum
        case none
    }

    private enum Lock: Equatable {
        case undecided
        case vertical
        case free
    }

    /// One detent's worth of continuous travel — the same 1.0 that `quantizedWheelDelta` turns into
    /// a packet. Judging any earlier reads finger jitter; judging later would drop a detent off the
    /// front of a deliberate swipe.
    static let decisionTravel = 1.0
    /// How far one axis must outrun the other before the gesture is called. Vertical scrolls run an
    /// order of magnitude past this; a 45° diagonal never reaches it and stays silent sideways.
    static let axisDominance = 2.0

    private var lock = Lock.free
    private var travelX = 0.0
    private var travelY = 0.0

    mutating func allowsHorizontal(phase: Phase, deltaX: Double, deltaY: Double) -> Bool {
        switch phase {
        case .none:
            // A wheel, a tilt wheel and shift-scroll all arrive phaseless, so there is no gesture to
            // scope and no finger noise to contain: what the device reported sideways was meant.
            reset(to: .free)
            return true
        case .began:
            reset(to: .undecided)
        case .gesture, .momentum:
            break
        }
        guard lock == .undecided else { return lock == .free }
        guard deltaX.isFinite, deltaY.isFinite else { return false }
        travelX += abs(deltaX)
        travelY += abs(deltaY)
        if travelX >= Self.decisionTravel, travelX > travelY * Self.axisDominance {
            lock = .free
        } else if travelY >= Self.decisionTravel, travelY > travelX * Self.axisDominance {
            lock = .vertical
        }
        return lock == .free
    }

    private mutating func reset(to lock: Lock) {
        self.lock = lock
        travelX = 0
        travelY = 0
    }
}

extension NativeWebRTCStreamView {
    func emitScrollWheel(_ event: NSEvent) {
        let timestamp = Self.timestamp()
        let phase = Self.scrollPhase(of: event)
        if phase == .began {
            // A fresh gesture starts from nothing: a fraction left over from the previous one would
            // otherwise be spent on this gesture's first detent.
            preciseScrollRemainder = 0
            preciseHorizontalScrollRemainder = 0
        }
        let allowsHorizontal = scrollAxisFilter.allowsHorizontal(phase: phase,
                                                                 deltaX: event.scrollingDeltaX,
                                                                 deltaY: event.scrollingDeltaY)
        let verticalDelta = Self.accumulatedWheelDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            remainder: &preciseScrollRemainder
        )
        if verticalDelta != 0 {
            onInputEvent?(.mouse(.wheel(deviceID: "mouse", delta: verticalDelta, timestamp: timestamp)))
        }
        guard allowsHorizontal else {
            // Dropped rather than carried: the noise of a vertical gesture is not sideways intent
            // being saved up for later.
            preciseHorizontalScrollRemainder = 0
            return
        }
        let horizontalDelta = Self.accumulatedWheelDelta(
            scrollingDeltaX: event.scrollingDeltaX,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            remainder: &preciseHorizontalScrollRemainder
        )
        guard horizontalDelta != 0 else { return }
        onInputEvent?(.mouse(.horizontalWheel(deviceID: "mouse", delta: horizontalDelta, timestamp: timestamp)))
    }

    /// Momentum arrives with an empty `phase` and a set `momentumPhase`, so the two have to be read
    /// in that order; a mouse wheel sets neither.
    static func scrollPhase(of event: NSEvent) -> NativeWebRTCScrollAxisFilter.Phase {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { return .began }
        if !event.momentumPhase.isEmpty { return .momentum }
        if !event.phase.isEmpty { return .gesture }
        return .none
    }

    static func accumulatedWheelDelta(scrollingDeltaY: Double,
                                      hasPreciseScrollingDeltas: Bool,
                                      remainder: inout Double) -> Int16 {
        quantizedWheelDelta(scrollingDeltaY, hasPreciseScrollingDeltas: hasPreciseScrollingDeltas, remainder: &remainder)
    }

    /// Shift-scroll, a tilt wheel and a two-finger sideways swipe all arrive as `scrollingDeltaX`
    /// on the same event, in the same units as the vertical axis, so the quantisation is shared and
    /// only the carry is per-axis. Which of those events reach here at all is the axis filter's
    /// decision, not this one's.
    static func accumulatedWheelDelta(scrollingDeltaX: Double,
                                      hasPreciseScrollingDeltas: Bool,
                                      remainder: inout Double) -> Int16 {
        quantizedWheelDelta(scrollingDeltaX, hasPreciseScrollingDeltas: hasPreciseScrollingDeltas, remainder: &remainder)
    }

    private static func quantizedWheelDelta(_ scrolling: Double,
                                            hasPreciseScrollingDeltas: Bool,
                                            remainder: inout Double) -> Int16 {
        guard scrolling.isFinite else { return 0 }
        if !hasPreciseScrollingDeltas {
            remainder = 0
            let scaled = min(max((scrolling * 120).rounded(), Double(Int16.min)), Double(Int16.max))
            return Int16(scaled)
        }
        remainder += scrolling
        let completeDetents = remainder.rounded(.towardZero)
        guard completeDetents != 0 else { return 0 }
        let packetLimit = Double(Int16.max / 120)
        let packetDetents = min(max(completeDetents, -packetLimit), packetLimit)
        remainder -= packetDetents
        return Int16(packetDetents * 120)
    }
}
