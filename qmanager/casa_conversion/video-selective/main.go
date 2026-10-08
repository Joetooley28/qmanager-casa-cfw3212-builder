// Experimental Casa video-only interception. DNS is answered only after the
// selected IPv4 rules are installed; unrelated TCP80/443 never enters tpws.
package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

const maxAddresses = 512

var exclusions = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"), netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"), netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"), netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"), netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"), netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"), netip.MustParsePrefix("240.0.0.0/4"),
}

func publicIPv4(a netip.Addr) bool {
	if !a.Is4() {
		return false
	}
	for _, p := range exclusions {
		if p.Contains(a) {
			return false
		}
	}
	return true
}

func hostname(s string) string { return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(s)), ".") }

func validDomain(s string) bool {
	if len(s) > 253 || !strings.Contains(s, ".") {
		return false
	}
	if _, err := netip.ParseAddr(s); err == nil {
		return false
	}
	for _, label := range strings.Split(s, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}

func loadDomains(path string) ([]string, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 256*1024 {
		return nil, errors.New("invalid host-list file")
	}
	s := bufio.NewScanner(io.LimitReader(f, 256*1024+1))
	out := []string{}
	for s.Scan() {
		d := hostname(strings.SplitN(s.Text(), "#", 2)[0])
		if d == "" {
			continue
		}
		if !validDomain(d) {
			return nil, errors.New("video list must contain bare DNS hostnames, not URLs or IP addresses")
		}
		out = append(out, d)
		if len(out) > 300 {
			return nil, errors.New("too many video domains")
		}
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, errors.New("add at least one video/CDN domain before enabling")
	}
	return out, nil
}

func matches(name string, domains []string) bool {
	name = hostname(name)
	for _, d := range domains {
		if name == d || strings.HasSuffix(name, "."+d) {
			return true
		}
	}
	return false
}

type lease struct {
	Address netip.Addr
	TTL     uint32
}

// Only answer-section addresses belonging to the queried name's CNAME chain
// are accepted. Unrelated/additional/private records cannot create rules.
func selectedAnswers(query, reply []byte, domains []string) ([]lease, error) {
	var q, r dnsmessage.Message
	if err := q.Unpack(query); err != nil {
		return nil, err
	}
	if err := r.Unpack(reply); err != nil {
		return nil, err
	}
	if q.Response || !r.Response || q.ID != r.ID || q.OpCode != 0 || r.OpCode != 0 ||
		len(q.Questions) != 1 || len(r.Questions) != 1 || q.Questions[0] != r.Questions[0] {
		return nil, errors.New("DNS reply does not match request")
	}
	if r.RCode != dnsmessage.RCodeSuccess || r.Truncated || q.Questions[0].Class != dnsmessage.ClassINET {
		return nil, nil
	}
	name := hostname(q.Questions[0].Name.String())
	if !matches(name, domains) {
		return nil, nil
	}
	chain := map[string]uint32{name: ^uint32(0)}
	for depth := 0; depth < 16; depth++ {
		changed := false
		for _, a := range r.Answers {
			if a.Header.Class != dnsmessage.ClassINET {
				continue
			}
			parentTTL, ok := chain[hostname(a.Header.Name.String())]
			if !ok {
				continue
			}
			if c, ok := a.Body.(*dnsmessage.CNAMEResource); ok {
				child := hostname(c.CNAME.String())
				ttl := min(parentTTL, a.Header.TTL)
				old, exists := chain[child]
				if !exists || ttl < old {
					chain[child] = ttl
					changed = true
				}
			}
		}
		if !changed {
			break
		}
	}
	out := []lease{}
	for _, a := range r.Answers {
		parentTTL, ok := chain[hostname(a.Header.Name.String())]
		if !ok || a.Header.Class != dnsmessage.ClassINET {
			continue
		}
		if v, ok := a.Body.(*dnsmessage.AResource); ok {
			ip := netip.AddrFrom4(v.A)
			if publicIPv4(ip) {
				out = append(out, lease{ip, min(parentTTL, a.Header.TTL)})
			}
		}
	}
	return out, nil
}

type status struct {
	State           string `json:"state"`
	UpdatedUTC      string `json:"updated_utc"`
	DNSQueries      uint64 `json:"dns_queries"`
	SelectedReplies uint64 `json:"selected_replies"`
	Addresses       int    `json:"addresses"`
	Connections     uint64 `json:"connections"`
	Errors          uint64 `json:"errors"`
	LastError       string `json:"last_error,omitempty"`
	IPv4Only        bool   `json:"ipv4_only"`
}

type engine struct {
	mu                             sync.Mutex
	domains                        []string
	entries                        map[netip.Addr]time.Time
	fw                             *firewall
	status                         status
	statusPath, hostlist, upstream string
	semaphore                      chan struct{}
	stopping                       bool
}

func (e *engine) writeStatus() {
	e.status.UpdatedUTC = time.Now().UTC().Format(time.RFC3339)
	e.status.Addresses = len(e.entries)
	b, _ := json.Marshal(e.status)
	f, err := os.CreateTemp(filepath.Dir(e.statusPath), ".status-")
	if err != nil {
		log.Printf("status: %v", err)
		return
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(b); err == nil {
		err = f.Chmod(0644)
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(name, e.statusPath)
	}
	if err != nil {
		log.Printf("status: %v", err)
	}
}

func (e *engine) recordError(err error) {
	e.status.Errors++
	e.status.LastError = err.Error()
	log.Print(err)
}

func (e *engine) classify(query, reply []byte) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stopping {
		return errors.New("selective optimizer stopping")
	}
	e.status.DNSQueries++
	leases, err := selectedAnswers(query, reply, e.domains)
	if err != nil {
		e.recordError(err)
		return err
	}
	if len(leases) > 0 {
		e.status.SelectedReplies++
	}
	now := time.Now()
	for _, l := range leases {
		// TTL0 answers need a short connection-start grace period. Otherwise
		// retain the DNS TTL, capped to one day to bound stale selections.
		expires := now.Add(time.Duration(max(5, min(l.TTL, 86400))) * time.Second)
		old, exists := e.entries[l.Address]
		if exists {
			if expires.After(old) {
				e.entries[l.Address] = expires
			}
			continue
		}
		if len(e.entries) >= maxAddresses {
			e.recordError(errors.New("video address limit reached; extra addresses bypass optimization"))
			continue
		}
		if err := e.fw.addAddress(l.Address); err != nil {
			e.recordError(err)
			return err
		}
		e.entries[l.Address] = expires
	}
	return nil
}

func (e *engine) exchange(query []byte, transport string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	c, err := (&net.Dialer{}).DialContext(ctx, transport, e.upstream)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(4 * time.Second))
	if transport == "tcp" {
		if len(query) > 65535 {
			return nil, errors.New("DNS query too large")
		}
		packet := make([]byte, 2+len(query))
		binary.BigEndian.PutUint16(packet, uint16(len(query)))
		copy(packet[2:], query)
		if err := writeAll(c, packet); err != nil {
			return nil, err
		}
		h := make([]byte, 2)
		if _, err := io.ReadFull(c, h); err != nil {
			return nil, err
		}
		b := make([]byte, binary.BigEndian.Uint16(h))
		_, err = io.ReadFull(c, b)
		return b, err
	}
	if _, err := c.Write(query); err != nil {
		return nil, err
	}
	b := make([]byte, 65535)
	n, err := c.Read(b)
	return b[:n], err
}

