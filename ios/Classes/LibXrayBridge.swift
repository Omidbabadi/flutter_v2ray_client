import Foundation
import Darwin

#if canImport(LibXray)
import LibXray
#endif

/// Native iOS bridge for `LibXray.xcframework` (`XTLS/libXray` API v3 `CGoInvoke` + `CGoFree`),
/// with automatic fallback to legacy `LibXray*` symbols if a different XCFramework build is linked.
public final class LibXrayBridge {
    public static let shared = LibXrayBridge()

    private static let apiVersion: Int = 3

    private typealias CGoInvokeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias CGoFreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias CStringUnaryFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias CStringNullaryFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

    private var isCoreRunningFlag: Bool = false
    private let lock = NSLock()

    private init() {}

    public var isCoreRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let stateResp = try? invokeAPIV3(method: "getXrayState", payload: nil),
           let dataDict = stateResp["data"] as? [String: Any],
           let running = dataDict["running"] as? Bool {
            isCoreRunningFlag = running
        }
        return isCoreRunningFlag
    }

    // MARK: - Geo Assets Directory

    /// Copies `geoip.dat` and `geosite.dat` from the app/plugin bundle into the target working directory if present,
    /// and sets `xray.location.asset` in the process environment.
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

        setenv("xray.location.asset", baseDir.path, 1)
        setenv("XRAY_LOCATION_ASSET", baseDir.path, 1)
        return baseDir
    }

    // MARK: - Core Lifecycle

    /// Starts Xray using `XTLS/libXray` API v3 (`method: "runXray"`, `payload: {"xrayJson": ...}`).
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

        setenv("xray.location.asset", datDir, 1)
        setenv("XRAY_LOCATION_ASSET", datDir, 1)
        setenv("GOMEMLIMIT", "\(maxMemory)B", 1)

        if tunFd > 0 {
            setenv("XRAY_TUN_FD", String(tunFd), 1)
            setenv("xray.tun.fd", String(tunFd), 1)
        } else {
            unsetenv("XRAY_TUN_FD")
            unsetenv("xray.tun.fd")
        }

        try configJSON.write(to: configFileURL, atomically: true, encoding: .utf8)

        // 1. Primary path: XTLS/libXray API v3 `CGoInvoke` (`method: "runXray"`)
        if let response = try invokeAPIV3(method: "runXray", payload: ["xrayJson": configJSON]) {
            try validateInvokeEnvelope(response, context: "runXray")
            isCoreRunningFlag = true
            V2rayLogManager.shared.log("Xray core started via CGoInvoke(runXray) (tunFd=\(tunFd))", level: "I", tag: "LibXrayBridge")
            return
        }

        // 2. Fallback: Legacy base64 `LibXrayRunXray` if linked against an older wrapper
        let legacyPayload: [String: Any] = [
            "datDir": datDir,
            "configPath": configFileURL.path,
            "maxMemory": maxMemory
        ]
        let base64Req = try encodeBase64JSON(legacyPayload)
        if let responseBase64 = invokeLegacyUnary(symbol: "LibXrayRunXray", arg: base64Req),
           let decoded = decodeBase64JSON(responseBase64) {
            try validateInvokeEnvelope(decoded, context: "LibXrayRunXray")
            isCoreRunningFlag = true
            V2rayLogManager.shared.log("Xray core started via legacy LibXrayRunXray (tunFd=\(tunFd))", level: "I", tag: "LibXrayBridge")
            return
        }

        throw NSError(
            domain: "LibXrayBridge",
            code: -404,
            userInfo: [NSLocalizedDescriptionKey: "LibXray symbols (CGoInvoke) not found. Ensure LibXray.xcframework is linked."]
        )
    }

    /// Stops the active Xray instance via `CGoInvoke` (`method: "stopXray"`).
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
        if let resp = try? invokeAPIV3(method: "stopXray", payload: nil) {
            let ok = (resp["success"] as? Bool) ?? true
            V2rayLogManager.shared.log("CGoInvoke(stopXray) completed (success=\(ok))", level: "I", tag: "LibXrayBridge")
            return ok
        }
        if let responseBase64 = invokeLegacyNullary(symbol: "LibXrayStopXray") {
            V2rayLogManager.shared.log("Legacy LibXrayStopXray completed: \(responseBase64)", level: "I", tag: "LibXrayBridge")
            return true
        }
        return false
    }

    // MARK: - Server Delay / Ping

    /// Measures server delay (in milliseconds) using `XTLS/libXray` API v3 `pingBatch`
    /// (when no managed Xray instance is running in the current process) or via an isolated temporary proxy session.
    public func measureOutboundDelay(
        configJSON: String,
        url: String,
        datDir: String,
        timeoutSeconds: Int = 10
    ) -> Int {
        setenv("xray.location.asset", datDir, 1)
        setenv("XRAY_LOCATION_ASSET", datDir, 1)

        let sanitizedConfig = V2rayConfigUtilities.prepareDelayTestConfig(configJSON)
        let outboundTag = extractPrimaryOutboundTag(from: sanitizedConfig) ?? "proxy"
        let timeoutMs = max(1000, timeoutSeconds * 1000)

        // 1. Primary path: XTLS/libXray API v3 `pingBatch`
        // Note: `pingBatch` requires no active managed Xray instance in the same process.
        // In VPN mode, Xray runs inside the PacketTunnel extension process, so the main app process is clean!
        let pingBatchPayload: [String: Any] = [
            "configs": [
                [
                    "xrayJson": sanitizedConfig,
                    "outboundTag": outboundTag
                ]
            ],
            "timeout": timeoutMs,
            "url": url
        ]

        if let response = try? invokeAPIV3(method: "pingBatch", payload: pingBatchPayload) {
            if let success = response["success"] as? Bool, success,
               let dataDict = response["data"] as? [String: Any],
               let results = dataDict["results"] as? [[String: Any]],
               let first = results.first {
                let itemSuccess = (first["success"] as? Bool) ?? false
                if itemSuccess {
                    if let delay = (first["delay"] as? NSNumber)?.intValue {
                        return delay
                    }
                } else if let errStr = first["error"] as? String {
                    V2rayLogManager.shared.log("pingBatch item error: \(errStr)", level: "W", tag: "LibXrayBridge")
                }
                return -1
            } else if let errStr = response["error"] as? String {
                V2rayLogManager.shared.log("pingBatch invoke note: \(errStr)", level: "W", tag: "LibXrayBridge")
                // If pingBatch returned "pingBatch requires an isolated process without a managed Xray instance"
                // (e.g., while proxy-only mode is active in the same process), fall back to connected proxy probe:
                if errStr.contains("isolated process") {
                    let localPort = extractLocalSocksOrHttpPort(from: sanitizedConfig)
                    return measureConnectedDelay(url: url, localProxyPort: localPort, timeoutSeconds: TimeInterval(timeoutSeconds))
                }
            }
        }

        // 2. Fallback: Legacy `LibXrayPing`
        let tempConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray_ping_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: tempConfigURL)
        }
        if let _ = try? sanitizedConfig.write(to: tempConfigURL, atomically: true, encoding: .utf8) {
            let localPort = extractLocalSocksOrHttpPort(from: sanitizedConfig) ?? 10808
            let legacyPing: [String: Any] = [
                "datDir": datDir,
                "configPath": tempConfigURL.path,
                "timeout": timeoutSeconds,
                "url": url,
                "proxy": "socks5://127.0.0.1:\(localPort)"
            ]
            if let base64Req = try? encodeBase64JSON(legacyPing),
               let responseBase64 = invokeLegacyUnary(symbol: "LibXrayPing", arg: base64Req),
               let decoded = decodeBase64JSON(responseBase64),
               let delay = (decoded["data"] as? NSNumber)?.intValue {
                return delay
            }
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
                "HTTPEnable": 1,
                "HTTPProxy": "127.0.0.1",
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": port,
                "SOCKSEnable": 1,
                "SOCKSProxy": "127.0.0.1",
                "SOCKSPort": port
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

    /// Queries cumulative outbound traffic `(downloadBytes, uploadBytes)` from Xray's built-in
    /// `/debug/vars` metrics endpoint on `127.0.0.1:apiPort` (or legacy `LibXrayQueryStats`).
    public func queryOutboundTraffic(apiPort: Int) -> (download: Int64, upload: Int64)? {
        // 1. Primary path: HTTP GET `http://127.0.0.1:<apiPort>/debug/vars`
        if let url = URL(string: "http://127.0.0.1:\(apiPort)/debug/vars") {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 0.8
            config.timeoutIntervalForResource = 0.8
            let session = URLSession(configuration: config)
            let semaphore = DispatchSemaphore(value: 0)
            var resultStats: (Int64, Int64)?

            let task = session.dataTask(with: url) { data, response, error in
                defer { semaphore.signal() }
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return
                }
                var down: Int64 = 0
                var up: Int64 = 0
                if let statsObj = root["stats"] {
                    self.accumulateStats(from: statsObj, download: &down, upload: &up)
                    resultStats = (down, up)
                }
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 0.9)
            session.invalidateAndCancel()

            if let stats = resultStats {
                return stats
            }
        }

        // 2. Fallback: Legacy `LibXrayQueryStats`
        let payload: [String: Any] = [
            "server": "127.0.0.1:\(apiPort)",
            "dir": ""
        ]
        if let base64Req = try? encodeBase64JSON(payload),
           let responseBase64 = invokeLegacyUnary(symbol: "LibXrayQueryStats", arg: base64Req),
           let json = decodeBase64JSON(responseBase64) {
            var down: Int64 = 0
            var up: Int64 = 0
            if let statsData = json["data"] {
                accumulateStats(from: statsData, download: &down, upload: &up)
                return (down, up)
            }
        }

        return nil
    }

    // MARK: - Core Version

    /// Returns the embedded Xray-core version string via `CGoInvoke` (`method: "xrayVersion"`).
    public func getCoreVersion() -> String {
        if let response = try? invokeAPIV3(method: "xrayVersion", payload: nil) {
            if let dataDict = response["data"] as? [String: Any],
               let version = dataDict["version"] as? String,
               !version.isEmpty {
                return version
            }
            if let versionStr = response["data"] as? String, !versionStr.isEmpty {
                return versionStr
            }
        }

        if let responseBase64 = invokeLegacyNullary(symbol: "LibXrayXrayVersion"),
           let json = decodeBase64JSON(responseBase64),
           let versionStr = json["data"] as? String,
           !versionStr.isEmpty {
            return versionStr
        }

        return "Xray v26.9.9 (iOS)"
    }

    // MARK: - API v3 `CGoInvoke` / `CGoFree` Dispatcher

    private func invokeAPIV3(method: String, payload: [String: Any]?) throws -> [String: Any]? {
        var envelope: [String: Any] = [
            "apiVersion": Self.apiVersion,
            "method": method
        ]
        if let payload = payload {
            envelope["payload"] = payload
        }

        let reqData = try JSONSerialization.data(withJSONObject: envelope, options: [])
        guard let reqJSON = String(data: reqData, encoding: .utf8) else {
            return nil
        }

        guard let respJSON = callCGoInvoke(reqJSON),
              let respData = respJSON.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func callCGoInvoke(_ requestJSON: String) -> String? {
        #if canImport(LibXray)
        return requestJSON.withCString { cStr -> String? in
            let mutableReq = strdup(cStr)
            defer { free(mutableReq) }
            guard let resPtr = CGoInvoke(mutableReq) else { return nil }
            defer { CGoFree(resPtr) }
            return String(cString: resPtr)
        }
        #else
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard let invokeSym = dlsym(RTLD_DEFAULT, "CGoInvoke") else {
            return nil
        }
        let invokeFn = unsafeBitCast(invokeSym, to: CGoInvokeFn.self)
        let freeSym = dlsym(RTLD_DEFAULT, "CGoFree")
        let freeFn = freeSym.map { unsafeBitCast($0, to: CGoFreeFn.self) }

        return requestJSON.withCString { cStr -> String? in
            let mutableReq = strdup(cStr)
            defer { free(mutableReq) }
            guard let resPtr = invokeFn(mutableReq) else { return nil }
            defer { freeFn?(resPtr) }
            return String(cString: resPtr)
        }
        #endif
    }

    // MARK: - Legacy Dynamic Symbol Fallbacks

    private func invokeLegacyUnary(symbol: String, arg: String) -> String? {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(RTLD_DEFAULT, symbol) {
            let fn = unsafeBitCast(sym, to: CStringUnaryFn.self)
            return arg.withCString { cStr in
                guard let resultPtr = fn(cStr) else { return nil }
                return String(cString: resultPtr)
            }
        }
        return nil
    }

    private func invokeLegacyNullary(symbol: String) -> String? {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(RTLD_DEFAULT, symbol) {
            let fn = unsafeBitCast(sym, to: CStringNullaryFn.self)
            guard let resultPtr = fn() else { return nil }
            return String(cString: resultPtr)
        }
        return nil
    }

    // MARK: - Serialization & Parsing Helpers

    private func encodeBase64JSON(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return data.base64EncodedString()
    }

    private func decodeBase64JSON(_ base64Str: String) -> [String: Any]? {
        let trimmed = base64Str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func validateInvokeEnvelope(_ json: [String: Any], context: String) throws {
        if let success = json["success"] as? Bool, !success {
            let errMsg = (json["error"] as? String) ?? "Unknown error in \(context)"
            V2rayLogManager.shared.log("\(context) failed: \(errMsg)", level: "E", tag: "LibXrayBridge")
            throw NSError(domain: "LibXrayBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
    }

    private func extractPrimaryOutboundTag(from configJSON: String) -> String? {
        guard let data = configJSON.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              let first = outbounds.first,
              let tag = first["tag"] as? String,
              !tag.isEmpty else {
            return nil
        }
        return tag
    }

    private func extractLocalSocksOrHttpPort(from configJSON: String) -> Int? {
        guard let data = configJSON.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inbounds = root["inbounds"] as? [[String: Any]] else {
            return nil
        }
        // Prefer HTTP inbound first because iOS URLSession natively supports HTTP/HTTPS proxies in connectionProxyDictionary.
        for inbound in inbounds {
            if let proto = (inbound["protocol"] as? String)?.lowercased(),
               proto == "http",
               let port = (inbound["port"] as? NSNumber)?.intValue, port > 0 {
                return port
            }
        }
        for inbound in inbounds {
            if let proto = (inbound["protocol"] as? String)?.lowercased(),
               proto == "socks",
               let port = (inbound["port"] as? NSNumber)?.intValue, port > 0 {
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

        guard let dict = rawStats as? [String: Any] else { return }

        // Format 1: `/debug/vars` -> `stats.outbound.<tag>.downlink` or `stats.outbound.<tag>.traffic.downlink`
        if let outboundDict = dict["outbound"] as? [String: Any] {
            let ignoredTags: Set<String> = ["direct", "blackhole", "metrics_out", "api"]
            for (tag, metricsAny) in outboundDict where !ignoredTags.contains(tag.lowercased()) {
                guard let metrics = metricsAny as? [String: Any] else { continue }
                if let traffic = metrics["traffic"] as? [String: Any] {
                    download += (traffic["downlink"] as? NSNumber)?.int64Value ?? 0
                    upload += (traffic["uplink"] as? NSNumber)?.int64Value ?? 0
                } else {
                    download += (metrics["downlink"] as? NSNumber)?.int64Value ?? 0
                    upload += (metrics["uplink"] as? NSNumber)?.int64Value ?? 0
                }
            }
            return
        }

        // Format 2: StatsService array `{"stat": [{"name": "outbound>>>proxy>>>traffic>>>downlink", "value": 123}]}`
        if let statArray = dict["stat"] as? [[String: Any]] {
            for item in statArray {
                guard let name = item["name"] as? String else { continue }
                let val: Int64
                if let vNum = item["value"] as? NSNumber {
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
        }
    }
}
