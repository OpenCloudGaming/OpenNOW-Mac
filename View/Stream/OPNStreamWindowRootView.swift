//  The dedicated stream window's content, hosted by an AppKit-owned `NSWindow`
//  (`OPNStreamWindow`).
//
//  The stream is created here and never moves. `NativeNVSTMediaStreamSurface` holds the session in a
//  `@StateObject`, so reparenting this hosting view between windows would destroy and recreate that
//  object and kill a live session - which is why the window is built for it up front rather than the
//  stream being hosted in the catalog window first.
//
//  What it reads is the application-owned `OPNGameSession`, not the catalog that started it: the
//  catalog is remounted whenever the browsing account changes, and this window has to outlive that.
//  The layout, the launch-loading overlay and the sponsored break all come from the session, so a
//  browsing switch cannot restyle or retarget a running game.
//

import AppKit
import Combine
import SwiftUI

struct OPNStreamWindowRootView: View {
    let configuration: StreamLaunchConfiguration
    let session: OPNGameSession
    @AppStorage(OPNInterfacePreferences.uiScaleKey) private var uiScale = OPNInterfacePreferences.defaultUIScale
    @AppStorage(OPNThemePreferences.accentColorKey) private var accentColorRawValue = OPNThemePreferences.AccentColor.cloudGreen.rawValue
    @AppStorage(OPNThemePreferences.appearanceKey) private var appearanceRawValue = OPNThemePreferences.Appearance.dark.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var windowTopInset: CGFloat = 0

    private var accentColorPreset: OPNThemePreferences.AccentColor {
        OPNThemePreferences.AccentColor(rawValue: accentColorRawValue) ?? .cloudGreen
    }

    private var appearancePreference: OPNThemePreferences.Appearance {
        OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearancePreference {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var body: some View {
        let _ = OPNDesign.applyTheme(accent: accentColorPreset, appearance: appearancePreference, systemColorScheme: colorScheme)
        ZStack {
            GeometryReader { proxy in
                StreamStageLayout(
                    viewport: proxy.size,
                    topInset: windowTopInset,
                    aspectRatio: CGFloat(session.streamProfile.aspectRatio)
                ) { _ in
                    StreamHostView(
                        configuration: configuration,
                        onProgress: { progress in session.updateProgress(progress) },
                        onRequiredSessionAd: { ad in
                            try await session.presentRequiredAd(ad)
                        },
                        onEnd: { success, message, report in
                            session.endStream(success: success, message: message, report: report)
                        }
                    )
                    .id(configuration.id)
                }
            }
            .background(WindowTopInsetReader { windowTopInset = $0 })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.isLaunchLoadingVisible {
                VendorStreamLaunchLoadingOverlay(session: session, windowTopInset: windowTopInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .ignoresSafeArea(edges: .all)
        .background(Color.black)
        .background(StreamWindowAspectConfigurator(aspectRatio: session.streamProfile.aspectRatio, isLocked: true))
        .environment(\.opnUIScale, uiScale)
        .preferredColorScheme(preferredColorScheme)
    }
}
