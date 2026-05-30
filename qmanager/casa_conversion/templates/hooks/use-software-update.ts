"use client";

import { useState, useCallback, useRef, useEffect } from "react";
import { authFetch } from "@/lib/auth-fetch";

// =============================================================================
// useSoftwareUpdate — Check, download, install QManager updates
// =============================================================================
// Checks GitHub Releases via the backend CGI on mount.
// Two-step flow: download + verify → install. Polls status during both phases.
//
// Backend: GET/POST /cgi-bin/quecmanager/system/update.sh
// =============================================================================

const CGI_ENDPOINT = "/cgi-bin/quecmanager/system/update.sh";
const POLL_INTERVAL = 2000;
const LAST_CHECKED_KEY = "qm_update_last_checked";

// ─── Types ──────────────────────────────────────────────────────────────────

export interface AvailableVersion {
  tag: string;
  has_assets: boolean;
  asset_size: string | null;
  is_current: boolean;
}

export interface DownloadState {
  status: "downloading" | "verifying" | "ready" | "error";
  version: string;
  message?: string;
  size?: string;
}

export interface UpdateInfo {
  current_version: string;
  latest_version: string | null;
  update_available: boolean;
  changelog: string | null;
  current_changelog: string | null;
  joetooley_changelog: string | null;
  upstream_changelog: string | null;
  current_joetooley_changelog: string | null;
  current_upstream_changelog: string | null;
  upstream_release_url: string | null;
  download_url: string | null;
  download_size: string | null;
  available_versions: AvailableVersion[];
  download_state: DownloadState | null;
  include_prerelease: boolean;
  auto_update_enabled: boolean;
  auto_update_time: string;
  check_error: string | null;
}

export interface UpdateStatus {
  status: "idle" | "downloading" | "installing" | "reboot_required" | "rebooting" | "error";
  message?: string;
  version?: string;
  size?: string;
}

export interface UseSoftwareUpdateReturn {
  updateInfo: UpdateInfo | null;
  updateStatus: UpdateStatus;
  downloadState: DownloadState | null;
  isLoading: boolean;
  isChecking: boolean;
  isUpdating: boolean;
  isDownloading: boolean;
  error: string | null;
  lastChecked: string | null;
  checkForUpdates: () => Promise<void>;
  downloadUpdate: (version?: string) => Promise<void>;
  installStaged: () => Promise<void>;
  clearStaged: () => Promise<void>;
  installUpdate: () => Promise<void>;
  rebootNow: () => Promise<void>;
  togglePrerelease: (enabled: boolean) => Promise<void>;
  saveAutoUpdate: (enabled: boolean, time: string) => Promise<void>;
}

// ─── Hook ───────────────────────────────────────────────────────────────────

