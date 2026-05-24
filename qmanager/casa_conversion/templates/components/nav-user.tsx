"use client";

import { useEffect, useRef, useState } from "react";
import {
  ChevronsUpDown,
  KeyRound,
  Loader2,
  LogOut,
  Moon,
  Power,
  RefreshCw,
  Sun,
  Camera,
  Pencil,
  CheckCircle2,
  Clock3,
  Wifi,
  WifiOff,
} from "lucide-react";
import { toast } from "sonner";
import { useTheme } from "next-themes";
import { logout } from "@/hooks/use-auth";
import { authFetch } from "@/lib/auth-fetch";

import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from "@/components/ui/sidebar";
import { ChangePasswordDialog } from "@/components/auth/change-password-dialog";
import type { ModemStatus } from "@/types/modem-status";

type ReconnectPhase =
  | "idle"
  | "sending"
  | "requested"
  | "waiting"
  | "registered"
  | "online"
  | "failed"
  | "timeout";

const RECONNECT_TIMEOUT_MS = 5 * 60 * 1000;
const RECONNECT_POLL_MS = 3000;
const MODEM_STATUS_ENDPOINT = "/cgi-bin/quecmanager/at_cmd/fetch_data.sh";

function formatElapsed(ms: number) {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

function hasUsableWanIp(ip?: string) {
  return Boolean(ip && ip !== "0.0.0.0" && ip !== "192.0.0.1" && ip !== "192.0.0.2");
}

function reconnectProgressFor(phase: ReconnectPhase, elapsedMs: number) {
  if (phase === "online") return 100;
  if (phase === "failed" || phase === "timeout") return 100;
  if (phase === "sending") return 8;
  if (phase === "requested") return 18;
  const timedProgress = 22 + (elapsedMs / RECONNECT_TIMEOUT_MS) * 68;
  return Math.min(92, Math.max(22, Math.round(timedProgress)));
}

function getReconnectPhase(data: ModemStatus, elapsedMs: number): ReconnectPhase {
  const serviceStatus = data.network?.service_status ?? "unknown";
  const internetAvailable = data.connectivity?.internet_available === true;
  const hasNetwork =
    Boolean(data.network?.type) ||
    serviceStatus === "connected" ||
    serviceStatus === "optimal";
  const hasWan = hasUsableWanIp(data.network?.wan_ipv4);

  if (internetAvailable && hasNetwork) {
    return elapsedMs >= 10000 ? "online" : "registered";
  }
  if (hasNetwork || hasWan) return "registered";
  if (data.modem_reachable === false || serviceStatus === "searching") {
    return "waiting";
  }
  return "waiting";
}

export function NavUser({
  user,
}: {
  user: {
    name: string;
    avatar: string;
  };
}) {
  const { isMobile } = useSidebar();
  const { theme, setTheme } = useTheme();

  // --- Display name from device hostname ---
  const [displayName, setDisplayName] = useState<string>(user.name);
  const [avatarSrc, setAvatarSrc] = useState<string>(() => {
    if (typeof window === "undefined") return user.avatar;
    return localStorage.getItem("qm_display_avatar") || user.avatar;
  });

  // Fetch hostname from system settings on mount
  useEffect(() => {
    authFetch("/cgi-bin/quecmanager/system/settings.sh")
      .then((r) => r.json())
      .then((json) => {
        if (json.success && json.settings?.hostname) {
          setDisplayName(json.settings.hostname);
        }
      })
      .catch(() => {});
  }, []);

  // --- Dialog state ---
  const [passwordDialogOpen, setPasswordDialogOpen] = useState(false);
  const [nameDialogOpen, setNameDialogOpen] = useState(false);
  const [rebootDialogOpen, setRebootDialogOpen] = useState(false);
  const [reconnectDialogOpen, setReconnectDialogOpen] = useState(false);
  const [rebooting, setRebooting] = useState(false);
  const [reconnecting, setReconnecting] = useState(false);
  const [reconnectPhase, setReconnectPhase] = useState<ReconnectPhase>("idle");
  const [reconnectDetail, setReconnectDetail] = useState(
    "Ready to ask QManager to refresh the cellular session."
  );
  const [reconnectElapsedMs, setReconnectElapsedMs] = useState(0);
  const [reconnectSnapshot, setReconnectSnapshot] = useState<ModemStatus | null>(null);
  const reconnectStartedAtRef = useRef<number | null>(null);

  // --- Name edit state ---
  const [nameInput, setNameInput] = useState(displayName);

  // --- Avatar upload ---
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleAvatarClick = () => {
    fileInputRef.current?.click();
  };

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      toast.error("Please select an image file.");
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = reader.result as string;
      localStorage.setItem("qm_display_avatar", base64);
      setAvatarSrc(base64);
      toast.success("Profile photo updated.");
    };
    reader.readAsDataURL(file);
    // Reset so same file can be re-selected
    e.target.value = "";
  };

  // --- Name save (updates device hostname) ---
  const [savingName, setSavingName] = useState(false);

  const handleNameSave = async () => {
    const name = nameInput.trim();
    if (!name) return;
    setSavingName(true);
    try {
      const resp = await authFetch("/cgi-bin/quecmanager/system/settings.sh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "save_settings", hostname: name }),
      });
      const json = await resp.json();
      if (!json.success) {
        toast.error("Failed to update display name.");
        return;
      }
      setDisplayName(name);
      setNameDialogOpen(false);
      toast.success("Display name updated.");
    } catch {
      toast.error("Failed to update display name.");
    } finally {
      setSavingName(false);
    }
  };

  // --- Reboot (optimistic) ---
  // Navigate to the countdown page FIRST, then fire the reboot request.
  // This ensures the /reboot/ page loads from cache/memory before the
  // device goes offline. The backend delays reboot by 1s after responding.
  const handleReboot = async (e: React.MouseEvent) => {
    e.preventDefault();
    setRebooting(true);

    // Prepare session state for the countdown page
    sessionStorage.setItem("qm_rebooting", "1");
    document.cookie = "qm_logged_in=; Path=/; Max-Age=0";

    // Fire-and-forget: keepalive ensures the request survives page navigation.
    fetch("/cgi-bin/quecmanager/system/reboot.sh", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "reboot" }),
      keepalive: true,
    }).catch(() => {});

    // Navigate to countdown page immediately
    window.location.href = "/reboot/";
  };

  const handleReconnect = async (e: React.MouseEvent) => {
    e.preventDefault();
    setReconnecting(true);
    setReconnectPhase("sending");
    setReconnectDetail("Sending reconnect request to QManager...");
    setReconnectElapsedMs(0);
    setReconnectSnapshot(null);
    reconnectStartedAtRef.current = Date.now();
    try {
      const resp = await authFetch("/cgi-bin/quecmanager/system/reboot.sh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "reconnect" }),
      });
      const data = await resp.json();
      if (data.success) {
        setReconnectPhase("requested");
        setReconnectDetail(data.detail || "Reconnect requested. Watching modem status...");
        toast.success("Network reconnect initiated. Watching status...");
      } else {
        setReconnectPhase("failed");
        setReconnectDetail("QManager did not accept the reconnect request.");
        toast.error("Reconnect failed.");
      }
    } catch {
      setReconnectPhase("failed");
      setReconnectDetail("QManager could not be reached to send the reconnect request.");
      toast.error("Failed to send reconnect command.");
    } finally {
      setReconnecting(false);
    }
  };

  useEffect(() => {
    if (!reconnectDialogOpen || reconnectPhase === "idle") return;
    if (reconnectPhase === "online" || reconnectPhase === "failed" || reconnectPhase === "timeout") {
      return;
    }

    let cancelled = false;

    const pollReconnectStatus = async () => {
      const startedAt = reconnectStartedAtRef.current ?? Date.now();
      const elapsedMs = Date.now() - startedAt;
      setReconnectElapsedMs(elapsedMs);

      if (elapsedMs > RECONNECT_TIMEOUT_MS) {
        setReconnectPhase("timeout");
        setReconnectDetail("Still waiting for confirmed internet after five minutes.");
        return;
      }

      if (reconnectPhase === "sending") return;

      try {
        const response = await authFetch(MODEM_STATUS_ENDPOINT);
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }

        const status: ModemStatus = await response.json();
        if (cancelled) return;

        const nextPhase = getReconnectPhase(status, elapsedMs);
        setReconnectSnapshot(status);
        setReconnectPhase(nextPhase);

        if (nextPhase === "online") {
          const networkLabel = status.network?.type || "cellular";
          setReconnectDetail(`${networkLabel} data is online.`);
          toast.success("Network reconnect complete.");
        } else if (nextPhase === "registered") {
          const service = status.network?.service_status ?? "registered";
          setReconnectDetail(`Modem is registered (${service}); waiting for internet check.`);
        } else if (status.modem_reachable === false) {
          setReconnectDetail("Waiting for the modem to respond after the reconnect request.");
        } else {
          setReconnectDetail("Waiting for the modem to register on the network.");
        }
      } catch {
        if (cancelled) return;
        setReconnectPhase("waiting");
        setReconnectDetail("QManager status is temporarily unreachable; retrying...");
      }
    };

    pollReconnectStatus();
    const interval = window.setInterval(pollReconnectStatus, RECONNECT_POLL_MS);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [reconnectDialogOpen, reconnectPhase]);

  const initials =
    displayName
      .split(/[-_ ]+/)
      .slice(0, 2)
      .map((w) => w[0]?.toUpperCase() ?? "")
      .join("") || "QM";
  const reconnectProgress = reconnectProgressFor(reconnectPhase, reconnectElapsedMs);
  const reconnectComplete = reconnectPhase === "online";
  const reconnectTerminal =
    reconnectComplete || reconnectPhase === "failed" || reconnectPhase === "timeout";
  const reconnectInProgress =
    reconnecting ||
    (reconnectPhase !== "idle" && !reconnectTerminal);
  const reconnectStatusIcon = reconnectComplete ? (
    <CheckCircle2 className="size-5 text-emerald-500" />
  ) : reconnectPhase === "failed" || reconnectPhase === "timeout" ? (
    <WifiOff className="size-5 text-destructive" />
  ) : (
    <Loader2 className="size-5 animate-spin text-primary" />
  );
  const reconnectStatusTitle = reconnectComplete
    ? "Network is back online"
    : reconnectPhase === "failed"
      ? "Reconnect request failed"
      : reconnectPhase === "timeout"
        ? "Still reconnecting"
        : reconnectPhase === "sending"
          ? "Sending reconnect request"
          : "Watching reconnect progress";
  const reconnectNetworkLabel =
    reconnectSnapshot?.network?.type || reconnectSnapshot?.network?.service_status || "Waiting";
  const reconnectWanLabel = reconnectSnapshot?.network?.wan_ipv4 || "Waiting";
  const reconnectInternetLabel =
    reconnectSnapshot?.connectivity?.internet_available === true
      ? "Online"
      : reconnectSnapshot?.connectivity?.internet_available === false
        ? "Offline"
        : "Checking";

  return (
    <>
      {/* Hidden file input for avatar upload */}
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={handleFileChange}
      />

      <SidebarMenu>
        <SidebarMenuItem>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <SidebarMenuButton
                size="lg"
                className="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
              >
                <Avatar className="h-8 w-8 rounded-lg">
                  <AvatarImage src={avatarSrc} alt={displayName} />
                  <AvatarFallback className="rounded-lg">
                    {initials}
                  </AvatarFallback>
                </Avatar>
                <div className="grid flex-1 text-left text-sm leading-tight">
                  <span className="truncate font-medium">{displayName}</span>
                </div>
                <ChevronsUpDown className="ml-auto size-4" />
              </SidebarMenuButton>
            </DropdownMenuTrigger>
            <DropdownMenuContent
              className="w-(--radix-dropdown-menu-trigger-width) min-w-56 rounded-lg"
              side={isMobile ? "bottom" : "right"}
              align="end"
              sideOffset={4}
            >
              <DropdownMenuLabel className="p-0 font-normal">
                <div className="flex items-center gap-2 px-1 py-1.5 text-left text-sm">
                  {/* Clickable avatar with camera overlay */}
                  <button
                    type="button"
                    onClick={handleAvatarClick}
                    className="relative group shrink-0 rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                    aria-label="Change profile photo"
                  >
                    <Avatar className="h-8 w-8 rounded-lg">
                      <AvatarImage src={avatarSrc} alt={displayName} />
                      <AvatarFallback className="rounded-lg">
                        {initials}
                      </AvatarFallback>
                    </Avatar>
                    <div className="absolute inset-0 rounded-lg bg-black/50 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
                      <Camera className="size-3.5 text-white" />
                    </div>
                  </button>
                  <div className="grid flex-1 text-left text-sm leading-tight">
                    <span className="truncate font-medium">{displayName}</span>
                  </div>
                </div>
              </DropdownMenuLabel>
              <DropdownMenuSeparator />
              <DropdownMenuGroup>
                <DropdownMenuItem
                  onClick={() => {
                    setNameInput(displayName);
                    setNameDialogOpen(true);
                  }}
                >
                  <Pencil />
                  Change Display Name
                </DropdownMenuItem>
                <DropdownMenuItem
                  onClick={() => setPasswordDialogOpen(true)}
                >
                  <KeyRound />
                  Change Password
                </DropdownMenuItem>
                <DropdownMenuItem
                  onClick={() =>
                    setTheme(theme === "dark" ? "light" : "dark")
                  }
                >
                  <Sun className="dark:hidden" />
                  <Moon className="hidden dark:block" />
                  Toggle Theme
                </DropdownMenuItem>
              </DropdownMenuGroup>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                onClick={() => setReconnectDialogOpen(true)}
              >
                <RefreshCw />
                Reconnect Network
              </DropdownMenuItem>
              <DropdownMenuItem
                variant="destructive"
                onClick={() => setRebootDialogOpen(true)}
              >
                <Power />
                Reboot Device
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => logout()}>
                <LogOut />
                Log out
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </SidebarMenuItem>
      </SidebarMenu>

      {/* Change Display Name dialog */}
      <Dialog
        open={nameDialogOpen}
        onOpenChange={(open) => {
          setNameDialogOpen(open);
          if (!open) setNameInput(displayName);
        }}
      >
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>Change Display Name</DialogTitle>
          </DialogHeader>
          <div className="py-2">
            <Input
              value={nameInput}
              onChange={(e) => setNameInput(e.target.value)}
              placeholder="Your name"
              autoFocus
              onKeyDown={(e) => {
                if (e.key === "Enter") handleNameSave();
              }}
            />
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setNameDialogOpen(false)}
            >
              Cancel
            </Button>
            <Button
              onClick={handleNameSave}
              disabled={!nameInput.trim() || nameInput.trim() === displayName || savingName}
            >
              {savingName ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Saving...
                </>
              ) : (
                "Save"
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ChangePasswordDialog
        open={passwordDialogOpen}
        onOpenChange={setPasswordDialogOpen}
      />

      <AlertDialog open={reconnectDialogOpen} onOpenChange={(open) => {
        if (reconnectInProgress && !open) return;
        setReconnectDialogOpen(open);
        if (!open) {
          setReconnectPhase("idle");
          setReconnectDetail("Ready to ask QManager to refresh the cellular session.");
          setReconnectElapsedMs(0);
          setReconnectSnapshot(null);
          reconnectStartedAtRef.current = null;
        }
      }}>
        <AlertDialogContent className="sm:max-w-md">
          <AlertDialogHeader>
            <AlertDialogTitle>Reconnect Network</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div>
                {reconnectPhase === "idle"
                  ? "QManager will ask Casa's connection manager to refresh the cellular session. Internet may drop while the modem reconnects."
                  : "QManager is watching the cached modem status while the network comes back."}
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>

          {reconnectPhase !== "idle" && (
            <div className="space-y-4 py-1" aria-live="polite">
              <div className="flex items-start gap-3 rounded-md border bg-muted/35 p-3">
                <div className="mt-0.5 shrink-0">{reconnectStatusIcon}</div>
                <div className="min-w-0 flex-1">
                  <div className="text-sm font-medium">{reconnectStatusTitle}</div>
                  <div className="mt-1 text-sm text-muted-foreground">
                    {reconnectDetail}
                  </div>
                </div>
              </div>

              <div className="space-y-2">
                <div className="flex items-center justify-between text-xs text-muted-foreground">
                  <span>Elapsed {formatElapsed(reconnectElapsedMs)}</span>
                  <span>{reconnectProgress}%</span>
                </div>
                <Progress value={reconnectProgress} />
              </div>

              <div className="grid grid-cols-3 gap-2 text-xs">
                <div className="rounded-md border p-2">
                  <div className="mb-1 flex items-center gap-1 text-muted-foreground">
                    <Wifi className="size-3.5" />
                    Network
                  </div>
                  <div className="truncate font-medium">{reconnectNetworkLabel}</div>
                </div>
                <div className="rounded-md border p-2">
                  <div className="mb-1 text-muted-foreground">WAN IP</div>
                  <div className="truncate font-medium">{reconnectWanLabel}</div>
                </div>
                <div className="rounded-md border p-2">
                  <div className="mb-1 text-muted-foreground">Internet</div>
                  <div className="truncate font-medium">{reconnectInternetLabel}</div>
                </div>
              </div>

              {!reconnectTerminal && (
                <div className="flex items-start gap-2 rounded-md border border-dashed p-3 text-xs text-muted-foreground">
                  <Clock3 className="mt-0.5 size-3.5 shrink-0" />
                  <span>
                    This can take several minutes on some carriers. Keep this window open
                    to watch registration, WAN IP, and internet status.
                  </span>
                </div>
              )}
            </div>
          )}

          <AlertDialogFooter>
            {reconnectPhase === "idle" ? (
              <>
                <AlertDialogCancel>
                  Cancel
                </AlertDialogCancel>
                <AlertDialogAction
                  disabled={reconnecting}
                  onClick={handleReconnect}
                >
                  {reconnecting ? (
                    <>
                      <Loader2 className="size-4 animate-spin" />
                      Reconnecting...
                    </>
                  ) : (
                    "Reconnect"
                  )}
                </AlertDialogAction>
              </>
            ) : (
              <AlertDialogAction disabled={!reconnectTerminal}>
                {reconnectTerminal ? "Close" : "Reconnect in progress"}
              </AlertDialogAction>
            )}
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog open={rebootDialogOpen} onOpenChange={(open) => {
        if (!rebooting) setRebootDialogOpen(open);
      }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Reboot Device</AlertDialogTitle>
            <AlertDialogDescription aria-live="polite">
              {rebooting
                ? "Reboot command sent. You will be logged out shortly..."
                : "The device will restart and all network connections will drop until it comes back online."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={rebooting}>
              Not Now
            </AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={rebooting}
              onClick={handleReboot}
            >
              {rebooting ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Rebooting...
                </>
              ) : (
                "Reboot Now"
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
