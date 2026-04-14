import Foundation

final class Log {
    static let shared = Log()

    let path: String
    private let handle: FileHandle
    private let formatter: DateFormatter

    private init() {
        // Write to ~/Library/Logs/OpenScribe/openscribe.log — a stable absolute path that
        // survives the working-directory changes that happen when launching via `open`.
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/OpenScribe")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("openscribe.log")
        FileManager.default.createFile(atPath: self.path, contents: nil)
        self.handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: self.path))

        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        self.formatter = f
    }

    func line(_ s: String) {
        let stamped = "[\(formatter.string(from: Date()))] \(s)\n"
        if let data = stamped.data(using: .utf8) {
            handle.write(data)
        }
    }
}
