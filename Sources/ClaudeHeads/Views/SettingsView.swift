import SwiftUI

struct SettingsView: View {
    private var settings = AppSettings.shared
    private var hookInstaller = HookInstaller.shared
    @State private var monoFonts: [String] = []

    var body: some View {
        // Fixed width, but the height follows the content: a grouped Form is a scroll view,
        // so giving it a fixed height that is shorter than its rows shows a scroll bar.
        // `fixedSize` makes it report its ideal height (all sections fully laid out) and
        // `AppState.showSettings()` sizes the window to that.
        form
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var form: some View {
        Form {
            Section("General") {
                Picker("Head size", selection: Bindable(settings).headSize) {
                    ForEach(HeadSize.allCases, id: \.self) { size in
                        Text(size.rawValue.capitalized).tag(size)
                    }
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Snap distance")
                        Spacer()
                        Text("\(Int(settings.snapDistance)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Bindable(settings).snapDistance,
                        in: 20...120,
                        step: 5
                    )
                }

                Toggle("Show status indicator", isOn: Bindable(settings).showStatusIndicator)
                Toggle("Show children for subagents", isOn: Bindable(settings).showSubagentChildren)

                HStack {
                    Text("Claude Code hooks")
                    Spacer()
                    Text(hookInstaller.status.label)
                        .foregroundStyle(hookStatusColor)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    Button("Reinstall hooks") {
                        hookInstaller.reinstall()
                    }
                    .controlSize(.small)
                }
            }

            Section("Terminal") {
                Picker("Font", selection: Bindable(settings).terminalFontName) {
                    ForEach(monoFonts, id: \.self) { fontName in
                        Text(fontName)
                            .font(.custom(fontName, size: 13))
                            .tag(fontName)
                    }
                }

                HStack {
                    Text("Font size")
                    Spacer()
                    TextField(
                        "Size",
                        value: Binding(
                            get: { Double(settings.terminalFontSize) },
                            set: { settings.terminalFontSize = CGFloat($0) }
                        ),
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    Stepper(
                        "",
                        value: Bindable(settings).terminalFontSize,
                        in: 8...32,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            Section {
                Toggle("Continue previous session (--continue)", isOn: Bindable(settings).claudeContinue)
                Toggle("Skip permissions (--dangerously-skip-permissions)", isOn: Bindable(settings).claudeSkipPermissions)
                Toggle("Remote control (--remote-control)", isOn: Bindable(settings).claudeRemoteControl)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra arguments")
                        .font(.body)
                    TextEditor(text: Bindable(settings).defaultExtraArgs)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 54)
                        .border(Color.secondary.opacity(0.3), width: 1)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Flags and extra arguments are passed to every new Claude Code instance. Quote arguments that contain spaces (shell-style).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            monoFonts = findMonospaceFonts()
            hookInstaller.refreshStatus()
        }
        .onChange(of: settings.terminalFontName) {
            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
        }
        .onChange(of: settings.terminalFontSize) {
            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
        }
        .onChange(of: settings.headSize) {
            NotificationCenter.default.post(name: .headSizeChanged, object: nil)
        }
        .onChange(of: settings.showSubagentChildren) {
            // The head panel is only enlarged for the orbit ring while children are shown.
            NotificationCenter.default.post(name: .subagentChildrenVisibilityChanged, object: nil)
        }
    }

    private var hookStatusColor: Color {
        switch hookInstaller.status {
        case .installed: .secondary
        case .missing: .orange
        case .failed: .red
        }
    }

    private func findMonospaceFonts() -> [String] {
        let manager = NSFontManager.shared
        var fonts: [String] = []
        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            for member in members {
                guard let fontName = member[0] as? String else { continue }
                guard let font = NSFont(name: fontName, size: 13) else { continue }
                if font.isFixedPitch {
                    fonts.append(family)
                    break
                }
            }
        }
        if !fonts.contains(settings.terminalFontName) {
            fonts.append(settings.terminalFontName)
        }
        return fonts.sorted()
    }
}

#Preview {
    SettingsView()
}
