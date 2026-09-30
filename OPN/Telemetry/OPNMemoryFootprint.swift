//  The app's only memory measurement: `phys_footprint`, the number Activity Monitor reports and the
//  one the kernel enforces a memory limit against. Baselines live in `docs/MemoryFootprintBaseline.md`.

import Darwin
import Foundation

/// A point in the launch and stream sequence whose footprint is worth recording.
enum OPNMemoryMilestone: String, CaseIterable, Sendable {
    /// Before any of this app's own work: dyld, the Swift runtime and the telemetry SDK have run.
    case preMain = "pre-main"
    /// The launch splash is on screen, which is the app's first frame.
    case firstFrame = "first-frame"
    /// The catalog behind the splash has content to draw.
    case catalogVisible = "catalog-visible"
    /// The native NVST transport connected and the stream is running.
    case streamConnected = "stream-connected"
}

enum OPNMemoryFootprint {
    /// The process's physical footprint in bytes, or nil when the kernel does not report the field.
    /// `task_info` reads a counter the kernel already keeps, so this allocates nothing and touches no file.
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= physicalFootprintFieldCount else { return nil }
        return info.phys_footprint
    }

    /// Samples and logs one milestone through the diagnostics-log path a user can already send.
    static func record(_ milestone: OPNMemoryMilestone) {
        guard let bytes = physicalFootprintBytes() else {
            OPNLog.warning(.memory, "Memory footprint milestone=\(milestone.rawValue) unavailable")
            return
        }
        OPNLog.info(.memory, "Memory footprint milestone=\(milestone.rawValue) bytes=\(bytes) mib=\(mebibytes(fromBytes: bytes))")
    }

    /// `task_info` fills as many fields as the running kernel knows and reports how many. A shorter
    /// count leaves `phys_footprint` at the zero the struct was initialised with, which reads as data.
    private static var physicalFootprintFieldCount: mach_msg_type_number_t {
        guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint) else { return .max }
        let end = offset + MemoryLayout<mach_vm_size_t>.size
        return mach_msg_type_number_t((end + MemoryLayout<natural_t>.size - 1) / MemoryLayout<natural_t>.size)
    }

    /// One decimal of MiB by integer arithmetic: a `ByteCountFormatter` would allocate a formatter.
    private static func mebibytes(fromBytes bytes: UInt64) -> String {
        let bytesPerMebibyte: UInt64 = 1_048_576
        let tenths = (bytes * 10 + bytesPerMebibyte / 2) / bytesPerMebibyte
        return "\(tenths / 10).\(tenths % 10)"
    }
}
