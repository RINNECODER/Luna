//
//  LunaApp.swift
//  Luna
//
//  Root app entry for the Luna browser.
//
import SwiftUI

@main
struct LunaApp: App {
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands { ProfileCommands() }
        Settings {
            SettingsView()
        }
    }
}
