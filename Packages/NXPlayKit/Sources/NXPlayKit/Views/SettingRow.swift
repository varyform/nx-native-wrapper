import SwiftUI

/// One setting drawn as nxnative's own window draws it: a switch, a slider with its percentage, a menu. A value set at
/// this level (the global one, or the game's own) is tinted and has a reset button; picking the value it would follow
/// anyway sets nothing, so only real changes stand out.
struct SettingRow: View {
    let setting: LauncherSetting
    /// The value set here, nil when it follows.
    let own: String?
    /// The value it follows: the global value or the tested default; nil when the games' defaults differ.
    let follows: String?
    /// What following means when there's no single value: "Each game's default", "As built".
    let followsLabel: String
    /// The reset button's help: "Reset to global: Docked".
    let resetHelp: String
    let set: (String?) -> Void
    @State private var sliding: Double?
    @State private var editing = false

    private var shown: String { own ?? follows ?? setting.defaultValue }
    private var differs: Bool { own == nil && follows == nil }

    var body: some View {
        switch setting.kind {
        case .toggle(let on, let off):
            HStack {
                label
                Spacer()
                reset
                Toggle(
                    setting.label,
                    isOn: Binding(get: { shown == on }, set: { choose($0 ? on : off) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
        case .range(let min, let max, let step):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    label
                    Spacer()
                    reset
                    Text(setting.title(for: sliding.map { setting.number($0) } ?? shown))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { sliding ?? Double(shown) ?? min },
                        set: { value in
                            let snapped = min + ((value - min) / step).rounded() * step
                            if editing {
                                sliding = snapped
                            } else {
                                choose(setting.number(snapped))
                            }
                        }),
                    in: min...max, step: step
                ) { editing in
                    self.editing = editing
                    // one write when the drag ends, not one per step
                    if !editing, let sliding {
                        choose(setting.number(sliding))
                        self.sliding = nil
                    }
                }
                .accessibilityLabel(setting.label)
                .accessibilityValue(setting.title(for: shown))
            }
        case .choice(let options):
            HStack {
                label
                Spacer()
                reset
                Picker(
                    setting.label,
                    selection: Binding(
                        get: { differs ? Choice.follow : .value(shown) },
                        set: { if let value = $0.value { choose(value) } else { set(nil) } })
                ) {
                    if differs {
                        Text(followsLabel).tag(Choice.follow)
                        Divider()
                    }
                    ForEach(options, id: \.value) { Text($0.label).tag(Choice.value($0.value)) }
                    // a value the list no longer has, so the menu shows what's set rather than nothing
                    if let own, !options.contains(where: { $0.value == own }) {
                        Text(setting.title(for: own)).tag(Choice.value(own))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setting.label).foregroundStyle(
                own == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            let note = [setting.note, differs && !isChoice ? followsLabel : ""].filter {
                !$0.isEmpty
            }
            if !note.isEmpty {
                Text(note.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var reset: some View {
        if own != nil {
            Button("Reset", systemImage: "arrow.counterclockwise") { set(nil) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(resetHelp)
        }
    }

    private var isChoice: Bool {
        if case .choice = setting.kind { return true }
        return false
    }

    /// The value it follows anyway sets nothing.
    private func choose(_ value: String) {
        set(follows.map { setting.same(value, $0) } == true ? nil : value)
    }

    enum Choice: Hashable {
        case follow
        case value(String)

        var value: String? {
            if case .value(let value) = self { return value }
            return nil
        }
    }
}

/// Rows grouped by nxnative's sections (Game, Controls, Performance, and any it adds), as its window shows them: the
/// basic ones first, the rest under Advanced settings. A sub-setting shows only while its parent row has the value it
/// needs.
struct SettingSections<Row: View>: View {
    let settings: [LauncherSetting]
    /// A setting's current value, for sub-settings.
    let current: (LauncherSetting) -> String
    @ViewBuilder let row: (LauncherSetting) -> Row
    @AppStorage("showsAdvancedGameSettings") private var showsAdvanced = false

    var body: some View {
        let shown = settings.filter { setting in
            guard let needs = setting.needs,
                let parent = settings.first(where: { $0.env == needs.env })
            else {
                return true
            }
            return parent.same(current(parent), needs.value)
        }
        // without any basic setting there's nothing to put first: everything shows
        let hasBasic = settings.contains(where: \.isBasic)
        sections(shown.filter { $0.isBasic || !hasBasic }, in: "basic")
        if hasBasic, shown.contains(where: { !$0.isBasic }) {
            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                } label: {
                    // the whole row opens it, not only the chevron
                    Text("Advanced settings")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation { showsAdvanced.toggle() } }
                }
            }
            if showsAdvanced { sections(shown.filter { !$0.isBasic }, in: "advanced") }
        }
    }

    /// A part's sections, identified within it: basic and advanced both have a Game section, and one identity for both
    /// makes SwiftUI draw one of them twice and drop rows.
    private func sections(_ rows: [LauncherSetting], in part: String) -> some View {
        let names = rows.map(\.section).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return ForEach(names.map { (id: "\(part)/\($0)", name: $0) }, id: \.id) { section in
            Section(section.name) {
                ForEach(rows.filter { $0.section == section.name }) { row($0) }
            }
        }
    }
}