func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}

func failure(query []byte) []byte {
	var m dnsmessage.Message
	if m.Unpack(query) != nil || m.Response {
		return nil
	}
	m.Response = true
	m.RCode = dnsmessage.RCodeServerFailure
	m.Answers = nil
	m.Authorities = nil
	m.Additionals = nil
	b, _ := m.Pack()
	return b
}

func (e *engine) answer(query []byte, transport string) []byte {
	b, err := e.exchange(query, transport)
	if err == nil {
		err = e.classify(query, b)
	}
	if err != nil {
		e.mu.Lock()
		e.recordError(err)
		e.mu.Unlock()
		// Do not return selected DNS addresses before their rules exist.
		return failure(query)
	}
	return b
}

func (e *engine) serveUDP(c net.PacketConn) {
	for {
		b := make([]byte, 4096)
		n, peer, err := c.ReadFrom(b)
		if err != nil {
			return
		}
		select {
		case e.semaphore <- struct{}{}:
		default:
			continue
		}
		go func(q []byte, p net.Addr) {
			defer func() { <-e.semaphore }()
			if reply := e.answer(q, "udp"); len(reply) > 0 {
				_, _ = c.WriteTo(reply, p)
			}
		}(b[:n], peer)
	}
}

func (e *engine) serveTCP(l net.Listener) {
	for {
		c, err := l.Accept()
		if err != nil {
			return
		}
		select {
		case e.semaphore <- struct{}{}:
		default:
			c.Close()
			continue
		}
		go func() {
			defer func() { c.Close(); <-e.semaphore }()
			for {
				_ = c.SetDeadline(time.Now().Add(5 * time.Second))
				h := make([]byte, 2)
				if _, err := io.ReadFull(c, h); err != nil {
					return
				}
				n := int(binary.BigEndian.Uint16(h))
				if n < 12 || n > 4096 {
					return
				}
				q := make([]byte, n)
				if _, err := io.ReadFull(c, q); err != nil {
					return
				}
				r := e.answer(q, "tcp")
				if len(r) == 0 {
					return
				}
				binary.BigEndian.PutUint16(h, uint16(len(r)))
				if writeAll(c, append(h, r...)) != nil {
					return
				}
			}
		}()
	}
}

