# Coding Standards

## Native first

**Native** means Apple frameworks and system components. Prefer native APIs, deletion, and the smallest solution within scope.

- Third-party dependencies, custom UI frameworks, and design systems need user approval; ZIPFoundation is the one approved dependency.
- `/apple-design` and `/emil-design-eng` write for the web: apply their principles with native UIKit/SwiftUI APIs (for example `UISpringTimingParameters`, `UIVisualEffectView`, Dynamic Type).

## Swift

Load `/write-swift` for all Swift work, including inside `/implement`, `/tdd`, and `/code-review`.

## Verification

**Fixtures** are in-memory stores, temporary files, and fake authentication.

- Run the affected fixtures for every code change.
- Finish every applicable check and report each unmet criterion with its blocker.
- Write temporary build and runtime logs to `.build/agent-logs/`.

## Commits

- Commit atomically as `<type>[optional scope]: <description>`, with type `feat`, `fix`, `refactor`, `docs`, or `chore`.
- Split changes over about 20 files by purpose unless they form one regeneration output.
