# Coding Standards

## Native first

**Native** means Apple frameworks and system components. Prefer native APIs, deletion, and the smallest solution within scope.

- Third-party dependencies, custom UI frameworks, and design systems need user approval; ZIPFoundation is the one approved dependency; its source is at `.build/os27/SourcePackages/checkouts/ZIPFoundation` after `scripts/test` runs.
- `/apple-design` and `/emil-design-eng` write for the web: apply their principles with native UIKit/SwiftUI APIs (for example `UISpringTimingParameters`, `UIVisualEffectView`, Dynamic Type).

## Swift

Load `/write-swift` for all Swift work, including inside `/implement`, `/tdd`, and `/code-review`.

## Verification

**Fixtures** are in-memory stores, temporary files, and fake authentication.

- Run tests with `scripts/test` (`--help` for usage): the affected suites while iterating, `scripts/test --all` (iPhone, then iPad) before committing.
- Shared fixture helpers (photos, in-memory stores, authenticators, alerts, view lookup) live in `LineyTests/TestSupport.swift`; `scripts/lint` rejects per-suite copies.
- The pre-push hook runs `scripts/lint` and `scripts/test --all`; enable it once per clone with `git config core.hooksPath .githooks`.
- Finish every applicable check and report each unmet criterion with its blocker.
- Write other temporary build and runtime logs to `.build/agent-logs/`.

## Commits

- Commit atomically as `<type>[optional scope]: <description>`, with type `feat`, `fix`, `refactor`, `docs`, or `chore`.
- Split changes over about 20 files by purpose unless they form one regeneration output.
