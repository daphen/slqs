package image

import "testing"

// TestTeamIDFromFilesURL_HostCheck verifies that team-ID extraction
// requires the URL host to be exactly files.slack.com. A previous
// implementation used strings.Contains, which let hostile URLs that
// merely embedded "files.slack.com/files-pri/..." in their path or
// query trigger auth attachment, leaking the workspace's xoxc Bearer
// and 'd' cookie to the attacker.
func TestTeamIDFromFilesURL_HostCheck(t *testing.T) {
	cases := []struct {
		name string
		url  string
		want string
	}{
		// Legitimate Slack file URLs — must keep working.
		{
			name: "files-pri canonical",
			url:  "https://files.slack.com/files-pri/T01ABCDEF-F0123/foo.png",
			want: "T01ABCDEF",
		},
		{
			name: "files-tmb canonical",
			url:  "https://files.slack.com/files-tmb/T01ABCDEF-F0123/foo_360.png",
			want: "T01ABCDEF",
		},
		{
			name: "files canonical (no team-suffix split)",
			url:  "https://files.slack.com/files/T01ABCDEF/foo.png",
			want: "T01ABCDEF",
		},
		{
			name: "with query string",
			url:  "https://files.slack.com/files-pri/T01ABCDEF-F0123/foo.png?t=abc",
			want: "T01ABCDEF",
		},

		// Spoofing vectors — must NOT extract a team ID.
		{
			name: "attacker host with files.slack.com in path",
			url:  "https://attacker.com/files.slack.com/files-pri/T01ABCDEF/x.png",
			want: "",
		},
		{
			name: "attacker host with files.slack.com in query",
			url:  "https://attacker.com/x?u=https://files.slack.com/files-pri/T01ABCDEF/x.png",
			want: "",
		},
		{
			name: "subdomain spoof",
			url:  "https://files.slack.com.attacker.com/files-pri/T01ABCDEF/x.png",
			want: "",
		},
		{
			name: "userinfo spoof",
			url:  "https://files.slack.com@attacker.com/files-pri/T01ABCDEF/x.png",
			want: "",
		},

		// Non-matches that should remain non-matches.
		{name: "empty", url: "", want: ""},
		{name: "garbage", url: "::not a url::", want: ""},
		{name: "unrelated host", url: "https://example.com/files-pri/T01ABCDEF/x.png", want: ""},
		{name: "slack.com root, not files.", url: "https://slack.com/files-pri/T01ABCDEF/x.png", want: ""},
		{name: "files.slack.com but unknown path prefix", url: "https://files.slack.com/api/foo", want: ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := teamIDFromFilesURL(tc.url)
			if got != tc.want {
				t.Errorf("teamIDFromFilesURL(%q) = %q, want %q", tc.url, got, tc.want)
			}
		})
	}
}
