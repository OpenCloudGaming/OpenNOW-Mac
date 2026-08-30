//
//  NativeWebRTCStreamSurface.swift
//  OpenNOW
//
//  SwiftUI bridge to the AppKit stream view. Lives in the view layer because it is presentation:
//  the service layer must not import SwiftUI.
//

import SwiftUI

struct NativeWebRTCStreamSurface: NSViewRepresentable {
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeWebRTCStreamView {
        let view = NativeWebRTCStreamView(frame: .zero)
        Task { @MainActor in onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NativeWebRTCStreamView, context: Context) {}
}
