package slackclient

import "testing"

func TestSubdomainFromTeamURL(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"https://truelist-workspace.slack.com/", "truelist-workspace"},
		{"https://hackclub.enterprise.slack.com/", "hackclub.enterprise"},
		{"https://slack.com/", ""},
		{"https://evil.example.com/", ""},
		{"", ""},
		{"::not-a-url::", ""},
	}
	for _, c := range cases {
		if got := subdomainFromTeamURL(c.in); got != c.want {
			t.Errorf("subdomainFromTeamURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
