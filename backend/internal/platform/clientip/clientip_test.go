package clientip

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

func mustProxies(t *testing.T, s string) *Resolver {
	t.Helper()
	p, err := ParseTrustedProxies(s)
	if err != nil {
		t.Fatal(err)
	}
	return New(p)
}

// Trusted: 10.0.0.0/8 (the load balancers), 192.0.2.7 (one CDN host), 2001:db8:ffff::/48.
const trusted = "10.0.0.0/8, 192.0.2.7, 2001:db8:ffff::/48"

func TestResolve(t *testing.T) {
	r := mustProxies(t, trusted)
	cases := []struct {
		name      string
		remote    string
		forwarded []string
		wantAddr  string
		wantSrc   Source
	}{
		// --- untrusted peer: the header is ignored whatever it says ---
		{"untrusted peer ignores a spoofed header", "203.0.113.9:4000", []string{"198.51.100.1"}, "203.0.113.9", SourcePeer},
		{"untrusted peer, no header", "203.0.113.9:4000", nil, "203.0.113.9", SourcePeer},
		{"untrusted peer pretending to be a proxy chain", "203.0.113.9:4000", []string{"198.51.100.1, 10.0.0.1"}, "203.0.113.9", SourcePeer},
		{"untrusted neighbour of a trusted host", "192.0.2.8:4000", []string{"198.51.100.1"}, "192.0.2.8", SourcePeer},

		// --- trusted peer ---
		{"trusted peer without header is the proxy itself", "10.1.2.3:443", nil, "10.1.2.3", SourceTrustedPeerNoHeader},
		{"blank header counts as absent", "10.1.2.3:443", []string{"  "}, "10.1.2.3", SourceTrustedPeerNoHeader},
		{"single client", "10.1.2.3:443", []string{"198.51.100.1"}, "198.51.100.1", SourceForwarded},
		{"client behind one more trusted hop", "10.1.2.3:443", []string{"198.51.100.1, 10.9.9.9"}, "198.51.100.1", SourceForwarded},
		{"client behind two trusted hops", "10.1.2.3:443", []string{"198.51.100.1, 10.9.9.9, 192.0.2.7"}, "198.51.100.1", SourceForwarded},
		{"spaces around hops", "10.1.2.3:443", []string{"  198.51.100.1 ,10.9.9.9  "}, "198.51.100.1", SourceForwarded},

		// --- right to left: what a client prepends is never believed ---
		{"client forges a leftmost address", "10.1.2.3:443", []string{"6.6.6.6, 198.51.100.1"}, "198.51.100.1", SourceForwarded},
		{"client forges several addresses", "10.1.2.3:443", []string{"6.6.6.6, 7.7.7.7, 198.51.100.1, 10.9.9.9"}, "198.51.100.1", SourceForwarded},
		{"client forges a trusted looking address", "10.1.2.3:443", []string{"10.5.5.5, 198.51.100.1"}, "198.51.100.1", SourceForwarded},
		{"a trusted address in the middle is skipped", "10.1.2.3:443", []string{"198.51.100.1, 10.5.5.5, 203.0.113.50, 10.9.9.9"}, "203.0.113.50", SourceForwarded},
		{"garbage left of the first untrusted hop is never read", "10.1.2.3:443", []string{"not-an-ip, , 198.51.100.1"}, "198.51.100.1", SourceForwarded},

		// --- every hop trusted ---
		{"all hops trusted: leftmost", "10.1.2.3:443", []string{"10.7.7.7, 10.8.8.8, 192.0.2.7"}, "10.7.7.7", SourceForwardedOrigin},
		{"single trusted hop", "10.1.2.3:443", []string{"10.7.7.7"}, "10.7.7.7", SourceForwardedOrigin},

		// --- several header lines are one chain ---
		{"two header lines", "10.1.2.3:443", []string{"6.6.6.6", "198.51.100.1, 10.9.9.9"}, "198.51.100.1", SourceForwarded},
		{"second line carries the client", "10.1.2.3:443", []string{"198.51.100.1", "10.9.9.9"}, "198.51.100.1", SourceForwarded},
		{"attacker cannot hide behind a later line", "10.1.2.3:443", []string{"198.51.100.1", "6.6.6.6"}, "6.6.6.6", SourceForwarded},
		{"empty line between lines", "10.1.2.3:443", []string{"198.51.100.1", "", "10.9.9.9"}, "198.51.100.1", SourceForwarded},

		// --- malformed chains fall back to the trusted peer ---
		{"unparsable rightmost hop", "10.1.2.3:443", []string{"198.51.100.1, garbage"}, "10.1.2.3", SourceMalformedFallback},
		{"empty rightmost hop", "10.1.2.3:443", []string{"198.51.100.1,"}, "10.1.2.3", SourceMalformedFallback},
		{"unknown token", "10.1.2.3:443", []string{"unknown"}, "10.1.2.3", SourceMalformedFallback},
		{"rfc 7239 syntax", "10.1.2.3:443", []string{"for=198.51.100.1"}, "10.1.2.3", SourceMalformedFallback},
		{"unparsable hop right of a trusted one", "10.1.2.3:443", []string{"198.51.100.1, 10.9.9.9, ???"}, "10.1.2.3", SourceMalformedFallback},
		{"garbage between trusted hops is reached", "10.1.2.3:443", []string{"198.51.100.1, garbage, 10.9.9.9"}, "10.1.2.3", SourceMalformedFallback},
		{"ipv6 zone", "10.1.2.3:443", []string{"fe80::1%eth0"}, "10.1.2.3", SourceMalformedFallback},
		{"octal looking ipv4", "10.1.2.3:443", []string{"198.051.100.1"}, "10.1.2.3", SourceMalformedFallback},
		{"too many hops", "10.1.2.3:443", []string{strings.Repeat("10.0.0.9,", 40) + "198.51.100.1"}, "10.1.2.3", SourceMalformedFallback},
		{"oversized header", "10.1.2.3:443", []string{strings.Repeat("1", 5000)}, "10.1.2.3", SourceMalformedFallback},
		{"nul byte", "10.1.2.3:443", []string{"198.51.100.1\x00"}, "10.1.2.3", SourceMalformedFallback},

		// --- accepted spellings of a hop ---
		{"ipv4 with port", "10.1.2.3:443", []string{"198.51.100.1:51234"}, "198.51.100.1", SourceForwarded},
		{"ipv6 with port", "10.1.2.3:443", []string{"[2001:db8:1::5]:51234"}, "2001:db8:1::5", SourceForwarded},
		{"ipv6 in brackets", "10.1.2.3:443", []string{"[2001:db8:1::5]"}, "2001:db8:1::5", SourceForwarded},
		{"bare ipv6", "10.1.2.3:443", []string{"2001:db8:1::5"}, "2001:db8:1::5", SourceForwarded},
		{"ipv4 mapped hop is unmapped", "10.1.2.3:443", []string{"::ffff:198.51.100.1"}, "198.51.100.1", SourceForwarded},
		{"ipv4 mapped trusted hop is recognized", "10.1.2.3:443", []string{"198.51.100.1, ::ffff:10.9.9.9"}, "198.51.100.1", SourceForwarded},

		// --- the peer itself ---
		{"ipv6 peer", "[2001:db8:7::1]:443", nil, "2001:db8:7::1", SourcePeer},
		{"trusted ipv6 peer", "[2001:db8:ffff::9]:443", []string{"198.51.100.1"}, "198.51.100.1", SourceForwarded},
		{"ipv4 mapped peer is unmapped and trusted", "[::ffff:10.1.2.3]:443", []string{"198.51.100.1"}, "198.51.100.1", SourceForwarded},
		{"peer without a port", "203.0.113.9", nil, "203.0.113.9", SourcePeer},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := r.Resolve(c.remote, c.forwarded)
			if got.Addr.String() != c.wantAddr || got.Source != c.wantSrc {
				t.Fatalf("got %s (%s), want %s (%s)", got.Addr, got.Source, c.wantAddr, c.wantSrc)
			}
			if got.Bucket != Bucket(got.Addr) {
				t.Fatalf("bucket %q does not match the address", got.Bucket)
			}
		})
	}
}

