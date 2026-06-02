import Cocoa

struct FontOverride {
    let name: String
    let size: Double
}

/// Lightweight user config at ~/.config/openautocomplete/config.json. Shape:
/// ```json
/// {
///   "fonts": {
///     "com.googlecode.iterm2": { "name": "MesloLGS NF", "size": 13 }
///   }
/// }
/// ```
/// Loaded once at startup; reload by quitting and relaunching.
final class Config {
    static let shared = Config()

    let fontOverrides: [String: FontOverride]

    private init() {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/openautocomplete/config.json")
        self.fontOverrides = Self.load(path: path)
        if !fontOverrides.isEmpty {
            Log.shared.line("Config: loaded \(fontOverrides.count) font override(s) from \(path)")
        }
    }

    func fontOverride(forBundle bundleId: String) -> NSFont? {
        guard let o = fontOverrides[bundleId] else { return nil }
        return NSFont(name: o.name, size: o.size)
    }

    private static func load(path: String) -> [String: FontOverride] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        guard let fonts = json["fonts"] as? [String: [String: Any]] else { return [:] }

        var out: [String: FontOverride] = [:]
        for (bundleId, entry) in fonts {
            guard let name = entry["name"] as? String else { continue }
            let size = (entry["size"] as? Double) ?? (entry["size"] as? Int).map(Double.init) ?? 14
            out[bundleId] = FontOverride(name: name, size: size)
        }
        return out
    }
}
