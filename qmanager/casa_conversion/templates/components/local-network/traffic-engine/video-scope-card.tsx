"use client";

import * as React from "react";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { authFetch } from "@/lib/auth-fetch";
import type { VideoScope } from "@/hooks/use-video-scope";
import type { DpiMode } from "@/types/traffic-engine";

const CGI_ENDPOINT = "/cgi-bin/quecmanager/network/video_optimizer.sh";

const AMBER_BOX = "rounded-md border border-amber-500/40 bg-amber-500/5 p-3";

type SelectionStatus = {
  state: string;
  dns_queries?: number;
  selected_replies?: number;
  addresses?: number;
  hidden_ipv6?: number;
  errors?: number;
  last_error?: string;
};

type VideoScopeCardProps = {
  mode: DpiMode;
  scope: VideoScope | null;
  isSaving: boolean;
  onScopeChange: (s: VideoScope) => void;
  forceTcp: boolean | undefined;
};

export default function VideoScopeCard({
  mode,
  scope,
  isSaving,
  onScopeChange,
  forceTcp,
}: VideoScopeCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Video Optimizer scope</CardTitle>
        <CardDescription>
          Applies when Video Optimizer is selected above. Changing it while Video
          Optimizer is on restarts the engine, which briefly drops connections going
          through it.
        </CardDescription>
      </CardHeader>

      <CardContent className="space-y-4 text-sm">
        <Select
          value={scope ?? ""}
          disabled={isSaving || scope === null}
          onValueChange={(v) => {
            if (v === "narrow" || v === "broad") onScopeChange(v);
          }}
        >
          <SelectTrigger className="w-full" aria-label="Video Optimizer scope">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="narrow">
              Narrow — only video sites use the proxy (recommended)
            </SelectItem>
            <SelectItem value="broad">
              Broad — all web traffic uses the proxy (upstream)
            </SelectItem>
          </SelectContent>
        </Select>

        <div className="overflow-x-auto">
          <table className="w-full min-w-[32rem] border-collapse text-left text-xs">
            <thead>
              <tr className="border-b text-muted-foreground">
                <th className="px-2 py-1.5 font-medium">Scope</th>
                <th className="px-2 py-1.5 font-medium">Goes through the proxy</th>
                <th className="px-2 py-1.5 font-medium">Gets the trick</th>
                <th className="px-2 py-1.5 font-medium">Ordinary web (speed tests, downloads)</th>
                <th className="px-2 py-1.5 font-medium">Router CPU</th>
              </tr>
            </thead>
            <tbody>
              <tr className={scope === "narrow" ? "bg-muted" : undefined}>
                <td className="px-2 py-1.5 font-medium">Narrow</td>
                <td className="px-2 py-1.5">only sites on your target list</td>
                <td className="px-2 py-1.5">target-list sites</td>
                <td className="px-2 py-1.5">stays on the hardware fast path</td>
                <td className="px-2 py-1.5">moderate, video only</td>
              </tr>
              <tr className={scope === "broad" ? "bg-muted" : undefined}>
                <td className="px-2 py-1.5 font-medium">Broad</td>
                <td className="px-2 py-1.5">all web traffic (TCP 80/443)</td>
                <td className="px-2 py-1.5">target-list sites</td>
                <td className="px-2 py-1.5">also goes through the proxy</td>
                <td className="px-2 py-1.5">high</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="text-xs text-muted-foreground">
          Full Bypass (in the mode list above) sends all web traffic through the proxy
          like Broad, and applies the trick to every site.
        </p>

        {scope === "narrow" && (
          <section className="space-y-2">
            <h3 className="font-medium">How Narrow picks video</h3>
            <ul className="list-disc space-y-1.5 pl-5">
              <li>
                Add bare video domains in Optimizer targets below — for example
                googlevideo.com (YouTube) or nflxvideo.net (Netflix). No https:// and no
                paths; subdomains match automatically. A site&apos;s homepage alone may
                not cover its video servers.
              </li>
              <li>
                Narrow learns video addresses from the router&apos;s DNS. Devices using
                Secure DNS / DNS over HTTPS, Private DNS, a VPN, or an app&apos;s own DNS
                are not detected — turn those off on the device.
              </li>
              <li>
                After turning Narrow on or editing targets, close and reopen the video
                app or browser so it looks the addresses up again.
              </li>
              <li>
                IPv6 addresses are hidden for target domains while Narrow is on, so
                video uses IPv4.
              </li>
              <li>
                Video QUIC is blocked only for detected video addresses, so it falls back
                to TCP. The separate Force TCP setting is paused in Narrow.
              </li>
              <li>
                Video CDN addresses can be shared, so another site on the same address may
                also use the proxy.
              </li>
            </ul>

            <NarrowLiveStatus active={mode === "video_optimizer"} />
          </section>
        )}

        {scope === "broad" && (
          <>
            <p className="text-muted-foreground">
              Broad catches video even when DNS is encrypted, because the proxy reads the
              site name in each connection. It costs the most CPU: about 82% average and
              near 100% peak in testing.
            </p>
            {mode === "video_optimizer" && forceTcp === false && (
              <div className={AMBER_BOX}>
                <p>
                  Force TCP is off. Video using QUIC (most YouTube traffic) skips the
                  optimizer. Turn on Force TCP below.
                </p>
              </div>
            )}
          </>
        )}

        <div className={AMBER_BOX}>
          <p className="font-medium">CPU and offloading</p>
          <p className="mt-1">
            Traffic through the proxy is handled in software instead of the hardware fast
            path, so CPU use and temperature rise and video speed can hit a CPU limit.
            Choose Off to remove all optimizer rules.
          </p>
        </div>
      </CardContent>
    </Card>
  );
}

