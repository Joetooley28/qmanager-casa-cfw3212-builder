"use client";

import { useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Field, FieldGroup, FieldLabel, FieldSet } from "@/components/ui/field";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Button } from "@/components/ui/button";
import { SaveButton, useSaveFlash } from "@/components/ui/save-button";
import { Skeleton } from "@/components/ui/skeleton";
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
import { RotateCcwIcon } from "lucide-react";

import { useIpPassthrough } from "@/hooks/use-ip-passthrough";
import type { DnsProxy, IpptNat, PassthroughMode, UsbMode } from "@/types/ip-passthrough";

type UsbModeLocal = "rmnet" | "ecm" | "mbim" | "rndis";

const USB_MODE_TO_API: Record<UsbModeLocal, string> = {
  rmnet: "0",
  ecm: "1",
  mbim: "2",
  rndis: "3",
};

const IPPassthroughCard = () => {
  const {
    passthroughMode,
    targetMac,
    ipptNat,
    usbMode,
    dnsProxy,
    isLoading,
    isSaving,
    error,
    saveSettings,
    refresh,
  } = useIpPassthrough();
  const { saved, markSaved } = useSaveFlash();

  const [localMode, setLocalMode] = useState<PassthroughMode>("disabled");
  const [showConfirmDialog, setShowConfirmDialog] = useState(false);

  useEffect(() => {
    if (passthroughMode !== null) {
      setLocalMode(passthroughMode);
    }
  }, [passthroughMode, targetMac, ipptNat, usbMode, dnsProxy]);

  const macValid = true;

  const resetToServer = () => {
    if (passthroughMode !== null) {
      setLocalMode(passthroughMode);
    }
  };

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault();

    if (!macValid) {
      toast.error("Enter a valid MAC address (XX:XX:XX:XX:XX:XX)");
      return;
    }

    setShowConfirmDialog(true);
  };

  const handleConfirmedApply = async () => {
    setShowConfirmDialog(false);

    const success = await saveSettings({
      passthrough_mode: localMode,
      target_mac: "",
      ippt_nat: "0" as IpptNat,
      usb_mode: USB_MODE_TO_API.rmnet as UsbMode,
      dns_proxy: "disabled" as DnsProxy,
    });

    if (success) {
      markSaved();
      toast.success("Casa IP Passthrough updated.");
    } else {
      toast.error("Failed to save IP Passthrough settings");
    }
  };

  if (isLoading) {
    return (
      <Card className="@container/card @3xl/main:col-span-2 max-w-[980px] w-full">
        <CardHeader>
          <CardTitle>IP Passthrough Configuration</CardTitle>
          <CardDescription>
            Assign the modem's public IP directly to a downstream device,
            bypassing the router's NAT.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid gap-4">
            <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
              <div className="space-y-2">
                <Skeleton className="h-4 w-40" />
                <Skeleton className="h-9 w-full" />
              </div>
              <div className="space-y-2">
                <Skeleton className="h-4 w-36" />
                <Skeleton className="h-9 w-full" />
              </div>
            </div>
            <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
              <div className="space-y-2">
                <Skeleton className="h-4 w-28" />
                <Skeleton className="h-9 w-full" />
              </div>
              <div className="space-y-2">
                <Skeleton className="h-4 w-36" />
                <Skeleton className="h-9 w-full" />
              </div>
            </div>
            <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
              <div className="space-y-2">
                <Skeleton className="h-4 w-28" />
                <Skeleton className="h-9 w-full" />
              </div>
            </div>
            <div className="flex gap-2">
              <Skeleton className="h-9 w-28" />
              <Skeleton className="h-9 w-9" />
            </div>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="@container/card @3xl/main:col-span-2 max-w-[980px] w-full">
      <CardHeader>
        <CardTitle>IP Passthrough Configuration</CardTitle>
        <CardDescription>
          Assign the modem's public IP directly to a downstream device,
          bypassing the router's NAT.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {error && (
          <div className="flex items-center justify-between gap-2 rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 mb-4">
            <p className="text-sm text-destructive">{error}</p>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="shrink-0 text-destructive hover:text-destructive"
              onClick={refresh}
            >
              Retry
            </Button>
          </div>
        )}
        <form className="grid gap-4" onSubmit={handleSubmit}>
          <div className="w-full">
            <FieldSet>
              <FieldGroup>
                <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
                  <Field>
                    <FieldLabel>IP Passthrough Mode</FieldLabel>
                    <Select
                      name="ippt_mode"
                      value={localMode}
                      onValueChange={(value) => setLocalMode(value as PassthroughMode)}
                      disabled={isSaving}
                    >
                      <SelectTrigger aria-label="IP Passthrough mode">
                        <span>
                          {localMode === "disabled"
                            ? "Disabled"
                            : "Enabled Ethernet (ETH)"}
                        </span>
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="disabled">Disabled</SelectItem>
                        <SelectItem value="eth">Enabled Ethernet (ETH)</SelectItem>
                      </SelectContent>
                    </Select>
                  </Field>

                  <Field>
                    <FieldLabel>Target Device (MAC)</FieldLabel>
                    <Select value="casa_locked" disabled>
                      <SelectTrigger aria-label="Target Device MAC">
                        <SelectValue placeholder="CASA Locked" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="casa_locked">CASA Locked</SelectItem>
                      </SelectContent>
                    </Select>
                  </Field>
                </div>

                <div className="grid @md/card:grid-cols-2 grid-cols-1 grid-flow-row gap-4">
                  <Field>
                    <FieldLabel>NAT Mode (Network Address Translation)</FieldLabel>
                    <Select value="casa_locked" disabled>
                      <SelectTrigger aria-label="NAT mode">
                        <SelectValue placeholder="CASA Locked" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="casa_locked">CASA Locked</SelectItem>
                      </SelectContent>
                    </Select>
                  </Field>

                  <Field>
                    <FieldLabel>USB Connection Mode</FieldLabel>
                    <Select value="rmnet" disabled>
                      <SelectTrigger aria-label="USB Connection Mode">
                        <SelectValue placeholder="QMI (CASA Locked)" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="rmnet">QMI (CASA Locked)</SelectItem>
                      </SelectContent>
                    </Select>
                  </Field>
                </div>

                <div className="grid @md/card:grid-cols-2 grid-cols-1 grid-flow-row gap-4">
                  <Field>
                    <FieldLabel>DNS Proxy</FieldLabel>
                    <Select value="casa_locked" disabled>
                      <SelectTrigger aria-label="DNS proxy">
                        <SelectValue placeholder="CASA Locked" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="casa_locked">CASA Locked</SelectItem>
                      </SelectContent>
                    </Select>
                  </Field>
                </div>
              </FieldGroup>
            </FieldSet>
          </div>

          <div className="flex items-center gap-x-2">
            <SaveButton
              type="submit"
              isSaving={isSaving}
              saved={saved}
              disabled={!macValid}
            />
            <Button
              type="button"
              variant="outline"
              onClick={resetToServer}
              disabled={isSaving}
              aria-label="Reset to saved values"
            >
              <RotateCcwIcon />
            </Button>
          </div>
        </form>

        <AlertDialog
          open={showConfirmDialog}
          onOpenChange={setShowConfirmDialog}
        >
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Apply Casa IP Passthrough</AlertDialogTitle>
              <AlertDialogDescription asChild>
                <div className="space-y-3 text-sm text-muted-foreground">
                  <p>
                    Applying these changes updates Casa IP Passthrough only.
                    USB composition stays fixed to QMI/rmnet and no reboot is
                    triggered here.
                  </p>
                  {localMode !== "disabled" && (
                    <p className="font-medium text-foreground">
                      Casa IP Passthrough may change LAN reachability on some
                      setups. No reboot is triggered by this page.
                    </p>
                  )}
                  <p>This setting persists through Casa profile state.</p>
                </div>
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction onClick={handleConfirmedApply}>
                Apply
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </CardContent>
    </Card>
  );
};

export default IPPassthroughCard;
