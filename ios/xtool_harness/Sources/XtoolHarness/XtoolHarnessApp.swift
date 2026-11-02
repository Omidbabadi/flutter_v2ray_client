import SwiftUI
import NetworkExtension
import flutter_v2ray_client

@main
struct XtoolHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            HarnessHomeView()
        }
    }
}

struct HarnessHomeView: View {
    @State private var configText: String = """
    {
      "log": { "loglevel": "warning" },
      "inbounds": [
        {
          "tag": "in_proxy",
          "port": 10808,
          "protocol": "socks",
          "listen": "127.0.0.1",
          "settings": { "auth": "noauth", "udp": true, "userLevel": 8 }
        }
      ],
      "outbounds": [
        { "tag": "proxy", "protocol": "freedom", "settings": {} },
        { "tag": "direct", "protocol": "freedom", "settings": {} },
        { "tag": "blackhole", "protocol": "blackhole", "settings": {} }
      ]
    }
    """
    @State private var statusText: String = "DISCONNECTED"
    @State private var coreVersion: String = "-"
    @State private var delayMs: String = "-"
    @State private var logs: [String] = []

    private let groupId = "group.dev.amirzr.flutterV2rayMobile"
    private let providerBundleId = "dev.amirzr.flutterV2rayMobile.XrayTunnel"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Core: \(coreVersion) | Status: \(statusText) | Delay: \(delayMs)")
                        .font(.caption)
                        .bold()

                    TextEditor(text: $configText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 180)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))

                    HStack(spacing: 8) {
                        Button("Start Proxy-Only") { startProxyOnly() }
                            .buttonStyle(.borderedProminent)
                        Button("Start VPN Tunnel") { startVPN() }
                            .buttonStyle(.bordered)
                        Button("Stop") { stopAll() }
                            .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button("Ping Delay") { measureDelay() }
                            .buttonStyle(.bordered)
                        Button("Refresh Logs") { logs = V2rayLogManager.shared.getLogs() }
                            .buttonStyle(.bordered)
                        Button("Clear Logs") {
                            _ = V2rayLogManager.shared.clearLogs()
                            logs = []
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()
                    Text("Logs (\(logs.count))").font(.headline)
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("V2Ray xtool Harness")
            .onAppear {
                V2rayLogManager.shared.configure(groupIdentifier: groupId)
                coreVersion = LibXrayBridge.shared.getCoreVersion()
                logs = V2rayLogManager.shared.getLogs()
            }
        }
    }

    private func startProxyOnly() {
        let prepared = V2rayConfigUtilities.prepareRuntimeConfig(configText, enableTrafficStats: true)
        let datDir = LibXrayBridge.shared.prepareAssetsDirectory(groupIdentifier: groupId).path
        let cfgURL = FileManager.default.temporaryDirectory.appendingPathComponent("xtool_proxy.json")
        do {
            try LibXrayBridge.shared.startXray(configJSON: prepared.config, datDir: datDir, configFileURL: cfgURL, tunFd: 0)
            statusText = "CONNECTED (Proxy)"
        } catch {
            statusText = "ERROR: \(error.localizedDescription)"
        }
        logs = V2rayLogManager.shared.getLogs()
    }

    private func startVPN() {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                statusText = "VPN Error: \(error.localizedDescription)"
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleId
            proto.serverAddress = "V2Ray xtool"
            proto.providerConfiguration = [
                "config": configText,
                "groupIdentifier": groupId
            ]
            manager.protocolConfiguration = proto
            manager.isEnabled = true
            manager.saveToPreferences { saveErr in
                if let saveErr = saveErr {
                    statusText = "Save Error: \(saveErr.localizedDescription)"
                    return
                }
                manager.loadFromPreferences { _ in
                    do {
                        try manager.connection.startVPNTunnel(options: [
                            "config": configText as NSString,
                            "groupIdentifier": groupId as NSString
                        ])
                        statusText = "CONNECTING (VPN)"
                    } catch {
                        statusText = "Start Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func stopAll() {
        LibXrayBridge.shared.stopXray()
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            managers?.forEach { $0.connection.stopVPNTunnel() }
        }
        statusText = "DISCONNECTED"
        logs = V2rayLogManager.shared.getLogs()
    }

    private func measureDelay() {
        let group = groupId
        let cfg = configText
        DispatchQueue.global(qos: .userInitiated).async {
            let datDir = LibXrayBridge.shared.prepareAssetsDirectory(groupIdentifier: group).path
            let ms = LibXrayBridge.shared.measureOutboundDelay(
                configJSON: cfg,
                url: "https://google.com/generate_204",
                datDir: datDir
            )
            DispatchQueue.main.async {
                delayMs = "\(ms)ms"
                logs = V2rayLogManager.shared.getLogs()
            }
        }
    }
}
