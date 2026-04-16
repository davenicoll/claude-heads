import SwiftUI

struct SettingsView: View {
    private var settings = AppSettings.shared
    @State private var monoFonts: [String] = []

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Bindable(settings).launchAtLogin)

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
                Text("Flags and extra arguments are passed to every new Claude Code instance.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onAppear {
            monoFonts = findMonospaceFonts()
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
