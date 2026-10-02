import AppKit
import Foundation

struct OPNCouchCoopAnnouncement: Equatable, Sendable {
    static let instanceKey = "instance"
    static let processKey = "pid"
    static let screenKey = "screen"
    static let revisionKey = "revision"
    static let assignmentsKey = "assignments"

    let instanceNumber: Int
    let processIdentifier: Int32
    let screenIdentifier: UInt32?
    let assignmentRevision: Int
    let assignmentOverrides: [String: OPNCouchCoopPadTarget]

    init(instanceNumber: Int,
         processIdentifier: Int32,
         screenIdentifier: UInt32?,
         assignmentRevision: Int,
         assignmentOverrides: [String: OPNCouchCoopPadTarget] = [:]) {
        self.instanceNumber = instanceNumber
        self.processIdentifier = processIdentifier
        self.screenIdentifier = screenIdentifier
        self.assignmentRevision = assignmentRevision
        self.assignmentOverrides = assignmentOverrides
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let instanceNumber = userInfo[Self.instanceKey] as? Int,
              let processIdentifier = userInfo[Self.processKey] as? Int,
              let assignmentRevision = userInfo[Self.revisionKey] as? Int,
              instanceNumber >= OPNAppInstance.primaryNumber,
              let processIdentifier = Int32(exactly: processIdentifier) else { return nil }
        self.instanceNumber = instanceNumber
        self.processIdentifier = processIdentifier
        self.assignmentRevision = assignmentRevision
        screenIdentifier = (userInfo[Self.screenKey] as? Int).flatMap { UInt32(exactly: $0) }
        assignmentOverrides = OPNCouchCoopControllerAssignment.overrides(fromPayload: userInfo[Self.assignmentsKey] as? String)
    }

    var userInfo: [String: Any] {
        var values: [String: Any] = [
            Self.instanceKey: instanceNumber,
            Self.processKey: Int(processIdentifier),
            Self.revisionKey: assignmentRevision,
        ]
        if let screenIdentifier { values[Self.screenKey] = Int(screenIdentifier) }
        if !assignmentOverrides.isEmpty {
            values[Self.assignmentsKey] = OPNCouchCoopControllerAssignment.payload(from: assignmentOverrides)
        }
        return values
    }
}

struct OPNCouchCoopRoster: Equatable, Sendable {
    private(set) var announcements: [Int: OPNCouchCoopAnnouncement] = [:]

    var instanceNumbers: [Int] { announcements.keys.sorted() }

    func announcement(forInstance number: Int) -> OPNCouchCoopAnnouncement? {
        announcements[number]
    }

    @discardableResult
    mutating func record(_ announcement: OPNCouchCoopAnnouncement) -> Bool {
        if let existing = announcements[announcement.instanceNumber],
           existing.processIdentifier == announcement.processIdentifier,
           existing.assignmentRevision > announcement.assignmentRevision {
            return false
        }
        let isNewProcess = announcements[announcement.instanceNumber]?.processIdentifier != announcement.processIdentifier
        announcements[announcement.instanceNumber] = announcement
        return isNewProcess
    }

    mutating func prune(livingProcessIdentifiers: Set<Int32>) {
        announcements = announcements.filter { livingProcessIdentifiers.contains($0.value.processIdentifier) }
    }
}

@MainActor
final class OPNCouchCoopPresence: NSObject, ObservableObject {
    static let shared = OPNCouchCoopPresence()

    @Published private(set) var isActive = false
    @Published private(set) var roster = OPNCouchCoopRoster()
    @Published private(set) var assignmentOverrides: [String: OPNCouchCoopPadTarget] = [:]
    private(set) var assignmentRevision = 0

