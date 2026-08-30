//
//  StreamWindowGeometryGateTests.swift
//  OpenNOWTests
//
//  The gate's whole job is telling "AppKit is between events" from "AppKit is inside a nested run
//  loop of its own". A titlebar double-click crashed the app because the old guard only knew about
//  live resize, and a zoom animation is neither live resize nor observable through a notification —
//  it is only visible as the run loop mode it spins in.
//
//  The mode test is exercised through `isNestedRunLoopMode` rather than by spinning a real nested
//  loop: doing that inside the test harness segfaults it.
//

import CoreFoundation
import Foundation
import Testing
@testable import OpenNOW

@Suite("StreamWindowGeometryGate")
struct StreamWindowGeometryGateTests {
    @Test("event tracking, which is what a zoom animation spins, reads as nested")
    func trackingModeReadsAsNested() {
        #expect(StreamWindowGeometryGate.isNestedRunLoopMode(CFRunLoopMode("NSEventTrackingRunLoopMode" as CFString)))
        #expect(StreamWindowGeometryGate.isNestedRunLoopMode(CFRunLoopMode("NSModalPanelRunLoopMode" as CFString)))
    }

    @Test("the default mode, and no running loop at all, read as mutable")
    func defaultModeReadsAsMutable() {
        #expect(!StreamWindowGeometryGate.isNestedRunLoopMode(.defaultMode))
        #expect(!StreamWindowGeometryGate.isNestedRunLoopMode(nil))
    }
}
