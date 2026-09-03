//
//  RecordingProgressivePolling.swift
//  OpenNOW
//
//  Both the filmstrip and the waveform are built in the background and published in pieces, and
//  both are read by a view that wants to redraw as the pieces land. Three copies of the same
//  five-line loop had already drifted - one returned on completion, one kept looping, one skipped
//  its first read.
//

import Foundation

/// Applies a store's snapshot until it says it is finished, or until the caller's task is
/// cancelled. Reads once before the first sleep, so a store that is already complete draws
/// immediately rather than after the interval.
@MainActor
func recordingPollUntilComplete<Value>(
    interval: Duration = .milliseconds(250),
    snapshot: () -> Value,
    isComplete: () -> Bool,
    apply: (Value) -> Void
) async {
    while !Task.isCancelled {
        apply(snapshot())
        if isComplete() { return }
        try? await Task.sleep(for: interval)
    }
}
