import Foundation

/// Persisted user settings. Reads/writes to `UserDefaults` under the app's domain.
/// Anything stored here survives launches and is editable from the menu-bar UI.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let modelId = "openscribe.model.id"
        static let acceptKeyCode = "openscribe.acceptkey.code"
    }

    /// HuggingFace repo ID of the model to load on launch. Changes take effect after
    /// quit + relaunch (the model is loaded once at startup and held in memory).
    var modelId: String {
        get { defaults.string(forKey: Keys.modelId) ?? Catalog.defaultModelId }
        set { defaults.set(newValue, forKey: Keys.modelId) }
    }

    /// CGEvent virtual keycode of the key that commits the next chunk of the
    /// suggestion. Changes take effect immediately. Default Tab (48).
    var acceptKeyCode: Int64 {
        get {
            let raw = defaults.integer(forKey: Keys.acceptKeyCode)
            return raw == 0 ? 48 : Int64(raw)
        }
        set { defaults.set(Int(newValue), forKey: Keys.acceptKeyCode) }
    }

    /// Curated lists of supported models + keys. Keeping them centralized so the
    /// settings UI and the runtime resolver agree on names, and so adding a new
    /// option is a one-line edit here.
    enum Catalog {
        struct Model {
            let label: String
            let id: String
            let approxSize: String
        }

        struct AcceptKey {
            let label: String
            let keyCode: Int64
        }

        static let defaultModelId = "mlx-community/gemma-4-e4b-it-4bit"

        static let models: [Model] = [
            Model(label: "Gemma 4 E4B (recommended)", id: "mlx-community/gemma-4-e4b-it-4bit", approxSize: "~3.2 GB"),
            Model(label: "Gemma 4 E2B (smaller)", id: "mlx-community/gemma-4-e2b-it-4bit", approxSize: "~1.6 GB"),
            Model(label: "Gemma 3 Text 4B", id: "mlx-community/gemma-3-text-4b-it-4bit", approxSize: "~2.3 GB"),
            Model(label: "Llama 3.2 3B Instruct", id: "mlx-community/Llama-3.2-3B-Instruct-4bit", approxSize: "~2.0 GB"),
            Model(label: "Llama 3.2 1B Instruct (fastest)", id: "mlx-community/Llama-3.2-1B-Instruct-4bit", approxSize: "~700 MB"),
            Model(label: "Qwen 2.5 3B Instruct", id: "mlx-community/Qwen2.5-3B-Instruct-4bit", approxSize: "~2.0 GB"),
        ]

        static let acceptKeys: [AcceptKey] = [
            AcceptKey(label: "Tab", keyCode: 48),
            AcceptKey(label: "Return", keyCode: 36),
            AcceptKey(label: "Right Arrow", keyCode: 124),
            AcceptKey(label: "F1", keyCode: 122),
        ]
    }
}
