package slackhttp

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// captureRT records every request it sees and forwards to a wrapped RT.
type captureRT struct {
	wrapped http.RoundTripper
	last    *http.Request
}

func (c *captureRT) RoundTrip(req *http.Request) (*http.Response, error) {
	c.last = req.Clone(req.Context())
	return c.wrapped.RoundTrip(req)
}

func newCaptureClient(t *testing.T, srv *httptest.Server) (*http.Client, *captureRT) {
	t.Helper()
	recorder := &captureRT{wrapped: http.DefaultTransport}
	bt := &BrowserTransport{Inner: recorder}
	return &http.Client{Transport: bt}, recorder
}

func TestBrowserTransport_AddsHeadersToSlackHosts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	client, recorder := newCaptureClient(t, srv)

	// Force the request to look like it's going to slack.com by rewriting Host.
	req, err := http.NewRequest("GET", srv.URL, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Host = "slack.com"
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()

	got := recorder.last
	if !strings.HasPrefix(got.Header.Get("User-Agent"), "Mozilla/5.0") {
		t.Errorf("User-Agent = %q; want Mozilla/5.0-prefixed Chrome UA", got.Header.Get("User-Agent"))
	}
	if got.Header.Get("Origin") != "https://app.slack.com" {
		t.Errorf("Origin = %q; want https://app.slack.com", got.Header.Get("Origin"))
	}
	if got.Header.Get("Referer") != "https://app.slack.com/" {
		t.Errorf("Referer = %q; want https://app.slack.com/", got.Header.Get("Referer"))
	}
	for _, h := range []string{"Accept", "Accept-Language", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest"} {
		if got.Header.Get(h) == "" {
			t.Errorf("header %s is empty; expected a value", h)
		}
	}
}

func TestBrowserTransport_MatchesSlackSubdomains(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	hosts := []string{"slack.com", "files.slack.com", "hackclub.enterprise.slack.com", "wss-primary.slack.com"}
	for _, h := range hosts {
		t.Run(h, func(t *testing.T) {
			client, recorder := newCaptureClient(t, srv)
			req, err := http.NewRequest("GET", srv.URL, nil)
			if err != nil {
				t.Fatalf("NewRequest: %v", err)
			}
			req.Host = h
			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("Do: %v", err)
			}
			resp.Body.Close()
			if recorder.last.Header.Get("Origin") == "" {
				t.Errorf("host %s: Origin header missing; expected the transport to recognize this as a Slack host", h)
			}
		})
	}
}

func TestBrowserTransport_DoesNotTouchNonSlackHosts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	client, recorder := newCaptureClient(t, srv)
	req, err := http.NewRequest("GET", srv.URL, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Host = "example.com"
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()

	if recorder.last.Header.Get("Origin") != "" {
		t.Errorf("Origin set on non-Slack host: %q", recorder.last.Header.Get("Origin"))
	}
	if ua := recorder.last.Header.Get("User-Agent"); strings.HasPrefix(ua, "Mozilla/5.0") {
		t.Errorf("browser User-Agent leaked to non-Slack host: %q", ua)
	}
}

func TestBrowserTransport_DoesNotOverrideCallerHeaders(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	client, recorder := newCaptureClient(t, srv)
	req, err := http.NewRequest("GET", srv.URL, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Host = "slack.com"
	req.Header.Set("User-Agent", "custom-agent/1.0")
	req.Header.Set("Authorization", "Bearer xoxc-test")
	req.Header.Set("Cookie", "d=test-cookie")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()

	if got := recorder.last.Header.Get("User-Agent"); got != "custom-agent/1.0" {
		t.Errorf("User-Agent was overridden: got %q, want custom-agent/1.0", got)
	}
	if got := recorder.last.Header.Get("Authorization"); got != "Bearer xoxc-test" {
		t.Errorf("Authorization was overridden: %q", got)
	}
	if got := recorder.last.Header.Get("Cookie"); got != "d=test-cookie" {
		t.Errorf("Cookie was overridden: %q", got)
	}
}

func TestBrowserTransport_HandlesNilHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()

	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// Literal request — Header is nil, URL is set, Host forces Slack-host match.
	req := &http.Request{
		Method: "GET",
		URL:    u,
		Host:   "slack.com",
	}

	client, recorder := newCaptureClient(t, srv)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	resp.Body.Close()

	if recorder.last.Header.Get("Origin") != "https://app.slack.com" {
		t.Errorf("Origin header missing after nil-Header request")
	}
}

func TestBrowserHeaders_ContainsAllRequiredKeys(t *testing.T) {
	h := BrowserHeaders()
	for _, key := range []string{"User-Agent", "Accept", "Accept-Language", "Origin", "Referer", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest"} {
		if h.Get(key) == "" {
			t.Errorf("BrowserHeaders missing %s", key)
		}
	}
}

func TestUserAgentForGOOS(t *testing.T) {
	cases := []struct {
		goos       string
		wantSubstr string
	}{
		{"linux", "X11; Linux x86_64"},
		{"darwin", "Macintosh; Intel Mac OS X"},
		{"windows", "Windows NT 10.0; Win64; x64"},
		{"freebsd", "X11; Linux x86_64"}, // unknown → linux fallback
	}
	for _, tc := range cases {
		t.Run(tc.goos, func(t *testing.T) {
			got := userAgentForGOOS(tc.goos)
			if !strings.Contains(got, tc.wantSubstr) {
				t.Errorf("userAgentForGOOS(%q) = %q; want substring %q", tc.goos, got, tc.wantSubstr)
			}
			if !strings.HasPrefix(got, "Mozilla/5.0") {
				t.Errorf("userAgentForGOOS(%q) = %q; want Mozilla/5.0 prefix", tc.goos, got)
			}
		})
	}
}
