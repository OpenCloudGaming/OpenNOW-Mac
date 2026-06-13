extension OPNStreamSessionHandle {
    @MainActor func configureSurface(streamView: OPNStreamView?, recordingManager: OPNStreamRecordingManager?) {
        session?.configureSurface(streamView: streamView, recordingManager: recordingManager)
    }

    @MainActor func clearSurfaceCallbacks(streamView: OPNStreamView?) {
        session?.clearSurfaceCallbacks(streamView: streamView)
    }
}
