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
- A player header shorter than `kinds.unit.minLines` (name + level, mode 2): `EditPlayerLines` keeps the class line as an empty line (`SPACE_LINE`, a space: an empty text is only ~2 px high) and counts it into the header, so the client fills the portrait height by itself and no pad texture is needed; only the faction line is removed.
- A header whose last line holds inline icons (class / faction on the level line) is not top-aligned: `ApplyLayout` leaves its `JustifyV` alone, so the client centers the icons and the text itself (a top-aligned line had its icons lower than the text by `(icon - font size) / 2`; lifting them by hand was tried and dropped, the client does it right).
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

## Battlegrounds and combat: hidden identity of units
Unit tooltips are in one of three states (all three seen in logs):
1. Everything readable (outside a match, allies, NPCs): text, data, GUID and the unit token of the tooltip are plain.
2. The unit token from `TooltipUtil.GetDisplayedUnit` is secret, text and GUID may still be plain.
3. Everything secret: the text of the lines (`GetText`, data lines, colors, widths) and the GUID of the data (absent). Only the line types (`type=`), the number of lines and fonts stay plain.
- The plain literal `"mouseover"` works where the secret token does not (`SetPortraitTexture` takes a secret token only from untainted code). `OnUnit` falls back to `"mouseover"`; `RequestPortrait` asks again only while the unit exists (otherwise the portrait vanishes at once while the tooltip fades).
- Measured for an enemy player target in a match / in combat: plain `UnitIsPlayer`, `UnitName`, `UnitLevel`, `UnitFactionGroup`, `GetGuildInfo`, `UnitIsEnemy`, `UnitReaction`, `UnitExists`, `UnitIsVisible`; secret `UnitClass`, `UnitRace`, `UnitSex`, `UnitIsPVP`, `UnitCreatureType`, `UnitGUID` (and `GetPlayerInfoByGUID`). The chat shows secret values but an addon can't read them; "<SECRET>" in a chat-copy addon is the same thing.
- `SecretUnitHeaderCount`: in a battleground the last line of a player is always "PvP", so the header is every line before it; elsewhere a secret player's header = name, guild (if `GetGuildInfo("mouseover")`), level, class, faction; other units: plain lines after the name by line type (`UnitOwner` counts). No class/faction icons in state 3 (class unknown, secret lines can't be removed).
- `MoveSecretPvp`: in a battleground (`IsInInstance()` -> "pvp") every player is flagged and the last line is "PvP": its secret text is passed to the right column of the name line with `SetFormattedText("%s", text)` and the line is emptied (a blank row stays).
- `HideSecretFaction` (player in a match, all secret): the line before "PvP" is the faction; its crest (from `UnitFactionGroup("mouseover")`, plain; the opposite of our faction for an enemy as a fallback) is drawn as a texture at the start of the class line, which is indented with spaces; in mode 1 the faction text goes to the right column of the class line; the faction line is emptied and leaves the header.
- Pets: the line of the type `UnitOwner` identifies a pet when the text is secret; its last line is "PvP" in a battleground as well. With readable text the "PvP" of a pet (no faction line takes it) goes next to the name like a player's.
- The option "Skip enemy players and pets in battlegrounds (Unstable)" (default off) uses only plain calls (`IsInInstance`, `UnitIsEnemy`, `UnitIsPlayer`, the owner line).
- `UnitIsUnit` / comparisons of units return secret booleans there: never test them in `if` without `issecret`.
- Portrait events: `UNIT_PORTRAIT_UPDATE` / `UNIT_MODEL_CHANGED` and a few timed retries re-request the portrait (a build that asks once can get an empty portrait of an enemy). A request while the data is processed gave no portrait in a match; one at `Show` did.
- Two builds in one frame happen (`dataInstanceID` +1): the deferred header check runs once per frame, so the debug output of the first build has no `header check`. `/tti debug` marks every build with `======== #n ... ========` and tags the deferred lines with `#n`.
- Blank rows (`"\n "`) appended to a secret line did not add height and broke the name (truncated, text under the icon): don't use them to enforce a minimum icon size.
- Minimum portrait height of a unit in the all-secret state (works): `ShowIcon` computes the missing rows (`st.extraRows`, minimum height of the kind minus the header block, in rows of the last line), `ApplyLayout` writes half of them as `"
"` before the indent and half after the secret text (`SetFormattedText`), so the name stands in the middle (a leading `"
"` is kept, a trailing row needs an invisible character `"
|c00000000.|r"`: the engine drops trailing empty rows); the last header line gets the word wrap back (`SetWordWrap(true)`, `SetHeight(0)`, `SetMaxLines(0)`) after `SetHeaderFlow` turned it off: with the wrap off only the first row is shown, cut off with an ellipsis ("Searing Blade Warlo..."), which looked like a width problem. The same rows are used for a unit header of ONE line with a readable text ("name only"): a pad texture on that line leaves the name low (the inline texture sits on the baseline), the rows put it in the middle. Do not widen the tooltip for secret headers: the engine sizes it for the indented text itself.
|c00000000.|r"`) at the end of a secret last header line (with `SetHeight(0)`) are the current attempt to keep the minimum portrait height of a unit in the all-secret state; earlier tries (blank rows, a pad in the right column) failed. The name got an ellipsis because the texts of a secret header can't be measured and the tooltip was not widened for the indent: the frame and the header lines are widened by the indent (`size + gap`) in `ShowIcon`.
|c00000000.|r"`) with `SetHeight(0)` did not work either: the engine fixes the height of a line to its original text, the extra rows are cut off and the name gets an ellipsis (`Searing Blade Warlo...`) while the portrait grows over the body lines. Three tricks failed (blank rows, a pad in the right column, invisible rows): in the all-secret state the icon is as high as the header block.
- A pad texture put into the right column of a secret last header line (the text there is ours, so the texture is drawn) shifted the text of the other header lines under the icon: there is no way found to enforce the minimum portrait height in the all-secret state (the icon is as high as the header block).

