//
//  SubscriptionMergeTests.swift
//  Turn
//

import Testing
import Foundation
@testable import Turn

/// The panel answers this app with sing-box, which has no XHTTP transport, so
/// XHTTP hosts come only from a second, share-link answer.
@Suite
struct SubscriptionMergeTests {

    /// A CDN host as the XHTTP guide sets it up: GET uplink (the CDN drops POST),
    /// session id in a header, sequence in the query, tokenish padding.
    private static let cdnLink: String = {
        let extra = """
        {"path":"/pizza","uplinkHTTPMethod":"GET","sessionKey":"X-Upload-Token","sessionPlacement":"header",\
        "seqKey":"chunk_id","seqPlacement":"query","xPaddingHeader":"X-Client-Version","xPaddingMethod":"tokenish",\
        "xPaddingKey":"hash","xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader",\
        "xmux":{"maxConcurrency":"16-32","hKeepAlivePeriod":20000}}
        """
        let encoded = extra.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "vless://11111111-2222-3333-4444-555555555555@cdn.example.ru:443"
            + "?type=xhttp&security=tls&sni=cdn.example.ru&host=cdn.example.ru&path=%2Fpizza"
            + "&mode=packet-up&fp=chrome&alpn=h2%2Chttp%2F1.1&extra=\(encoded)#CDN"
    }()

    private static func xhttp(_ config: ProxyConfiguration) -> XHTTPConfiguration? {
        guard case .vless(_, _, _, let transport, _) = config.outbound,
              case .xhttp(let xhttp) = transport else { return nil }
        return xhttp
    }

    @Test("A CDN XHTTP link keeps every setting the server insists on")
    func cdnLinkParses() throws {
        let config = try ProxyConfiguration.parse(url: Self.cdnLink)
        let xhttp = try #require(Self.xhttp(config), "parsed as \(config.outbound), not XHTTP")

        #expect(xhttp.mode == .packetUp)
        #expect(xhttp.path == "/pizza")
        #expect(xhttp.uplinkHTTPMethod == "GET")
        #expect(xhttp.sessionIDPlacement == .header)
        #expect(xhttp.sessionIDKey == "X-Upload-Token")
        #expect(xhttp.seqPlacement == .query)
        #expect(xhttp.seqKey == "chunk_id")
        #expect(xhttp.xPaddingObfsMode)
        #expect(xhttp.xPaddingMethod == .tokenish)
        #expect(xhttp.xPaddingHeader == "X-Client-Version")
        #expect(xhttp.xPaddingKey == "hash")
        #expect(xhttp.xPaddingPlacement == .queryInHeader)
    }

    private static func server(_ name: String, _ address: String, _ port: UInt16) -> ProxyConfiguration {
        ProxyConfiguration(
            name: name, serverAddress: address, serverPort: port,
            outbound: .vless(uuid: UUID(), encryption: "none", flow: nil, transport: .raw, security: .none)
        )
    }

    @Test("Only servers the sing-box answer lacks are added, each once")
    func mergeAddsOnlyMissing() {
        let primary = [Self.server("RU", "ru.example.net", 443), Self.server("DE", "de.example.net", 8443)]
        let links = [
            Self.server("RU link", "RU.example.net", 443),     // same server, other case
            Self.server("DE other port", "de.example.net", 443),
            Self.server("CDN", "cdn.example.ru", 443),
            Self.server("CDN twice", "cdn.example.ru", 443),
        ]
        let extras = SubscriptionFetcher.mergingLinkOnly(primary, links)
        #expect(extras.map(\.name) == ["DE other port", "CDN"])
    }

    @Test("Nothing new in the share links means nothing added")
    func mergeWithNothingNew() {
        let primary = [Self.server("RU", "ru.example.net", 443)]
        #expect(SubscriptionFetcher.mergingLinkOnly(primary, primary).isEmpty)
    }
}
