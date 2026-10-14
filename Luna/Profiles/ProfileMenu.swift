import AppKit
import Combine
import SwiftUI

// MARK: - Avatar

enum ProfileAvatar {
    /// A filled circle with the profile's initial, for menus and toolbars.
    static func image(for profile: BrowserProfile, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            profile.profileColor.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let initial = String(profile.name.prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = initial.size(withAttributes: attrs)
            initial.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func swatch(_ color: ProfileColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Settings routing

/// Lets menus open Settings directly on a given pane.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var requestedPane: SettingsPane?
    nonisolated deinit {}
}

/// Opens Settings on the Profiles pane.
struct ManageProfilesButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Manage Profiles…") {
            SettingsRouter.shared.requestedPane = .profiles
            openSettings()
        }
    }
}

// MARK: - Shared actions

enum ProfileActions {
    /// Prompts for a name and creates a profile with the next unused color.
    static func createProfile(manager: ProfileManager) -> BrowserProfile? {
        guard let name = TextPrompt.name(title: "New Profile", initial: "Profile \(manager.profiles.count + 1)", confirm: "Create") else { return nil }
        let used = Set(manager.profiles.map(\.colorId))
        let color = ProfileColor.presets.first { !used.contains($0.id) } ?? ProfileColor.presets[manager.profiles.count % ProfileColor.presets.count]
        return manager.addProfile(name: name, colorId: color.id)
    }
}

// MARK: - Toolbar / sidebar menu

/// The profile avatar button. Opens a native menu: switch profile, open one in
/// a new window, create one, or manage them in Settings.
struct ProfileMenu: View {
    @ObservedObject var profileManager: ProfileManager
    let activeProfileId: UUID
    let onSwitch: (BrowserProfile) -> Void
    let onOpenInNewWindow: (BrowserProfile) -> Void

    private var active: BrowserProfile { profileManager.profile(for: activeProfileId) }

    var body: some View {
        Menu {
            ProfileMenuItems(
                profileManager: profileManager,
                activeProfileId: activeProfileId,
                onSwitch: onSwitch,
                onOpenInNewWindow: onOpenInNewWindow
            )
        } label: {
            Image(nsImage: ProfileAvatar.image(for: active, size: 20))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile: \(active.name)")
        .accessibilityLabel("Profile \(active.name)")
    }
}

/// Menu items shared by the avatar menu and the menu bar's Profiles menu.
struct ProfileMenuItems: View {
    @ObservedObject var profileManager: ProfileManager
    let activeProfileId: UUID?
    let onSwitch: (BrowserProfile) -> Void
    let onOpenInNewWindow: (BrowserProfile) -> Void

    var body: some View {
        ForEach(profileManager.profiles) { profile in
            Toggle(isOn: Binding(
                get: { profile.id == activeProfileId },
                set: { if $0 { onSwitch(profile) } }
            )) {
                Label { Text(profile.name) } icon: { Image(nsImage: ProfileAvatar.image(for: profile, size: 16)) }
            }
        }
        if profileManager.profiles.count > 1 {
            Menu("Open in New Window") {
                ForEach(profileManager.profiles) { profile in
                    Button(profile.name) { onOpenInNewWindow(profile) }
                }
            }
        }
        Divider()
        Button("New Profile…") {
            if let profile = ProfileActions.createProfile(manager: profileManager) { onSwitch(profile) }
        }
        ManageProfilesButton()
    }
}

// MARK: - Menu bar

/// What the key browser window exposes to the menu bar's Profiles menu.
struct ProfileCommandContext {
    let activeProfileId: UUID
    let switchTo: (BrowserProfile) -> Void
    let openInNewWindow: (BrowserProfile) -> Void
}

extension FocusedValues {
    @Entry var profileCommands: ProfileCommandContext?
}

struct ProfileCommands: Commands {
    @FocusedValue(\.profileCommands) private var context

    var body: some Commands {
        CommandMenu("Profiles") {
            ProfileMenuItems(
                profileManager: ProfileManager.shared,
                activeProfileId: context?.activeProfileId,
                onSwitch: { context?.switchTo($0) },
                onOpenInNewWindow: { context?.openInNewWindow($0) }
            )
        }
    }
}
