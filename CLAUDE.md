# PixelLoupe

Project rules for people and agents are in `SKILLS.md`. Read it before making changes.

## Agent skills

### Issue tracker

Work is tracked in Jira (project `RAW` on pixegen.atlassian.net) through the Atlassian connector. GitHub (`twlatl/PixelLoupe`) holds the code and PRs, and takes bug reports and feature requests from the public as GitHub issues, which are triaged into Jira. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), applied as Jira labels. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