## Locale-dependent line detection
- The level line of a unit is found by the game's templates first; they miss in other locales (ruRU: template `%d-й уровень` vs the line "6-го уровня", player line "Нежить, 9-го уровня" with a comma). The fallback uses `UnitLevel` + `UnitRace` / `UnitCreatureType` (or the race of the GUID / the creature type on the next line).
- The line holds the level inside a color code (`|cffffd100` + `12-го уровня` + `|r`): the digits of the code stick to the level. Strip color codes before looking for digits.
- The tooltip writes `??` instead of the level of a unit far above ours (a red color code) while `UnitLevel` still returns the real level (34): the level line is accepted when it holds the level digits OR `??`. `/tti debug` prints `level line search: ...` per line for this.
- NPC faction line: joins the header when "PvP" follows it or when its text is the name of a faction (`C_Reputation.GetFactionDataByID(1..3500)` names, built once, `IsFactionName`).
- Class of a player from the text of the class line: `LOCALIZED_CLASS_NAMES_MALE/FEMALE`; faction from `FACTION_ALLIANCE` / `FACTION_HORDE`. `GetPlayerInfoByGUID` returns 8 values, the 8th is the race ID (`C_CreatureInfo.GetFactionInfo(raceID)` gives the faction).
- Unit data from `C_TooltipInfo`: the lines of the data hold `leftText` as sent by the engine; a text such as "Scarce" (an item rarity line, color `87ABFF`) is not in any Lua file, `GlobalStrings` or addon.

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
- Other locales use positional format arguments and plural markup in the same globals (ruRU `CONTAINER_SLOTS` = `%2$s (%1$d |4ячейка:ячейки:ячеек;)`): `BuildPatterns` strips `%1$` and turns `|4a:b:c;` into `%S+`. A raw `%1$d` made `string.find` throw "invalid capture index" in the ru client. Test new patterns against a non-English format string.
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
