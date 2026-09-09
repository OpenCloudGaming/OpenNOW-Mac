import Foundation
import Testing
@testable import OpenNOW

/// The HUD's mouse readout and the cursor cycle, driven as pure state → text and value → next
/// value. Both helpers are `nonisolated` statics precisely so this suite never has to stand a
/// `@MainActor` stream host up.
struct NativeNVSTHostMouseModeTests {
    @Test func mouseModeSubtitleNamesTheEffectiveMode() {
        #expect(NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: false, isPointerLocked: false).hasPrefix("Absolute"))
        #expect(NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: true, isPointerLocked: false).hasPrefix("Relative"))
        #expect(NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: true, isPointerLocked: true).hasPrefix("Relative"))
    }

    /// Inside the HUD the lock is always down, so relative-without-lock has to read as its own
    /// state rather than borrowing the locked wording.
    @Test func relativeReadsDifferentlyWithAndWithoutTheLock() {
        let locked = NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: true, isPointerLocked: true)
        let unlocked = NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: true, isPointerLocked: false)
        #expect(locked != unlocked)
    }

    /// A manual capture makes the mode relative, so an absolute reading cannot depend on the lock.
    @Test func absoluteIgnoresTheLockFlag() {
        #expect(NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: false, isPointerLocked: true)
            == NativeNVSTHostViewModel.mouseModeSubtitle(isRelative: false, isPointerLocked: false))
    }

    @Test func cursorPolicyCyclesThroughEveryCaseAndWraps() {
        #expect(NativeNVSTHostViewModel.nextCursorPolicy(after: .auto) == .local)
        #expect(NativeNVSTHostViewModel.nextCursorPolicy(after: .local) == .stream)
        #expect(NativeNVSTHostViewModel.nextCursorPolicy(after: .stream) == .auto)

        var visited: [OPNCursorPolicy] = [.auto]
        for _ in 1..<OPNCursorPolicy.allCases.count {
            guard let current = visited.last else { break }
            visited.append(NativeNVSTHostViewModel.nextCursorPolicy(after: current))
        }
        #expect(Set(visited) == Set(OPNCursorPolicy.allCases))
    }

    /// The tile's second line is the only place the chosen option is named, so it has to carry the
    /// same word the Settings picker uses.
    @Test func cursorPolicySubtitleLeadsWithThePolicyLabel() {
        for policy in OPNCursorPolicy.allCases {
            #expect(NativeNVSTHostViewModel.cursorPolicySubtitle(for: policy).hasPrefix(policy.label))
        }
    }
}
