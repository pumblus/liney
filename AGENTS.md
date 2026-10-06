# Liney Agent Guide

- **Scope:** read the affected scope and architecture in [MVP.md](MVP.md) before product changes. New product surface, including surface a spec adds, needs a user-approved MVP.md scope update first.
- **Code:** read [CODING_STANDARDS.md](CODING_STANDARDS.md) before changing code or dependencies, building, testing, or committing.
- **Release:** [release.md](release.md) owns checks, verification records, and distribution decisions. Only device evidence closes device and release gates.
- **Issues:** track remaining work as GitHub issues, not audit or progress documents, per `docs/agents/issue-tracker.md` and `docs/agents/triage-labels.md`.
- **Terms:** name domain concepts with [GLOSSARY.md](GLOSSARY.md); ADRs follow `docs/agents/domain.md`.
- **Workflow:** new work enters at `/grill-with-docs`, small changes at `/implement`, others' issues at `/triage` (never tickets from `/to-tickets`), stubborn bugs at `/diagnosing-bugs`, upkeep at `/improve-codebase-architecture`; `/ask-matt` when none fits.
- **Private data** (journal text, photo contents, precise locations, and anything else personal) stays out of logs and public GitHub text (issues, specs, comments).
- **Risky changes** (destructive file/git operations, schema migrations, imports, exports, privacy/security changes) need an explicit task and a rollback path. Reuse existing authorization; ask only for missing decisions or permission.
- **Real journals:** run on fixtures; open a real journal only with separate authorization.