func TestResolveWithoutTrustedProxiesIgnoresTheHeader(t *testing.T) {
	r := New(nil)
	got := r.Resolve("10.1.2.3:443", []string{"198.51.100.1"})
	if got.Addr.String() != "10.1.2.3" || got.Source != SourcePeer {
		t.Fatalf("got %s (%s)", got.Addr, got.Source)
	}
}

func TestResolveUnparsablePeer(t *testing.T) {
	r := mustProxies(t, trusted)
	for _, remote := range []string{"", "@", "unix", "not an address", "999.1.1.1:80", "fe80::1%eth0"} {
		got := r.Resolve(remote, []string{"198.51.100.1"})
		if got.Source != SourceUnknown || got.Bucket != "unknown" || got.Addr.IsValid() {
			t.Errorf("%q: got %+v, want the shared unknown bucket", remote, got)
		}
	}
}

func TestResolveRequest(t *testing.T) {
	r := mustProxies(t, trusted)
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/start", nil)
	req.RemoteAddr = "10.1.2.3:5555"
	req.Header.Add("X-Forwarded-For", "6.6.6.6")
	req.Header.Add("x-forwarded-for", "198.51.100.1, 10.9.9.9") // other casing is the same header
	got := r.ResolveRequest(req)
	if got.Addr.String() != "198.51.100.1" || got.Source != SourceForwarded {
		t.Fatalf("got %s (%s)", got.Addr, got.Source)
	}
}

