# Liney Agent Guide

- **Product changes:** Read the affected scope and architecture in [MVP.md](MVP.md) and terminology in [GLOSSARY.md](GLOSSARY.md). New product surface, including surface a spec adds, requires an explicit user-approved scope update in MVP.md first.
- **Verification and release:** Use [release.md](release.md) for checks, verification records, and distribution decisions. Track remaining work (defects, features, acceptance items) as GitHub issues; don't create audit or progress documents.
- **Coding standards:** Read [CODING_STANDARDS.md](CODING_STANDARDS.md) before writing code, adding a dependency, or committing.
- Destructive file/git operations, schema migrations, imports, exports, and privacy/security changes need an explicit task and rollback path. Reuse existing authorization; ask only for missing decisions or permission.
- Run affected fixtures with in-memory stores, temporary files, and fake authentication. Real journals require separate authorization. Finish applicable checks and report unmet criteria with blockers; simulator passes cannot complete device/release gates.
- Store temporary build/runtime logs in `.build/agent-logs/`. Keep journal text, photo contents, precise locations, and other private data out of logs.

## Development workflow

All work follows Matt Pocock's skill flow; run `/ask-matt` when unsure which skill fits.

- **New work:** `/grill-with-docs` → (`/prototype` if a question needs runnable code) → `/to-spec` → `/to-tickets` for multi-session builds → `/implement` per ticket, clearing context between tickets. Small changes go straight to `/implement`.
- **Building:** `/implement` drives `/tdd` and closes with `/code-review`. Write PR bodies with `/pr`.
- **Incoming issues:** `/triage` issues you didn't create; never triage tickets from `/to-tickets`.
- **Bugs:** `/diagnosing-bugs` for anything that resists a first look, then `/retro`.
- **Upkeep:** `/improve-codebase-architecture`, with `/codebase-design` for module shape and `/domain-modeling` for terms and ADRs.
- Specs, tickets, and comments are public, so follow the privacy rule in `docs/agents/issue-tracker.md`.

## Swift and design skills

- `/write-swift`: use whenever writing, reviewing, or migrating Swift, including inside `/implement`, `/tdd`, and `/code-review`; also for concurrency errors, hangs, retain cycles, and performance problems.
- `/apple-design`: use when designing or reviewing gestures, springs, sheets, swipe/drag, interruptible transitions, materials, typography, and reduced motion. Its examples target the web; apply the principles with native UIKit/SwiftUI APIs (for example `UISpringTimingParameters`, `UIVisualEffectView`, Dynamic Type) rather than porting web code.
- `/emil-design-eng`: use for UI polish and animation decisions (whether to animate, duration, easing, feedback details). Translate to native APIs the same way.
- `/pick-ui-library`: user-invoked only. Its list covers web/React libraries, so it rarely applies here.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `pumblus/liney`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.
