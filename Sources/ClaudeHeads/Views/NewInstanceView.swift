import SwiftUI
import AppKit

struct NewInstanceView: View {
    var onLaunch: (String, [String], Data?) -> Void
    var onCancel: () -> Void

    @State private var folderPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var extraArgs: String = ""
    @State private var avatarData: Data?
    @State private var avatarImage: NSImage?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Claude Head")
                .font(.headline)

            // Directory picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Project directory")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Directory", text: $folderPath)
                        .textFieldStyle(.roundedBorder)
                        .truncationMode(.head)
                    Button("Browse\u{2026}") {
                        browseForDirectory()
                    }
                }
            }

            // Extra CLI arguments
            VStack(alignment: .leading, spacing: 4) {
                Text("Extra CLI arguments")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. --model opus", text: $extraArgs)
                    .textFieldStyle(.roundedBorder)
            }

            // Avatar picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Avatar (optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Choose Avatar\u{2026}") {
                        browseForAvatar()
                    }
                    if let avatarImage {
                        Image(nsImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                        Button(role: .destructive) {
                            self.avatarData = nil
                            self.avatarImage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Launch") {
                    let args = extraArgs
                        .split(separator: " ")
                        .map(String.init)
                    onLaunch(folderPath, args, avatarData)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - File Dialogs

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    private func browseForAvatar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                avatarData = data
                avatarImage = image
            }
        }
    }
}

#Preview {
    NewInstanceView(
        onLaunch: { path, args, avatar in
            print("Launch:", path, args, avatar?.count ?? 0)
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
