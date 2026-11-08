# Architecture

## Files
- `TooltipIcon.lua` — everything except the settings UI: constants, line helpers, layout, kinds, unit edits, handlers, `ns.*` accessors, slash command, startup (db defaults and clamping in the `ADDON_LOADED` block).
- `Settings.lua` — `ns.RegisterSettings`: master checkbox, size/gap sliders, icon border, per-kind checkboxes with "name only" children, Units children (class/faction mode dropdown, color by class, round portraits, class/faction icon size and shift sliders). `ns.ResetSettings` resets every registered setting (`/tti reset`).
- `Locale/` — globals `TTI_*`; enUS unconditional, the others wrapped in `if GetLocale() == ...`.
- `blank.tga` — 8x8 transparent texture used as the inline spacer.

## How a tooltip is changed
1. A post-hook of `tooltip:ProcessInfo` (runs after all post-calls of all addons) dispatches by `tooltipData.type` to a handler (`OnSpell`, `OnItem`, `OnUnit`, ...), which calls `ShowIcon(tooltip, tooltipData, kind, texture)`.
2. `kinds[kind]` describes the kind: `maxHeader`, `isDescription` or `headerCount`, `isPromoted`, `edit`, `minLines`, `bodyGap`, `padTop`, `nameOnlyKey`, `category`, `noBorder`.
3. The header lines are prefixed with a transparent inline texture (`blank.tga`, as wide as icon + gap); the last header line also gets a tall pad texture when the icon is higher than the header block. The layout is corrected in the next frames (`Correct`, `FitHeader`) and cached in memory (`layoutCache[kind][count]`, never saved).
4. `st.applied[i]` holds the text written to header line i; a next-frame driver compares it with the line. A mismatch means another addon rewrote the line: the hooks are re-registered after `REHOOK_DELAY` (max `MAX_REHOOKS`, then one chat warning).
5. Unit tooltips are rearranged first (`EditUnitLines`): class and faction lines become inline icons on the level line, PvP / Skinnable move to the right column, the name is class-colored.

## Inline icons on the level line
Sizes and shifts come from `db.classIcon*` / `db.factionIcon*`. The last header line that holds them keeps the default vertical alignment (the client centers icons and text); the pad texture only raises the line to the portrait height.
