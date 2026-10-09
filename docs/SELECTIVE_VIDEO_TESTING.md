# Selective Video Optimizer on Casa

This feature is experimental on `test/AI-72-selective-video`. The current
testing build is `v0.1.16-cfw3212.1.40.dev`; it is a workflow artifact, not a
public package release. Full installed-package validation is in progress.

The goal is sustained 60–70 Mbps video while ordinary LAN traffic stays near
800 Mbps. Those combined rates have **not been demonstrated**. Earlier bounded
`.1.39.dev` helper trials reached 38–39 Mbps video at approximately 95–96% CPU,
against a 5.5 Mbps unmodified comparison. Treat these as measurements under one
set of conditions, not promised speeds.

## Set it up in the UI

1. Use Casa in routed mode with **IP Passthrough off**, and connect a LAN client.
2. Use Casa for DNS. For the comparison, disable client VPNs, browser Secure DNS,
   DNS over HTTPS and Private DNS. This version selects IPv4 traffic.
3. Open **Local Network → Traffic Engine**. Install optimizer tools if prompted.
4. Under **Optimizer targets**, use bare media domains such as
   `googlevideo.com` for YouTube and `nflxvideo.net` for Netflix. Subdomains match
   automatically. A homepage domain alone may not cover the video servers.
5. Review inherited targets. Older lists include `speedtest.net`, `ookla.com`,
   `cloudfront.net` and `akamaized.net`. Those can select ordinary traffic too.
   Remove entries you do not want processed, or use **Reset targets** for Casa's
   focused YouTube/Netflix media defaults.
6. Select **Video Optimizer**, then reopen the browser or video and refresh
   client DNS if needed. Repeat after target edits. Check that learned-address
   and video-DNS counters increase before judging the result.

Updates preserve the live target list. The factory reset list is refreshed
separately and is never copied from a custom live list. Add other services'
actual media domains when you have identified them.

## CPU, offloading and selection limits

Video Optimizer learns public video destinations from plain IPv4 DNS and sends
their TCP 80/443 connections through the software proxy. Other destinations
retain their normal forwarding path. This differs from upstream's blanket web
relay, where the host list selects handshake changes inside the proxy.

**Selected video is not hardware offloaded. CPU use and temperature rise, and
video speed can hit a CPU limit.** Unselected traffic remains eligible for
hardware forwarding; signal, congestion and simultaneous streams still affect
its speed. Full Bypass retains the upstream all-web relay and its larger CPU
cost. No global hardware-offload setting is disabled by Video Optimizer.

Only learned video addresses receive UDP 443 rejection for TCP fallback. The
saved global Force TCP preference is paused during Video Optimizer and resumes
in other modes. Shared CDN addresses can cause other sites at those addresses
to enter the proxy. IPv6, encrypted DNS and cached connections can bypass
selection. Learned addresses expire with DNS, with a five-second grace minimum,
one-day maximum and 512-address limit. Target edits clear learned selections.

## Compare and stop

Run tests from the LAN client, using the same server and similar conditions:

- Record ordinary Speedtest and Fast.com results with the optimizer Off.
- Enable video optimization, refresh DNS/connections, verify selection counters,
  then repeat both tests. Distinguish TCP 8080 speed tests from HTTPS traffic.
- Compare actual video playback, router CPU, temperature and other traffic.
  Short CLI transfers do not establish sustained playback or combined rates.
- Choose **Off** afterward and reopen affected streams. Verify service stop,
  DNS availability and cleanup before declaring the comparison complete.

Before reinstalling an older package, choose Off and confirm the optimizer has
stopped. Otherwise its saved enabled setting could activate the older blanket
proxy after a downgrade. Keep the exact prior package and checksum for rollback.
A cleanup-error message requires reviewing the router log before downgrading.

## Validation record

| Build / check | Result |
| --- | --- |
| `.1.39.dev` CI | Race tests, frontend build and package checks passed |
| Earlier scoped default-proxy trials | 38–39 Mbps video, about 95–96% CPU |
| Earlier unmodified video comparison | 5.5 Mbps |
| `.1.40.dev` target defaults | Fresh seed, legacy factory refresh and custom live-list preservation fixtures passed |
| Full package / authenticated controls / cleanup / client tests | In progress; results will be recorded here |
| Sustained 60–70 Mbps video with ~800 Mbps ordinary traffic | Unverified |

Packet-only NFQUEUE experiments did not establish test connections on this
firmware and are excluded from the build. Their offload compatibility remains
unproven. Raw captures, signed test URLs and device identifiers stay private.

See the [implementation notes](../qmanager/casa_conversion/video-selective/README.md)
and [artifact installation workflow](../scripts/README.md).
