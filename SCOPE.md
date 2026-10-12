# Liney Scope

This document owns Liney's product boundaries: the invariants every change keeps, what Liney leaves out, and which feature document owns each area's behavior. What Liney is and how to build it: [README.md](README.md).

- **Domain Terms**: [GLOSSARY.md](GLOSSARY.md)
- **Future Directions** (not approved scope): [ROADMAP.md](ROADMAP.md)
- **Code Map**: [docs/agents/architecture.md](docs/agents/architecture.md)

## Changing Scope

New product surface starts only after the user approves it. Record the approval here and in the affected feature document before building: a Feature Map line for a new area, and the area's stories and behavior rules in `docs/features/`.

Each kind of document holds one thing:

- **SCOPE.md**: boundaries that hold for every change.
- **Feature document** (`docs/features/*.md`): the current behavior of one area. It owns that area's stories and rules. Story numbers are stable acceptance references used by `release.md`; a new story takes the next unused number across all feature documents.
- **Build plan**: a GitHub issue from `/to-spec`, split into tickets by `/to-tickets`. It holds how one build gets done (seams, tests, ticket order) and points to the feature document for behavior. It closes when the build lands.

## Invariants

- **Local-Only & Private**: All content persists on the device via SwiftData and the app sandbox.
- **Apple Native**: iOS/iPadOS 17 minimum, adapted through 27.1. System UIKit components only: a Split View root, system navigation, SF Symbols. Liney Aqua is an accent and tint.
- **Content Model**: Entries hold plain-text blocks and photo groups. The one exception is checklist markers (`☑ ` / `☐ `) inside text blocks.
- **Single Journal**: All entries live in one journal, ordered by Entry Date, newest first.

## Non-Goals

Liney stays a calm, single-device journal. These stay out unless the user approves a scope change:

- **Cloud & Accounts**: iCloud sync, remote servers, accounts, analytics, tracking SDKs.
- **Rich Media**: audio, video, PDF, generic file attachments, in-app camera, photo captions.
- **Complex Organization**: tags, multiple journals, reminders, streaks, writing prompts, AI features.
- **Formatting**: rich text styles, in-editor Markdown rendering, manual block reordering.
- **Location Services**: background location, live location permission, embedded maps, manual place search.

## Feature Map

Read the feature document for the area a change touches.

| Area | Feature document |
|---|---|
| Launch, timeline, search, entry deletion | [timeline-and-search.md](docs/features/timeline-and-search.md) |
| Editor, photos, Photo Info, photo detail | [editor-and-photos.md](docs/features/editor-and-photos.md) |
| Day One Import | [day-one-import.md](docs/features/day-one-import.md) |
| Markdown Export | [markdown-export.md](docs/features/markdown-export.md) |
| App Lock, privacy copy | [app-lock.md](docs/features/app-lock.md) |
| Width adaptation, Split View, iPhone Duo, Entry Windows | [duo-and-windows.md](docs/features/duo-and-windows.md) |
| Native UI, accessibility, localization, distribution | [platform-and-accessibility.md](docs/features/platform-and-accessibility.md) |