// -----------------------------------------------------------------------------
// Narrow live status. Polls while Narrow is the chosen scope so a cleanup
// failure stays visible even after the mode is switched Off.
// -----------------------------------------------------------------------------
function NarrowLiveStatus({ active }: { active: boolean }) {
  const [selection, setSelection] = React.useState<SelectionStatus | null>(null);
  const [readFailed, setReadFailed] = React.useState(false);

  React.useEffect(() => {
    let alive = true;
    const controller = new AbortController();
    const read = async () => {
      try {
        const response = await authFetch(`${CGI_ENDPOINT}?action=selective_status`, {
          signal: controller.signal,
        });
        if (!response.ok) throw new Error("Status unavailable");
        const result = (await response.json()) as SelectionStatus;
        if (alive) {
          setSelection(result);
          setReadFailed(false);
        }
      } catch {
        if (alive) setReadFailed(true);
      }
    };
    void read();
    const timer = setInterval(() => {
      void read();
    }, 5000);
    return () => {
      alive = false;
      controller.abort();
      clearInterval(timer);
    };
  }, []);

  const addresses = selection?.addresses ?? 0;
  const errors = selection?.errors ?? 0;

  return (
    <div aria-live="polite" className="rounded-md bg-muted p-3">
      {readFailed ? (
        <p>Selection status unavailable. Refresh before judging whether the test is active.</p>
      ) : selection?.state === "cleanup_error" ? (
        <p>
          Cleanup is incomplete. Leave the optimizer Off and review the router log before
          reinstalling an older package.
        </p>
      ) : selection === null ? (
        <p>Checking selective video status…</p>
      ) : !active ? (
        <p>Selective video routing is off.</p>
      ) : selection.state === "running" ? (
        <>
          <p>
            {addresses} learned video addresses · {selection.hidden_ipv6 ?? 0} IPv6 hidden ·{" "}
            {selection.dns_queries ?? 0} DNS requests · {selection.selected_replies ?? 0} video
            DNS replies
          </p>
          {addresses === 0 && (
            <p className="mt-1">
              Waiting for video DNS. Check the domain list, Secure DNS setting, and reopen the
              browser.
            </p>
          )}
          {errors > 0 && (
            <p className="mt-1">
              {errors} selection errors. Review the router log before continuing.
            </p>
          )}
        </>
      ) : (
        <p>
          Video mode is selected, but the selective service has not reported ready. Check
          installation and service status.
        </p>
      )}
    </div>
  );
}
