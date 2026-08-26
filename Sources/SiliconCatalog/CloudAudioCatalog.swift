import Foundation
import SiliconCore

/// What a remote audio model does. Speech and music share a queue and share no payload.
public enum CloudAudioKind: String, Sendable, Codable {
    case speech
    case music
}

/// What GMI Cloud's catalogue documents today, as a starting point for the picker.
///
/// A seed, not a limit. There is no `/models` endpoint for the audio queue, so this list has
/// to be written down — and a written-down list is stale the moment a provider ships
/// something. The request that prompted this named "Speech 2.8" while the catalogue still
/// documented 2.6, which is why `Settings.customCloudAudioModels` exists: ids typed there are
/// offered alongside these. Anything a key cannot actually reach fails on use, in the
/// provider's own words.
public enum CloudAudioCatalog {

    public struct Entry: Sendable, Identifiable, Equatable {
        public var id: String
        public var displayName: String
        public var kind: CloudAudioKind
    }

    public static let gmi: [Entry] = [
        Entry(id: "minimax-music-3.0", displayName: "MiniMax Music 3.0", kind: .music),
        Entry(id: "minimax-music-2.5", displayName: "MiniMax Music 2.5", kind: .music),
        Entry(
            id: "minimax-tts-speech-2.6-turbo",
            displayName: "MiniMax Speech 2.6 Turbo", kind: .speech
        ),
        Entry(
            id: "minimax-tts-speech-2.6-hd",
            displayName: "MiniMax Speech 2.6 HD", kind: .speech
        ),
        Entry(
            id: "minimax-audio-voice-clone-speech-2.6-turbo",
            displayName: "MiniMax Speech 2.6 Turbo (voice clone)", kind: .speech
        ),
        Entry(
            id: "minimax-audio-voice-clone-speech-2.6-hd",
            displayName: "MiniMax Speech 2.6 HD (voice clone)", kind: .speech
        ),
    ]

    public static func entries(for provider: CloudProvider, kind: CloudAudioKind) -> [Entry] {
        guard provider.offersAudio else { return [] }
        return gmi.filter { $0.kind == kind }
    }
}
