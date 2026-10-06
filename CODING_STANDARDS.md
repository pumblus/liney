# Coding Standards

## Swift

- Load `/write-swift` whenever you write, review, or migrate Swift, including inside `/implement`, `/tdd`, and `/code-review`.
- Prefer native APIs, deletion, and the smallest solution within scope.

## UI design

- `/apple-design` examples target the web: apply its principles with native UIKit/SwiftUI APIs (for example `UISpringTimingParameters`, `UIVisualEffectView`, Dynamic Type).
- Use `/emil-design-eng` for animation decisions (whether to animate, duration, easing, feedback), translated to native APIs the same way.

## Dependencies

- Build UI from system components. Custom UI frameworks, design systems, and third-party dependencies need user approval; ZIPFoundation is the one approved dependency.

## Tests

- Run the affected fixtures with in-memory stores, temporary files, and fake authentication.

## Logs

- Store temporary build/runtime logs in `.build/agent-logs/`, with private data (journal text, photo contents, precise locations) kept out.

## Commits

- Use atomic commits named `<type>[optional scope]: <description>` with `feat`, `fix`, `refactor`, `docs`, or `chore`.
- Split changes over about 20 files by purpose unless they form one regeneration output.
