# Selective video optimizer — testing build

This branch builds workflow artifacts only. It is not a public package release.
The performance goal is sustained 60–70 Mbps video with ordinary client traffic
near 800 Mbps. Rates must be measured on the router and network in use.
Initial bounded client trials reached 38–42 Mbps video at approximately
95–96% CPU, against a 5.5 Mbps unmodified baseline. The requested combined
60–70 / 800 Mbps performance has not been demonstrated. Packet-only NFQUEUE
trials did not establish connections on this firmware and are not included.

Video Optimizer starts a small IPv4 DNS forwarder in front of the existing Casa
resolver. Plain LAN DNS requests use that resolver while the mode is enabled.
Public A records for configured video/CDN domains and their CNAME chain install
destination-specific TCP80/443 redirects before the DNS answer is returned.
Unselected destinations keep their normal forwarding path. Selected UDP443 is
rejected for TCP fallback; other QUIC destinations are unaffected by this mode.
Full Bypass retains its upstream all-web relay behavior.

Use Casa routed mode with IP Passthrough off, Casa DNS, and a LAN client.
Disable client Secure DNS / DNS over HTTPS / Private DNS and VPNs for testing.
Enter bare CDN domains: `googlevideo.com` for YouTube, `nflxvideo.net` for Netflix.
Subdomains match automatically. Reopen browsers/streams and clear client DNS
after enabling or changing targets so fresh DNS and connections are observed.

This prototype selects IPv4 only; IPv6 or encrypted DNS can bypass selection.
Use an IPv4 client for comparisons. Shared CDN addresses may also select
unrelated sites at those addresses. Empty/invalid lists are rejected. Selections
follow DNS TTLs (five-second minimum, one-day maximum), with 512 active addresses.
Editing the list clears learned addresses; reopen streams afterward.

Selected traffic uses a software proxy and raises CPU load; it can be limited
by CPU and temperature. Unselected traffic remains eligible for hardware
forwarding offload. No global offload setting is changed. Off removes the owned
DNS/video rules. Cached client DNS sockets may need reopening after Off.
The stored global Force TCP preference is paused in Video Optimizer mode and
resumes in other modes. The previous package remains the full-build rollback.
Choose Off and verify the service has stopped before reinstalling an older
package, so its saved configuration cannot enable the older blanket proxy.

`go test -race ./...` checks DNS identity, CNAME boundaries, domain validation,
private-address exclusions, expiry, list changes, and partial-rule rollback.
`build-video-selective-cfw3212.sh` builds a static Linux ARMv7 helper for the
converter's vendor overlay. The backend helper is root-only and is not exposed
through CGI sudoers. tpws runs as www-data to read the existing private host list.
Only aggregate selection counters are returned by the UI status endpoint.
