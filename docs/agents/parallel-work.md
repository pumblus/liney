# Parallel work

For an orchestrator running subagents in worktrees (`/implement-spec`), and for the implementer and merger subagents it starts. Pass this file to each subagent as a context pointer.

## Implementer

- Read the spec sections and user stories your ticket cites, not only the ticket. Where the code you build differs from the spec's wording, report it in your hand-back as an unmet acceptance criterion; the orchestrator or the user decides.
- Run tests with your own simulator slot: `LINEY_SIM_SLOT=<n> scripts/test ...`, with `<n>` given by the orchestrator.
- Run each `git` command as its own Bash call inside your worktree, and read other worktrees with the Read tool by absolute path. The worktree guard refuses compound commands that contain `git` or `cd` elsewhere.

## Merger

- Before merging a ticket branch, review its diff against the spec's user stories for that ticket only. Send any gap back to the implementer instead of merging.

## Orchestrator

- Run exploration whose notes later subagents read as general-purpose: it must write the notes file, and every implementer builds on it. Send single lookups to Explore.
- Give each concurrent implementer a distinct slot number. After the run, `scripts/test --remove-slots` deletes the clones.
- In the PR body, write one `Closes #<n>` line per issue: GitHub closes only the first number of a comma list.
- Remove the integration worktree as soon as the PR is open, so `gh pr merge --delete-branch` can delete the local branch.
