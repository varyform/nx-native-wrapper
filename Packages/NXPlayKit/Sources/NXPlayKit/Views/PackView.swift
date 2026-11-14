import SwiftUI

/// Install & IPA: one window for getting a game onto an iPhone or iPad. Install it on a device or make an IPA file,
/// with the game files in the app or copied on their own (issue #30), signed through Xcode's team, with a .p12
/// certificate (issue #31) or not at all. Install on Device… and Build IPA… open it; it starts from the last choices.
public struct PackView: View {
    public static let windowID = "install-ipa"
    @Environment(Library.self) private var library
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        Group {
            if let packing = library.packing {
                PackForm(packing: packing) { dismissWindow(id: Self.windowID) }
            } else {
                ContentUnavailableView(
                    "No game chosen", systemImage: "shippingbox",
                    description: Text("Choose Install on Device… or Build IPA… for a game."))
                    .frame(width: 560, height: 300)
            }
        }
    }
}

private struct PackForm: View {
    @Bindable var packing: Packing
    let close: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            Form {
                header
                Section("Make") { target }
                Section {
                    Picker("Game files", selection: $packing.withGameFiles) {
                        Text("In the app").tag(true)
                        Text("Copied on their own").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    if !packing.withGameFiles, packing.toDevice {
                        Toggle("Copy them again, though this Mac copied them before", isOn: $packing.copyGameFilesAgain)
                    }
                } header: {
                    Text("Game files")
                } footer: {
                    Text(gameFilesNote).font(.caption).foregroundStyle(.secondary)
                }
                Section("Signing") {
                    Picker("Sign with", selection: $packing.signing) {
                        Text(packing.toDevice ? "Xcode: \(library.team?.name ?? "no team")" : "Unsigned, for a sideloading tool")
                            .tag(packing.toDevice ? PackRequest.Signing.xcodeTeam : .unsigned)
                        Text("A certificate (.p12) and its provisioning profile").tag(PackRequest.Signing.certificate)
                    }
                    .pickerStyle(.radioGroup)
                    if packing.effectiveSigning == .certificate { CertificateFields(packing: packing) }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: packing.toDevice) { normalizeSigning() }
        .onAppear(perform: normalizeSigning)
    }

    private var header: some View {
        HStack(spacing: 12) {
            GameIcon(url: library.icon(for: packing.game)).frame(width: 40, height: 40)
            VStack(alignment: .leading) {
                Text(packing.game.name).font(.headline)
                if let version = packing.game.version { Text(version).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var target: some View {
        Picker("Make", selection: $packing.toDevice) {
            Text("Install on a device").tag(true)
            Text("An IPA file in the game folder").tag(false)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        if packing.toDevice {
            HStack {
                Picker("Device", selection: deviceBinding) {
                    if library.devices.isEmpty {
                        Text(library.isLoadingDevices ? "Looking for devices…" : "No device").tag(String?.none)
                    }
                    ForEach(library.devices) { device in
                        Text("\(device.name) · \(device.model)").tag(Optional(device.id))
                    }
                }
                Button("Look Again", systemImage: "arrow.clockwise") { library.refreshDevices() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Look for devices again")
            }
        }
    }

    private var deviceBinding: Binding<String?> {
        Binding(
            get: { packing.device(in: library.devices)?.id },
            set: { packing.deviceID = $0 })
    }

    private var gameFilesNote: String {
        if packing.withGameFiles {
            return "The whole game goes into the app: one install, and each reinstall sends it all again."
        }
        return packing.toDevice
            ? "The app is small and reinstalls quickly. NX Play copies the game files into its folder on the device once per game version: over USB, or over Wi-Fi for a game smaller than half this Mac's memory. Deleting the app on the device deletes them too."
            : "The IPA is small and quick to sideload again. Finder shows the game's RomFS.img beside it: after installing, copy it into the app's folder on the device (Finder › the device › Files, or the Files app), once per game version."
    }

    private var footer: some View {
        HStack {
            if let missing = packing.missing(devices: library.devices) {
                Label(missing, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                library.packing = nil
                close()
            }
            .keyboardShortcut(.cancelAction)
            Button(packing.toDevice ? "Install" : "Build IPA") {
                library.pack(packing)
                close()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(packing.request(devices: library.devices) == nil || library.isBusy(packing.game))
        }
        .padding(16)
    }

    /// Xcode's team only installs and an IPA file can't come from it: the radio shows the one that applies.
    private func normalizeSigning() {
        if packing.signing != .certificate { packing.signing = packing.toDevice ? .xcodeTeam : .unsigned }
    }
}

/// The certificate's .p12 file and password, and its provisioning profile, with what each one says.
private struct CertificateFields: View {
    @Bindable var packing: Packing

    var body: some View {
        LabeledContent("Certificate") {
            fileButton(packing.p12Path, placeholder: "Choose .p12…") { packing.p12Path = $0 }
        }
        SecureField("Password", text: $packing.password)
        if let check = packing.certificate {
            switch check {
            case .valid(let name): note(name, ok: true)
            case .wrongPassword: note("The password doesn't open it.", ok: false)
            case .unreadable: note("Not a .p12 certificate NX Play can read.", ok: false)
            }
        }
        LabeledContent("Provisioning profile") {
            fileButton(packing.profilePath, placeholder: "Choose .mobileprovision…") { packing.profilePath = $0 }
        }
        if let profile = packing.profile {
            note(profileSummary(profile), ok: !profile.isExpired)
        } else if !packing.profilePath.isEmpty {
            note("Not a provisioning profile NX Play can read.", ok: false)
        }
    }

    private func profileSummary(_ profile: ProvisioningProfile) -> String {
        let devices = profile.allDevices ? "any device" : "\(profile.devices.count) device\(profile.devices.count == 1 ? "" : "s")"
        let expiry = (profile.isExpired ? "expired " : "until ") + profile.expires.formatted(date: .abbreviated, time: .omitted)
        return "\(profile.name) · \(profile.teamName) · \(profile.appID) · \(devices) · \(expiry)"
    }

    private func note(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.seal" : "exclamationmark.triangle")
            .font(.caption).foregroundStyle(ok ? Color.secondary : Color.orange)
    }

    private func fileButton(_ path: String, placeholder: String, set: @escaping (String) -> Void) -> some View {
        Button(path.isEmpty ? placeholder : (path as NSString).lastPathComponent) {
            if let url = PathPicker.choose(directory: false, startingAt: path) { set(url.path) }
        }
        .help(path)
    }
}
