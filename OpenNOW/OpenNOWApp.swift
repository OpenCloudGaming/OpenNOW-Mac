//
//  OpenNOWApp.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import SwiftUI
import SwiftData
import WebRTCMedia

@main
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OpenNOWAppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        CatalogImageCache.shared.configure(container: container)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LoginAccount.self,
            LoginSession.self,
            LoginDeviceRegistration.self,
            CatalogImageCacheEntry.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        Window("OpenNOW", id: "main") {
            ContentView()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        OpenNOWTitlebarBrand()
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct OpenNOWTitlebarBrand: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text("OpenNOW")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("OpenNOW")
    }
}

final class OpenNOWAppDelegate: NSObject, NSApplicationDelegate {
    private var isCompletingUserApprovedTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCompletingUserApprovedTermination {
            return .terminateNow
        }
        guard WebRTCMediaStreamLifecycle.hasActiveStream else {
            return .terminateNow
        }
        guard WebRTCMediaStreamLifecycle.requestApplicationQuitDecision(completion: { [weak self, weak sender] shouldTerminateApplication in
            guard let sender else { return }
            if shouldTerminateApplication {
                self?.isCompletingUserApprovedTermination = true
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminateApplication)
        }) else {
            return .terminateNow
        }
        return .terminateLater
    }
}
