//! Connectivity-probe name resolution for Casa CFW-3212 (AI-64).
//!
//! Uses the system resolver (`getaddrinfo` via std). It honors every nameserver
//! in `/etc/resolv.conf` — including the carrier IPv6 nameservers that answer
//! under IP Passthrough — so the Online/Offline badge keeps upstream reachability
//! behavior and does not flip to Offline just because the IPv4 IPPT placeholder
//! `192.0.0.1` is listed.
//!
//! Earlier revisions sniffed `/etc/resolv.conf` for `192.0.0.1` and force-routed
//! the probe to bridge0 dnsmasq. On real IPPT boxes that is wrong in both
//! directions: the placeholder sometimes answers while bridge dnsmasq does not,
//! so the heuristic produced false Offline (DNS) badges while the internet
//! worked. DNS-source classification and any carrier-DNS repair now live in the
//! separate `qmanager_dns_reconcile` path, not in the connectivity probe.

use std::net::{SocketAddr, ToSocketAddrs};

use crate::probe::DownReason;

/// Resolve a `host:port` (or `[v6]:port`) string to socket addresses using the
/// system resolver. Literal IPs are parsed without a DNS lookup by std.
pub fn resolve_host_port(host_port: &str) -> Result<Vec<SocketAddr>, DownReason> {
    match host_port.to_socket_addrs() {
        Ok(addrs) => {
            let addrs: Vec<SocketAddr> = addrs.collect();
            if addrs.is_empty() {
                Err(DownReason::Dns)
            } else {
                Ok(addrs)
            }
        }
        Err(_) => Err(DownReason::Dns),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_ipv4_resolves_without_dns() {
        let addrs = resolve_host_port("127.0.0.1:80").unwrap();
        assert_eq!(addrs[0], "127.0.0.1:80".parse::<SocketAddr>().unwrap());
    }

    #[test]
    fn literal_ipv6_resolves_without_dns() {
        let addrs = resolve_host_port("[::1]:443").unwrap();
        assert_eq!(addrs[0], "[::1]:443".parse::<SocketAddr>().unwrap());
    }
}
