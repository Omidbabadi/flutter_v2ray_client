import Foundation
import NetworkExtension
import Darwin

/// Reusable base `NEPacketTunnelProvider` implementation for `flutter_v2ray_client` on iOS.
///
/// Host applications can subclass `V2rayPacketTunnelProvider` in their NetworkExtension target:
/// ```swift
/// import flutter_v2ray_client
///
/// class PacketTunnelProvider: V2rayPacketTunnelProvider {}
/// ```
open class V2rayPacketTunnelProvider: NEPacketTunnelProvider {
    private let defaultMtu: Int = 1500
    private let defaultApiPort: Int = 10085
    private var activeApiPort: Int = 10085
    private var groupIdentifier: String = ""

    open override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let protoConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]

        let groupId = (options?["groupIdentifier"] as? String)
            ?? (protoConfig["groupIdentifier"] as? String)
            ?? ""
        self.groupIdentifier = groupId
        V2rayLogManager.shared.configure(groupIdentifier: groupId)

        let rawConfig = (options?["config"] as? String)
            ?? (protoConfig["config"] as? String)
            ?? readSharedConfig(groupIdentifier: groupId)
            ?? ""

        guard !rawConfig.isEmpty else {
            let err = NSError(
                domain: "V2rayPacketTunnelProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Xray JSON configuration in providerConfiguration or options."]
            )
            V2rayLogManager.shared.log("startTunnel failed: \(err.localizedDescription)", level: "E", tag: "V2rayPacketTunnelProvider")
            completionHandler(err)
            return
        }

        let bypassSubnets = (options?["bypassSubnets"] as? [String])
            ?? (protoConfig["bypassSubnets"] as? [String])
            ?? []

        let prepared = V2rayConfigUtilities.prepareRuntimeConfig(
            rawConfig,
            enableTrafficStats: true,
            apiPort: defaultApiPort,
            injectTunInbound: true,
            tunName: "xray0",
            mtu: defaultMtu
        )
        self.activeApiPort = prepared.apiPort

        let networkSettings = buildTunnelNetworkSettings(
            dnsServers: prepared.dnsServers,
            bypassSubnets: bypassSubnets,
            mtu: defaultMtu
        )

        V2rayLogManager.shared.log("Applying tunnel network settings (MTU=\(defaultMtu), DNS=\(prepared.dnsServers.joined(separator: ",")))", level: "I", tag: "V2rayPacketTunnelProvider")

        setTunnelNetworkSettings(networkSettings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                V2rayLogManager.shared.log("setTunnelNetworkSettings failed: \(error.localizedDescription)", level: "E", tag: "V2rayPacketTunnelProvider")
                completionHandler(error)
                return
            }

            do {
                let tunFd = self.resolveTunnelFileDescriptor() ?? 0
                let datDir = LibXrayBridge.shared.prepareAssetsDirectory(groupIdentifier: self.groupIdentifier).path
                let configFileURL = self.resolveRuntimeConfigFileURL(groupIdentifier: self.groupIdentifier)

                try LibXrayBridge.shared.startXray(
                    configJSON: prepared.config,
                    datDir: datDir,
                    configFileURL: configFileURL,
                    tunFd: tunFd
                )
                V2rayLogManager.shared.log("Tunnel started successfully (tunFd=\(tunFd))", level: "I", tag: "V2rayPacketTunnelProvider")
                completionHandler(nil)
            } catch {
                V2rayLogManager.shared.log("Failed to start Xray core inside tunnel: \(error.localizedDescription)", level: "E", tag: "V2rayPacketTunnelProvider")
                completionHandler(error)
            }
        }
    }

    open override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        V2rayLogManager.shared.log("Stopping tunnel (reason=\(reason.rawValue))", level: "I", tag: "V2rayPacketTunnelProvider")
        LibXrayBridge.shared.stopXray()
        completionHandler()
    }

    open override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let command = message["command"] as? String else {
            completionHandler?(nil)
            return
        }

        switch command {
        case "queryStats":
            let stats = LibXrayBridge.shared.queryOutboundTraffic(apiPort: activeApiPort) ?? (0, 0)
            let response: [String: Any] = [
                "download": stats.download,
                "upload": stats.upload
            ]
            let data = try? JSONSerialization.data(withJSONObject: response)
            completionHandler?(data)

        case "measureDelay":
            let url = (message["url"] as? String) ?? "https://google.com/generate_204"
            DispatchQueue.global(qos: .userInitiated).async {
                let delay = LibXrayBridge.shared.measureConnectedDelay(url: url)
                let response: [String: Any] = ["delay": delay]
                let data = try? JSONSerialization.data(withJSONObject: response)
                completionHandler?(data)
            }

        case "getCoreVersion":
            let response: [String: Any] = ["version": LibXrayBridge.shared.getCoreVersion()]
            let data = try? JSONSerialization.data(withJSONObject: response)
            completionHandler?(data)

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Network Settings Construction

    private func buildTunnelNetworkSettings(
        dnsServers: [String],
        bypassSubnets: [String],
        mtu: Int
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "26.26.26.2")
        settings.mtu = NSNumber(value: mtu)

        // IPv4 configuration (matches Android V2rayVPNService 26.26.26.1/30)
        let ipv4Settings = NEIPv4Settings(addresses: ["26.26.26.1"], subnetMasks: ["255.255.255.252"])
        if bypassSubnets.isEmpty {
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        } else {
            var includedRoutes: [NEIPv4Route] = []
            for cidr in bypassSubnets {
                if let route = parseIPv4CIDR(cidr) {
                    includedRoutes.append(route)
                }
            }
            ipv4Settings.includedRoutes = includedRoutes.isEmpty ? [NEIPv4Route.default()] : includedRoutes
        }
        settings.ipv4Settings = ipv4Settings

        // IPv6 sinkhole configuration (matches Android fd00:1:fd00:1:fd00:1:fd00:1/126)
        let ipv6Settings = NEIPv6Settings(
            addresses: ["fd00:1:fd00:1:fd00:1:fd00:1"],
            networkPrefixLengths: [126]
        )
        ipv6Settings.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6Settings

        // DNS Settings
        let dnsSettings = NEDNSSettings(servers: dnsServers.isEmpty ? ["1.1.1.1", "8.8.8.8"] : dnsServers)
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        return settings
    }

    private func parseIPv4CIDR(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 2,
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength) else {
            return nil
        }
        let ip = String(parts[0])
        let maskInt: UInt32 = prefixLength == 0 ? 0 : (~UInt32(0) << (32 - prefixLength))
        let mask = String(
            format: "%d.%d.%d.%d",
            (maskInt >> 24) & 0xFF,
            (maskInt >> 16) & 0xFF,
            (maskInt >> 8) & 0xFF,
            maskInt & 0xFF
        )
        return NEIPv4Route(destinationAddress: ip, subnetMask: mask)
    }

    // MARK: - TUN File Descriptor Discovery

    /// Locates the underlying `utun` file descriptor created by `NEPacketTunnelProvider`.
    private func resolveTunnelFileDescriptor() -> Int32? {
        // 1. Try KVC on packetFlow (`socket.fileDescriptor`)
        if let fd = (packetFlow.value(forKeyPath: "socket.fileDescriptor") as? NSNumber)?.int32Value, fd > 0 {
            return fd
        }

        // 2. Scan open file descriptors for `utun` ctl_info / getsockopt
        let CTLIOCGINFO: UInt = 0xC0644E03
        struct ctl_info {
            var ctl_id: UInt32 = 0
            var ctl_name: (
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar
            ) = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            )
        }

        let controlName = "com.apple.net.utun_control"
        for fd: Int32 in 0...1024 {
            var info = ctl_info()
            withUnsafeMutablePointer(to: &info.ctl_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 96) { charPtr in
                    _ = strncpy(charPtr, controlName, 95)
                }
            }
            if ioctl(fd, CTLIOCGINFO, &info) == 0 {
                return fd
            }
        }

        // 3. Fallback: check `ifname` via `getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ...)`
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2, 2, &buf, &len) == 0 {
                let name = String(cString: buf)
                if name.hasPrefix("utun") {
                    return fd
                }
            }
        }

        return nil
    }

    // MARK: - Shared Container Helpers

    private func resolveRuntimeConfigFileURL(groupIdentifier: String) -> URL {
        if !groupIdentifier.isEmpty,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return container.appendingPathComponent("xray_runtime_config.json")
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("xray_runtime_config.json")
    }

    private func readSharedConfig(groupIdentifier: String) -> String? {
        guard !groupIdentifier.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            return nil
        }
        let url = container.appendingPathComponent("xray_shared_config.json")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