export function useSoftwareUpdate(): UseSoftwareUpdateReturn {
  const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null);
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus>({ status: "idle" });
  const [isLoading, setIsLoading] = useState(true);
  const [isChecking, setIsChecking] = useState(false);
  const [isUpdating, setIsUpdating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [downloadState, setDownloadState] = useState<DownloadState | null>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [lastChecked, setLastChecked] = useState<string | null>(null);

  const mountedRef = useRef(true);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    mountedRef.current = true;
    // Load last checked from localStorage
    const stored = localStorage.getItem(LAST_CHECKED_KEY);
    if (stored) setLastChecked(stored);
    return () => {
      mountedRef.current = false;
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Poll download status during background download
  // ---------------------------------------------------------------------------
  const startDownloadPolling = useCallback(() => {
    if (pollRef.current) clearInterval(pollRef.current);

    pollRef.current = setInterval(async () => {
      try {
        const resp = await authFetch(`${CGI_ENDPOINT}?action=status`);
        if (!resp.ok) return;

        const json = await resp.json();
        if (!mountedRef.current) return;

        setDownloadState(json as DownloadState);

        if (json.status === "ready") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          setIsDownloading(false);
        }

        if (json.status === "error") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          setIsDownloading(false);
          setError(json.message || "Download failed");
        }
      } catch {
        // Silently retry on next interval
      }
    }, POLL_INTERVAL);
  }, []);

  // ---------------------------------------------------------------------------
  // Fetch update info from CGI
  // ---------------------------------------------------------------------------
  const fetchUpdateInfo = useCallback(async (silent = false) => {
    if (!silent) setIsLoading(true);
    setError(null);

    try {
      const resp = await authFetch(CGI_ENDPOINT);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);

      const json = await resp.json();
      if (!mountedRef.current) return;

      if (!json.success) {
        setError(json.detail || json.error || "Failed to check for updates");
        return;
      }

      setUpdateInfo(json as UpdateInfo);

      // Sync download state from backend
      const info = json as UpdateInfo;
      if (info.download_state) {
        setDownloadState(info.download_state);
        if (info.download_state.status === "downloading" || info.download_state.status === "verifying") {
          setIsDownloading(true);
          startDownloadPolling();
        }
      }

      // Update last checked timestamp
      const now = new Date().toISOString();
      localStorage.setItem(LAST_CHECKED_KEY, now);
      setLastChecked(now);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to check for updates");
    } finally {
      if (mountedRef.current && !silent) setIsLoading(false);
    }
  }, [startDownloadPolling]);

  // Fetch on mount
  useEffect(() => {
    fetchUpdateInfo();
  }, [fetchUpdateInfo]);

  // Rehydrate a pending post-install reboot on mount / tab revisit.
  // The install poller only sets reboot_required while it is actively running;
  // if the user navigates away and comes back, updateStatus resets to "idle"
  // and the "Reboot required" banner disappears even though the device still
  // needs a reboot. The backend persists this in /tmp/qmanager_update.json
  // (which the reboot itself clears), so re-read it once on mount and restore
  // the banner until the reboot actually happens.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const resp = await authFetch(`${CGI_ENDPOINT}?action=status`);
        if (!resp.ok) return;
        const json: UpdateStatus = await resp.json();
        if (cancelled || !mountedRef.current) return;
        if (json.status === "reboot_required" || json.status === "rebooting") {
          setUpdateStatus(json);
        }
      } catch {
        // ignore — the regular poller will pick it up if a job is active
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Poll update status during install/rollback
  // ---------------------------------------------------------------------------
  const startPolling = useCallback(() => {
    if (pollRef.current) clearInterval(pollRef.current);

    pollRef.current = setInterval(async () => {
      try {
        const resp = await authFetch(`${CGI_ENDPOINT}?action=status`);
        if (!resp.ok) return;

        const json: UpdateStatus = await resp.json();
        if (!mountedRef.current) return;

        setUpdateStatus(json);

        if (json.status === "reboot_required") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          sessionStorage.removeItem("qm_update_reload_scheduled");
          setIsUpdating(false);
          return;
        }

        if (json.status === "rebooting") {
          // Navigate to /reboot/ immediately so the static page loads from
          // lighttpd before the OTA worker fires the reboot syscall. The
          // worker waits for the page's reboot_ack before issuing reboot,
          // so any delay here only widens the race.
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          sessionStorage.setItem("qm_rebooting", "1");
          document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
          window.location.href = "/reboot/";
        }

        if (json.status === "error") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          setIsUpdating(false);
          setError(json.message || "Update failed");
        }
      } catch {
        // Casa restarts QManager/lighttpd during install. A failed poll here is
        // expected while services restart, so keep polling until the worker
        // reports reboot_required or a real error. Navigate once to the UI
        // root as a fallback for users left on a stale nested route.
        if (!sessionStorage.getItem("qm_update_reload_scheduled")) {
          sessionStorage.setItem("qm_update_reload_scheduled", "1");
          window.setTimeout(() => {
            window.location.assign("/");
          }, 30000);
        }
        setError(null);
        setUpdateStatus({
          status: "installing",
          message: "QManager services are restarting; reconnecting. This page will return to the main QManager screen in about 30 seconds if the status does not recover.",
        });
      }
    }, POLL_INTERVAL);
  }, []);

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------
  const checkForUpdates = useCallback(async () => {
    setIsChecking(true);
    await fetchUpdateInfo(true);
    if (mountedRef.current) setIsChecking(false);
  }, [fetchUpdateInfo]);

  const downloadUpdate = useCallback(async (version?: string) => {
    const targetVersion = version || updateInfo?.latest_version;
    if (!targetVersion) return;

    setError(null);
    setIsDownloading(true);
    setDownloadState({ status: "downloading", version: targetVersion });

    try {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "download", version: targetVersion }),
      });

      const json = await resp.json();
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start download");
        setIsDownloading(false);
        setDownloadState(null);
        return;
      }

      startDownloadPolling();
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start download");
      setIsDownloading(false);
      setDownloadState(null);
    }
  }, [updateInfo, startDownloadPolling]);

  const installStaged = useCallback(async () => {
    setError(null);
    setIsUpdating(true);
    setUpdateStatus({ status: "installing", message: "Installing update..." });

    try {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "install_staged" }),
      });

      const json = await resp.json();
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start installation");
        setIsUpdating(false);
        return;
      }

      startPolling();
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start installation");
      setIsUpdating(false);
    }
  }, [startPolling]);

  const clearStaged = useCallback(async () => {
    setError(null);
    try {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "clear_staged" }),
      });
      const json = await resp.json();
      if (!json.success) {
        setError(json.detail || json.error || "Failed to clear staged download");
        return;
      }
      setDownloadState(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to clear staged download");
    }
  }, []);

  const installUpdate = useCallback(async () => {
    if (!updateInfo?.download_url || !updateInfo?.latest_version) return;

    setError(null);
    setIsUpdating(true);
    setUpdateStatus({ status: "downloading", version: updateInfo.latest_version });

    try {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "install",
          download_url: updateInfo.download_url,
          version: updateInfo.latest_version,
          download_size: updateInfo.download_size,
        }),
      });

      const json = await resp.json();
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start update");
        setIsUpdating(false);
        return;
      }

      startPolling();
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start update");
      setIsUpdating(false);
    }
  }, [updateInfo, startPolling]);

  const rebootNow = useCallback(async () => {
    setError(null);
    setUpdateStatus({ status: "rebooting", message: "Rebooting device..." });
    sessionStorage.setItem("qm_rebooting", "1");
    document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
    fetch(CGI_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "reboot_now" }),
      keepalive: true,
    }).catch(() => {});
    window.location.href = "/reboot/";
  }, []);

  const togglePrerelease = useCallback(async (enabled: boolean) => {
    try {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "save_prerelease", enabled }),
      });

      const json = await resp.json();
      if (!json.success) {
        setError(json.detail || json.error || "Failed to save preference");
        return;
      }

      // Re-check with new preference
      await fetchUpdateInfo(true);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to save preference");
    }
  }, [fetchUpdateInfo]);

  const saveAutoUpdate = useCallback(async (enabled: boolean, time: string) => {
    try {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "save_auto_update", enabled, time }),
      });

      const json = await resp.json();
      if (!json.success) {
        setError(json.detail || json.error || "Failed to save auto-update preference");
        return;
      }

      await fetchUpdateInfo(true);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to save auto-update preference");
    }
  }, [fetchUpdateInfo]);

  return {
    updateInfo,
    updateStatus,
    downloadState,
    isLoading,
    isChecking,
    isUpdating,
    isDownloading,
    error,
    lastChecked,
    checkForUpdates,
    downloadUpdate,
    installStaged,
    clearStaged,
    installUpdate,
    rebootNow,
    togglePrerelease,
    saveAutoUpdate,
  };
}
