# Liney Agent Guide

- **Product changes:** read the affected scope and architecture in [MVP.md](MVP.md) and terms in [GLOSSARY.md](GLOSSARY.md). New product surface, including surface a spec adds, needs a user-approved scope update in MVP.md first.
- **Code:** read [CODING_STANDARDS.md](CODING_STANDARDS.md) before writing Swift, running builds or tests, designing UI, adding a dependency, or committing.
- **Verification and release:** follow [release.md](release.md) for checks, records, and distribution decisions. Finish every applicable check and report each unmet criterion with its blocker. Device and release gates need device evidence; simulator passes only support them.
- **Issues:** track remaining work (defects, features, acceptance items) as GitHub issues, with commands in `docs/agents/issue-tracker.md` and labels in `docs/agents/triage-labels.md`. Issues, specs, and comments are public: keep private data (journal text, photo contents, precise locations) out of them.

## Guardrails

- Destructive file/git operations, schema migrations, imports, exports, and privacy/security changes need an explicit task and a rollback path. Reuse existing authorization; ask only for missing decisions or permission.
- Use real journals only with separate authorization.

## Workflow

Route work through these skills; run `/ask-matt` when none clearly fits.

- **New work:** `/grill-with-docs` → (`/prototype` if a question needs runnable code) → `/to-spec` → `/to-tickets` for multi-session builds → `/implement` per ticket, clearing context between tickets. Small changes go straight to `/implement`.
- **Incoming issues:** `/triage` issues opened by others; tickets from `/to-tickets` arrive already triaged.
- **Bugs:** `/diagnosing-bugs` for anything that resists a first look, then `/retro`.
- **Upkeep:** `/improve-codebase-architecture`; domain terms and ADRs follow `docs/agents/domain.md`.
