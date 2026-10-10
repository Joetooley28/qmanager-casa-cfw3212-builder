package main

import (
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func dnsPair(t *testing.T, name string, answers []dnsmessage.Resource) ([]byte, []byte) {
	t.Helper()
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	b, err := q.Pack()
	if err != nil {
		t.Fatal(err)
	}
	q.Response = true
	q.Answers = answers
	r, err := q.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return b, r
}

func aRecord(name string, ip [4]byte, ttl uint32) dnsmessage.Resource {
	return dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: ttl}, Body: &dnsmessage.AResource{A: ip}}
}

func TestSelectionAndCNAMEExpiry(t *testing.T) {
	answers := []dnsmessage.Resource{
		{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName("r1.googlevideo.com."), Type: dnsmessage.TypeCNAME, Class: dnsmessage.ClassINET, TTL: 30}, Body: &dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("edge.example.net.")}},
		aRecord("edge.example.net.", [4]byte{8, 8, 4, 4}, 120),
		aRecord("unrelated.example.net.", [4]byte{1, 1, 1, 1}, 120),
		aRecord("edge.example.net.", [4]byte{192, 168, 50, 1}, 120),
	}
	q, r := dnsPair(t, "r1.googlevideo.com.", answers)
	out, err := selectedAnswers(q, r, []string{"googlevideo.com"})
	if err != nil || len(out) != 1 || out[0].Address.String() != "8.8.4.4" || out[0].TTL != 30 {
		t.Fatalf("selection %v, %v", out, err)
	}
	q, r = dnsPair(t, "ordinary.example.net.", []dnsmessage.Resource{aRecord("ordinary.example.net.", [4]byte{8, 8, 8, 8}, 120)})
	out, err = selectedAnswers(q, r, []string{"googlevideo.com"})
	if err != nil || len(out) != 0 {
		t.Fatalf("ordinary HTTPS selected: %v %v", out, err)
	}
}

func TestDNSIdentityAndMalformedPackets(t *testing.T) {
	q, r := dnsPair(t, "googlevideo.com.", []dnsmessage.Resource{aRecord("googlevideo.com.", [4]byte{8, 8, 8, 8}, 60)})
	r[1] ^= 1
	if _, err := selectedAnswers(q, r, []string{"googlevideo.com"}); err == nil {
		t.Fatal("accepted unrelated DNS transaction")
	}
	for _, bad := range [][]byte{nil, {0}, make([]byte, 12), {0, 1, 128, 0, 0, 1, 0, 0, 0, 0, 0, 0, 192, 12}} {
		if out, _ := selectedAnswers(q, bad, []string{"googlevideo.com"}); len(out) != 0 {
			t.Fatal("malformed packet selected addresses")
		}
	}
}

func TestDomainBoundariesAndPrivateDestinations(t *testing.T) {
	for _, d := range []string{"notgooglevideo.com", "googlevideo.com.evil.test", "example.com"} {
		if matches(d, []string{"googlevideo.com"}) {
			t.Fatal(d)
		}
	}
	if !matches("R1.GoogleVideo.com.", []string{"googlevideo.com"}) {
		t.Fatal("subdomain should match")
	}
	for _, ip := range []string{"127.0.0.1", "100.98.1.2", "192.168.50.1", "169.254.1.1", "10.0.0.1", "172.16.0.1", "224.0.0.1", "::1", "2001:4860:4860::8888"} {
		if publicIPv4(netip.MustParseAddr(ip)) {
			t.Fatal("unsafe address", ip)
		}
	}
	for _, d := range []string{"https://youtube.com", "8.8.8.8", "youtube.com/path", "a..com", "*.googlevideo.com", "a_com.example"} {
		if validDomain(d) {
			t.Fatal("accepted invalid domain", d)
		}
	}
}

