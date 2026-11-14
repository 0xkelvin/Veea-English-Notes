// Package clientip decides which IP address a request is attributed to, for rate limiting
// (TRD 01 section 10).
//
// The rule is conservative: a request header can only influence the result when the TCP peer is
// a configured trusted proxy, and even then only the part of X-Forwarded-For that was appended
// by trusted hops is believed.
package clientip

import (
	"net"
	"net/http"
	"net/netip"
	"strings"
)

// Limits on the X-Forwarded-For data examined. Anything beyond them is treated as malformed,
// so hostile input cannot make resolution expensive.
const (
	maxForwardedBytes = 4096
	maxForwardedHops  = 32
)

// Source tells how the address was chosen. It is for logs and tests, not for decisions.
type Source string

const (
	// SourcePeer: the socket peer, because it is not a trusted proxy.
	SourcePeer Source = "peer"
	// SourceForwarded: the first untrusted hop of X-Forwarded-For, walking right to left.
	SourceForwarded Source = "forwarded"
	// SourceForwardedOrigin: every hop was trusted, so the leftmost one is used.
	SourceForwardedOrigin Source = "forwarded_origin"
	// SourceTrustedPeerNoHeader: a trusted proxy sent no X-Forwarded-For, so the proxy itself.
	SourceTrustedPeerNoHeader Source = "trusted_peer_no_header"
	// SourceMalformedFallback: the chain could not be parsed, so the trusted peer.
	SourceMalformedFallback Source = "malformed_fallback"
	// SourceUnknown: even the peer address could not be parsed.
	SourceUnknown Source = "unknown"
)

// Result is the attribution for one request.
type Result struct {
	// Addr is the resolved address, IPv4-mapped IPv6 unmapped. It is the zero value for
	// SourceUnknown.
	Addr netip.Addr
	// Bucket is the rate-limit subject: the IPv4 address, or the /64 prefix of an IPv6 address.
	// Everything in one /64 shares a bucket, because a single subscriber usually holds a whole
	// /64 and could otherwise rotate through 2^64 addresses. It is "unknown" for SourceUnknown.
	Bucket string
	Source Source
}

// Resolver resolves client addresses against a fixed set of trusted proxies. It is immutable
// and safe for concurrent use.
type Resolver struct {
	trusted []netip.Prefix
}

// New returns a Resolver that trusts the given proxy networks. With none, X-Forwarded-For is
// always ignored.
func New(trusted []netip.Prefix) *Resolver {
	cp := make([]netip.Prefix, 0, len(trusted))
	for _, p := range trusted {
		cp = append(cp, p.Masked())
	}
	return &Resolver{trusted: cp}
}

// ParseTrustedProxies parses a comma-separated list of CIDRs or bare addresses, as in
// VEEA_TRUSTED_PROXIES. A bare address means a single host. Whitespace and empty items are
// ignored, so an empty string means no trusted proxies.
func ParseTrustedProxies(s string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, item := range strings.Split(s, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if strings.Contains(item, "/") {
			p, err := netip.ParsePrefix(item)
			if err != nil {
				return nil, errInvalidProxy
			}
			out = append(out, p.Masked())
			continue
		}
		a, err := netip.ParseAddr(item)
		if err != nil || a.Zone() != "" {
			return nil, errInvalidProxy
		}
		a = a.Unmap()
		out = append(out, netip.PrefixFrom(a, a.BitLen()))
	}
	return out, nil
}

// ResolveRequest resolves r using its socket peer and all of its X-Forwarded-For headers.
func (r *Resolver) ResolveRequest(req *http.Request) Result {
	return r.Resolve(req.RemoteAddr, req.Header.Values("X-Forwarded-For"))
}

