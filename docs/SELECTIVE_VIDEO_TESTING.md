# Selective Video Optimizer on Casa

This feature is experimental on `test/AI-72-selective-video`. The current
testing build is `v0.1.16-cfw3212.1.41.dev`; it is a workflow artifact, not a
public package release. Installed-package controls, client comparisons and a bounded 15-minute
soak have passed. The throughput goal remains unmet.

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
| `.1.41.dev` CI | Race tests, frontend build and package checks passed; artifact only |
| Full package / settings preservation | Installed; original configuration and live targets preserved |
| Authenticated installed controls | Tool installation, invalid-URL rejection, target edit/reset and On/Off passed |
| Cleanup / recovery | Owned rules removed, DNS available; controlled proxy exit cleaned up and service restarted |
| `.1.41.dev` Off | Fast.com 6.2 Mbps; Ookla 144 Mbps |
| `.1.41.dev` On, separate tests | Fast.com 37.3 Mbps; Ookla 155 Mbps |
| Video CPU / temperature | About 92% average CPU, 100% five-second peak; 57.5°C CPU sensor peak |
| Overlapping video / ordinary tests | Fast.com 39.7 Mbps; Ookla 111 Mbps; complete-test averages with overlapping intervals |
| Unlisted HTTPS check | HTTP 200, 10 MiB transferred, no increase in video redirect counters |
| 15-minute bounded soak | Passed with four short video bursts: 33.3–42.5 Mbps; no selection errors or unexpected helper restart |
| Soak video CPU / temperature | About 93–97% CPU during later video bursts; soak CPU sensor peak 55.8°C |
| Final state | Optimizer Off; original configuration and live targets restored exactly; DNS and core services healthy |
| Browser UI acceptance | Frontend build passed; headless runner stalled before rendering, so browser clicks remain unverified |
| Overnight read-only logging | Finished at 07:00:15–07:00:20 EDT on 2026-10-09; final logs harvested and checksums verified |
| Overnight optimizer-Off CPU / temperature | 43.3% average CPU, 49.2% highest sample interval; CPU sensor 51.0–53.8°C |
| Overnight service / Ethernet health | 535 samples; no observed reboot, non-active core service, or carrier-down sample |
| Sustained 60–70 Mbps video with ~800 Mbps ordinary traffic | Unverified |

Packet-only NFQUEUE experiments did not establish test connections on this
firmware and are excluded from the build. Their offload compatibility remains
unproven. Raw captures, signed test URLs and device identifiers stay private.

The wired comparison uses three Fast.com streams with a shared 20-second
deadline, a fixed Ookla server, IPv4 source binding and fresh Casa DNS. Partial
HTTP 200 transfers before the deadline count; zero-byte deadline attempts do
not. CPU comes from five-second router samples. Ordinary Ookla traffic stayed
outside the selected video path, but these tests do not establish hardware
offload operation at 800 Mbps. The optimizer-Off connection was only about
134–144 Mbps that night. The 15-minute soak used intermittent 20-second bursts, rather than a
continuous 15-minute video transfer. No sustained browser playback claim is
made. The exact prior `v0.1.16-cfw3212.1.35.dev` package was retained for
rollback. Read-only CPU, temperature and service/carrier logging stopped just
after 07:00 EDT / 11:00 UTC on 2026-10-09. Post-test optimizer-Off telemetry
covers 02:32:55–06:59:49 EDT (534 samples, about 4 hours 27 minutes).
Core services stayed active and Ethernet carriers stayed up in all 535 health
samples; uptime showed no reboot. Approximately 30-second polling can miss
brief outages or restarts between samples. Overnight monitoring generated no
video or speed-test traffic, so it does not extend the earlier load-test result.
The morning read-only check confirmed both loggers had stopped, the installed
version remained `.1.41.dev`, and original configuration/live target hashes
still matched.

The original live target list was restored after testing. Before testing again,
review legacy entries or use **Reset targets**, then enable Video Optimizer.

