import Foundation

/// Debug log at ~/Coding/SlideOver/debug.log (temporary, for tracking down the desktop/Spaces issue).
enum Log {
    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Coding/SlideOver/debug.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Off by default. Turn on with:  defaults write ch.nicoberlinger.SlideOver debugLog -bool true
    static var enabled = UserDefaults.standard.bool(forKey: "debugLog")

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
