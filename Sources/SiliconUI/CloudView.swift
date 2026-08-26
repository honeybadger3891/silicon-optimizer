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
/// Empty until someone adds a key, and it says so rather than showing a scaffold of controls
/// that cannot do anything yet.
struct CloudView: View {
    @Environment(AppModel.self) private var model

    @State private var drafts: [String: String] = [:]
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro

                ForEach(CloudProvider.allCases) { provider in
                    providerCard(provider)
                }

                if !model.cloudCredentials.isEmpty {
                    modelsCard
                    if model.cloudCredentials.configured.contains(where: \.offersAudio) {
                        audioCard
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Cloud")
        .task {
            // Only asks if a key exists; refreshCloudModels returns immediately otherwise.
            if !model.cloudCredentials.isEmpty, model.cloudModels.isEmpty {
                await model.refreshCloudModels()
            }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Models you don't own")
                    .font(.title3.weight(.semibold))
                Text(
                    model.cloudCredentials.isEmpty
                        ? "Nothing here is switched on. Add a key below and this Mac can reach "
                          + "models too big for any machine in your swarm — you pay whoever "
                          + "runs them, and nothing else about the app changes."
                        : "These run on someone else's hardware and bill you for it. Everything "
                          + "else — Chat, the agents, the MCP tools — reaches them exactly the "
                          + "way it reaches a model on this Mac."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !model.cloudCredentials.isEmpty {
                    Label(
                        "A remote model is never picked for you. Agents fall back to a local "
                        + "model unless you choose a remote one yourself.",
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - One provider

    private func providerCard(_ provider: CloudProvider) -> some View {
        let saved = model.cloudCredentials.key(for: provider) != nil
        let reachable = model.cloudModels.filter { $0.provider == provider }.count

        return Card(title: provider.displayName, systemImage: saved ? "key.fill" : "key") {
            VStack(alignment: .leading, spacing: 10) {
                Text(blurb(provider))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if saved {
                    HStack(spacing: 10) {
                        Label(
                            reachable > 0
                                ? "\(reachable) models reachable"
                                : "Key saved — nothing listed yet",
                            systemImage: "checkmark.seal.fill"
                        )
                        .foregroundStyle(reachable > 0 ? .green : .secondary)
                        Spacer()
                        Button("Refresh") { Task { await model.refreshCloudModels() } }
                            .disabled(model.cloudRefreshing)
                        Button("Remove key", role: .destructive) {
                            model.setCloudKey(nil, for: provider)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField(
                            "Paste your API key",
                            text: Binding(
                                get: { drafts[provider.rawValue] ?? "" },
                                set: { drafts[provider.rawValue] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(provider) }

                        Button("Save") { save(provider) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(draftIsEmpty(provider))

                        Button("Get a key") { NSWorkspace.shared.open(provider.keyPageURL) }
                    }
                }
            }
        }
    }

    private func draftIsEmpty(_ provider: CloudProvider) -> Bool {
        (drafts[provider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(_ provider: CloudProvider) {
        guard !draftIsEmpty(provider) else { return }
        model.setCloudKey(drafts[provider.rawValue], for: provider)
        drafts[provider.rawValue] = ""
    }

    private func blurb(_ provider: CloudProvider) -> String {
        switch provider {
        case .gmi:
            "Chat models, and the only one here that also does speech and music — those "
            + "appear in the Audio tab once a key is saved."
        case .openRouter:
            "One key, most of the industry's models behind it. Chat only."
        case .nvidia:
            "Around 95 open models on NVIDIA's own hardware. The developer key is free and "
            + "needs no card; you are rate limited rather than metered. Chat only."
        }
    }

    // MARK: - Models

    private var modelsCard: some View {
        Card(title: "Models", systemImage: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if model.cloudRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Asking each provider what it can reach…")
                            .foregroundStyle(.secondary)
                    } else if let error = model.cloudRefreshError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    } else {
                        Text(
                            "Tick a model to offer it in the Chat picker, the agents, and the "
                            + "MCP tools."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if !model.cloudModels.isEmpty {
                    TextField("Search \(model.cloudModels.count) models", text: $search)
                        .textFieldStyle(.roundedBorder)

                    let matches = filtered
                    if matches.isEmpty {
                        Text("Nothing matches “\(search)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // A provider can offer hundreds; the list scrolls in its own box so
                        // the page does not become a mile of checkboxes.
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(matches) { entry in
                                    Toggle(isOn: binding(for: entry)) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.displayName)
                                            Text(subtitle(entry))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }
        }
    }

    private var filtered: [CloudModel] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.cloudModels }
        return model.cloudModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.id.localizedCaseInsensitiveContains(needle)
        }
    }

    private func subtitle(_ entry: CloudModel) -> String {
        var parts = [entry.provider.displayName, entry.id]
        // Only NVIDIA's listing omits it, and claiming a window it never stated would be
        // worse than leaving the line short.
        if let window = entry.contextWindow { parts.append("\(window / 1000)K context") }
        return parts.joined(separator: " · ")
    }

    private func binding(for entry: CloudModel) -> Binding<Bool> {
        Binding(
            get: { (model.settings.enabledCloudModels ?? []).contains(entry.gatewayID) },
            set: { isOn in
                var enabled = model.settings.enabledCloudModels ?? []
                if isOn {
                    if !enabled.contains(entry.gatewayID) { enabled.append(entry.gatewayID) }
                } else {
                    enabled.removeAll { $0 == entry.gatewayID }
                }
                model.settings.enabledCloudModels = enabled
                model.settings.save()
            }
        )
    }

    // MARK: - Audio

    private var audioCard: some View {
        Card(title: "Speech and music", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "These appear in the Audio tab's model pickers. They run on a job queue "
                    + "rather than the chat API, so they show progress like a render on a node."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(audioEntries, id: \.id) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.kind == .music ? "music.note" : "waveform")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(entry.displayName)
                        Spacer()
                        Text(entry.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                Text("Not listed?")
                    .font(.callout.weight(.medium))
                Text(
                    "There is no way to ask the audio queue what it has, so this list is "
                    + "written down and goes stale. Add an id and it appears in the pickers "
                    + "— anything with “music” in the name lands under Music, the rest under "
                    + "Speak. A wrong id fails when you use it, in the provider's own words."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField(
                    "Extra model ids",
                    text: Binding(
                        get: {
                            (model.settings.customCloudAudioModels ?? [])
                                .joined(separator: ", ")
                        },
                        set: { typed in
                            model.settings.customCloudAudioModels = typed
                                .split(whereSeparator: { $0 == "," || $0.isNewline })
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            model.settings.save()
                        }
                    ),
                    prompt: Text("minimax-tts-speech-2.8-turbo")
                )
                .textFieldStyle(.roundedBorder)
            }
        }
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
