# Issue tracker: Jira

Issues and specs live in Jira project `RAW` on https://pixegen.atlassian.net (cloudId `1eb1ad1a-6c94-4c2b-b52d-dda3ed57bfa4`). Use the Atlassian MCP tools. GitHub (`twlatl/PixelLoupe`) holds only code and pull requests.

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
