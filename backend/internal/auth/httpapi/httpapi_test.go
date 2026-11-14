package httpapi

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestUserAgentIsSanitized(t *testing.T) {
	cases := map[string]string{
		"VeeaApp/1.0 (iOS 18)":   "VeeaApp/1.0 (iOS 18)",
		"  padded  ":             "padded",
		"tab\there":              "tabhere",
		"client vct_secret":      "",
		"Bearer VAT_x":           "",
		strings.Repeat("a", 300): strings.Repeat("a", 256),
		"bad \xff utf8":          "",
	}
	for in, want := range cases {
		r := httptest.NewRequest("POST", "/", nil)
		r.Header.Set("User-Agent", in)
		if got := UserAgent(r); got != want {
			t.Errorf("%.20q: got %.20q, want %.20q", in, got, want)
		}
	}
}

func TestBearerToken(t *testing.T) {
	cases := []struct {
		headers []string
		want    string
		ok      bool
	}{
		{[]string{"Bearer vat_abc"}, "vat_abc", true},
		{[]string{"bearer vat_abc"}, "vat_abc", true},
		{[]string{"BEARER vat_abc"}, "vat_abc", true},
		{nil, "", false},
		{[]string{""}, "", false},
		{[]string{"Bearer"}, "", false},
		{[]string{"Bearer "}, "", false},
		{[]string{"Basic dXNlcjpwYXNz"}, "", false},
		{[]string{"Bearer vat_a vat_b"}, "", false},
		{[]string{"Bearer vat_a\tx"}, "", false},
		{[]string{"Bearer vat_a", "Bearer vat_b"}, "", false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/", nil)
		for _, h := range c.headers {
			r.Header.Add("Authorization", h)
		}
		got, ok := bearerToken(r)
		if got != c.want || ok != c.ok {
			t.Errorf("%q: got %q %v, want %q %v", c.headers, got, ok, c.want, c.ok)
		}
	}
}
