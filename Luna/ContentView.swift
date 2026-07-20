//
//  ContentView.swift
//  Luna
//
//  Root view that hosts the main browser shell.
//
import SwiftUI
import AppKit

struct ContentView: View {
    @AppStorage("luma_appearance") private var appearance: String = "system"

    var body: some View {
        BrowserShellView()
            .onAppear { applyLunaAppearance(appearance) }
            .onChange(of: appearance) { _, new in applyLunaAppearance(new) }
    }

    private func applyLunaAppearance(_ value: String) {
        switch value {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}

#Preview {
    BrowserShellView()
}
