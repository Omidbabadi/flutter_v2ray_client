import Foundation

/// Thread-safe file and in-memory log manager for iOS V2Ray / Xray operations.
/// Supports sharing logs across the main app and the `NEPacketTunnelProvider` extension
/// via the configured App Group container directory (falling back to the local caches directory).
public final class V2rayLogManager {
    public static let shared = V2rayLogManager()

    private let maxLogLines = 500
    private let queue = DispatchQueue(label: "dev.amirzr.flutter_v2ray_client.log_queue", attributes: .concurrent)
    private var memoryBuffer: [String] = []
    private var groupIdentifier: String = ""

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private init() {}

    /// Configures the App Group identifier so logs from the PacketTunnel extension are visible in the UI app.
    public func configure(groupIdentifier: String) {
        queue.async(flags: .barrier) {
            self.groupIdentifier = groupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Resolves the shared log file URL (inside App Group container when available, or local Caches directory).
    public var logFileURL: URL {
        var currentGroup = ""
        queue.sync {
            currentGroup = self.groupIdentifier
        }
        if !currentGroup.isEmpty,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: currentGroup) {
            return containerURL.appendingPathComponent("v2ray_ios.log")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("v2ray_ios.log")
    }

    /// Appends a formatted log entry (`MM-dd HH:mm:ss.SSS I/Tag: message`) to the shared log file and buffer.
    public func log(_ message: String, level: String = "I", tag: String = "FlutterV2rayPlugin") {
        let timestamp = dateFormatter.string(from: Date())
        let formatted = "\(timestamp) \(level)/\(tag): \(message)"
        NSLog("[\(tag)] \(message)")

        queue.async(flags: .barrier) {
            self.memoryBuffer.append(formatted)
            if self.memoryBuffer.count > self.maxLogLines {
                self.memoryBuffer.removeFirst(self.memoryBuffer.count - self.maxLogLines)
            }
            self.appendLineToFile(formatted)
        }
    }

    /// Reads all log lines in chronological order (oldest -> newest), capped at `maxLogLines`.
    public func getLogs() -> [String] {
        return queue.sync {
            let fileURL = self.resolveLogFileURLInternal()
            var combined: [String] = []

            if FileManager.default.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                combined.append(contentsOf: lines)
            }

            // Also check if Xray wrote a core access/error log file in the shared container
            if let coreLogURL = self.resolveCoreErrorLogURLInternal(),
               FileManager.default.fileExists(atPath: coreLogURL.path),
               let coreContent = try? String(contentsOf: coreLogURL, encoding: .utf8) {
                let coreLines = coreContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
                combined.append(contentsOf: coreLines)
            }

            if combined.isEmpty {
                combined = self.memoryBuffer
            }

            if combined.count > self.maxLogLines {
                return Array(combined.suffix(self.maxLogLines))
            }
            return combined
        }
    }

    /// Clears both the in-memory log buffer and shared log files.
    public func clearLogs() -> Bool {
        return queue.sync(flags: .barrier) {
            self.memoryBuffer.removeAll()
            let fileURL = self.resolveLogFileURLInternal()
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                if let coreLogURL = self.resolveCoreErrorLogURLInternal(),
                   FileManager.default.fileExists(atPath: coreLogURL.path) {
                    try FileManager.default.removeItem(at: coreLogURL)
                }
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Private Helpers

    private func resolveLogFileURLInternal() -> URL {
        if !groupIdentifier.isEmpty,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return containerURL.appendingPathComponent("v2ray_ios.log")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("v2ray_ios.log")
    }

    private func resolveCoreErrorLogURLInternal() -> URL? {
        if !groupIdentifier.isEmpty,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return containerURL.appendingPathComponent("xray_core.log")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("xray_core.log")
    }

    private func appendLineToFile(_ line: String) {
        let fileURL = resolveLogFileURLInternal()
        let lineWithNewline = line + "\n"
        guard let data = lineWithNewline.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
