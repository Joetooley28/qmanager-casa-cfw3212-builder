"use client";

import { CheckIcon } from "lucide-react";

import type { VideoScope } from "@/hooks/use-video-scope";
import { cn } from "@/lib/utils";

// Casa: Narrow/Broad switch laid over the Video Optimizer row of the Bypass
// mode card. It is a sibling of the row's button (never inside it), so a
// click changes scope without re-selecting the mode. Below sm it sits under
// the row instead. The Narrow vs Broad card further down explains each one.
//
// Drawn by hand rather than with ToggleGroup: the stock "on" state was not
// distinguishable on the blue selected row (owner feedback). The chosen side
// is a solid light pill with a check and bold text; the other is faint.
const OPTIONS: { value: VideoScope; label: string; title: string }[] = [
  { value: "narrow", label: "Narrow", title: "Only target-list video sites use the proxy" },
  { value: "broad", label: "Broad", title: "All web traffic uses the proxy (upstream)" },
];

export default function VideoScopeToggle({
  scope,
  isSaving,
  onScopeChange,
}: {
  scope: VideoScope | null;
  isSaving: boolean;
  onScopeChange: (s: VideoScope) => void;
}) {
  const disabled = isSaving || scope === null;
  return (
    <div className="mt-2 flex items-center justify-end gap-2 sm:absolute sm:right-16 sm:top-1/2 sm:mt-0 sm:-translate-y-1/2">
      <span className="text-xs font-medium opacity-80">Scope</span>
      <div
        role="radiogroup"
        aria-label="Video Optimizer scope"
        className="flex rounded-full border border-white/30 bg-zinc-900/90 p-0.5"
      >
        {OPTIONS.map((o) => {
          const selected = scope === o.value;
          return (
            <button
              key={o.value}
              type="button"
              role="radio"
              aria-checked={selected}
              title={o.title}
              disabled={disabled}
              onClick={() => {
                if (!selected) onScopeChange(o.value);
              }}
              className={cn(
                "flex items-center gap-1 rounded-full px-3 py-1 text-sm transition-colors disabled:cursor-not-allowed",
                selected
                  ? "bg-white font-semibold text-blue-900 shadow-sm"
                  : "text-white/60 hover:bg-white/10 hover:text-white",
              )}
            >
              {selected && <CheckIcon className="size-3.5" aria-hidden="true" />}
              {o.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}
