import Foundation
import GameController

struct NativeControllerMappingConfiguration: Sendable {
    let deviceID: InputDeviceID
    let playerIndex: Int
    let profile: ControllerMappingProfile?
}

final class NativeGamepadPollState {
    var controllerSlots: [ObjectIdentifier: Int] = [:]
    var steamControllerSlots: [InputDeviceID: Int] = [:]
    var cachedControllers: [GCController] = []
    var pendingEvents: [UserInputEvent] = []
    private var mappingSessions: [ObjectIdentifier: ControllerMappingSession] = [:]
    var lastBatteryLevels: [ObjectIdentifier: Int] = [:]
    private var timer: DispatchSourceTimer?

    func takePendingEvents() -> [UserInputEvent] {
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return pendingEvents
    }

    func configureMappings(_ configurations: [ObjectIdentifier: NativeControllerMappingConfiguration]) -> [UserInputEvent] {
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        var events: [UserInputEvent] = []
        for key in Array(mappingSessions.keys) {
            guard let configuration = configurations[key],
                  configuration.playerIndex == mappingSessions[key]?.playerIndex else {
                if var removed = mappingSessions.removeValue(forKey: key) {
                    events.append(contentsOf: removed.reset(timestamp: timestamp))
                }
                continue
            }
            events.append(contentsOf: mappingSessions[key]?.configure(profile: configuration.profile, timestamp: timestamp) ?? [])
        }
        for (key, configuration) in configurations where mappingSessions[key] == nil {
            mappingSessions[key] = ControllerMappingSession(deviceID: configuration.deviceID, playerIndex: configuration.playerIndex,
                                                            profile: configuration.profile)
        }
        return events
    }

    func resetMappings() -> [UserInputEvent] {
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        return mappingSessions.keys.flatMap { mappingSessions[$0]?.reset(timestamp: timestamp) ?? [] }
    }

    func startPolling(on queue: DispatchQueue, onEvents: @escaping @Sendable ([UserInputEvent]) -> Void, onBatteryChange: @escaping @Sendable ([ControllerBatteryInfo]) -> Void) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.pollAndEmit(onEvents: onEvents, onBatteryChange: onBatteryChange)
        }
        self.timer = timer
        timer.resume()
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    func pollAndEmit(onEvents: @escaping @Sendable ([UserInputEvent]) -> Void, onBatteryChange: @escaping @Sendable ([ControllerBatteryInfo]) -> Void) {
        // No global count gate: it raced the slot maps and could bail every tick, killing the whole
        // poll. The per-controller `controllerSlots[id]` lookup below already skips anything unslotted.
        var events: [UserInputEvent] = []
        var batteryChanges: [ControllerBatteryInfo] = []
        for controller in cachedControllers {
            guard let gamepad = controller.extendedGamepad,
                  let playerIndex = controllerSlots[ObjectIdentifier(controller)] else { continue }
            let identifier = ObjectIdentifier(controller)
            guard var session = mappingSessions[identifier] else { continue }
            let snapshot = ControllerInputSnapshot(gamepad: gamepad)
            events.append(contentsOf: session.process(snapshot, now: .now,
                                                      timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)))
            mappingSessions[identifier] = session
            if let battery = controller.battery {
                let percent = ControllerBatteryInfo.percentage(level: battery.batteryLevel, state: battery.batteryState) ?? -1
                let bucketedLevel = percent < 0 ? -1 : (percent / 5) * 5
                if lastBatteryLevels[identifier] != bucketedLevel {
                    lastBatteryLevels[identifier] = bucketedLevel
                    let label = "P\(playerIndex + 1)"
                    batteryChanges.append(ControllerBatteryInfo(id: "native-\(identifier.hashValue)", label: label, level: percent, charging: battery.batteryState == .charging))
                }
            }
        }
        let currentIDs = Set(cachedControllers.prefix(4).map { ObjectIdentifier($0) })
        let staleIDs = lastBatteryLevels.keys.filter { !currentIDs.contains($0) }
        for staleID in staleIDs {
            lastBatteryLevels.removeValue(forKey: staleID)
        }
        if !events.isEmpty {
            onEvents(events)
        }
        if !batteryChanges.isEmpty {
            onBatteryChange(batteryChanges)
        }
    }
}

