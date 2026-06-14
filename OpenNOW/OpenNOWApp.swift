//
//  OpenNOWApp.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import SwiftUI
import SwiftData

@main
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OpenNOWAppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            LoginAccount.self,
            LoginSession.self,
            LoginDeviceRegistration.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup("OpenNOW") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .modelContainer(sharedModelContainer)
    }
}

final class OpenNOWAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
