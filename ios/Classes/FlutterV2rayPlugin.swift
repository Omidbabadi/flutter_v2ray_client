#if canImport(Flutter)
import Flutter
import UIKit
import NetworkExtension

public class FlutterV2rayPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    // Configuration from initializeV2Ray
    private var providerBundleIdentifier: String = ""
    private var groupIdentifier: String = ""

    // Active connection state
    private var isProxyOnlyMode: Bool = false
    private var activeManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    private var statusTimer: DispatchSourceTimer?
    private var connectedAt: Date?

    // Traffic counters
    private var totalDownload: Int64 = 0
    private var totalUpload: Int64 = 0
    private var downloadSpeed: Int64 = 0
    private var uploadSpeed: Int64 = 0
    private var lastRawDownload: Int64 = 0
    private var lastRawUpload: Int64 = 0
    private var currentState: String = "DISCONNECTED"
    private var activeApiPort: Int = 10085
    private var activeLocalProxyPort: Int?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "flutter_v2ray_client",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "flutter_v2ray_client/status",
            binaryMessenger: registrar.messenger()
        )

        let instance = FlutterV2rayPlugin()
        instance.methodChannel = methodChannel
        instance.eventChannel = eventChannel

        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    deinit {
        stopStatusTimer()
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        emitCurrentStatus()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - FlutterPlugin Method Call Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initializeV2Ray":
            handleInitialize(args: args, result: result)

        case "requestPermission":
            handleRequestPermission(result: result)

        case "startV2Ray":
            handleStartV2Ray(args: args, result: result)

        case "stopV2Ray":
            handleStopV2Ray(result: result)

        case "getServerDelay":
            handleGetServerDelay(args: args, result: result)

        case "getConnectedServerDelay":
            handleGetConnectedServerDelay(args: args, result: result)

        case "getCoreVersion":
            result(LibXrayBridge.shared.getCoreVersion())

        case "getLogs":
            DispatchQueue.global(qos: .userInitiated).async {
                let logs = V2rayLogManager.shared.getLogs()
                DispatchQueue.main.async {
                    result(logs)
                }
            }

        case "clearLogs":
            DispatchQueue.global(qos: .userInitiated).async {
                let cleared = V2rayLogManager.shared.clearLogs()
                DispatchQueue.main.async {
                    result(cleared)
                }
            }

        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Implementations

    private func handleInitialize(args: [String: Any], result: @escaping FlutterResult) {
        let bundleId = (args["providerBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupId = (args["groupIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !bundleId.isEmpty {
            self.providerBundleIdentifier = bundleId
        } else if let mainBundleId = Bundle.main.bundleIdentifier {
            self.providerBundleIdentifier = "\(mainBundleId).XrayTunnel"
        }

        if !groupId.isEmpty {
            self.groupIdentifier = groupId
        } else if let mainBundleId = Bundle.main.bundleIdentifier {
            self.groupIdentifier = "group.\(mainBundleId)"
        }

        V2rayLogManager.shared.configure(groupIdentifier: self.groupIdentifier)
        _ = LibXrayBridge.shared.prepareAssetsDirectory(groupIdentifier: self.groupIdentifier)

        observeVPNStatusChanges()
        syncExistingTunnelState()

        V2rayLogManager.shared.log(
            "Initialized iOS V2Ray plugin (provider=\(self.providerBundleIdentifier), group=\(self.groupIdentifier))",
            level: "I",
            tag: "FlutterV2rayPlugin"
        )
        result(nil)
    }

    private func handleRequestPermission(result: @escaping FlutterResult) {
        if isProxyOnlyMode {
            result(true)
            return
        }

        loadOrCreateTunnelManager { [weak self] manager, error in
            guard let self = self else { return }
            if let error = error {
                V2rayLogManager.shared.log("VPN permission request error: \(error.localizedDescription)", level: "E", tag: "FlutterV2rayPlugin")
                result(false)
                return
            }
            guard let manager = manager else {
                result(false)
                return
            }
            self.activeManager = manager
            result(true)
        }
    }

    private func handleStartV2Ray(args: [String: Any], result: @escaping FlutterResult) {
        let remark = (args["remark"] as? String) ?? "Flutter V2Ray"
        let rawConfig = (args["config"] as? String) ?? ""
        let proxyOnly = (args["proxy_only"] as? Bool) ?? false
        let bypassSubnets = (args["bypass_subnets"] as? [String]) ?? []

        self.isProxyOnlyMode = proxyOnly
        resetTrafficMetrics()

        if proxyOnly {
            startProxyOnlySession(remark: remark, rawConfig: rawConfig, result: result)
        } else {
            startVPNSession(remark: remark, rawConfig: rawConfig, bypassSubnets: bypassSubnets, result: result)
        }
    }

    private func handleStopV2Ray(result: @escaping FlutterResult) {
        V2rayLogManager.shared.log("Stopping V2Ray (proxyOnly=\(isProxyOnlyMode))", level: "I", tag: "FlutterV2rayPlugin")

        if isProxyOnlyMode || LibXrayBridge.shared.isCoreRunning {
            LibXrayBridge.shared.stopXray()
            stopStatusTimer()
            connectedAt = nil
            updateStateAndEmit("DISCONNECTED")
        }

        if let manager = activeManager {
            manager.connection.stopVPNTunnel()
            stopStatusTimer()
            connectedAt = nil
            updateStateAndEmit("DISCONNECTED")
            result(nil)
            return
        }

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            managers?.forEach { $0.connection.stopVPNTunnel() }
            self?.stopStatusTimer()
            self?.connectedAt = nil
            self?.updateStateAndEmit("DISCONNECTED")
            result(nil)
        }
    }

    private func handleGetServerDelay(args: [String: Any], result: @escaping FlutterResult) {
        let rawConfig = (args["config"] as? String) ?? ""
        let url = (args["url"] as? String) ?? "https://google.com/generate_204"
        let groupId = self.groupIdentifier

        DispatchQueue.global(qos: .userInitiated).async {
            let datDir = LibXrayBridge.shared.prepareAssetsDirectory(groupIdentifier: groupId).path
            let delay = LibXrayBridge.shared.measureOutboundDelay(
                configJSON: rawConfig,
                url: url,
                datDir: datDir
            )
            DispatchQueue.main.async {
                result(delay)
            }
        }
    }

    private func handleGetConnectedServerDelay(args: [String: Any], result: @escaping FlutterResult) {
        let url = (args["url"] as? String) ?? "https://google.com/generate_204"

        guard currentState == "CONNECTED" else {
            result(-1)
            return
        }

        if isProxyOnlyMode {
            let port = activeLocalProxyPort
            DispatchQueue.global(qos: .userInitiated).async {
                let delay = LibXrayBridge.shared.measureConnectedDelay(url: url, localProxyPort: port)
                DispatchQueue.main.async {
                    result(delay)
                }
            }
            return
        }

        // In VPN mode, ask the PacketTunnel extension via sendProviderMessage, falling back to direct URLSession probe
        if let session = activeManager?.connection as? NETunnelProviderSession,
           session.status == .connected,
           let payload = try? JSONSerialization.data(withJSONObject: ["command": "measureDelay", "url": url]) {
            do {
                try session.sendProviderMessage(payload) { responseData in
                    if let data = responseData,
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let delay = json["delay"] as? Int {
                        DispatchQueue.main.async {
                            result(delay)
                        }
                    } else {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let fallbackDelay = LibXrayBridge.shared.measureConnectedDelay(url: url)
                            DispatchQueue.main.async {
                                result(fallbackDelay)
                            }
                        }
                    }
                }
                return
            } catch {
                // Fall through to direct URLSession probe
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let delay = LibXrayBridge.shared.measureConnectedDelay(url: url)
            DispatchQueue.main.async {
                result(delay)
            }
        }
    }

    // MARK: - Proxy-Only Mode (In-Process LibXray)

    private func startProxyOnlySession(
        remark: String,
        rawConfig: String,
        result: @escaping FlutterResult
    ) {
        updateStateAndEmit("CONNECTING")
        let groupId = self.groupIdentifier

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let prepared = V2rayConfigUtilities.prepareRuntimeConfig(
                rawConfig,
                enableTrafficStats: true,
                apiPort: 10085,
                injectTunInbound: false
            )
            self.activeApiPort = prepared.apiPort
            self.activeLocalProxyPort = self.extractLocalPort(from: prepared.config)

            let datDir = LibXrayBridge.shared.prepareAssetsDirectory(groupIdentifier: groupId).path
            let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("xray_proxy_config.json")

            do {
                try LibXrayBridge.shared.startXray(
                    configJSON: prepared.config,
                    datDir: datDir,
                    configFileURL: configURL,
                    tunFd: 0
                )
                DispatchQueue.main.async {
                    self.connectedAt = Date()
                    self.updateStateAndEmit("CONNECTED")
                    self.startStatusTimer()
                    V2rayLogManager.shared.log("Started proxy-only session (\(remark))", level: "I", tag: "FlutterV2rayPlugin")
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStateAndEmit("DISCONNECTED")
                    V2rayLogManager.shared.log("Proxy-only start failed: \(error.localizedDescription)", level: "E", tag: "FlutterV2rayPlugin")
                    result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - VPN Mode (NETunnelProviderManager + V2rayPacketTunnelProvider)

    private func startVPNSession(
        remark: String,
        rawConfig: String,
        bypassSubnets: [String],
        result: @escaping FlutterResult
    ) {
        updateStateAndEmit("CONNECTING")
        saveSharedConfig(rawConfig)

        loadOrCreateTunnelManager(remark: remark, rawConfig: rawConfig, bypassSubnets: bypassSubnets) { [weak self] manager, error in
            guard let self = self else { return }
            if let error = error {
                self.updateStateAndEmit("DISCONNECTED")
                V2rayLogManager.shared.log("Failed to configure VPN manager: \(error.localizedDescription)", level: "E", tag: "FlutterV2rayPlugin")
                result(FlutterError(code: "VPN_CONFIG_ERROR", message: error.localizedDescription, details: nil))
                return
            }

            guard let manager = manager else {
                self.updateStateAndEmit("DISCONNECTED")
                result(FlutterError(code: "VPN_MANAGER_NIL", message: "NETunnelProviderManager is nil", details: nil))
                return
            }

            self.activeManager = manager
            let options: [String: NSObject] = [
                "config": rawConfig as NSString,
                "remark": remark as NSString,
                "groupIdentifier": self.groupIdentifier as NSString,
                "bypassSubnets": bypassSubnets as NSArray
            ]

            do {
                try manager.connection.startVPNTunnel(options: options)
                V2rayLogManager.shared.log("Requested startVPNTunnel (\(remark))", level: "I", tag: "FlutterV2rayPlugin")
                result(nil)
            } catch {
                self.updateStateAndEmit("DISCONNECTED")
                V2rayLogManager.shared.log("startVPNTunnel threw error: \(error.localizedDescription)", level: "E", tag: "FlutterV2rayPlugin")
                result(FlutterError(code: "VPN_START_ERROR", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func loadOrCreateTunnelManager(
        remark: String = "Flutter V2Ray",
        rawConfig: String? = nil,
        bypassSubnets: [String] = [],
        completion: @escaping (NETunnelProviderManager?, Error?) -> Void
    ) {
        let targetBundleId = self.providerBundleIdentifier.isEmpty
            ? "\(Bundle.main.bundleIdentifier ?? "com.example.example").XrayTunnel"
            : self.providerBundleIdentifier

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                completion(nil, error)
                return
            }

            let manager = managers?.first { mgr in
                guard let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol else { return false }
                return proto.providerBundleIdentifier == targetBundleId
            } ?? managers?.first ?? NETunnelProviderManager()

            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = targetBundleId
            proto.serverAddress = remark.isEmpty ? "Flutter V2Ray" : remark

            var providerConfig = proto.providerConfiguration ?? [:]
            providerConfig["groupIdentifier"] = self.groupIdentifier
            providerConfig["remark"] = remark
            if let rawConfig = rawConfig {
                providerConfig["config"] = rawConfig
            }
            if !bypassSubnets.isEmpty {
                providerConfig["bypassSubnets"] = bypassSubnets
            }
            proto.providerConfiguration = providerConfig

            manager.protocolConfiguration = proto
            manager.localizedDescription = remark.isEmpty ? "Flutter V2Ray" : remark
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    completion(nil, saveError)
                    return
                }
                manager.loadFromPreferences { reloadError in
                    if let reloadError = reloadError {
                        completion(nil, reloadError)
                        return
                    }
                    completion(manager, nil)
                }
            }
        }
    }

    // MARK: - VPN Status Observation & 1-Second Telemetry Timer

    private func observeVPNStatusChanges() {
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        vpnObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let connection = notification.object as? NEVPNConnection else {
                return
            }
            self.applyNEVPNStatus(connection.status)
        }
    }

    private func syncExistingTunnelState() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self, let manager = managers?.first else { return }
            self.activeManager = manager
            DispatchQueue.main.async {
                self.applyNEVPNStatus(manager.connection.status)
            }
        }
    }

    private func applyNEVPNStatus(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            if connectedAt == nil {
                connectedAt = Date()
            }
            updateStateAndEmit("CONNECTED")
            startStatusTimer()
        case .connecting, .reasserting:
            updateStateAndEmit("CONNECTING")
        case .disconnecting, .disconnected, .invalid:
            if !isProxyOnlyMode {
                stopStatusTimer()
                connectedAt = nil
                downloadSpeed = 0
                uploadSpeed = 0
                updateStateAndEmit("DISCONNECTED")
            }
        @unknown default:
            break
        }
    }

    private func startStatusTimer() {
        stopStatusTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.tickStatusAndStats()
        }
        timer.resume()
        self.statusTimer = timer
    }

    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    private func tickStatusAndStats() {
        guard currentState == "CONNECTED" else { return }

        if isProxyOnlyMode {
            if let stats = LibXrayBridge.shared.queryOutboundTraffic(apiPort: activeApiPort) {
                updateTrafficCounters(newDownload: stats.download, newUpload: stats.upload)
            }
            DispatchQueue.main.async { [weak self] in
                self?.emitCurrentStatus()
            }
            return
        }

        // VPN mode: request stats from PacketTunnel extension
        if let session = activeManager?.connection as? NETunnelProviderSession,
           session.status == .connected,
           let payload = try? JSONSerialization.data(withJSONObject: ["command": "queryStats"]) {
            do {
                try session.sendProviderMessage(payload) { [weak self] responseData in
                    guard let self = self else { return }
                    if let data = responseData,
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        let down = (json["download"] as? NSNumber)?.int64Value ?? 0
                        let up = (json["upload"] as? NSNumber)?.int64Value ?? 0
                        self.updateTrafficCounters(newDownload: down, newUpload: up)
                    }
                    DispatchQueue.main.async {
                        self.emitCurrentStatus()
                    }
                }
                return
            } catch {
                // Fallback to emitting duration even if provider message fails
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.emitCurrentStatus()
        }
    }

    private func updateTrafficCounters(newDownload: Int64, newUpload: Int64) {
        if newDownload >= lastRawDownload && newUpload >= lastRawUpload {
            downloadSpeed = max(0, newDownload - lastRawDownload)
            uploadSpeed = max(0, newUpload - lastRawUpload)
            totalDownload = newDownload
            totalUpload = newUpload
        } else {
            // If Xray resets counters per query (delta mode)
            downloadSpeed = max(0, newDownload)
            uploadSpeed = max(0, newUpload)
            totalDownload += downloadSpeed
            totalUpload += uploadSpeed
        }
        lastRawDownload = newDownload
        lastRawUpload = newUpload
    }

    private func resetTrafficMetrics() {
        totalDownload = 0
        totalUpload = 0
        downloadSpeed = 0
        uploadSpeed = 0
        lastRawDownload = 0
        lastRawUpload = 0
    }

    private func updateStateAndEmit(_ newState: String) {
        currentState = newState
        if Thread.isMainThread {
            emitCurrentStatus()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.emitCurrentStatus()
            }
        }
    }

    private func emitCurrentStatus() {
        guard let sink = eventSink else { return }
        let durationStr = formatDuration(since: connectedAt)
        let payload: [String] = [
            durationStr,
            String(uploadSpeed),
            String(downloadSpeed),
            String(totalUpload),
            String(totalDownload),
            currentState
        ]
        sink(payload)
    }

    private func formatDuration(since startDate: Date?) -> String {
        guard let start = startDate, currentState == "CONNECTED" else {
            return "00:00:00"
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(start)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Helpers

    private func saveSharedConfig(_ config: String) {
        guard !groupIdentifier.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            return
        }
        let fileURL = container.appendingPathComponent("xray_shared_config.json")
        try? config.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func extractLocalPort(from configJSON: String) -> Int? {
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
}
#endif
