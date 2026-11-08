import Foundation
import Darwin

/// Sanitization, statistics injection, and TUN configuration utilities for Xray JSON on iOS.
/// Mirrors Android's `Utilities.java` so both platforms produce identical Xray behavior.
public enum V2rayConfigUtilities {
    public static let defaultApiPort: Int = 10085
    public static let defaultMtu: Int = 1500

    /// Sanitizes raw Xray JSON config:
    /// - Strips removed `allowInsecure` TLS keys recursively
    /// - Migrates freedom outbound `settings.domainStrategy` to `streamSettings.sockopt.domainStrategy`
    /// - Strips legacy gRPC `api` (`Commander`) blocks to avoid `Commander.Start`/`Close` races
    public static func sanitizeConfig(_ rawConfig: String) -> String {
        guard let data = rawConfig.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return rawConfig
        }
        root = stripAllowInsecureRecursive(root) as? [String: Any] ?? root
        migrateFreedomDomainStrategy(&root)
        stripLegacyCommanderApi(&root)
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: []),
              let outString = String(data: outData, encoding: .utf8) else {
            return rawConfig
        }
        return outString
    }

    /// Prepares an Xray configuration for execution by:
    /// 1. Sanitizing deprecated TLS/freedom fields and removing legacy `Commander` (`api`) blocks
    /// 2. Optionally injecting `stats`, `policy`, and the built-in `metrics` HTTP endpoint (`/debug/vars`)
    /// 3. Optionally injecting the built-in `tun` inbound and DNS routing rules when running in VPN mode
    public static func prepareRuntimeConfig(
        _ rawConfig: String,
        enableTrafficStats: Bool = true,
        apiPort: Int = defaultApiPort,
        injectTunInbound: Bool = false,
        tunName: String = "xray0",
        mtu: Int = defaultMtu
    ) -> (config: String, apiPort: Int, dnsServers: [String]) {
        let sanitized = sanitizeConfig(rawConfig)
        guard let data = sanitized.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (sanitized, apiPort, ["1.1.1.1", "8.8.8.8"])
        }

        let usedPorts = collectConfiguredInboundPorts(from: root)
        let resolvedApiPort = findAvailableLocalPort(preferred: apiPort, excluding: usedPorts)

        if enableTrafficStats {
            injectStatsAndMetrics(&root, apiPort: resolvedApiPort)
        }

        if injectTunInbound {
            ensureTunInbound(&root, tunName: tunName, mtu: mtu)
        } else {
            ensureLocalHttpProxyInbound(&root, excluding: usedPorts.union([resolvedApiPort]))
        }

        let dnsServers = extractPlainIpDnsServers(from: root)

        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: []),
              let outString = String(data: outData, encoding: .utf8) else {
            return (sanitized, resolvedApiPort, dnsServers)
        }
        return (outString, resolvedApiPort, dnsServers)
    }

    /// Prepares a configuration for standalone outbound delay testing (`getServerDelay`).
    /// Removes custom routing rules, inbounds, and metrics/API listeners so the probe goes directly through the primary outbound.
    public static func prepareDelayTestConfig(_ rawConfig: String) -> String {
        let sanitized = sanitizeConfig(rawConfig)
        guard let data = sanitized.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return sanitized
        }
        root.removeValue(forKey: "api")
        root.removeValue(forKey: "metrics")
        root.removeValue(forKey: "stats")
        if var routing = root["routing"] as? [String: Any] {
            routing.removeValue(forKey: "rules")
            root["routing"] = routing
        }
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: []),
              let outString = String(data: outData, encoding: .utf8) else {
            return sanitized
        }
        return outString
    }

    /// Extracts plain IPv4/IPv6 DNS server addresses from the Xray config `dns.servers` array.
    public static func extractPlainIpDnsServers(from root: [String: Any]) -> [String] {
        var result: [String] = []
        if let dns = root["dns"] as? [String: Any],
           let servers = dns["servers"] as? [Any] {
            for entry in servers {
                if let str = entry as? String, isPlainIpAddress(str) {
                    result.append(str)
                } else if let obj = entry as? [String: Any],
                          let addr = obj["address"] as? String,
                          isPlainIpAddress(addr) {
                    result.append(addr)
                }
            }
        }
        if result.isEmpty {
            return ["1.1.1.1", "8.8.8.8"]
        }
        return result
    }

    /// Checks whether a string is a plain IPv4 or IPv6 address (not `https://`, `quic://`, `localhost`, etc.).
    public static func isPlainIpAddress(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty || host.contains("/") || host.contains("://") {
            return false
        }
        var ipv4Addr = in_addr()
        if inet_pton(AF_INET, host, &ipv4Addr) == 1 {
            return true
        }
        var ipv6Addr = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6Addr) == 1 {
            return true
        }
        return false
    }

    // MARK: - Private Helpers

    private static func stripAllowInsecureRecursive(_ node: Any) -> Any {
        if var dict = node as? [String: Any] {
            dict.removeValue(forKey: "allowInsecure")
            for (k, v) in dict {
                dict[k] = stripAllowInsecureRecursive(v)
            }
            return dict
        } else if let arr = node as? [Any] {
            return arr.map { stripAllowInsecureRecursive($0) }
        }
        return node
    }

    private static func migrateFreedomDomainStrategy(_ root: inout [String: Any]) {
        guard var outbounds = root["outbounds"] as? [[String: Any]] else { return }
        for i in outbounds.indices {
            var outbound = outbounds[i]
            guard let proto = outbound["protocol"] as? String,
                  proto.lowercased() == "freedom",
                  var settings = outbound["settings"] as? [String: Any],
                  let rawStrategy = settings["domainStrategy"] as? String else {
                continue
            }
            settings.removeValue(forKey: "domainStrategy")
            outbound["settings"] = settings
            if rawStrategy.isEmpty {
                outbounds[i] = outbound
                continue
            }
            let strategy = rawStrategy.lowercased() == "useip" ? "UseIP" : rawStrategy
            var streamSettings = (outbound["streamSettings"] as? [String: Any]) ?? [:]
            var sockopt = (streamSettings["sockopt"] as? [String: Any]) ?? [:]
            if sockopt["domainStrategy"] == nil {
                sockopt["domainStrategy"] = strategy
            }
            streamSettings["sockopt"] = sockopt
            outbound["streamSettings"] = streamSettings
            outbounds[i] = outbound
        }
        root["outbounds"] = outbounds
    }

    /// Removes legacy `"api"` (`Commander`), `"api_in"` (`dokodemo-door`), and `"outboundTag": "api"` rules.
    /// Xray-core v26+ exposes traffic counters directly via `"metrics"` (`/debug/vars`), and starting `"api"`
    /// alongside `"metrics"` on the same port triggers a port conflict + nil-pointer race in `Commander.Start.func1`.
    private static func stripLegacyCommanderApi(_ root: inout [String: Any]) {
        root.removeValue(forKey: "api")

        if var inbounds = root["inbounds"] as? [[String: Any]] {
            inbounds.removeAll { inbound in
                let tag = (inbound["tag"] as? String) ?? ""
                return tag == "api_in" || tag == "api"
            }
            root["inbounds"] = inbounds
        }

        if var routing = root["routing"] as? [String: Any],
           var rules = routing["rules"] as? [[String: Any]] {
            rules.removeAll { rule in
                let outTag = (rule["outboundTag"] as? String) ?? ""
                if outTag == "api" {
                    return true
                }
                if let inTags = rule["inboundTag"] as? [String],
                   inTags.contains("api_in") || inTags.contains("api") {
                    return true
                }
                return false
            }
            routing["rules"] = rules
            root["routing"] = routing
        }
    }

    private static func injectStatsAndMetrics(_ root: inout [String: Any], apiPort: Int) {
        stripLegacyCommanderApi(&root)

        root["stats"] = [String: Any]()

        var policy = (root["policy"] as? [String: Any]) ?? [:]
        var levels = (policy["levels"] as? [String: Any]) ?? [:]
        levels["8"] = [
            "connIdle": 300,
            "downlinkOnly": 1,
            "handshake": 4,
            "uplinkOnly": 1
        ]
        policy["levels"] = levels
        policy["system"] = [
            "statsInboundUplink": true,
            "statsInboundDownlink": true,
            "statsOutboundUplink": true,
            "statsOutboundDownlink": true
        ]
        root["policy"] = policy

        // Enable built-in HTTP expvar metrics (`/debug/vars`) on 127.0.0.1:apiPort.
        // Do NOT inject `api` (Commander) or `api_in` (dokodemo-door) on `apiPort`,
        // because `metrics.listen` already binds `127.0.0.1:apiPort` directly.
        root["metrics"] = [
            "tag": "metrics_out",
            "listen": "127.0.0.1:\(apiPort)"
        ]
    }

    private static func ensureLocalHttpProxyInbound(_ root: inout [String: Any], excluding usedPorts: Set<Int>) {
        var inbounds = (root["inbounds"] as? [[String: Any]]) ?? []
        let hasHttp = inbounds.contains { ($0["protocol"] as? String)?.lowercased() == "http" }
        guard !hasHttp else { return }

        let httpPort = findAvailableLocalPort(preferred: 10809, excluding: usedPorts)
        let httpInbound: [String: Any] = [
            "tag": "in_http",
            "port": httpPort,
            "protocol": "http",
            "listen": "127.0.0.1",
            "settings": ["userLevel": 8],
            "sniffing": ["enabled": false]
        ]
        inbounds.append(httpInbound)
        root["inbounds"] = inbounds
    }

    private static func collectConfiguredInboundPorts(from root: [String: Any]) -> Set<Int> {
        var ports = Set<Int>()
        guard let inbounds = root["inbounds"] as? [[String: Any]] else { return ports }
        for inbound in inbounds {
            if let port = (inbound["port"] as? NSNumber)?.intValue, port > 0 {
                ports.insert(port)
            }
        }
        return ports
    }

    /// Finds an available TCP port on `127.0.0.1`, preferring `preferred` if it is not in `excluding` and can bind.
    public static func findAvailableLocalPort(preferred: Int, excluding: Set<Int> = []) -> Int {
        if preferred > 0 && !excluding.contains(preferred) && canBindLocalPort(UInt16(clamping: preferred)) {
            return preferred
        }
        for candidate in 10085...10150 where !excluding.contains(candidate) {
            if canBindLocalPort(UInt16(candidate)) {
                return candidate
            }
        }
        if let ephemeral = allocateEphemeralLocalPort(), !excluding.contains(ephemeral) {
            return ephemeral
        }
        return preferred
    }

    private static func canBindLocalPort(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    private static func allocateEphemeralLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var assignedAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assignedAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { return nil }
        return Int(UInt16(bigEndian: assignedAddr.sin_port))
    }

    private static func ensureTunInbound(_ root: inout [String: Any], tunName: String, mtu: Int) {
        var inbounds = (root["inbounds"] as? [[String: Any]]) ?? []
        var hasTun = false
        for i in inbounds.indices {
            if let proto = inbounds[i]["protocol"] as? String, proto.lowercased() == "tun" {
                hasTun = true
                var settings = (inbounds[i]["settings"] as? [String: Any]) ?? [:]
                settings["MTU"] = mtu
                if settings["name"] == nil {
                    settings["name"] = tunName
                }
                inbounds[i]["settings"] = settings

                var sniffing = (inbounds[i]["sniffing"] as? [String: Any]) ?? [:]
                sniffing["enabled"] = true
                if sniffing["destOverride"] == nil {
                    sniffing["destOverride"] = ["http", "tls", "quic"]
                }
                inbounds[i]["sniffing"] = sniffing
                break
            }
        }

        if !hasTun {
            let tunInbound: [String: Any] = [
                "tag": "tun",
                "protocol": "tun",
                "settings": [
                    "name": tunName,
                    "MTU": mtu,
                    "userLevel": 8
                ],
                "sniffing": [
                    "enabled": true,
                    "destOverride": ["http", "tls", "quic"]
                ]
            ]
            inbounds.append(tunInbound)
        }
        root["inbounds"] = inbounds

        // Prefer IPv4 and ensure DNS servers exist
        var dns = (root["dns"] as? [String: Any]) ?? [:]
        if dns["queryStrategy"] == nil {
            dns["queryStrategy"] = "UseIPv4"
        }
        if dns["servers"] == nil {
            dns["servers"] = ["1.1.1.1", "8.8.8.8"]
        }
        root["dns"] = dns

        var routing = (root["routing"] as? [String: Any]) ?? [:]
        if routing["domainStrategy"] == nil {
            routing["domainStrategy"] = "AsIs"
        }
        var rules = (routing["rules"] as? [[String: Any]]) ?? []
        let hasDnsRule = rules.contains { rule in
            let outbound = rule["outboundTag"] as? String
            let port = String(describing: rule["port"] ?? "")
            return outbound == "direct" && port.contains("853")
        }
        if !hasDnsRule {
            let dnsPortRule: [String: Any] = [
                "type": "field",
                "port": "53,853",
                "outboundTag": "direct"
            ]
            let dnsIpRule: [String: Any] = [
                "type": "field",
                "ip": ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"],
                "outboundTag": "direct"
            ]
            rules.insert(contentsOf: [dnsPortRule, dnsIpRule], at: 0)
            routing["rules"] = rules
        }
        root["routing"] = routing
    }
}
