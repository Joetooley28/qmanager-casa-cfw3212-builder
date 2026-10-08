"use client";

import * as React from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { authFetch } from "@/lib/auth-fetch";
import type { DpiMode } from "@/types/traffic-engine";

type Selection = {
  state: string;
  dns_queries: number;
  selected_replies: number;
  addresses: number;
  errors: number;
  last_error?: string;
};

export default function SelectiveSetupCard({ mode }: { mode: DpiMode }) {
  const [selection, setSelection] = React.useState<Selection | null>(null);
  const [readFailed, setReadFailed] = React.useState(false);
  React.useEffect(() => {
    let alive = true;
    const controller = new AbortController();
    const read = async () => {
      try {
        const response = await authFetch("/cgi-bin/quecmanager/network/video_optimizer.sh?action=selective_status", { signal: controller.signal });
        if (!response.ok) throw new Error("Status unavailable");
        const result = await response.json();
        if (alive) { setSelection(result); setReadFailed(false); }
      } catch { if (alive) setReadFailed(true); }
    };
    void read();
    const timer = setInterval(() => { void read(); }, 5000);
    return () => { alive = false; controller.abort(); clearInterval(timer); };
  }, []);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Selective video optimizer · Testing build</CardTitle>
        <CardDescription>
          Video Optimizer sends learned video destinations through the bypass. Other destinations keep their normal forwarding path.
          Full Bypass still relays all web traffic and has a larger CPU cost.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4 text-sm">
        <ol className="list-decimal space-y-2 pl-5">
          <li>Use Casa in routed mode with IP Passthrough off. Test from an Ethernet or Wi-Fi client connected to Casa.</li>
          <li>Use Casa for DNS. Disable browser Secure DNS / DNS over HTTPS, Private DNS, and client VPNs for the test. While enabled, plain IPv4 DNS requests use Casa’s existing resolver.</li>
          <li>Add bare video CDN domains under Optimizer targets. For YouTube include <code>googlevideo.com</code>; for Netflix include <code>nflxvideo.net</code>. A site’s homepage alone may not cover its video servers. Subdomains match automatically.</li>
          <li>Select Video Optimizer, then close and reopen the video/browser to make fresh DNS requests and connections. Repeat after editing the list. If needed, clear the client DNS cache.</li>
          <li>This first testing version optimizes IPv4. Use an IPv4 client for comparison; IPv6 and encrypted DNS traffic can bypass selection.</li>
        </ol>
        <div className="rounded-md border border-amber-500/40 bg-amber-500/5 p-3">
          <p className="font-medium">CPU and offloading</p>
          <p className="mt-1">Selected video uses a software proxy rather than the normal forwarding offload path. CPU use and temperature can rise, and video speed can hit a CPU limit. Other destinations remain eligible for normal hardware offloading; their speed still depends on signal, network load, and competing streams.</p>
        </div>
        <p>TCP fallback is automatic for learned video addresses, so selected video QUIC is rejected. In Video Optimizer mode the separate global Force TCP setting is paused; its saved preference resumes in other modes.</p>
        <p>CDN addresses can be shared: another site using a selected address may also enter the proxy. Addresses expire with DNS, with a maximum of one day and 512 active addresses. Restart streams after list edits.</p>
        <p>Compare Fast.com or actual video stats with a client-side ordinary speed test. The target is 60–70 Mbps video alongside roughly 800 Mbps ordinary traffic; this build does not guarantee those rates. Initial client tests reached about 38–42 Mbps video with CPU close to its limit. Router-side tests also consume the router’s CPU.</p>
        <p>Choose Off to stop optimization and remove its DNS/video rules, then reopen affected streams or browsers. Before reinstalling an older package, choose Off and confirm the optimizer has stopped. Reinstalling the previous package rolls back the whole build.</p>
        <div aria-live="polite" className="rounded-md bg-muted p-3">
          {readFailed ? <p>Selection status unavailable. Refresh before judging whether the test is active.</p> : selection?.state === "cleanup_error" ? <p>Cleanup is incomplete. Leave the optimizer Off and review the router log before reinstalling an older package.</p> : mode !== "video_optimizer" ? <p>Selective video routing is off.</p> : selection?.state === "running" ? (
            <>
              <p>{selection.addresses} learned video addresses · {selection.dns_queries} DNS requests · {selection.selected_replies} video DNS replies</p>
              {selection.addresses === 0 && <p className="mt-1">Waiting for video DNS. Check the domain list, Secure DNS setting, and reopen the browser.</p>}
              {selection.errors > 0 && <p className="mt-1">{selection.errors} selection errors. Review the router log before continuing.</p>}
            </>
          ) : <p>Video mode is selected, but the selective service has not reported ready. Check installation and service status.</p>}
        </div>
      </CardContent>
    </Card>
  );
}
