import Foundation

/// Sanitization, statistics injection, and TUN configuration utilities for Xray JSON on iOS.
/// Mirrors Android's `Utilities.java` so both platforms produce identical Xray behavior.
public enum V2rayConfigUtilities {
    public static let defaultApiPort: Int = 10808
    public static let defaultMtu: Int = 1500

    /// Sanitizes raw Xray JSON config:
    /// - Strips removed `allowInsecure` TLS keys recursively
    /// - Migrates freedom outbound `settings.domainStrategy` to `streamSettings.sockopt.domainStrategy`
    public static func sanitizeConfig(_ rawConfig: String) -> String {
        guard let data = rawConfig.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return rawConfig
        }
        root = stripAllowInsecureRecursive(root) as? [String: Any] ?? root
        migrateFreedomDomainStrategy(&root)
        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: []),
              let outString = String(data: outData, encoding: .utf8) else {
            return rawConfig
        }
        return outString
    }

    /// Prepares an Xray configuration for execution by:
    /// 1. Sanitizing deprecated TLS/freedom fields
    /// 2. Optionally injecting `stats`, `policy`, and the local Dokodemo-door API inbound for `LibXrayQueryStats`
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

        if enableTrafficStats {
            injectStatsAndMetrics(&root, apiPort: apiPort)
        }

        if injectTunInbound {
            ensureTunInbound(&root, tunName: tunName, mtu: mtu)
        }

        let dnsServers = extractPlainIpDnsServers(from: root)

        guard let outData = try? JSONSerialization.data(withJSONObject: root, options: []),
              let outString = String(data: outData, encoding: .utf8) else {
            return (sanitized, apiPort, dnsServers)
        }
        return (outString, apiPort, dnsServers)
    }

    /// Prepares a configuration for standalone outbound delay testing (`getServerDelay`).
    /// Removes custom routing rules so the probe goes directly through the primary outbound.
    public static func prepareDelayTestConfig(_ rawConfig: String) -> String {
        let sanitized = sanitizeConfig(rawConfig)
        guard let data = sanitized.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return sanitized
        }
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

    private static func injectStatsAndMetrics(_ root: inout [String: Any], apiPort: Int) {
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

        // Enable built-in HTTP expvar metrics (`/debug/vars`) on 127.0.0.1:apiPort
        if root["metrics"] == nil {
            root["metrics"] = [
                "tag": "metrics_out",
                "listen": "127.0.0.1:\(apiPort)"
            ]
        }

        // Also enable built-in StatsService API for compatibility
        if root["api"] == nil {
            root["api"] = [
                "tag": "api",
                "services": ["StatsService"]
            ]
        }

        var inbounds = (root["inbounds"] as? [[String: Any]]) ?? []
        let hasApiInbound = inbounds.contains { ($0["tag"] as? String) == "api_in" }
        if !hasApiInbound {
            let apiInbound: [String: Any] = [
                "tag": "api_in",
                "listen": "127.0.0.1",
                "port": apiPort,
                "protocol": "dokodemo-door",
                "settings": [
                    "address": "127.0.0.1"
                ]
            ]
            inbounds.append(apiInbound)
            root["inbounds"] = inbounds
        }

        var routing = (root["routing"] as? [String: Any]) ?? [:]
        var rules = (routing["rules"] as? [[String: Any]]) ?? []
        let hasApiRule = rules.contains {
            guard let tags = $0["inboundTag"] as? [String] else { return false }
            return tags.contains("api_in")
        }
        if !hasApiRule {
            let apiRule: [String: Any] = [
                "type": "field",
                "inboundTag": ["api_in"],
                "outboundTag": "api"
            ]
            rules.insert(apiRule, at: 0)
            routing["rules"] = rules
            root["routing"] = routing
        }
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
