# Platform & Accessibility

This document owns native UI rules, accessibility, localization, and distribution: the behavior every screen shares.

- Scope: [SCOPE.md](../../SCOPE.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: app-wide (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

- **Story 64**: Support VoiceOver across writing, browsing, import, export, and App Lock.
- **Story 65**: Adapt the interface to Dynamic Type.
- **Story 66**: Follow system dark mode.
- **Story 67**: Localize the app in English and Simplified Chinese.
- **Story 68**: Release free, without in-app purchases, subscriptions, or ads.

## 2. Implementation Decisions

### Native UI
- Follow Apple's Human Interface Guidelines for layout, navigation, accessibility, Dynamic Type, dark mode, and localization.
- Use system UIKit surfaces: system lists and sections, sheets, forms, alerts, confirmation dialogs, menus, `UIDatePicker`, `PHPickerViewController`, the share sheet, and SF Symbols. Liney has no custom UI framework or design system.
- Liney Aqua is the app tint only, never a full-screen background.
- Build with the iOS 27.1 SDK so iPhone Duo runs edge to edge. iOS 27.1-only APIs sit behind availability checks. Layout never detects device model, idiom, or orientation.
- Check release-facing UI, privacy, and metadata against the current App Store Review Guidelines before submission.

### Localization
- UI copy ships in English and Simplified Chinese (`zh-Hans`). Imported user content is not translated.
- Dates and place names follow the system locale.
- App Store metadata is prepared in both languages; approved drafts live in `release.md`.

### Distribution
- Free, with no in-app purchases, subscriptions, ads, analytics, tracking SDK, account system, or backend.
- `ZIPFoundation` is the only approved third-party dependency, because ZIP correctness is better served by an established library than a custom archive implementation. Any other dependency needs explicit user approval.