func TestHostlistRejectsSymlinksAndEmptyLists(t *testing.T) {
	d := t.TempDir()
	f := filepath.Join(d, "list")
	if err := os.WriteFile(f, []byte("# comment\n\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadDomains(f); err == nil {
		t.Fatal("accepted empty list")
	}
	link := filepath.Join(d, "link")
	if err := os.Symlink(f, link); err != nil {
		t.Fatal(err)
	}
	if _, err := loadDomains(link); err == nil {
		t.Fatal("followed untrusted symlink")
	}
}

func TestFailedQUICRuleRollsBackRedirect(t *testing.T) {
	calls := []string{}
	f := &firewall{proxyPort: 989, execute: func(args ...string) error {
		s := strings.Join(args, " ")
		calls = append(calls, s)
		if strings.Contains(s, "-I "+quicChain) {
			return errors.New("simulated rule failure")
		}
		return nil
	}}
	if f.addAddress(netip.MustParseAddr("8.8.8.8")) == nil {
		t.Fatal("expected failure")
	}
	if len(calls) != 3 || !strings.Contains(calls[2], "-D "+videoChain) {
		t.Fatal("partial redirect was left active", calls)
	}
}

func TestExpiredAndEditedListsRemoveSelection(t *testing.T) {
	d := t.TempDir()
	list := filepath.Join(d, "list")
	_ = os.WriteFile(list, []byte("youtube.com\n"), 0600)
	ip := netip.MustParseAddr("8.8.8.8")
	calls := []string{}
	f := &firewall{iface: "bridge0", proxyPort: 989, dnsPort: 1053, execute: func(args ...string) error { calls = append(calls, strings.Join(args, " ")); return nil }}
	e := &engine{domains: []string{"youtube.com"}, entries: map[netip.Addr]time.Time{ip: time.Now().Add(-time.Second)}, fw: f, hostlist: list, statusPath: filepath.Join(d, "status")}
	if err := e.reconcile(); err != nil {
		t.Fatal(err)
	}
	if len(e.entries) != 0 {
		t.Fatal("expired selection kept")
	}
	found := false
	for _, s := range calls {
		if strings.Contains(s, "-D "+videoChain) {
			found = true
		}
	}
	if !found {
		t.Fatal("expiry did not remove redirect")
	}
	e.entries[ip] = time.Now().Add(time.Hour)
	_ = os.WriteFile(list, []byte("nflxvideo.net\n"), 0600)
	if err := e.reconcile(); err != nil {
		t.Fatal(err)
	}
	if len(e.entries) != 0 || e.domains[0] != "nflxvideo.net" {
		t.Fatal("list removal retained old addresses")
	}
}

func queryType(t *testing.T, name string, typ dnsmessage.Type) []byte {
	t.Helper()
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 7, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name), Type: typ, Class: dnsmessage.ClassINET}}}
	b, err := q.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestNODATAForTargetIPv6(t *testing.T) {
	domains := []string{"googlevideo.com"}
	for _, typ := range []dnsmessage.Type{dnsmessage.TypeAAAA, typeHTTPS} {
		for _, name := range []string{"googlevideo.com.", "r1.googlevideo.com."} {
			out := nodata(queryType(t, name, typ), domains)
			var m dnsmessage.Message
			if out == nil || m.Unpack(out) != nil {
				t.Fatalf("no NODATA for %s type %d", name, typ)
			}
			if m.ID != 7 || !m.Response || !m.RecursionDesired || !m.RecursionAvailable || m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 0 || len(m.Authorities) != 0 || len(m.Additionals) != 0 || len(m.Questions) != 1 {
				t.Fatalf("bad NODATA %+v", m.Header)
			}
		}
	}
	q, r := dnsPair(t, "googlevideo.com.", nil)
	for _, in := range [][]byte{
		q,
		r,
		queryType(t, "example.com.", dnsmessage.TypeAAAA),
		queryType(t, "notgooglevideo.com.", dnsmessage.TypeAAAA),
		{0, 1, 2},
	} {
		if out := nodata(in, domains); out != nil {
			t.Fatalf("NODATA applied to %x", in)
		}
	}
}

func TestRecordErrorRedactsAndTruncates(t *testing.T) {
	e := &engine{}
	e.recordError(errors.New("iptables -t nat -A QMVS_VIDEO -d 142.250.1.2 -p tcp"))
	if !strings.Contains(e.status.LastError, "<addr>") || strings.Contains(e.status.LastError, "142.250.1.2") {
		t.Fatalf("unredacted error %q", e.status.LastError)
	}
	e.recordError(errors.New(strings.Repeat("x", 300)))
	if len(e.status.LastError) != 200 {
		t.Fatalf("error length %d", len(e.status.LastError))
	}
}

func FuzzDNSSelection(f *testing.F) {
	f.Add([]byte{0, 1, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	f.Fuzz(func(t *testing.T, b []byte) {
		q, _ := dnsPair(t, "googlevideo.com.", nil)
		out, _ := selectedAnswers(q, b, []string{"googlevideo.com"})
		for _, l := range out {
			if !publicIPv4(l.Address) {
				t.Fatal("selected private address")
			}
		}
	})
}