// Resolve attributes a request. remoteAddr is the socket peer ("host:port"). forwarded holds
// every X-Forwarded-For header value in order. Multiple header lines are one chain, exactly as
// if they had been joined with commas, so a client cannot hide behind a second header line.
//
//  1. Peer not trusted: the peer. X-Forwarded-For is ignored entirely.
//  2. Peer trusted, no header: the peer, which is the proxy itself.
//  3. Peer trusted, header present: walk the chain from right to left. A trusted hop is skipped.
//     The first untrusted hop is the client. If every hop is trusted, the leftmost is used.
//     Whatever sits left of the first untrusted hop is attacker-controlled and never read.
//  4. Peer trusted but a hop that has to be read cannot be parsed, or the chain is oversized:
//     the peer (conservative fallback). The attacker cannot pick the bucket, and cannot escape
//     limiting by sending garbage; they only share the proxy's bucket with other garbage.
//  5. The peer address itself cannot be parsed: bucket "unknown", shared and limited together.
func (r *Resolver) Resolve(remoteAddr string, forwarded []string) Result {
	peer, ok := parsePeer(remoteAddr)
	if !ok {
		return Result{Bucket: "unknown", Source: SourceUnknown}
	}
	if !r.isTrusted(peer) {
		return result(peer, SourcePeer)
	}

	hops, ok := splitChain(forwarded)
	if !ok {
		return result(peer, SourceMalformedFallback)
	}
	if len(hops) == 0 {
		return result(peer, SourceTrustedPeerNoHeader)
	}

	for i := len(hops) - 1; i >= 0; i-- {
		addr, ok := parseHop(hops[i])
		if !ok {
			return result(peer, SourceMalformedFallback)
		}
		if r.isTrusted(addr) {
			if i == 0 {
				return result(addr, SourceForwardedOrigin)
			}
			continue
		}
		return result(addr, SourceForwarded)
	}
	return result(peer, SourceMalformedFallback) // unreachable: the loop always returns
}

func (r *Resolver) isTrusted(a netip.Addr) bool {
	for _, p := range r.trusted {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

func result(a netip.Addr, s Source) Result {
	return Result{Addr: a, Bucket: Bucket(a), Source: s}
}

// Bucket returns the rate-limit subject for an address: "ip4:<addr>" for IPv4 (IPv4-mapped IPv6
// included) and "ip6:<prefix>/64" for IPv6.
func Bucket(a netip.Addr) string {
	a = a.Unmap()
	if a.Is4() {
		return "ip4:" + a.String()
	}
	return "ip6:" + netip.PrefixFrom(a, 64).Masked().String()
}

func parsePeer(remoteAddr string) (netip.Addr, bool) {
	if ap, err := netip.ParseAddrPort(remoteAddr); err == nil {
		return ap.Addr().Unmap(), true
	}
	// A bare address, as some test servers and unix-socket proxies produce.
	if host, _, err := net.SplitHostPort(remoteAddr); err == nil {
		remoteAddr = host
	}
	a, err := netip.ParseAddr(remoteAddr)
	if err != nil || a.Zone() != "" {
		return netip.Addr{}, false
	}
	return a.Unmap(), true
}

// splitChain joins all header values into one list of hops. It reports false for oversized
// input. An absent header yields no hops. Empty items are kept, so the walk can see them.
func splitChain(values []string) ([]string, bool) {
	total := 0
	for _, v := range values {
		total += len(v)
	}
	if total > maxForwardedBytes {
		return nil, false
	}
	var hops []string
	for _, v := range values {
		if strings.TrimSpace(v) == "" {
			// An empty header line adds no hops. A present but blank header is not a chain.
			continue
		}
		hops = append(hops, strings.Split(v, ",")...)
	}
	if len(hops) > maxForwardedHops {
		return nil, false
	}
	return hops, true
}

// parseHop parses one X-Forwarded-For element: an IPv4 or IPv6 address, optionally with a port
// ("1.2.3.4:5678", "[2001:db8::1]:443") or IPv6 in brackets. Zones, names, "unknown" and
// RFC 7239 "for=" syntax are rejected.
func parseHop(s string) (netip.Addr, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return netip.Addr{}, false
	}
	if a, err := netip.ParseAddr(s); err == nil {
		if a.Zone() != "" {
			return netip.Addr{}, false
		}
		return a.Unmap(), true
	}
	if ap, err := netip.ParseAddrPort(s); err == nil {
		return ap.Addr().Unmap(), true
	}
	if inner, ok := strings.CutPrefix(s, "["); ok {
		if inner, ok = strings.CutSuffix(inner, "]"); ok {
			if a, err := netip.ParseAddr(inner); err == nil && a.Zone() == "" {
				return a.Unmap(), true
			}
		}
	}
	return netip.Addr{}, false
}