// --- buckets ------------------------------------------------------------------------------

func TestBucket(t *testing.T) {
	cases := map[string]string{
		"198.51.100.1":                           "ip4:198.51.100.1",
		"::ffff:198.51.100.1":                    "ip4:198.51.100.1",
		"2001:db8:1:2:3:4:5:6":                   "ip6:2001:db8:1:2::/64",
		"2001:db8:1:2:ffff:ffff:ffff:ffff":       "ip6:2001:db8:1:2::/64",
		"2001:db8:1:3::1":                        "ip6:2001:db8:1:3::/64",
		"::1":                                    "ip6:::/64",
		"2001:DB8:0001:0002:0000:0000:0000:0001": "ip6:2001:db8:1:2::/64",
	}
	for in, want := range cases {
		if got := Bucket(netip.MustParseAddr(in)); got != want {
			t.Errorf("Bucket(%s) = %s, want %s", in, got, want)
		}
	}
}

func TestIPv6AddressesInOneSlash64ShareABucket(t *testing.T) {
	r := New(nil)
	a := r.Resolve("[2001:db8:aaaa:bbbb::1]:1", nil)
	b := r.Resolve("[2001:db8:aaaa:bbbb:dead:beef:1234:5678]:1", nil)
	c := r.Resolve("[2001:db8:aaaa:bbbc::1]:1", nil)
	if a.Bucket != b.Bucket {
		t.Fatalf("one /64 must be one bucket: %s vs %s", a.Bucket, b.Bucket)
	}
	if a.Bucket == c.Bucket {
		t.Fatal("neighbouring /64s must be separate buckets")
	}
	// IPv4 addresses are never merged.
	if r.Resolve("198.51.100.1:1", nil).Bucket == r.Resolve("198.51.100.2:1", nil).Bucket {
		t.Fatal("distinct IPv4 addresses must not share a bucket")
	}
}

func TestSpoofedIPv6HopsInOneSlash64CannotMultiplyBuckets(t *testing.T) {
	r := mustProxies(t, trusted)
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		hop := netip.AddrFrom16([16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, byte(i)}).String()
		seen[r.Resolve("10.1.2.3:443", []string{hop}).Bucket] = true
	}
	if len(seen) != 1 {
		t.Fatalf("100 addresses of one /64 produced %d buckets", len(seen))
	}
}

// --- ParseTrustedProxies ------------------------------------------------------------------

func TestParseTrustedProxies(t *testing.T) {
	got, err := ParseTrustedProxies(" 10.1.2.3/8 , 192.0.2.7,::1, 2001:db8::5/32 ,, ")
	if err != nil {
		t.Fatal(err)
	}
	var s []string
	for _, p := range got {
		s = append(s, p.String())
	}
	want := "10.0.0.0/8 192.0.2.7/32 ::1/128 2001:db8::/32"
	if strings.Join(s, " ") != want {
		t.Fatalf("got %v, want %s", s, want)
	}
	if p, err := ParseTrustedProxies(""); err != nil || len(p) != 0 {
		t.Fatalf("empty must mean no proxies: %v %v", p, err)
	}
	// A bare IPv4-mapped address means the IPv4 host.
	if p, _ := ParseTrustedProxies("::ffff:10.0.0.1"); len(p) != 1 || p[0].String() != "10.0.0.1/32" {
		t.Fatalf("got %v", p)
	}
	for _, bad := range []string{"10.0.0.0/33", "10.0.0.256", "example.com", "10.0.0.1/", "fe80::1%eth0", "10.0.0.1 10.0.0.2", "10.0.0.0/8/9"} {
		if _, err := ParseTrustedProxies(bad); err == nil {
			t.Errorf("%q: expected an error", bad)
		} else if strings.Contains(err.Error(), bad) {
			t.Errorf("%q: error echoes the value", bad)
		}
	}
}

func TestAnyTrustedHostInACIDRIsTrusted(t *testing.T) {
	r := mustProxies(t, "10.0.0.0/8")
	for _, peer := range []string{"10.0.0.0:1", "10.255.255.255:1", "10.128.0.1:1"} {
		if got := r.Resolve(peer, []string{"198.51.100.1"}); got.Source != SourceForwarded {
			t.Errorf("%s should be trusted", peer)
		}
	}
	for _, peer := range []string{"9.255.255.255:1", "11.0.0.0:1"} {
		if got := r.Resolve(peer, []string{"198.51.100.1"}); got.Source != SourcePeer {
			t.Errorf("%s should not be trusted", peer)
		}
	}
}
