# Gotchas

## Header text is changed by others after us
- The game appends text to a header line after `ProcessInfo` (e.g. the key binding ` (F10)` of a bag on the bag bar). `HeaderOverwritten` therefore treats a line that still *starts with* `st.applied[i]` as intact, and `ApplyLayout` carries the appended tail over when it rewrites the line. Comparing the whole line caused false "Another addon keeps rewriting..." warnings with no other addon loaded.
- `rehooks` is cumulative for the session, so a few false positives add up to the warning. `/tti debug` prints the line, expected and found text of every detected mismatch.
- Leatrix Plus rewrites unit lines inside post-calls of `ProcessInfo`; our post-hook runs after them.

## Layout
- `SetMinimumWidth` makes the engine stop wrapping body text and stretches the tooltip: never use it. Widen with `SetPadding` (right) + `SetWidth` on the cut header lines.
- Every tooltip line has word wrap on: header and body can't be told apart by wrapping.
- An inline texture's width scales with the font of the line (header 14 vs body 12): the spacer is calibrated with `GetStringWidth`.
- A tall inline texture raises the whole line and bottom-aligns its text; a line is `PAD_DESCENT` (4 px) taller than its pad texture. Units keep text at the top (`padTop`, `JustifyV TOP` on both columns, right text padded too).
- In a line with `JustifyV TOP` the icons are aligned to the line top as well: their center is lower than the text center by `(icon - font) / 2`; lift them by that. In a line without pad both are centered together: no lift.
- The engine sets width/wrap of header FontStrings for the original text; the addon turns wrap off and width 0 while shown and restores only what it changed (`st.flow`).
- Data line index != screen index (empty data lines are skipped on screen): use `DataLine` by `lineIndex`.
- Line types (`type=`) are mostly 0/nil in this client: recognize lines by text and global constants (`BuildPatterns` / `MatchesAny`).
- `FontString:GetStringHeight` equals the font size for any text ("x" and "X" alike): glyph heights can't be measured. Derive offsets from font size and icon size, not from tuned constants.

## Combat (secret values)
- Widths, heights, text and colors of tooltip lines can be secret. Read through `Plain()`; secret text is only passed on via `SetFormattedText(prefix .. "%s", text)` / `SetText`.
- Addon textures (`blank.tga`) are not drawn in a line with secret text: such lines are indented with plain spaces (`SpaceWidth`, measured with a FontString of our own), no vertical pad, the icon is as high as the header block. A ~1 px misalignment is accepted.
- The em space (U+2003) is missing in the tooltip font: only plain spaces work as an indent. Unit names and levels are secret in combat (the header is the name only).
- Remembering a spell's header per spell to get the layout in combat was rejected (the simpler space indent works).
- `a and f()` truncates multiple return values; `GetText()` of an empty line is `nil`.

## Lua / tooling
- Write `"/"` in texture paths in Lua source (a single `\` breaks python-generated strings).
- `\n` in a bash heredoc can become a raw newline inside a Lua string: use the Edit tool or a Write-created script, then scan for odd quotes.

## Tooltip rebuild and hooks
- The tooltip is rebuilt about every 0.2 s (ClearLines + ProcessInfo): the layout must be stable between rebuilds, hence the in-memory `layoutCache`. Handlers run in a post-hook of `ProcessInfo`, not in the per-type post-calls, so they see the final lines.
- Hooks can't be removed. `HookProcessInfo` registers a new hook behind all earlier ones and a generation counter switches the older hooks of ours off; `MAX_REHOOKS` stops endless re-hooking.
- `SetHeaderFlow(false)` must run only if the flow was applied (`st.flow`); otherwise unrelated tooltips keep stale widths. `OnTooltipCleared` resets the state, including padding added by us.
- Removing lines (class/faction line of a player) leaves an empty trailing line (+2 px height, not compensated). Rebuilding the tooltip with `ClearLines` to avoid it was tried and rejected.

## Recognizing lines
- Header detection is per kind (`isDescription` / `headerCount`). Spell header lines are white, the description is yellow, warnings red; a white line with color codes or line breaks is a long text, not a header field.
- Talent rank line ("Rank 0/1") is matched by shape with color codes stripped (`IsTalentRankLine`) and forced into the header.
- An item header line with a line break inside (a recipe line) must not join the header: it was shown as "...".
- Item header lines come from global constants (`ITEM_COSMETIC`, `PROFESSIONS_USED_IN_COOKING`, `TOY`, `CONTAINER_SLOTS`, ...). Units: `UnitCreatureType` / `UnitLevel` / `UnitClass` / `UnitFactionGroup` and `BuildPatterns` for "PvP", "Skinnable", faction lines.
- A color table from `tooltipData` (`info.leftColor`) can be secret: check `issecret(color)` before indexing.
- A debug dump of secret strings crashes: print through a `Show()` helper that handles secrets.
- Class icons: atlas `classicon-<class>`, else `CLASS_ICON_TCOORDS` of the glues texture; faction crests are textures of `Interface/TargetingFrame`.

## Settings UI
- Children of a setting get one fixed indent level (`SetParentInitializer`); the parent predicate is re-evaluated only when the parent changes, so the master switch refreshes the page by hand (`RepairDisplay`) and every child also gets `AddModifyPredicate(MasterOn)`.
- The panel's own "Defaults" button resets every game interface setting: it is hidden while our category is shown; `/tti reset` calls `ns.ResetSettings`.
- Sliders: `Settings.CreateSlider` + `CreateSliderOptions`; the `%d` label formatter works for negative values.
- Numbers from the saved variables are clamped on load (`Clamped`); changing a size/gap/offset setting must `wipe(layoutCache)`.
- Locales: non-enUS files are wrapped in `if GetLocale() == ...` (esES also covers esMX). de/fr/es/zh strings are unreviewed by native speakers.

## Docs
- README.md and CURSEFORGE.md are user-facing and concrete, without internal layout details and without a Credits section; they were not updated for the later options (user's choice).

## Debug
- `/tti debug` prints kind, id, icon, line types and colors, layout passes, pad line, header check.
