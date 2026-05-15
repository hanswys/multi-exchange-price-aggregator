# CLAUDE.md

Repo-level guidance for Claude Code.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Runtime flows

End-to-end flow tour for engineers (polling, aggregation, broadcast,
source health, dashboard render) in [`docs/FLOWS.md`](docs/FLOWS.md).
Read after `CONTEXT.md` — it leans on the vocabulary defined there.
