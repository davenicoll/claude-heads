import SwiftUI

struct SettingsView: View {
    private var settings = AppSettings.shared

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
            }

            Section("Terminal") {
                TextField("Font name", text: Bindable(settings).terminalFontName)

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
                TextField("Default extra arguments", text: Bindable(settings).defaultExtraArgs)
            } header: {
                Text("Claude CLI")
            } footer: {
                Text("These arguments are passed to every new Claude CLI instance (e.g. \"--dangerously-skip-permissions\").")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 420)
    }
}

#Preview {
    SettingsView()
}