func (e *engine) reconcile() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	domains, err := loadDomains(e.hostlist)
	if err != nil {
		e.recordError(err)
		return err
	}
	if strings.Join(domains, "\n") != strings.Join(e.domains, "\n") {
		// A removed domain must not leave stale selections. Drop selections;
		// users must reopen streams after any list edit to trigger fresh DNS.
		for ip := range e.entries {
			if err := e.fw.removeAddress(ip); err != nil {
				return err
			}
		}
		e.entries = map[netip.Addr]time.Time{}
		e.domains = domains
	}
	now := time.Now()
	for ip, expiry := range e.entries {
		if !expiry.After(now) {
			if err := e.fw.removeAddress(ip); err != nil {
				return err
			}
			delete(e.entries, ip)
		}
	}
	if err := e.fw.ensure(e.entries); err != nil {
		e.recordError(err)
		return err
	}
	if e.fw.execute == nil {
		if n, err := e.fw.connections(); err == nil {
			e.status.Connections = n
		}
	}
	e.writeStatus()
	return nil
}

func main() {
	hostlist := flag.String("hostlist", "/etc/qmanager/video_domains.txt", "video/CDN domain list")
	proxy := flag.String("tpws", "/usrdata/qmanager/bin/tpws", "verified tpws executable")
	listen := flag.String("dns-listen", "", "IPv4 LAN DNS listener; default is LAN interface address:1053")
	upstream := flag.String("dns-upstream", "127.0.0.1:53", "existing Casa DNS resolver")
	port := flag.Int("proxy-port", 989, "tpws listener port")
	iface := flag.String("interface", "bridge0", "LAN interface")
	client := flag.String("client", "", "optional single IPv4 LAN client for bounded testing")
	runtime := flag.String("runtime", "/run/qmanager-video-selective", "root-owned runtime directory")
	clear := flag.Bool("clear", false, "remove only selective optimizer chains")
	flag.Parse()
	if os.Geteuid() != 0 {
		log.Fatal("root required for video firewall ownership")
	}
	if *port < 1 || *port > 65535 || strings.ContainsAny(*iface, " \t\n") {
		log.Fatal("invalid port/interface")
	}
	if *client != "" {
		a, err := netip.ParseAddr(*client)
		if err != nil || !a.Is4() {
			log.Fatal("client must be an IPv4 address")
		}
	}
	fw := &firewall{iface: *iface, client: *client, proxyPort: *port, dnsPort: 1053}
	if *clear {
		if err := fw.cleanup(); err != nil {
			log.Fatal(err)
		}
		return
	}
	if err := run(*hostlist, *proxy, *listen, *upstream, *runtime, fw); err != nil {
		log.Fatal(err)
	}
}

