# Issue tracker: Jira

Issues and specs live in Jira project `RAW` on https://pixegen.atlassian.net (cloudId `1eb1ad1a-6c94-4c2b-b52d-dda3ed57bfa4`). Use the Atlassian MCP tools. GitHub (`twlatl/PixelLoupe`) holds the code and pull requests, and is where the public files bug reports and feature requests (see below).

## Conventions

- **Issue types**: `Bug`, `Task`, `Subtask`. Statuses: `To Do` → `In Progress` → `Done`.
- **JQL**: `RAW` is a reserved JQL word, so always quote it: `project = "RAW"`.
- **Create**: `createJiraIssue` with projectKey `RAW`. Use `Bug` for defects, `Task` for everything else, and `Subtask` (with a parent) for pieces of a Task.
- **Read**: `getJiraIssue` with the key (e.g. `RAW-70`), including comments.
- **List**: `searchJiraIssuesUsingJql`, e.g. `project = "RAW" AND statusCategory != Done ORDER BY updated DESC`; filter by label with `AND labels = "needs-triage"`. Request only the fields you need, since full results are large.
- **Comment**: `addCommentToJiraIssue`.
- **Labels**: `editJiraIssue`, updating the `labels` field.
- **Close**: `transitionJiraIssue` to `Done` (find the transition with `getTransitionsForJiraIssue`), with a comment giving the reason.
- **Branches and PRs**: name branches `RAW-<n>-<slug>` and start commit messages with `RAW-<n>:`.

## GitHub issues from the public

The repo is public, and outside users report bugs and request features as GitHub issues (templates in
`.github/ISSUE_TEMPLATE/`, auto-labelled `bug`/`enhancement` plus `needs-triage`). Jira stays the place work is planned:

- **Triage**: `gh issue list --repo twlatl/PixelLoupe --label needs-triage`. Ask for missing details with a comment and the
  `needs-info` label; close duplicates, and things that won't be done with `wontfix` and a reason.
- **Accept**: create a Jira `Bug` or `Task` in `RAW` that links the GitHub issue (its URL in the description), comment the
  `RAW-<n>` key on the GitHub issue, and remove `needs-triage`.
- **Ship**: the PR says `Fixes #<n>` (GitHub issue) and `RAW-<n>` (Jira) so both close or update together.
- Security reports come in privately as GitHub security advisories (see `SECURITY.md`), never as public issues.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## When a skill says "publish to the issue tracker"

Create a Jira issue in `RAW`.

## When a skill says "fetch the relevant ticket"

`getJiraIssue` on the `RAW-<n>` key, with comments.

## Wayfinding operations

- **Map**: a `Task` labelled `wayfinder:map`.
- **Child ticket**: a `Subtask` of the map, labelled `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: a Jira "Blocks" issue link (`createIssueLink`). A ticket is unblocked when all its blockers are `Done`.
- **Frontier**: the map's open subtasks with no open blocker and no assignee, in key order.
- **Claim**: assign it to yourself and transition it to `In Progress`.
- **Resolve**: comment with the answer, transition to `Done`, and add a pointer (summary + key) to the map's description.
