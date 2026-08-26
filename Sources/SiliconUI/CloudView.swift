import AppKit
import SiliconCatalog
import SiliconCore
import SwiftUI

/// The Cloud tab: the one place in this app where the work happens on hardware you do not own.
///
/// It sits next to Swarm on purpose. Swarm is the machines you have; this is the machines you
/// rent, and putting them side by side makes the trade legible — a swarm node costs
/// electricity and a provider costs money, and everything else about using them is the same.
///
/// Three panes, because the task is three questions in a row: which provider, which model, and
/// is this the one. A flat list could answer none of them — one key alone returns 417 models,
/// and a list that long is a wall, not a chooser.
///
/// Selecting a model *inspects* it. Enabling is a separate, deliberate act, because enabling is
/// the half that costs money and a row you clicked to read about should never start billing you.
struct CloudView: View {
    @Environment(AppModel.self) private var model

    /// What the rail is pointing at. Not a provider on its own: "everything I switched on" is a
    /// question worth asking across providers, and the audio queue is not a chat catalogue at
    /// all, so both earn their own place rather than being modes hidden inside a filter.
    enum Section: Hashable {
        case provider(CloudProvider)
        case enabled
        case audio
    }

    @State private var section: Section = .provider(.nvidia)
    /// The gateway id under inspection. Nil means the detail pane describes the section.
    @State private var inspecting: String?
    @State private var search = ""
    @State private var ownerFilter: String?
    @State private var enabledOnly = false
    @State private var drafts: [String: String] = [:]

    var body: some View {
        Group {
            if model.cloudCredentials.isEmpty {
                CloudSetupPane(drafts: $drafts)
            } else {
                browser
            }
        }
        .navigationTitle("Cloud")
        .task {
            if !model.cloudCredentials.isEmpty, model.cloudModels.isEmpty {
                await model.refreshCloudModels()
            }
            if case .provider(let current) = section,
               model.cloudCredentials.key(for: current) == nil,
               let first = model.cloudCredentials.configured.first {
                section = .provider(first)
            }
        }
    }

    // MARK: - The browser

