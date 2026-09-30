//  Memory measurement for the launch and stream path.
//
//  There was no memory instrumentation anywhere in the app, which made every footprint claim
//  unfalsifiable: the only numbers the tree produced were wall-clock timings. One milestone series
//  - pre-main, first frame, catalog visible, stream connected - is enough to attribute a footprint
//  regression to a phase without a profiler attached, and it lands in the diagnostics file a user
//  can already send.
//
//  `phys_footprint` rather than resident size: it is the number Activity Monitor reports and the
//  number the kernel enforces a memory limit against, so it is the one worth tracking.
//
//  `docs/MemoryFootprintBaseline.md` records what these numbers were on a named machine.

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
    /// The process's physical footprint in bytes, or nil if the kernel did not report it.
    ///
    /// `task_vm_info_data_t` lives on the stack and `task_info` only reads counters the kernel
    /// already keeps: this allocates nothing, takes no lock and touches no file, so it is safe on
    /// the launch path and safe from any thread.
    static func currentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= physFootprintFieldCount else { return nil }
        return info.phys_footprint
    }

    /// Samples and logs one milestone through the ordinary `OPNLog` path, which is what puts the
    /// number in the diagnostics log. The file write is that path's own async queue and never this
    /// call, so nothing here blocks the launch path on disk.
    static func record(_ milestone: OPNMemoryMilestone) {
        guard let bytes = currentBytes() else {
            OPNLog.warning(.memory, "Memory footprint milestone=\(milestone.rawValue) unavailable")
            return
        }
        OPNLog.info(.memory, "Memory footprint milestone=\(milestone.rawValue) bytes=\(bytes) mib=\(mebibytes(bytes))")
    }

    /// `task_info` writes as many fields as the running kernel knows about and reports how many it
    /// wrote. A count short of this one means `phys_footprint` was never filled in and reads back
    /// as the zero the struct was initialised with, which would be recorded as a real measurement.
    private static var physFootprintFieldCount: mach_msg_type_number_t {
        guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint) else { return .max }
        let end = offset + MemoryLayout<mach_vm_size_t>.size
        return mach_msg_type_number_t((end + MemoryLayout<natural_t>.size - 1) / MemoryLayout<natural_t>.size)
    }

    /// One decimal of MiB by integer arithmetic. A `ByteCountFormatter` would allocate a formatter
    /// on the launch path for a log line nothing parses.
    private static func mebibytes(_ bytes: UInt64) -> String {
        let tenths = (bytes * 10 + 524_288) / 1_048_576
        return "\(tenths / 10).\(tenths % 10)"
    }
}
