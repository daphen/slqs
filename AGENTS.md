# AGENTS.md — slqs

Instructions for any coding agent working in this repo.

## Changelog trailers (drive the in-app "What's new" modal)

slqs shows a "What's new" modal when a newer build is available, built from
`Changelog:` commit trailers: the daemon pulls the commits between the running
build and latest (GitHub compare API) and keeps only their `Changelog:` lines.
So when you commit here:

- **User-facing change** (new feature, changed behavior, a bug fix the user
  would notice, a visible UI change) → add exactly ONE `Changelog:` trailer to
  the commit body: a plain, present-tense sentence written FOR THE USER, not a
  restatement of the diff. Example:

      feat: timed channel mute

      Changelog: You can now mute channels — press m on one in the sidebar

- **Plumbing** (vendored-QsLib refreshes, `sync-ui.sh` syncs, refactors, flake
  bumps, CI, test-only) → NO trailer; it must not appear in the changelog.
- One trailer per commit; split a multi-feature commit, else write the single
  most important line.
- The subject line stays conventional (for git history); the trailer is the
  user-facing summary — they may differ.

Never mention AI tooling / Claude / Anthropic in commit messages or trailers.
