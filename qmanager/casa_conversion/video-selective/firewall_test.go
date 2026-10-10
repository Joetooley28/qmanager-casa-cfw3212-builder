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

func TestIPv6DNSCaptureAndCleanup(t *testing.T) {
	present := map[string]bool{}
	var calls []string
	f := &firewall{iface: "bridge0", proxyPort: 989, dnsPort: 1053, ipv6: true,
		execute: func(args ...string) error { return nil },
		execute6: func(args ...string) error {
			s := strings.Join(args, " ")
			calls = append(calls, s)
			switch args[2] {
			case "-N":
				present[args[3]] = true
			case "-X":
				delete(present, args[3])
			case "-L":
				if !present[args[3]] {
					return errors.New("no chain")
				}
			case "-C":
				return errors.New("absent")
			}
			return nil
		}}
	if err := f.ensure6(); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(calls, "\n")
	for _, want := range []string{
		"-t nat -A QMVS_DNS6 -p udp -j REDIRECT --to-ports 1053",
		"-t nat -A QMVS_DNS6 -p tcp -j REDIRECT --to-ports 1053",
		"-t filter -A QMVS_INPUT6 -i bridge0 -j ACCEPT",
		"-t filter -A QMVS_INPUT6 -j REJECT",
		"-t nat -I PREROUTING 1 -i bridge0 -p udp --dport 53 -j QMVS_DNS6",
		"-t filter -I INPUT 1 -p tcp --dport 1053 -j QMVS_INPUT6",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q", want)
		}
	}
	if err := f.cleanup6(); err != nil || len(present) != 0 {
		t.Fatalf("cleanup6 err=%v remaining=%v", err, present)
	}
}
