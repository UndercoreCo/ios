import Foundation

/// Only these fixed codes and aggregate byte counters may cross extension IPC.
public enum VPNDiagnosticCode: Equatable, Sendable {
    public enum Health: String, Sendable {
        case checking, ok, dns, degraded, network_unavailable, source_unconfirmed
        case name_unavailable, egress_unconfirmed, tunnel_unreachable
    }
    public enum Probe: String, Sendable {
        case tls, fallback_tls, system_dns, fallback_name, outside_tls, outside_fallback_tls
        case handshake_fresh, rx_progress, tx_progress
    }
    public enum Outcome: String, Sendable { case ok, failed, timeout, dns_failed }
    case health(Health)
    case probe(Probe, Outcome)
    case counters(handshake: Bool, sent: UInt64, received: UInt64)

    public init?(wireValue: String) {
        guard wireValue.utf8.count <= 256 else { return nil }
        let pair = wireValue.split(separator: "=", omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let key = String(pair[0]), value = String(pair[1])
        if key == "health", let health = Health(rawValue: value) { self = .health(health); return }
        if key.hasPrefix("probe_"), let probe = Probe(rawValue: String(key.dropFirst(6))),
           let outcome = Outcome(rawValue: value) { self = .probe(probe, outcome); return }
        if key == "stats" {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                  let handshake = UInt64(parts[0]), handshake <= 1,
                  let sent = UInt64(parts[1]), let received = UInt64(parts[2]) else { return nil }
            self = .counters(handshake: handshake == 1, sent: sent, received: received); return
        }
        return nil
    }
    public var wireValue: String {
        switch self {
        case .health(let value): return "health=\(value.rawValue)"
        case .probe(let probe, let outcome): return "probe_\(probe.rawValue)=\(outcome.rawValue)"
        case .counters(let handshake, let sent, let received): return "stats=\(handshake ? 1 : 0),\(sent),\(received)"
        }
    }
}
