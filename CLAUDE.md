# CLAUDE.md — TooltipIcon

WoW addon for the Forever client (Interface 16001, retail 12.x engine): draws the icon inside the tooltip (top-left, no frame), shifts the header lines to its right, the body stays below. Entry point for Claude Code agents; deeper reference in [`.claude-docs/`](.claude-docs/index.md).

## Documentation index
- [.claude-docs/index.md](.claude-docs/index.md) — routing table; start here when unsure
- [.claude-docs/gotchas.md](.claude-docs/gotchas.md) — non-obvious footguns (read before touching layout, hooks or combat code)
- [.claude-docs/architecture.md](.claude-docs/architecture.md) — files, kinds, layout, hooks

## Commands
- No build step and no Lua compiler on the dev machine: changes are tested in game (`/reload`), the user reports screenshots, Lua errors and `/tti debug` output.
- `/tti` opens the options; `/tti on|off|toggle|size <n>|gap <n>|reset|debug`.
- Wipe the saved variables: `/run wipe(TooltipIconDB) ReloadUI()`.

## Boundaries
### MUST
- Wrap every measurement read from a tooltip line (width, height, font size, color) in `Plain()` / `issecret` checks: values are secret in combat.
- Keep code comments short and factual.
- Put new user-visible strings (`TTI_*`) in all six `Locale/` files.
### MUST NOT
- Never call `SetMinimumWidth` on a tooltip (see gotchas).
- Never say a change works in game: it can't be run here. Say it is untested.
- Don't mention "Classic+" anywhere; third-party addon tooltips are out of scope.
- Don't update README.md / CURSEFORGE.md for new options unless asked.

## Workflow
- Only toc: `TooltipIcon_Camelot.toc`. Settings UI: `Settings.lua` (style reference: `..\TerrainWorldMap`); main logic: `TooltipIcon.lua`.
- Edit Lua via the Edit tool or a python script run with `python -I`; non-ASCII strings and `\n` inside Lua strings are safe only from a file written with the Write tool (a bash heredoc once produced a raw newline inside a Lua string).
