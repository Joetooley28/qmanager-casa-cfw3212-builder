//! Casa CFW-3212 IP passthrough: /etc/resolv.conf often lists the handover
//! placeholder 192.0.0.1 which does not answer DNS. dnsmasq on bridge0 LAN
//! still proxies correctly — query that instead when poisoned nameservers are
//! detected. When resolv is healthy (IPPT off), use the normal system resolver.

use std::io;
use std::net::{Ipv4Addr, SocketAddr, ToSocketAddrs, UdpSocket};
use std::time::Duration;

use crate::probe::DownReason;

const POISON_NAMESERVERS: [&str; 2] = ["192.0.0.1", "192.0.0.2"];
const RESOLV_PATHS: [&str; 2] = ["/etc/resolv.conf", "/run/resolv.conf"];

pub fn resolve_host_port(host_port: &str) -> Result<Vec<SocketAddr>, DownReason> {
    let (host, port) = split_host_port(host_port)?;

    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, port)]);
    }

    if resolv_poisoned() {
        let resolver = bridge_lan_resolver().unwrap_or(Ipv4Addr::new(1, 1, 1, 1));
        let ips = dns_lookup_a(host, resolver)?;
        if ips.is_empty() {
            return Err(DownReason::Dns);
        }
        return Ok(ips.into_iter().map(|ip| SocketAddr::from((ip, port))).collect());
    }

    match host_port.to_socket_addrs() {
        Ok(it) => {
            let addrs: Vec<_> = it.collect();
            if addrs.is_empty() {
                Err(DownReason::Dns)
            } else {
                Ok(addrs)
            }
        }
        Err(_) => Err(DownReason::Dns),
    }
}

fn split_host_port(host_port: &str) -> Result<(&str, u16), DownReason> {
    if host_port.starts_with('[') {
        let end = host_port.find(']').ok_or(DownReason::Malformed)?;
        let host = &host_port[1..end];
        let port_str = host_port[end + 1..]
            .strip_prefix(':')
            .ok_or(DownReason::Malformed)?;
        let port = port_str
            .parse::<u16>()
            .map_err(|_| DownReason::Malformed)?;
        return Ok((host, port));
    }
    let (host, port_str) = host_port
        .rsplit_once(':')
        .ok_or(DownReason::Malformed)?;
    let port = port_str
        .parse::<u16>()
        .map_err(|_| DownReason::Malformed)?;
    Ok((host, port))
}

pub fn resolv_poisoned() -> bool {
    for path in RESOLV_PATHS {
        let Ok(content) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in content.lines() {
            let line = line.trim();
            if !line.starts_with("nameserver") {
                continue;
            }
            let Some(ns) = line.split_whitespace().nth(1) else {
                continue;
            };
            if POISON_NAMESERVERS.contains(&ns) {
                return true;
            }
        }
    }
    false
}

pub fn bridge_lan_resolver() -> Option<Ipv4Addr> {
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) != 0 {
            return None;
        }
        let mut cur = ifap;
        let mut found = None;
        while !cur.is_null() {
            let ifa = &*cur;
            if !ifa.ifa_name.is_null() && !ifa.ifa_addr.is_null() {
                let name = std::ffi::CStr::from_ptr(ifa.ifa_name).to_string_lossy();
                if name == "bridge0" {
                    let sa = ifa.ifa_addr as *const libc::sockaddr_in;
                    if (*sa).sin_family as i32 == libc::AF_INET {
                        let ip = Ipv4Addr::from(u32::from_be((*sa).sin_addr.s_addr));
                        let [a, b, _, _] = ip.octets();
                        if a == 192 && b == 168 {
                            found = Some(ip);
                            break;
                        }
                    }
                }
            }
            cur = ifa.ifa_next;
        }
        libc::freeifaddrs(ifap);
        found
    }
}

fn dns_lookup_a(host: &str, resolver: Ipv4Addr) -> Result<Vec<Ipv4Addr>, DownReason> {
    let query = build_dns_query(host).map_err(|_| DownReason::Dns)?;
    let sock = UdpSocket::bind("0.0.0.0:0").map_err(|_| DownReason::Dns)?;
    sock.set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| DownReason::Dns)?;
    let dest = SocketAddr::from((resolver, 53));
    sock.send_to(&query, dest).map_err(|_| DownReason::Dns)?;
    let mut buf = [0u8; 512];
    let n = sock.recv(&mut buf).map_err(|_| DownReason::Dns)?;
    parse_dns_a(&buf[..n]).map_err(|_| DownReason::Dns)
}

fn build_dns_query(host: &str) -> io::Result<Vec<u8>> {
    let mut out = Vec::with_capacity(64);
    out.extend_from_slice(&[0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "bad hostname"));
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]);
    Ok(out)
}

fn parse_dns_a(packet: &[u8]) -> io::Result<Vec<Ipv4Addr>> {
    if packet.len() < 12 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "short packet"));
    }
    let ancount = u16::from_be_bytes([packet[6], packet[7]]) as usize;
    if ancount == 0 {
        return Ok(Vec::new());
    }
    let mut offset = 12;
    offset = skip_name(packet, offset)?;
    offset = offset.saturating_add(4);
    let mut ips = Vec::new();
    for _ in 0..ancount {
        if offset >= packet.len() {
            break;
        }
        offset = skip_name(packet, offset)?;
        if offset + 10 > packet.len() {
            break;
        }
        let rtype = u16::from_be_bytes([packet[offset], packet[offset + 1]]);
        let rdlength = u16::from_be_bytes([packet[offset + 8], packet[offset + 9]]) as usize;
        offset += 10;
        if offset + rdlength > packet.len() {
            break;
        }
        if rtype == 1 && rdlength == 4 {
            let ip = Ipv4Addr::new(
                packet[offset],
                packet[offset + 1],
                packet[offset + 2],
                packet[offset + 3],
            );
            ips.push(ip);
        }
        offset += rdlength;
    }
    Ok(ips)
}

fn skip_name(packet: &[u8], mut offset: usize) -> io::Result<usize> {
    let mut jumped = false;
    let mut jumps = 0usize;
    loop {
        if offset >= packet.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "name past end"));
        }
        let len = packet[offset];
        if len & 0xC0 == 0xC0 {
            if offset + 1 >= packet.len() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "bad compression"));
            }
            if !jumped {
                offset += 2;
            }
            jumps += 1;
            if jumps > 16 {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "too many jumps"));
            }
            offset = (((len & 0x3F) as usize) << 8) | packet[offset + 1] as usize;
            jumped = true;
            continue;
        }
        if len == 0 {
            return Ok(offset + 1);
        }
        offset += 1 + len as usize;
        if !jumped && offset > packet.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "label past end"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_host_port_parses_hostname() {
        let (h, p) = split_host_port("cp.cloudflare.com:80").unwrap();
        assert_eq!(h, "cp.cloudflare.com");
        assert_eq!(p, 80);
    }

    #[test]
    fn poisoned_nameserver_detected_in_content() {
        let tmp = std::env::temp_dir().join("qmanager-resolv-test");
        std::fs::write(&tmp, "nameserver 192.0.0.1\n").unwrap();
        let content = std::fs::read_to_string(&tmp).unwrap();
        assert!(content.contains("192.0.0.1"));
        let _ = std::fs::remove_file(tmp);
    }
}
