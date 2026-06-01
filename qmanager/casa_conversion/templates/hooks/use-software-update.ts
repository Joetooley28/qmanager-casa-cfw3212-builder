"use client";

import { useState, useCallback, useRef, useEffect } from "react";
import { authFetch } from "@/lib/auth-fetch";

// =============================================================================
// useSoftwareUpdate — Check, download, install QManager updates
// =============================================================================
// On mount: action=check (fresh GitHub probe for latest version).
// Version dropdown: action=versions (cached list; refresh=1 to refetch).
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
  loadVersionList: () => Promise<void>;
  refreshVersionList: () => Promise<void>;
  isLoadingVersions: boolean;
  versionsLoaded: boolean;
  versionsCacheMiss: boolean;
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
  const [isLoadingVersions, setIsLoadingVersions] = useState(false);
  const [versionsLoaded, setVersionsLoaded] = useState(false);
  const [versionsCacheMiss, setVersionsCacheMiss] = useState(false);

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

  const applyCheckResponse = useCallback(
    (json: UpdateInfo) => {
      setUpdateInfo((prev) => ({
        ...(prev ?? {}),
        ...json,
        available_versions: prev?.available_versions ?? json.available_versions ?? [],
      } as UpdateInfo));

      if (json.download_state) {
        setDownloadState(json.download_state);
        if (
          json.download_state.status === "downloading" ||
          json.download_state.status === "verifying"
        ) {
          setIsDownloading(true);
          startDownloadPolling();
        }
      }

      const now = new Date().toISOString();
      localStorage.setItem(LAST_CHECKED_KEY, now);
      setLastChecked(now);
    },
    [startDownloadPolling],
  );

  // ---------------------------------------------------------------------------
  // Fetch latest-version check (auto on mount; Check for Updates button)
  // ---------------------------------------------------------------------------
  const fetchUpdateCheck = useCallback(
    async (refresh = true) => {
      setError(null);
      const qs = refresh ? "?action=check&refresh=1" : "?action=check";
      const resp = await authFetch(`${CGI_ENDPOINT}${qs}`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);

      const json = await resp.json();
      if (!mountedRef.current) return;

      if (!json.success) {
        setError(json.detail || json.error || "Failed to check for updates");
        return;
      }

      applyCheckResponse(json as UpdateInfo);
    },
    [applyCheckResponse],
  );

  // ---------------------------------------------------------------------------
  // Fetch cached version list for Version Management dropdown
  // ---------------------------------------------------------------------------
  const fetchVersionList = useCallback(
    async (refresh = false) => {
      setIsLoadingVersions(true);
      setError(null);
      try {
        const qs = refresh
          ? "?action=versions&refresh=1"
          : "?action=versions";
        const resp = await authFetch(`${CGI_ENDPOINT}${qs}`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);

        const json = await resp.json();
        if (!mountedRef.current) return;

        if (!json.success) {
          setError(json.detail || json.error || "Failed to load version list");
          return;
        }

        const cacheMiss = Boolean(json.versions_cache_miss);
        setVersionsCacheMiss(cacheMiss);
        setVersionsLoaded(!cacheMiss && (json.available_versions?.length ?? 0) > 0);

        setUpdateInfo((prev) => ({
          ...(prev ?? {
            current_version: "",
            latest_version: null,
            update_available: false,
            changelog: null,
            current_changelog: null,
            joetooley_changelog: null,
            upstream_changelog: null,
            current_joetooley_changelog: null,
            current_upstream_changelog: null,
            upstream_release_url: null,
            download_url: null,
            download_size: null,
            available_versions: [],
            download_state: null,
            include_prerelease: json.include_prerelease ?? true,
            auto_update_enabled: false,
            auto_update_time: "03:00",
            check_error: null,
          }),
          available_versions: json.available_versions ?? [],
          include_prerelease:
            json.include_prerelease ?? prev?.include_prerelease ?? true,
        } as UpdateInfo));
      } catch (err) {
        if (!mountedRef.current) return;
        setError(err instanceof Error ? err.message : "Failed to load version list");
      } finally {
        if (mountedRef.current) setIsLoadingVersions(false);
      }
    },
    [],
  );

  // Auto-check for updates on mount (does not load the full version list).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      setIsLoading(true);
      try {
        await fetchUpdateCheck(true);
      } catch (err) {
        if (!cancelled && mountedRef.current) {
          setError(err instanceof Error ? err.message : "Failed to check for updates");
        }
      } finally {
        if (!cancelled && mountedRef.current) setIsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [fetchUpdateCheck]);

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
    try {
      await fetchUpdateCheck(true);
    } catch (err) {
      if (mountedRef.current) {
        setError(err instanceof Error ? err.message : "Failed to check for updates");
      }
    } finally {
      if (mountedRef.current) setIsChecking(false);
    }
  }, [fetchUpdateCheck]);

  const loadVersionList = useCallback(async () => {
    await fetchVersionList(false);
  }, [fetchVersionList]);

  const refreshVersionList = useCallback(async () => {
    await fetchVersionList(true);
  }, [fetchVersionList]);

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

      setVersionsLoaded(false);
      setVersionsCacheMiss(false);
      await fetchUpdateCheck(true);
      if (versionsLoaded) {
        await fetchVersionList(true);
      }
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to save preference");
    }
  }, [fetchUpdateCheck, fetchVersionList, versionsLoaded]);

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

      await fetchUpdateCheck(true);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to save auto-update preference");
    }
  }, [fetchUpdateCheck]);

  return {
    updateInfo,
    updateStatus,
    downloadState,
    isLoading,
    isChecking,
    isUpdating,
    isDownloading,
    isLoadingVersions,
    versionsLoaded,
    versionsCacheMiss,
    error,
    lastChecked,
    checkForUpdates,
    loadVersionList,
    refreshVersionList,
    downloadUpdate,
    installStaged,
    clearStaged,
    installUpdate,
    rebootNow,
    togglePrerelease,
    saveAutoUpdate,
  };
}
