//  The Picture-in-Picture control strip.
//
//  PiP suppresses the whole HUD - the dock is 268pt wide at its narrowest and the window is 320pt,
//  so it would cover nearly all of the picture - and this replaces it: two actions, on the picture,
//  in the smallest form the design system has. Restore is the way back to the windowed stream;
//  End Session is the same call the in-stream quit menu's third button makes, so a menu bar action
//  and this strip tear down identically.
//
//  Everything here scales with the dock's `opnInterfaceScale(uiScale)`, which the surrounding
//  overlay already applies.
//

import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativePictureInPictureControls: some View {
        HStack(spacing: 6) {
            StreamQuitMenuButton(
                title: "Restore",
                isPrimary: true,
                isFocused: false,
                isDisabled: model.isEnding,
                action: model.togglePictureInPicture
            )
            StreamQuitMenuButton(
                title: "End Session",
                isPrimary: false,
                isFocused: false,
                isDisabled: model.isEnding,
                action: model.endFromStreamControls
            )
        }
        .padding(6)
        .background(StreamHUDTheme.panel.opacity(0.92))
        .overlay {
            Rectangle()
                .stroke(StreamHUDTheme.accent.opacity(0.28), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}