    private let bundleIdentifier: String
    private let ownProcessIdentifier: Int32
    private let instance: OPNAppInstance
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? OPNProductIdentity.releaseBundleIdentifier,
         processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
         instance: OPNAppInstance = OPNAppInstance.current) {
        self.bundleIdentifier = bundleIdentifier
        ownProcessIdentifier = processIdentifier
        self.instance = instance
        super.init()
    }

    static func isActive(isFlagEnabled: Bool, livingProcessIdentifiers: Set<Int32>) -> Bool {
        isFlagEnabled && livingProcessIdentifiers.count > 1
    }

    static func blocksUpdateInstall(isFlagEnabled: Bool, isActive: Bool) -> Bool {
        isFlagEnabled && isActive
    }

    static func announcementName(bundleIdentifier: String) -> Notification.Name {
        Notification.Name("\(bundleIdentifier).couchCoop.presence")
    }

    static func assignmentRequestName(bundleIdentifier: String) -> Notification.Name {
        Notification.Name("\(bundleIdentifier).couchCoop.assignmentRequest")
    }

    static func screenIdentifier(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var blocksUpdateInstall: Bool {
        Self.blocksUpdateInstall(isFlagEnabled: OPNLabs.isCouchCoopEnabled, isActive: isActive)
    }

    func start() {
        guard OPNLabs.isCouchCoopEnabled, !isStarted else { return }
        isStarted = true
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.announce() }
        })
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveAnnouncement(_:)),
            name: Self.announcementName(bundleIdentifier: bundleIdentifier),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveAssignmentRequest(_:)),
            name: Self.assignmentRequestName(bundleIdentifier: bundleIdentifier),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        refresh()
        announce()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var primaryAssignmentOverrides: [String: OPNCouchCoopPadTarget] {
        if instance.isPrimary { return assignmentOverrides }
        return roster.announcement(forInstance: OPNAppInstance.primaryNumber)?.assignmentOverrides ?? [:]
    }

    func setAssignmentOverrides(_ overrides: [String: OPNCouchCoopPadTarget]) {
        guard instance.isPrimary, overrides != assignmentOverrides else { return }
        assignmentOverrides = overrides
        bumpAssignmentRevision()
    }

    func requestAssignmentOverrides(_ overrides: [String: OPNCouchCoopPadTarget]) {
        if instance.isPrimary {
            setAssignmentOverrides(overrides)
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.assignmentRequestName(bundleIdentifier: bundleIdentifier),
            object: nil,
            userInfo: [OPNCouchCoopAnnouncement.assignmentsKey: OPNCouchCoopControllerAssignment.payload(from: overrides)],
            deliverImmediately: true
        )
    }

    func bumpAssignmentRevision() {
        assignmentRevision += 1
        announce()
    }

    func announce() {
        guard isStarted else { return }
        let announcement = ownAnnouncement()
        roster.record(announcement)
        DistributedNotificationCenter.default().postNotificationName(
            Self.announcementName(bundleIdentifier: bundleIdentifier),
            object: nil,
            userInfo: announcement.userInfo,
            deliverImmediately: true
        )
    }

    private func ownAnnouncement() -> OPNCouchCoopAnnouncement {
        OPNCouchCoopAnnouncement(
            instanceNumber: instance.number,
            processIdentifier: ownProcessIdentifier,
            screenIdentifier: Self.screenIdentifier(of: OPNMainWindow.existing()?.screen),
            assignmentRevision: assignmentRevision,
            assignmentOverrides: instance.isPrimary ? assignmentOverrides : [:]
        )
    }

    private func livingProcessIdentifiers() -> Set<Int32> {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
        return Set(others).union([ownProcessIdentifier])
    }

    private func refresh() {
        let living = livingProcessIdentifiers()
        var pruned = roster
        pruned.prune(livingProcessIdentifiers: living)
        if pruned != roster { roster = pruned }
        let active = Self.isActive(isFlagEnabled: OPNLabs.isCouchCoopEnabled, livingProcessIdentifiers: living)
        if active != isActive { isActive = active }
    }

    @objc private func receiveAssignmentRequest(_ notification: Notification) {
        guard instance.isPrimary else { return }
        let payload = notification.userInfo?[OPNCouchCoopAnnouncement.assignmentsKey] as? String
        setAssignmentOverrides(OPNCouchCoopControllerAssignment.overrides(fromPayload: payload))
    }

    @objc private func receiveAnnouncement(_ notification: Notification) {
        guard let announcement = OPNCouchCoopAnnouncement(userInfo: notification.userInfo),
              announcement.processIdentifier != ownProcessIdentifier else { return }
        let isNewPeer = roster.record(announcement)
        refresh()
        if isNewPeer { announce() }
    }
}
