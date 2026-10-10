"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { authFetch } from "@/lib/auth-fetch";

// =============================================================================
// useVideoScope — Video Optimizer narrow/broad scope status & control
// =============================================================================
// Backend endpoint:
//   GET/POST /cgi-bin/quecmanager/network/video_optimizer.sh
// Fetches once on mount; no polling.
// =============================================================================

const CGI_ENDPOINT = "/cgi-bin/quecmanager/network/video_optimizer.sh";

export type VideoScope = "narrow" | "broad";

export interface UseVideoScopeReturn {
  scope: VideoScope | null;
  isSaving: boolean;
  error: string | null;
  saveScope: (next: VideoScope) => Promise<boolean>;
  refresh: () => void;
}

export function useVideoScope(): UseVideoScopeReturn {
  const [scope, setScope] = useState<VideoScope | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Fetch status
  // ---------------------------------------------------------------------------
  const fetchScope = useCallback(async () => {
    try {
      const resp = await authFetch(CGI_ENDPOINT);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
      const json = await resp.json();
      if (!mountedRef.current) return;

      if (!json.success) {
        setError(json.error || "Failed to fetch Video Optimizer scope");
        return;
      }
      // Missing or unknown values fall back to narrow.
      setScope(json.scope === "broad" ? "broad" : "narrow");
      setError(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(
        err instanceof Error ? err.message : "Failed to fetch Video Optimizer scope",
      );
    }
  }, []);

  useEffect(() => {
    void fetchScope();
  }, [fetchScope]);

  // ---------------------------------------------------------------------------
  // Save scope
  // ---------------------------------------------------------------------------
  const saveScope = useCallback(
    async (next: VideoScope): Promise<boolean> => {
      setError(null);
      setIsSaving(true);
      try {
        const resp = await authFetch(CGI_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "save_scope", scope: next }),
        });
        if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        const json = await resp.json();
        if (!mountedRef.current) return false;

        if (!json.success) {
          setError(json.detail || json.error || "Failed to save Video Optimizer scope");
          return false;
        }
        setScope(next);
        await fetchScope();
        return true;
      } catch (err) {
        if (!mountedRef.current) return false;
        setError(
          err instanceof Error ? err.message : "Failed to save Video Optimizer scope",
        );
        return false;
      } finally {
        if (mountedRef.current) setIsSaving(false);
      }
    },
    [fetchScope],
  );

  return {
    scope,
    isSaving,
    error,
    saveScope,
    refresh: () => {
      void fetchScope();
    },
  };
}
