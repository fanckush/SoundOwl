import AppKit
import SwiftUI

/// Ways to use SoundOwl besides the owl. They all use the settings under Recordings.
struct IntegrationsView: View {
    @State private var copied = false

    private static let linkCommand = "ln -sf /Applications/SoundOwl.app/Contents/Resources/soundowl /usr/local/bin/soundowl"

    var body: some View {
        Form {
            Section("Finder") {
                LabeledContent {
                    Button("Keyboard Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                } label: {
                    Text("Restore with SoundOwl")
                    Text(
                        "Right-click recordings and choose it under Services for clear copies next to them. Missing? Turn it on under Keyboard Shortcuts › Services."
                    )
                }
            }
            Section("Shortcuts") {
                LabeledContent {
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                } label: {
                    Text("Restore Audio")
                    Text("Restores a folder, the files you share to it, or a recording you just made.")
                }
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Turn Live On or Off")
                    Text("Switches an app on or off, for example when a meeting starts.")
                }
            }
            Section {
                LabeledContent {
                    Button(copied ? "Copied" : "Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.linkCommand, forType: .string)
                        copied = true
                    }
                } label: {
                    Text("soundowl").font(.body.monospaced())
                    Text(
                        "Restores files and folders in bulk: soundowl restore *.m4a. Installed with Homebrew, it's ready; otherwise paste the install command into Terminal once."
                    )
                }
            } header: {
                Text("Terminal")
            }
        }
        .formStyle(.grouped)
    }
}
