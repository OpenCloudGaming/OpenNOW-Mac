//
//  RecordingEditorFixtures.swift
//  OpenNOWTests
//
//  Recordings and editors for the recording-editor tests, shared by the behaviour tests and the
//  geometry ones.
//

import Foundation
import Testing
@testable import OpenNOW

func makeRecording(
    title: String = "Clip",
    duration: Double = 30,
    width: Int = 1920,
    height: Int = 1080
) -> WebRTCStreamRecording {
    WebRTCStreamRecording(
        id: UUID(),
        title: title,
        applicationID: "com.example.game",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        durationSeconds: duration,
        width: width,
        height: height,
        videoBitrateMbps: 40,
        audioBitrateKbps: 160,
        enhancedVideo: false,
        fileName: "clip.mp4",
        fileSizeBytes: 100_000_000,
        storageDirectoryPath: NSTemporaryDirectory()
    )
}

@MainActor
func makeEditor(duration: Double = 30, width: Int = 1920, height: Int = 1080) -> RecordingEditorViewModel {
    let recording = makeRecording(duration: duration, width: width, height: height)
    return RecordingEditorViewModel(recording: recording, library: [recording])
}

/// Splits the single starting clip into three back-to-back thirds.
@MainActor
func makeThreeClipEditor() -> RecordingEditorViewModel {
    let model = makeEditor(duration: 30)
    model.splitAtPlayhead(10)
    model.selectedSegmentID = model.segments[1].id
    model.splitAtPlayhead(20)
    return model
}

