"use client";

import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import type { VideoScope } from "@/hooks/use-video-scope";

// Casa: Narrow/Broad switch laid over the Video Optimizer row of the Bypass
// mode card. It is a sibling of the row's button (never inside it), so a
// click changes scope without re-selecting the mode. Below sm it sits under
// the row instead. The Narrow vs Broad card further down explains each one.
export default function VideoScopeToggle({
  scope,
  isSaving,
  onScopeChange,
}: {
  scope: VideoScope | null;
  isSaving: boolean;
  onScopeChange: (s: VideoScope) => void;
}) {
  return (
    <div className="mt-2 flex items-center justify-end gap-2 sm:absolute sm:right-16 sm:top-1/2 sm:mt-0 sm:-translate-y-1/2">
      <span className="text-xs opacity-80">Scope</span>
      <ToggleGroup
        type="single"
        variant="outline"
        size="sm"
        value={scope ?? ""}
        disabled={isSaving || scope === null}
        onValueChange={(v) => {
          if ((v === "narrow" || v === "broad") && v !== scope) onScopeChange(v);
        }}
        aria-label="Video Optimizer scope"
        className="bg-background text-foreground"
      >
        <ToggleGroupItem value="narrow" className="px-3" title="Only target-list video sites use the proxy">
          Narrow
        </ToggleGroupItem>
        <ToggleGroupItem value="broad" className="px-3" title="All web traffic uses the proxy (upstream)">
          Broad
        </ToggleGroupItem>
      </ToggleGroup>
    </div>
  );
}
