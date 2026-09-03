//  Remaining-session-time model shown in the stream sidebar. Pure value type over the session
//  descriptor and the seat's limit updates.
//

import Foundation

struct StreamSessionSidebarLimit: Equatable {
    let startedAt: Date
    let durationSeconds: Int

    init?(session: StreamSessionDescriptor, fallbackStartedAt: Date = Date()) {
        guard let duration = Int(session.metadata["sessionLimitSeconds"] ?? ""), duration > 0 else { return nil }
        let startedAtEpoch = Double(session.metadata["startedAtEpochSeconds"] ?? "")
        let startedAt = startedAtEpoch.map { Date(timeIntervalSince1970: $0) } ?? fallbackStartedAt
        self.startedAt = startedAt
        self.durationSeconds = duration
    }

    init?(update: StreamSessionLimitUpdate, receivedAt: Date = Date()) {
        let durationSeconds = max(3600, update.remainingSeconds)
        self.startedAt = receivedAt.addingTimeInterval(-Double(durationSeconds - update.remainingSeconds))
        self.durationSeconds = durationSeconds
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, durationSeconds - Int(now.timeIntervalSince(startedAt)))
    }
}