func run(hostlist, proxy, listen, upstream, runtime string, fw *firewall) error {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)
	if err := os.MkdirAll(runtime, 0755); err != nil {
		return err
	}
	info, err := os.Stat(runtime)
	if err != nil {
		return err
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 || info.Mode().Perm()&0022 != 0 {
		return errors.New("runtime directory must be root-owned and not writable by others")
	}
	lock, err := os.OpenFile(filepath.Join(runtime, "lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("selective optimizer already running")
	}
	domains, err := loadDomains(hostlist)
	if err != nil {
		return err
	}
	var bind string
	if listen == "" {
		iface, err := net.InterfaceByName(fw.iface)
		if err != nil {
			return err
		}
		addrs, err := iface.Addrs()
		if err != nil {
			return err
		}
		for _, a := range addrs {
			p, err := netip.ParsePrefix(a.String())
			if err == nil && p.Addr().Is4() {
				bind = p.Addr().String()
				break
			}
		}
		if bind == "" {
			return errors.New("LAN has no IPv4 address; use routed mode with IP Passthrough off")
		}
		listen = net.JoinHostPort(bind, "1053")
	} else {
		var err error
		bind, _, err = net.SplitHostPort(listen)
		if err != nil {
			return err
		}
		if a, err := netip.ParseAddr(bind); err != nil || !a.Is4() || a.IsUnspecified() {
			return errors.New("DNS listener must bind a specific LAN IPv4 address")
		}
	}
	udp, err := net.ListenPacket("udp4", listen)
	if err != nil {
		return err
	}
	defer udp.Close()
	tcp, err := net.Listen("tcp4", listen)
	if err != nil {
		return err
	}
	defer tcp.Close()
	probe, err := net.Listen("tcp4", net.JoinHostPort(bind, fmt.Sprint(fw.proxyPort)))
	if err != nil {
		return fmt.Errorf("proxy port already in use: %w", err)
	}
	probe.Close()
	cmd := exec.Command(proxy, fmt.Sprintf("--port=%d", fw.proxyPort), "--bind-addr="+bind, "--user=www-data", "--hostlist="+hostlist, "--filter-l7=tls,http", "--split-pos=1,midsld,sniext+1", "--disorder=tls")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	defer func() {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = cmd.Process.Kill()
		}
	}()
	for i := 0; i < 30; i++ {
		c, err := net.DialTimeout("tcp4", net.JoinHostPort(bind, fmt.Sprint(fw.proxyPort)), 100*time.Millisecond)
		if err == nil {
			c.Close()
			break
		}
		if i == 29 {
			return errors.New("tpws listener did not start")
		}
		time.Sleep(100 * time.Millisecond)
	}
	e := &engine{domains: domains, entries: map[netip.Addr]time.Time{}, fw: fw, hostlist: hostlist, upstream: upstream, statusPath: filepath.Join(runtime, "status.json"), semaphore: make(chan struct{}, 64), status: status{State: "running", IPv4Only: true}}
	defer func() {
		e.mu.Lock()
		e.stopping = true
		e.status.State = "off"
		if err := fw.cleanup(); err != nil {
			e.status.State = "cleanup_error"
			e.recordError(err)
		}
		e.entries = map[netip.Addr]time.Time{}
		e.writeStatus()
		e.mu.Unlock()
	}()
	if err := fw.ensure(e.entries); err != nil {
		return err
	}
	dnsDone := make(chan struct{}, 2)
	go func() { e.serveUDP(udp); dnsDone <- struct{}{} }()
	go func() { e.serveTCP(tcp); dnsDone <- struct{}{} }()
	e.mu.Lock()
	e.writeStatus()
	e.mu.Unlock()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-sig:
			return nil
		case <-dnsDone:
			return errors.New("DNS listener exited unexpectedly")
		case err := <-done:
			if err == nil {
				return errors.New("tpws exited unexpectedly")
			}
			return fmt.Errorf("tpws exited: %w", err)
		case <-ticker.C:
			if err := e.reconcile(); err != nil {
				return err
			}
		}
	}
}

func sortedAddresses(m map[netip.Addr]time.Time) []netip.Addr {
	out := make([]netip.Addr, 0, len(m))
	for a := range m {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Less(out[j]) })
	return out
}
