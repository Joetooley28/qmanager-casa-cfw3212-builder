package main

import (
	"errors"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestDNSTransportRulesAndClientScope(t *testing.T) {
	calls := []string{}
	f := &firewall{iface: "bridge0", client: "192.168.50.10", proxyPort: 19907, dnsPort: 1053, execute: func(args ...string) error {
		s := strings.Join(args, " ")
		calls = append(calls, s)
		if strings.Contains(s, " -L ") || strings.Contains(s, " -C ") {
			return errors.New("absent")
		}
		return nil
	}}
	if err := f.ensure(map[netip.Addr]time.Time{}); err != nil {
		t.Fatal(err)
	}
	udp, tcp := false, false
	for _, s := range calls {
		if strings.Contains(s, "-A "+dnsChain) && strings.Contains(s, "--to-ports") {
			if !strings.Contains(s, "-p tcp") && !strings.Contains(s, "-p udp") {
				t.Fatal("REDIRECT port needs explicit protocol", s)
			}
			udp = udp || strings.Contains(s, "-p udp")
			tcp = tcp || strings.Contains(s, "-p tcp")
		}
		if strings.Contains(s, "-I PREROUTING") || strings.Contains(s, "-I FORWARD") {
			if !strings.Contains(s, "-i bridge0 -s 192.168.50.10") {
				t.Fatal("pilot escaped client scope", s)
			}
		}
	}
	if !tcp || !udp {
		t.Fatal("missing DNS transport")
	}
}

func TestCleanupReportsAnOwnedChainThatCannotBeRemoved(t *testing.T) {
	f := &firewall{iface: "bridge0", proxyPort: 989, dnsPort: 1053, execute: func(args ...string) error {
		s := strings.Join(args, " ")
		if s == "-t nat -L "+videoChain+" -n" {
			return nil // Simulate an orphan that survives failed deletion.
		}
		return errors.New("simulated deletion failure or absent chain")
	}}
	if err := f.cleanup(); err == nil || !strings.Contains(err.Error(), videoChain) {
		t.Fatalf("claimed cleanup succeeded while owned chain remained: %v", err)
	}
}
