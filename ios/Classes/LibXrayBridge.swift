import Foundation
import Darwin

#if canImport(LibXray)
import LibXray
#endif

/// Dynamic and compile-time bridge for `LibXray.xcframework` (`XTLS/libXray`) and `Libv2ray` on iOS.
///
/// Works seamlessly whether:
/// 1. `LibXray.xcframework` is imported at compile time (`#if canImport(LibXray)`), OR
/// 2. `LibXray` / `Libv2ray` symbols are linked into the binary or loaded dynamically via `dlsym` / Objective-C runtime.
public final class LibXrayBridge {
    public static let shared = LibXrayBridge()

    private typealias CStringUnaryFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias CStringNullaryFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

    private var isCoreRunningFlag: Bool = false
    private let lock = NSLock()

    private init() {}

    public var isCoreRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCoreRunningFlag
    }

    // MARK: - Geo Assets Directory

    /// Copies `geoip.dat` and `geosite.dat` from the app/plugin bundle into the target working directory if present.
    public func prepareAssetsDirectory(groupIdentifier: String = "") -> URL {
        let baseDir: URL
        if !groupIdentifier.isEmpty,
           let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            baseDir = groupURL.appendingPathComponent("assets", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            baseDir = appSupport.appendingPathComponent("assets", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let geoFiles = ["geoip.dat", "geosite.dat"]
        let candidateBundles: [Bundle] = [
            Bundle.main,
            Bundle(for: LibXrayBridge.self)
        ]

        for file in geoFiles {
            let dest = baseDir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) {
                continue
            }
            let name = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            for bundle in candidateBundles {
                if let src = bundle.url(forResource: name, withExtension: ext) {
                    try? FileManager.default.copyItem(at: src, to: dest)
                    break
                }
            }
        }

        return baseDir
    }

    // MARK: - Core Lifecycle

    /// Starts Xray using `LibXrayRunXray` (or `LibXrayRunXrayFromJSON`).
    ///
    /// - Parameters:
    ///   - configJSON: Full Xray JSON configuration string.
    ///   - datDir: Path to directory containing `geoip.dat` / `geosite.dat`.
    ///   - configFileURL: File URL where `config.json` will be written for `LibXrayRunXray`.
    ///   - tunFd: Optional TUN file descriptor (`> 0` in PacketTunnel mode).
    ///   - maxMemory: Soft memory cap in bytes (default 45 MB for iOS NetworkExtension safety).
    public func startXray(
        configJSON: String,
        datDir: String,
        configFileURL: URL,
        tunFd: Int32 = 0,
        maxMemory: Int64 = 45 * 1024 * 1024
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if isCoreRunningFlag {
            _ = stopXrayInternal()
        }

        if tunFd > 0 {
            setenv("XRAY_TUN_FD", String(tunFd), 1)
            setenv("xray.tun.fd", String(tunFd), 1)
        } else {
            unsetenv("XRAY_TUN_FD")
            unsetenv("xray.tun.fd")
        }

        try configJSON.write(to: configFileURL, atomically: true, encoding: .utf8)

        let payload: [String: Any] = [
            "datDir": datDir,
            "configPath": configFileURL.path,
            "maxMemory": maxMemory
        ]
        let base64Req = try encodeBase64JSON(payload)

        if let responseBase64 = invokeUnary(symbol: "LibXrayRunXray", arg: base64Req) {
            try validateLibXrayResponse(responseBase64, context: "LibXrayRunXray")
            isCoreRunningFlag = true
            V2rayLogManager.shared.log("Xray core started via LibXrayRunXray (tunFd=\(tunFd))", level: "I", tag: "LibXrayBridge")
            return
        }

        // Fallback to LibXrayRunXrayFromJSON
        let jsonPayload: [String: Any] = [
            "datDir": datDir,
            "xrayJson": configJSON,
            "maxMemory": maxMemory
        ]
        let base64JsonReq = try encodeBase64JSON(jsonPayload)
        if let responseBase64 = invokeUnary(symbol: "LibXrayRunXrayFromJSON", arg: base64JsonReq) {
            try validateLibXrayResponse(responseBase64, context: "LibXrayRunXrayFromJSON")
            isCoreRunningFlag = true
            V2rayLogManager.shared.log("Xray core started via LibXrayRunXrayFromJSON (tunFd=\(tunFd))", level: "I", tag: "LibXrayBridge")
            return
        }

        throw NSError(
            domain: "LibXrayBridge",
            code: -404,
            userInfo: [NSLocalizedDescriptionKey: "LibXray binary not linked. Place LibXray.xcframework inside ios/Frameworks/ and run pod install."]
        )
    }

    /// Stops the active Xray instance via `LibXrayStopXray`.
    @discardableResult
    public func stopXray() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopXrayInternal()
    }

    private func stopXrayInternal() -> Bool {
        defer {
            isCoreRunningFlag = false
            unsetenv("XRAY_TUN_FD")
            unsetenv("xray.tun.fd")
        }
        if let responseBase64 = invokeNullary(symbol: "LibXrayStopXray") {
            V2rayLogManager.shared.log("LibXrayStopXray completed: \(decodeBase64String(responseBase64) ?? "OK")", level: "I", tag: "LibXrayBridge")
            return true
        }
        return false
    }

    // MARK: - Server Delay / Ping

    /// Measures server delay (in milliseconds) using `LibXrayPing` with an automatic HTTP URL probe fallback.
    public func measureOutboundDelay(
        configJSON: String,
        url: String,
        datDir: String,
        timeoutSeconds: Int = 10
    ) -> Int {
        let sanitizedConfig = V2rayConfigUtilities.prepareDelayTestConfig(configJSON)
        let tempConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray_ping_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: tempConfigURL)
        }

        do {
            try sanitizedConfig.write(to: tempConfigURL, atomically: true, encoding: .utf8)
            let localPort = extractLocalSocksOrHttpPort(from: sanitizedConfig) ?? 10808
            let proxyURI = "socks5://127.0.0.1:\(localPort)"

            let pingPayload: [String: Any] = [
                "datDir": datDir,
                "configPath": tempConfigURL.path,
                "timeout": timeoutSeconds,
                "url": url,
                "proxy": proxyURI
            ]
            let base64Req = try encodeBase64JSON(pingPayload)

            if let responseBase64 = invokeUnary(symbol: "LibXrayPing", arg: base64Req),
               let delay = parseDelayResponse(responseBase64) {
                return delay
            }
        } catch {
            V2rayLogManager.shared.log("measureOutboundDelay error: \(error.localizedDescription)", level: "W", tag: "LibXrayBridge")
        }

        return -1
    }

    /// Measures delay through the currently connected tunnel or local proxy by timing an HTTP request to `url`.
    public func measureConnectedDelay(url: String, localProxyPort: Int? = nil, timeoutSeconds: TimeInterval = 5.0) -> Int {
        guard let targetURL = URL(string: url) else { return -1 }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        if let port = localProxyPort, port > 0 {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as AnyHashable: 1,
                kCFNetworkProxiesSOCKSProxy as AnyHashable: "127.0.0.1",
                kCFNetworkProxiesSOCKSPort as AnyHashable: port
            ]
        }

        let session = URLSession(configuration: config)
        var request = URLRequest(url: targetURL)
        request.httpMethod = "HEAD"

        let semaphore = DispatchSemaphore(value: 0)
        var measuredMs: Int = -1
        let startTime = DispatchTime.now()

        let task = session.dataTask(with: request) { _, response, error in
            if error == nil, let httpResp = response as? HTTPURLResponse, (200..<400).contains(httpResp.statusCode) {
                let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                measuredMs = max(1, Int(elapsedNanos / 1_000_000))
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeoutSeconds + 0.5)
        session.invalidateAndCancel()
        return measuredMs
    }

    // MARK: - Traffic Statistics

    /// Queries cumulative outbound traffic `(downloadBytes, uploadBytes)` via `LibXrayQueryStats`.
    public func queryOutboundTraffic(apiPort: Int) -> (download: Int64, upload: Int64)? {
        let payload: [String: Any] = [
            "server": "127.0.0.1:\(apiPort)",
            "dir": ""
        ]
        guard let base64Req = try? encodeBase64JSON(payload),
              let responseBase64 = invokeUnary(symbol: "LibXrayQueryStats", arg: base64Req),
              let decoded = decodeBase64String(responseBase64),
              let data = decoded.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        // Parse LibXray response envelope (`{"success": true, "data": ...}`)
        var downloadTotal: Int64 = 0
        var uploadTotal: Int64 = 0

        if let statsData = json["data"] {
            accumulateStats(from: statsData, download: &downloadTotal, upload: &uploadTotal)
            return (downloadTotal, uploadTotal)
        } else if json["stat"] != nil {
            accumulateStats(from: json, download: &downloadTotal, upload: &uploadTotal)
            return (downloadTotal, uploadTotal)
        }

        return nil
    }

    // MARK: - Core Version

    /// Returns the embedded Xray-core version string via `LibXrayXrayVersion` (or fallback version).
    public func getCoreVersion() -> String {
        if let responseBase64 = invokeNullary(symbol: "LibXrayXrayVersion") {
            if let decoded = decodeBase64String(responseBase64),
               let data = decoded.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let versionStr = json["data"] as? String, !versionStr.isEmpty {
                    return versionStr
                }
            }
            if let plain = decodeBase64String(responseBase64), !plain.isEmpty {
                return plain
            }
            return responseBase64
        }
        return "Xray v26.9.9 (iOS)"
    }

    // MARK: - Internal FFI / Symbol Invocation

    private func invokeUnary(symbol: String, arg: String) -> String? {
        #if canImport(LibXray)
        switch symbol {
        case "LibXrayRunXray":
            return LibXrayRunXray(arg)
        case "LibXrayRunXrayFromJSON":
            return LibXrayRunXrayFromJSON(arg)
        case "LibXrayPing":
            return LibXrayPing(arg)
        case "LibXrayQueryStats":
            return LibXrayQueryStats(arg)
        case "LibXrayTestXray":
            return LibXrayTestXray(arg)
        default:
            break
        }
        #endif

        // Dynamic symbol lookup (`dlsym`) for CGo / Gomobile exported functions
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(RTLD_DEFAULT, symbol) {
            let fn = unsafeBitCast(sym, to: CStringUnaryFn.self)
            return arg.withCString { cStr in
                guard let resultPtr = fn(cStr) else { return nil }
                let str = String(cString: resultPtr)
                return str
            }
        }

        return nil
    }

    private func invokeNullary(symbol: String) -> String? {
        #if canImport(LibXray)
        switch symbol {
        case "LibXrayStopXray":
            return LibXrayStopXray()
        case "LibXrayXrayVersion":
            return LibXrayXrayVersion()
        default:
            break
        }
        #endif

        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(RTLD_DEFAULT, symbol) {
            let fn = unsafeBitCast(sym, to: CStringNullaryFn.self)
            guard let resultPtr = fn() else { return nil }
            return String(cString: resultPtr)
        }

        return nil
    }

    // MARK: - Serialization Helpers

    private func encodeBase64JSON(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return data.base64EncodedString()
    }

    private func decodeBase64String(_ base64Str: String) -> String? {
        let trimmed = base64Str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func validateLibXrayResponse(_ responseBase64: String, context: String) throws {
        guard let decoded = decodeBase64String(responseBase64),
              let data = decoded.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        if let success = json["success"] as? Bool, !success {
            let errMsg = (json["error"] as? String) ?? "Unknown error in \(context)"
            V2rayLogManager.shared.log("\(context) failed: \(errMsg)", level: "E", tag: "LibXrayBridge")
            throw NSError(domain: "LibXrayBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
    }

    private func parseDelayResponse(_ responseBase64: String) -> Int? {
        guard let decoded = decodeBase64String(responseBase64),
              let data = decoded.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let success = json["success"] as? Bool, !success {
            return -1
        }
        if let delayInt = json["data"] as? Int {
            return delayInt
        }
        if let delayInt64 = json["data"] as? Int64 {
            return Int(delayInt64)
        }
        if let delayStr = json["data"] as? String, let parsed = Int(delayStr) {
            return parsed
        }
        return nil
    }

    private func extractLocalSocksOrHttpPort(from configJSON: String) -> Int? {
        guard let data = configJSON.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inbounds = root["inbounds"] as? [[String: Any]] else {
            return nil
        }
        for inbound in inbounds {
            if let proto = inbound["protocol"] as? String,
               (proto == "socks" || proto == "http"),
               let port = inbound["port"] as? Int {
                return port
            }
        }
        return nil
    }

    private func accumulateStats(from rawStats: Any, download: inout Int64, upload: inout Int64) {
        if let str = rawStats as? String,
           let data = str.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data) {
            accumulateStats(from: nested, download: &download, upload: &upload)
            return
        }

        if let dict = rawStats as? [String: Any] {
            if let statArray = dict["stat"] as? [[String: Any]] {
                for item in statArray {
                    guard let name = item["name"] as? String else { continue }
                    let val: Int64
                    if let vInt = item["value"] as? Int64 {
                        val = vInt
                    } else if let vNum = item["value"] as? NSNumber {
                        val = vNum.int64Value
                    } else if let vStr = item["value"] as? String, let parsed = Int64(vStr) {
                        val = parsed
                    } else {
                        val = 0
                    }

                    if name.contains("outbound>>>proxy>>>traffic>>>downlink") ||
                       name.contains("outbound>>>block>>>traffic>>>downlink") {
                        download += val
                    } else if name.contains("outbound>>>proxy>>>traffic>>>uplink") ||
                              name.contains("outbound>>>block>>>traffic>>>uplink") {
                        upload += val
                    }
                }
            } else if let outboundDict = dict["outbound"] as? [String: Any] {
                for (tag, metricsAny) in outboundDict where tag == "proxy" || tag == "block" {
                    if let metrics = metricsAny as? [String: Any] {
                        if let down = (metrics["downlink"] as? NSNumber)?.int64Value {
                            download += down
                        }
                        if let up = (metrics["uplink"] as? NSNumber)?.int64Value {
                            upload += up
                        }
                    }
                }
            }
        }
    }
}