    private var browser: some View {
        HSplitView {
            rail
                .frame(minWidth: 208, idealWidth: 232, maxWidth: 300)

            ModelListPane(
                rows: rows,
                total: sectionTotal,
                inspecting: $inspecting,
                section: section
            )
            .frame(minWidth: 300)

            CloudDetailPane(
                section: section,
                model: inspectingModel,
                drafts: $drafts
            )
            .frame(minWidth: 268, idealWidth: 320, maxWidth: 420)
        }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Providers")
                    .railHeading()

                ForEach(CloudProvider.allCases) { provider in
                    CloudRailRow(
                        title: provider.displayName,
                        systemImage: model.cloudCredentials.key(for: provider) == nil
                            ? "key" : "cloud",
                        count: model.cloudModels.filter { $0.provider == provider }.count,
                        dimmed: model.cloudCredentials.key(for: provider) == nil,
                        isSelected: section == .provider(provider)
                    ) {
                        select(.provider(provider))
                    }

                    // Filters live inside the row that owns them, so they can never be read as
                    // applying to a provider you are not looking at.
                    if section == .provider(provider),
                       model.cloudCredentials.key(for: provider) != nil {
                        filters(for: provider)
                    }
                }

                Text("Views")
                    .railHeading()

                CloudRailRow(
                    title: "Enabled",
                    systemImage: "checkmark.circle",
                    count: enabledModels.count,
                    dimmed: false,
                    isSelected: section == .enabled
                ) {
                    select(.enabled)
                }

                if model.cloudCredentials.configured.contains(where: \.offersAudio) {
                    CloudRailRow(
                        title: "Speech and music",
                        systemImage: "waveform",
                        count: audioEntries.count,
                        dimmed: false,
                        isSelected: section == .audio
                    ) {
                        select(.audio)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private func filters(for provider: CloudProvider) -> some View {
        let owners = ownersFor(provider)

        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if owners.count > 1 {
                // The ids are "owner/model" at all three providers, so the owner is the one
                // grouping that is in the data rather than invented for the picker.
                Picker("Maker", selection: $ownerFilter) {
                    Text("Every maker").tag(String?.none)
                    ForEach(owners, id: \.self) { owner in
                        Text(owner).tag(String?.some(owner))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            Toggle("Only what I switched on", isOn: $enabledOnly)
                .controlSize(.small)
                .font(.caption)

            if search.isEmpty && ownerFilter == nil && !enabledOnly {
                Text("\(model.cloudModels.filter { $0.provider == provider }.count) models")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Button("Clear filters") {
                    search = ""; ownerFilter = nil; enabledOnly = false
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func select(_ next: Section) {
        withAnimation(.easeOut(duration: 0.18)) {
            if section != next {
                // Filters belong to the section that set them; carrying a maker filter from
                // NVIDIA to OpenRouter would silently hide almost everything.
                search = ""; ownerFilter = nil; enabledOnly = false
                inspecting = nil
            }
            section = next
        }
    }

    // MARK: - Data

    private func ownersFor(_ provider: CloudProvider) -> [String] {
        let owners = model.cloudModels
            .filter { $0.provider == provider }
            .compactMap { CloudView.owner(of: $0.id) }
        return Array(Set(owners)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// "nvidia/llama-3.3-nemotron-super-49b-v1" → "nvidia". Nil when an id carries no maker,
    /// which is rarer than it sounds — every id all three providers return has one.
    static func owner(of id: String) -> String? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let owner = String(id[..<slash])
        return owner.isEmpty ? nil : owner
    }

    /// The model's own name, with its maker taken off the front.
    static func bareName(of id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        let bare = String(id[id.index(after: slash)...])
        return bare.isEmpty ? id : bare
    }

    /// What to print on two lines.
    ///
    /// NVIDIA and GMI return ids with no display name, so `displayName` falls back to the id —
    /// and printing that twice was ninety-five rows of the same string stacked on itself. When
    /// the name is only the id, the maker comes off the front and becomes the second line,
    /// which is the part that actually differs between neighbouring rows.
    static func labels(for entry: CloudModel) -> (title: String, subtitle: String) {
        guard entry.displayName == entry.id else { return (entry.displayName, entry.id) }
        guard let owner = owner(of: entry.id) else { return (entry.id, "") }
        return (bareName(of: entry.id), owner)
    }

    private var enabledModels: [CloudModel] {
        let enabled = Set(model.settings.enabledCloudModels ?? [])
        return model.cloudModels.filter { enabled.contains($0.gatewayID) }
    }

    private var sectionTotal: Int {
        switch section {
        case .provider(let provider): model.cloudModels.filter { $0.provider == provider }.count
        case .enabled: enabledModels.count
        case .audio: audioEntries.count
        }
    }

    private var rows: [CloudRow] {
        switch section {
        case .audio:
            return audioEntries.map {
                CloudRow(id: $0.id, title: $0.displayName, subtitle: $0.id, detail: nil,
                         enabled: nil)
            }
        case .enabled:
            return enabledModels.map(row(for:))
        case .provider(let provider):
            let enabled = Set(model.settings.enabledCloudModels ?? [])
            let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.cloudModels
                .filter { $0.provider == provider }
                .filter { ownerFilter == nil || CloudView.owner(of: $0.id) == ownerFilter }
                .filter { !enabledOnly || enabled.contains($0.gatewayID) }
                .filter {
                    needle.isEmpty
                        || $0.displayName.localizedCaseInsensitiveContains(needle)
                        || $0.id.localizedCaseInsensitiveContains(needle)
                }
                .map(row(for:))
        }
    }

    private func row(for entry: CloudModel) -> CloudRow {
        let enabled = Set(model.settings.enabledCloudModels ?? [])
        let labels = CloudView.labels(for: entry)
        return CloudRow(
            id: entry.gatewayID,
            title: labels.title,
            subtitle: labels.subtitle,
            detail: entry.contextWindow.map { "\($0 / 1000)K" },
            enabled: enabled.contains(entry.gatewayID)
        )
    }

    private var inspectingModel: CloudModel? {
        guard let inspecting else { return nil }
        return model.cloudModels.first { $0.gatewayID == inspecting }
    }

    private var audioEntries: [CloudAudioCatalog.Entry] {
        model.cloudCredentials.configured
            .filter(\.offersAudio)
            .flatMap { provider in
                CloudAudioCatalog.entries(for: provider, kind: .speech)
                    + CloudAudioCatalog.entries(for: provider, kind: .music)
            }
    }
}

// MARK: - Row model

/// One line in the middle pane. A plain value so the list never reaches back into the app model
/// while scrolling several hundred rows.
struct CloudRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    /// The right-hand figure — a context window, when the provider reported one.
    var detail: String?
    /// Nil for rows that cannot be switched on, like the audio catalogue.
    var enabled: Bool?
}

// MARK: - Rail row

private struct CloudRailRow: View {
    var title: String
    var systemImage: String
    var count: Int
    var dimmed: Bool
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(dimmed && !isSelected ? .secondary : .primary)
                Spacer(minLength: 6)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(background, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}

private extension Text {
    /// The rail's section labels. Small, quiet, and spaced away from what came before rather
    /// than from what follows — a heading belongs to the thing under it.
    func railHeading() -> some View {
        self
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

// MARK: - Middle pane

private struct ModelListPane: View {
    var rows: [CloudRow]
    var total: Int
    @Binding var inspecting: String?
    var section: CloudView.Section

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                emptyState
            } else {
                List(rows, selection: $inspecting) { row in
                    ModelRow(row: row) { toggle(row) }
                        .tag(row.id)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            Divider()
            HStack {
                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.cloudRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await model.refreshCloudModels() } }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var countLine: String {
        if rows.count == total { return "\(total) models" }
        return "\(rows.count) of \(total)"
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyIcon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.callout.weight(.medium))
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch section {
        case .enabled: "checkmark.circle"
        default: "magnifyingglass"
        }
    }

    private var emptyTitle: String {
        switch section {
        case .enabled: "Nothing switched on yet"
        default: total == 0 ? "No models listed" : "Nothing matches those filters"
        }
    }

    private var emptyHint: String {
        switch section {
        case .enabled:
            "Pick a provider on the left, choose a model, and switch it on. Only what you "
            + "switch on appears in the Chat picker."
        default:
            total == 0
                ? "Refresh to ask this provider what your key can reach."
                : "Widen the search, or clear the maker filter."
        }
    }

    private func toggle(_ row: CloudRow) {
        var enabled = model.settings.enabledCloudModels ?? []
        if enabled.contains(row.id) {
            enabled.removeAll { $0 == row.id }
        } else {
            enabled.append(row.id)
        }
        model.settings.enabledCloudModels = enabled
        model.settings.save()
    }
}

/// One model. The whole row selects for reading; only the switch commits.
private struct ModelRow: View {
    var row: CloudRow
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let enabled = row.enabled {
                Button(action: toggle) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help(enabled ? "Remove from your pickers" : "Add to your pickers")
                .accessibilityLabel(enabled ? "Switched on" : "Switched off")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let detail = row.detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail pane

private struct CloudDetailPane: View {
    var section: CloudView.Section
    var model: CloudModel?
    @Binding var drafts: [String: String]

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let model {
                    modelDetail(model)
                } else {
                    sectionDetail
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .background(.background.secondary)
    }

    // MARK: One model

    @ViewBuilder
    private func modelDetail(_ entry: CloudModel) -> some View {
        let enabled = (app.settings.enabledCloudModels ?? []).contains(entry.gatewayID)

        VStack(alignment: .leading, spacing: 6) {
            Text(CloudView.labels(for: entry).title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.provider.displayName)
                .foregroundStyle(.secondary)
        }

        // Prominent while it is the thing to do, quiet once it is done — two buttons rather
        // than one erased style, because the erasure needed a shim and the shim was a lie.
        if enabled {
            Button { setEnabled(false, entry) } label: {
                Label("Switched on", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        } else {
            Button { setEnabled(true, entry) } label: {
                Label("Switch on", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }

        Text(
            enabled
                ? "In the Chat picker, the agents and the MCP tools. Never chosen for you — "
                  + "an agent falls back to a local model unless you pick this one yourself."
                : "Switching on adds it to your pickers. It stays off everywhere until you do."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Divider()

        DetailRow("Maker", CloudView.owner(of: entry.id) ?? "—")
        DetailRow("Called this by \(entry.provider.displayName)", entry.id, mono: true)
        DetailRow("Called this here", entry.gatewayID, mono: true)
        DetailRow(
            "Context",
            entry.contextWindow.map { "\($0.formatted()) tokens" }
                // NVIDIA's listing carries no window. Saying so beats a blank, and beats a
                // number borrowed from somewhere it was never stated.
                ?? "Not reported by \(entry.provider.displayName)"
        )

        if enabled {
            Divider()
            Button("Open Chat") { app.selectedTab = .chat }
                .buttonStyle(.link)
        }
    }

    // MARK: A section

    @ViewBuilder
    private var sectionDetail: some View {
        switch section {
        case .provider(let provider):
            providerDetail(provider)
        case .enabled:
            placeholder(
                title: "What you switched on",
                body: "Everything here is offered in the Chat picker, to Codex, Qwen Code, the "
                    + "harness and Pi, and to Claude or ChatGPT through the MCP tools. Pick one "
                    + "to see it, or switch it back off."
            )
        case .audio:
            audioDetail
        }
    }

    @ViewBuilder
    private func providerDetail(_ provider: CloudProvider) -> some View {
        let key = app.cloudCredentials.key(for: provider)

        Text(provider.displayName)
            .font(.title3.weight(.semibold))

        Text(blurb(provider))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()

        if key != nil {
            Label("Key saved", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Kept in cloud-providers.json, readable only by you. Never in settings.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Remove key", role: .destructive) {
                app.setCloudKey(nil, for: provider)
            }
        } else {
            Text("No key yet")
                .font(.callout.weight(.medium))
            SecureField(
                "API key",
                text: Binding(
                    get: { drafts[provider.rawValue] ?? "" },
                    set: { drafts[provider.rawValue] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { save(provider) }

            HStack {
                Button("Save") { save(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBlank(provider))
                Button("Get a key") { NSWorkspace.shared.open(provider.keyPageURL) }
            }
        }

        if let error = app.cloudRefreshError {
            Divider()
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var audioDetail: some View {
        Text("Speech and music")
            .font(.title3.weight(.semibold))
        Text(
            "These run on a job queue rather than the chat API, so they report progress like a "
            + "render on one of your own machines. They appear in the Audio tab's pickers."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Divider()

        Text("Not listed?")
            .font(.callout.weight(.medium))
        Text(
            "There is no way to ask the audio queue what it has, so this list is written down "
            + "and goes stale. Add an id and it joins the pickers — anything with “music” in "
            + "the name lands under Music, the rest under Speak."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        TextField(
            "Extra model ids",
            text: Binding(
                get: { (app.settings.customCloudAudioModels ?? []).joined(separator: ", ") },
                set: { typed in
                    app.settings.customCloudAudioModels = typed
                        .split(whereSeparator: { $0 == "," || $0.isNewline })
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    app.settings.save()
                }
            ),
            prompt: Text("minimax-tts-speech-2.8-turbo")
        )
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func placeholder(title: String, body: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
        Text(body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func setEnabled(_ on: Bool, _ entry: CloudModel) {
        var list = app.settings.enabledCloudModels ?? []
        if on {
            if !list.contains(entry.gatewayID) { list.append(entry.gatewayID) }
        } else {
            list.removeAll { $0 == entry.gatewayID }
        }
        app.settings.enabledCloudModels = list
        app.settings.save()
    }

    private func blurb(_ provider: CloudProvider) -> String {
        switch provider {
        case .gmi:
            "Chat models, and the only provider here that also does speech and music."
        case .openRouter:
            "One key, most of the industry's models behind it. Chat only."
        case .nvidia:
            "Around 95 open models on NVIDIA's own hardware. The developer key is free and "
            + "needs no card; you are rate limited rather than metered. Chat only."
        }
    }

    private func isBlank(_ provider: CloudProvider) -> Bool {
        (drafts[provider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(_ provider: CloudProvider) {
        guard !isBlank(provider) else { return }
        app.setCloudKey(drafts[provider.rawValue], for: provider)
        drafts[provider.rawValue] = ""
    }
}

private struct DetailRow: View {
    var label: String
    var value: String
    var mono: Bool = false

    init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Before there is a key

/// The whole pane before anyone has opted in. Not a disabled browser: there is nothing to
/// browse, and showing the shell of one implies the app is holding something back.
private struct CloudSetupPane: View {
    @Environment(AppModel.self) private var app
    @Binding var drafts: [String: String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Models you don't own")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Every other tab in this app runs on hardware you own. This one rents "
                        + "someone else's, for models too big for any machine in your swarm. "
                        + "Add a key and it switches on; remove it and this tab goes back to "
                        + "being empty."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                }

                ForEach(CloudProvider.allCases) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider.displayName)
                            .font(.headline)
                        Text(pitch(provider))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            SecureField(
                                "API key",
                                text: Binding(
                                    get: { drafts[provider.rawValue] ?? "" },
                                    set: { drafts[provider.rawValue] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .onSubmit { save(provider) }
                            Button("Save") { save(provider) }
                                .disabled(isBlank(provider))
                            Button("Get a key") { NSWorkspace.shared.open(provider.keyPageURL) }
                                .buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pitch(_ provider: CloudProvider) -> String {
        switch provider {
        case .nvidia:
            "Free, and the quickest to try: the developer key needs no card, and you are rate "
            + "limited rather than metered. Around 95 open models."
        case .openRouter:
            "One key, most of the industry's models behind it — several hundred."
        case .gmi:
            "Chat models, plus the only speech and music queue of the three."
        }
    }

    private func isBlank(_ provider: CloudProvider) -> Bool {
        (drafts[provider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(_ provider: CloudProvider) {
        guard !isBlank(provider) else { return }
        app.setCloudKey(drafts[provider.rawValue], for: provider)
        drafts[provider.rawValue] = ""
    }
}
