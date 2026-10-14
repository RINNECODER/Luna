import SwiftUI

/// Settings → Profiles: rename, recolor, add and delete profiles.
struct ProfileSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var pendingDelete: BrowserProfile?

    var body: some View {
        Form {
            Section {
                ForEach(profileManager.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        canDelete: profileManager.profiles.count > 1,
                        onDelete: { pendingDelete = profile }
                    )
                }
            } footer: {
                Text("Each profile keeps its own cookies, logins, history, tabs and AI chats, like a separate browser.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Add Profile…") {
                    _ = ProfileActions.createProfile(manager: profileManager)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("Delete Profile and Data", role: .destructive) {
                profileManager.deleteProfile(profileId: profile.id) {}
                pendingDelete = nil
            }
        } message: { _ in
            Text("Its history, cookies, logins, tabs and chats are removed. This can't be undone.")
        }
    }
}

private struct ProfileRow: View {
    let profile: BrowserProfile
    let canDelete: Bool
    let onDelete: () -> Void

    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: ProfileAvatar.image(for: profile, size: 24))
            TextField("Name", text: $name, prompt: Text("Name"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onSubmit(commitName)
                .onAppear { name = profile.name }
                .onChange(of: profile.name) { _, new in name = new }
            Picker("Color", selection: Binding(
                get: { profile.colorId },
                set: { profileManager.recolor(profileId: profile.id, colorId: $0) }
            )) {
                ForEach(ProfileColor.presets) { color in
                    Label { Text(color.id.capitalized) } icon: { Image(nsImage: ProfileAvatar.swatch(color)) }
                        .tag(color.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "Delete Profile" : "Luna needs at least one profile")
        }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = profile.name } else if trimmed != profile.name {
            profileManager.rename(profileId: profile.id, to: trimmed)
        }
    }
}
