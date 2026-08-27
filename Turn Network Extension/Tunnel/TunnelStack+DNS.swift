//
//  TunnelStack+DNS.swift
//  Turn
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation

extension TunnelStack {

    // MARK: - DNS Interception (Fake-IP)

    enum DNSDestination {
        case turnResolver
        case publicResolver
    }
    
    static let interceptedDNSServers: [String: DNSDestination] = [
        TunnelConstants.tunnelAddressIPv4: .turnResolver,
        TunnelConstants.tunnelAddressIPv6: .turnResolver,
        "8.8.8.8": .publicResolver,
        "8.8.4.4": .publicResolver,
        "2001:4860:4860::8888": .publicResolver,
        "2001:4860:4860::8844": .publicResolver,
    ]
    
    static func interceptExemptDNSServers() -> Set<String> {
        let upstreams = [
            AWCore.getSubscriptionDNSUpstream(),
            AWCore.getIPRuleDNSUpstream(),
            AWCore.getProxyDNSUpstream(),
            AWCore.getECHDNSUpstream(),
            AWCore.getFallbackDNSUpstream()
        ]
        var addresses: Set<String> = []
        for case .plain(let host, _) in upstreams
        where interceptedDNSServers[host] == .publicResolver {
            addresses.insert(host)
        }
        return addresses
    }
    
    static func dnsDestination(for dstIP: String, exempting exempt: Set<String>) -> DNSDestination? {
        switch interceptedDNSServers[dstIP] {
        case .turnResolver:
            return .turnResolver
        case .publicResolver:
            return exempt.contains(dstIP) ? nil : .publicResolver
        case nil:
            return nil
        }
    }
}
