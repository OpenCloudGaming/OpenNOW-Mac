import Testing
@testable import OpenNOW

/// The in-app Reduce Motion switch only ever adds to the system setting: a reader who turned on
/// macOS Reduce Motion must never get animation back because the in-app preference is off.
@Test func systemReduceMotionOnAndPreferenceOffIsReduced() {
    #expect(OPNDesign.Motion.isMotionReduced(system: true, preference: false))
}

@Test func systemReduceMotionOffAndPreferenceOnIsReduced() {
    #expect(OPNDesign.Motion.isMotionReduced(system: false, preference: true))
}

@Test func systemReduceMotionOffAndPreferenceOffIsNotReduced() {
    #expect(!OPNDesign.Motion.isMotionReduced(system: false, preference: false))
}

@Test func systemReduceMotionOnAndPreferenceOnIsReduced() {
    #expect(OPNDesign.Motion.isMotionReduced(system: true, preference: true))
}
