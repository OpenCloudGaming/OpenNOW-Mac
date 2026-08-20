import Darwin
import Foundation

enum MacForceNowUpdatePreferences {
    static let automaticUpdateChecksEnabledKey = "MacForceNowAutomaticUpdateChecksEnabled"
    static let defaultAutomaticUpdateChecksEnabled = true

    private static let remindAfterKey = "MacForceNowUpdateRemindAfter"

    static var automaticUpdateChecksEnabled: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: automaticUpdateChecksEnabledKey) != nil else {
                return defaultAutomaticUpdateChecksEnabled
            }
            return OPNAppPreferenceStorage.standard.bool(forKey: automaticUpdateChecksEnabledKey)
        }
        set {
            OPNAppPreferenceStorage.standard.set(newValue, forKey: automaticUpdateChecksEnabledKey)
        }
    }

    static var updateChecksAreSuspendedForDebugging: Bool {
        #if DEBUG
        return true
        #else
        return isDebuggerAttached
        #endif
    }

    static var automaticUpdateChecksCanBeScheduled: Bool {
        automaticUpdateChecksEnabled && !updateChecksAreSuspendedForDebugging
    }

    static func shouldRunAutomaticUpdateCheck(now: Date = Date()) -> Bool {
        guard automaticUpdateChecksCanBeScheduled else { return false }
        guard let remindAfterDate else { return true }
        if remindAfterDate <= now {
            clearReminder()
            return true
        }
        return false
    }

    static func remindTomorrow(from date: Date = Date()) {
        let reminderDate = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * 60 * 60)
        OPNAppPreferenceStorage.standard.set(reminderDate.timeIntervalSince1970, forKey: remindAfterKey)
    }

    private static var remindAfterDate: Date? {
        guard OPNAppPreferenceStorage.standard.object(forKey: remindAfterKey) != nil else { return nil }
        let timestamp = OPNAppPreferenceStorage.standard.double(forKey: remindAfterKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func clearReminder() {
        OPNAppPreferenceStorage.standard.removeObject(forKey: remindAfterKey)
    }

    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