Build source: [testing branch commit](https://github.com/Joetooley28/qmanager-casa-cfw3212-builder/commit/0295981b52315d94ada39960e8a136880108450c).
[Artifact-only CI run](https://github.com/Joetooley28/qmanager-casa-cfw3212-builder/actions/runs/37891088605).

### Packet-level offload investigation — 2026-10-09

A follow-up test isolated NFQUEUE delivery before attempting video manipulation.
A direct wired-client video HEAD request succeeded with HTTP 200. Routing only
that client's SYN packets to one exact video destination through an unchanged
queue caused connection timeouts. Rule counters advanced, but the queue's
packet sequence remained zero and its reader logged no packets.

Local loopback ping worked without interception, but also failed through the
unchanged queue under explicit UID 0. Queue numbers 206 and 0, with and without
the bypass flag, did not establish delivery. This does not identify the exact
kernel/reader cause, but shows the tested failure occurs before the proposed
TLS manipulation and also occurs outside LAN/WAN acceleration. It is not a
valid speed measurement or proof that every packet-level design is impossible.

No packet-level optimizer was added to the package. The installed `.1.41.dev`
build, original settings and target list were preserved; optimizer remains Off.
The exact current package and settings backup are retained for recovery, in
addition to the earlier `.1.35.dev` rollback. The next investigation is queue
delivery/compatibility; admission of an optimized flow to Casa's proprietary
hardware offload remains unproven.

The independent 60-second rollback timer was tested without manual cleanup:
the owned queue/rules were gone after 61 seconds. Original settings hashes and
permissions matched, core services stayed active, the normalized full rule
set matched the baseline, and the direct video HEAD request returned HTTP 200
again. This kernel lacks the kprobe interface needed to observe the queue's
return code with that tracing method; no kernel, module or offload settings
were changed to work around it.

### Independent queue compatibility check — 2026-10-09

A separate raw-netlink diagnostic reader was tested before any further client
or offloaded-video experiment. It sends only unchanged `NF_ACCEPT` verdicts;
it does not modify packet payloads or marks. Its local protocol tests passed
for mixed byte order, verdict framing, packet IDs, ACK/error handling and
malformed messages. No successful reference-kernel packet test was completed,
so these tests validate framing, not live packet delivery.

On Casa, running as UID 0, the kernel acknowledged queue binding, copy mode,
queue limit and fail-open configuration. The following loopback-only controls
each sent one ping through the same scoped rule:

| Control | Table | Queue-rule hits | Ping replies | Reader packets |
| --- | --- | ---: | ---: | ---: |
| Bound queue, metadata copy | mangle | 1 | 0 | 0 |
| Bound queue, full-packet copy | mangle | 1 | 0 | 0 |
| Bound queue, full-packet copy | filter | 1 | 0 | 0 |
| No reader, `--queue-bypass` | mangle | 1 | 0 | No reader |
| No reader, `--queue-bypass` | filter | 1 | 0 | No reader |
| Same scoped jump with `RETURN` | mangle / filter | No queue | 1 each | No queue |

All three bound queues retained packet sequence 0, with no queue or userspace drops
recorded. Plain loopback ping passed after each cleanup. The no-reader control
also failed despite the displayed bypass flag, so this build's tested path
cannot rely on that flag to preserve traffic. Queue configuration ACKs establish
the control interface works; they do not establish packet enqueue or reinjection.
The exact failing kernel/target path remains unresolved, and these results do
not attribute it to Casa's hardware offload. Moving the rule from mangle to
filter did not repair delivery or the no-reader bypass control.

The next step is offline inspection of the matching vendor kernel and NFQUEUE
target/backend compatibility. Establish unchanged packet delivery and safe
fallback before retrying client video manipulation or measuring offloaded
throughput. The installed `.1.41.dev` build and optimizer-Off settings remain
the recovery baseline; this diagnostic is not included in a package.

The final independent guard was exercised using a harmless `RETURN` rule with
automatic exit cleanup disabled for that control. It removed the owned rule
after exactly 60 seconds. Original settings hashes/permissions and the
normalized full firewall rules matched the baseline; no test queues remained.
Core services, DNS and the UI were healthy, and retained evidence checksums
matched the router. No client video or performance test followed these failed
compatibility prerequisites.

See the [implementation notes](../qmanager/casa_conversion/video-selective/README.md)
and [artifact installation workflow](../scripts/README.md).
