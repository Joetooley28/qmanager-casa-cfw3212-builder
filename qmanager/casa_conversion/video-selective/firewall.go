package main

import (
	"context"
	"fmt"
	"net/netip"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const videoChain = "QMVS_VIDEO"
const dnsChain = "QMVS_DNS"
const quicChain = "QMVS_QUIC"
const inputChain = "QMVS_INPUT"

func (f *firewall) connections() (uint64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, "iptables", "-t", "nat", "-n", "-v", "-x", "-L", videoChain).Output()
	if err != nil {
		return 0, err
	}
	var count uint64
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 2 && fields[2] == "REDIRECT" {
			n, err := strconv.ParseUint(fields[0], 10, 64)
			if err == nil {
				count += n
			}
		}
	}
	return count, nil
}

type firewall struct {
	iface              string
	client             string
	proxyPort, dnsPort int
	execute            func(...string) error
}

func (f *firewall) lan(spec ...string) []string {
	prefix := []string{"-i", f.iface}
	if f.client != "" {
		prefix = append(prefix, "-s", f.client)
	}
	return append(prefix, spec...)
}

func (f *firewall) call(args ...string) error {
	if f.execute != nil {
		return f.execute(args...)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, "iptables", append([]string{"-w", "5"}, args...)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("iptables %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(b)))
	}
	return nil
}

func (f *firewall) hook(table, chain string, spec []string) error {
	args := append([]string{"-t", table, "-C", chain}, spec...)
	if f.call(args...) == nil {
		return nil
	}
	return f.call(append([]string{"-t", table, "-I", chain, "1"}, spec...)...)
}

func (f *firewall) ensure(entries map[netip.Addr]time.Time) error {
	reset := false
	for _, c := range []struct{ table, name string }{{"nat", videoChain}, {"nat", dnsChain}, {"filter", quicChain}, {"filter", inputChain}} {
		if f.call("-t", c.table, "-L", c.name, "-n") != nil {
			if err := f.call("-t", c.table, "-N", c.name); err != nil {
				return err
			}
			reset = true
			continue
		}
		var sentinel []string
		switch c.name {
		case dnsChain:
			sentinel = []string{"-p", "udp", "-j", "REDIRECT", "--to-ports", strconv.Itoa(f.dnsPort)}
		case inputChain:
			sentinel = []string{"-j", "REJECT"}
		default:
			sentinel = []string{"-j", "RETURN"}
		}
		if f.call(append([]string{"-t", c.table, "-C", c.name}, sentinel...)...) != nil {
			reset = true
		}
	}
	if reset {
		// Reconstruct only our chains after QCMAP re-dial or partial setup.
		for _, c := range []struct{ table, name string }{{"nat", videoChain}, {"nat", dnsChain}, {"filter", quicChain}, {"filter", inputChain}} {
			if err := f.call("-t", c.table, "-F", c.name); err != nil {
				return err
			}
		}
		for _, protocol := range []string{"tcp", "udp"} {
			if err := f.call("-t", "nat", "-A", dnsChain, "-p", protocol, "-j", "REDIRECT", "--to-ports", strconv.Itoa(f.dnsPort)); err != nil {
				return err
			}
		}
		for _, i := range []string{f.iface, "lo"} {
			spec := []string{"-i", i}
			if i == f.iface && f.client != "" {
				spec = append(spec, "-s", f.client)
			}
			if err := f.call(append([]string{"-A", inputChain}, append(spec, "-j", "ACCEPT")...)...); err != nil {
				return err
			}
		}
		if err := f.call("-A", inputChain, "-j", "REJECT"); err != nil {
			return err
		}
		if err := f.call("-t", "nat", "-A", videoChain, "-j", "RETURN"); err != nil {
			return err
		}
		if err := f.call("-A", quicChain, "-j", "RETURN"); err != nil {
			return err
		}
		for _, ip := range sortedAddresses(entries) {
			if err := f.addAddress(ip); err != nil {
				return err
			}
		}
	}
	for _, spec := range [][]string{{"-p", "tcp", "--dport", strconv.Itoa(f.proxyPort), "-j", inputChain}, {"-p", "tcp", "--dport", strconv.Itoa(f.dnsPort), "-j", inputChain}, {"-p", "udp", "--dport", strconv.Itoa(f.dnsPort), "-j", inputChain}} {
		if err := f.hook("filter", "INPUT", spec); err != nil {
			return err
		}
	}
	if err := f.hook("filter", "FORWARD", f.lan("-p", "udp", "--dport", "443", "-j", quicChain)); err != nil {
		return err
	}
	if err := f.hook("nat", "PREROUTING", f.lan("-p", "tcp", "-m", "multiport", "--dports", "80,443", "-j", videoChain)); err != nil {
		return err
	}
	// DNS jumps are last: both listeners and all selection chains exist first.
	for _, p := range []string{"tcp", "udp"} {
		if err := f.hook("nat", "PREROUTING", f.lan("-p", p, "--dport", "53", "-j", dnsChain)); err != nil {
			return err
		}
	}
	return nil
}

func (f *firewall) addressRules(a netip.Addr) [][]string {
	return [][]string{
		{"-t", "nat", "-I", videoChain, "-d", a.String(), "-p", "tcp", "-m", "multiport", "--dports", "80,443", "-j", "REDIRECT", "--to-ports", strconv.Itoa(f.proxyPort)},
		{"-t", "filter", "-I", quicChain, "-d", a.String(), "-p", "udp", "--dport", "443", "-j", "REJECT", "--reject-with", "icmp-port-unreachable"},
	}
}

func (f *firewall) addAddress(a netip.Addr) error {
	if !publicIPv4(a) {
		return fmt.Errorf("refuse non-public video address %s", a)
	}
	r := f.addressRules(a)
	if err := f.call(r[0]...); err != nil {
		return err
	}
	if err := f.call(r[1]...); err != nil {
		r[0][2] = "-D"
		_ = f.call(r[0]...)
		return err
	}
	return nil
}

func (f *firewall) removeAddress(a netip.Addr) error {
	for _, r := range f.addressRules(a) {
		r[2] = "-C"
		if f.call(r...) != nil {
			continue
		}
		r[2] = "-D"
		if err := f.call(r...); err != nil {
			return err
		}
	}
	return nil
}

func (f *firewall) cleanup() error {
	hooks := []struct {
		table, chain string
		spec         []string
	}{
		{"nat", "PREROUTING", f.lan("-p", "tcp", "-m", "multiport", "--dports", "80,443", "-j", videoChain)},
		{"nat", "PREROUTING", f.lan("-p", "tcp", "--dport", "53", "-j", dnsChain)},
		{"nat", "PREROUTING", f.lan("-p", "udp", "--dport", "53", "-j", dnsChain)},
		{"filter", "FORWARD", f.lan("-p", "udp", "--dport", "443", "-j", quicChain)},
	}
	for _, spec := range [][]string{{"-p", "tcp", "--dport", strconv.Itoa(f.proxyPort), "-j", inputChain}, {"-p", "tcp", "--dport", strconv.Itoa(f.dnsPort), "-j", inputChain}, {"-p", "udp", "--dport", strconv.Itoa(f.dnsPort), "-j", inputChain}} {
		hooks = append(hooks, struct {
			table, chain string
			spec         []string
		}{"filter", "INPUT", spec})
	}
	for _, h := range hooks {
		for i := 0; i < 16; i++ {
			if f.call(append([]string{"-t", h.table, "-D", h.chain}, h.spec...)...) != nil {
				break
			}
		}
	}
	for _, c := range []struct{ table, name string }{{"nat", videoChain}, {"nat", dnsChain}, {"filter", quicChain}, {"filter", inputChain}} {
		_ = f.call("-t", c.table, "-F", c.name)
		_ = f.call("-t", c.table, "-X", c.name)
	}
	for _, c := range []struct{ table, name string }{{"nat", videoChain}, {"nat", dnsChain}, {"filter", quicChain}, {"filter", inputChain}} {
		if f.call("-t", c.table, "-L", c.name, "-n") == nil {
			return fmt.Errorf("cleanup incomplete: owned chain %s remains", c.name)
		}
	}
	return nil
}
