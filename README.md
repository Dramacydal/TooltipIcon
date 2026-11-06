# TooltipIcon

Adds icons to tooltips. The icon is drawn inside the tooltip, in the top-left corner next to the name,
without a frame; the tooltip text is shifted to the right of it.

Made for **WoW: Forever**. Lightweight: no libraries, no frames of its own.

## Supported tooltips

| Tooltip | Icon |
| --- | --- |
| Spells — spellbook, action bars, macros, spell links | spell icon |
| Talents — standard interface and the talent window of ClassicUIForever | spell icon |
| Buffs and debuffs | aura icon |
| Items — bags, loot, vendors, item links, comparison tooltips | item icon |
| Toys | toy icon |
| Companion pets | pet icon |
| Mounts | mount icon |
| Transmog appearances — wardrobe and the transmogrifier | item icon |
| Units — players and NPCs | portrait |

## Features

- Icon inside the tooltip instead of next to it.
- A master switch and a checkbox for every tooltip category in the settings.
- **Items:** the item properties (binding, item level, slot, Unique, Conjured Item, Quest Item,
  Crafting Reagent, Cosmetic, Toy, bag size) are shown next to the icon.
- **Talents:** the rank (`Rank 0/5`) is shown next to the icon.
- **Units:**
  - NPCs: the faction, `PvP` and `Skinnable` are shown on the same lines as the level and the creature type.
  - Players: the class and the faction are shown either on one line, or as a class icon and a faction
    crest before the level; `PvP` is shown next to the name.
  - Optional class color for player names.
- Works in every client language; the settings are localized (enUS, ruRU, deDE, frFR, esES, esMX, zhCN).

## Settings

Esc → Options → AddOns → TooltipIcon, or `/tti`.

- **Show icons in tooltips** — master switch.
- **Tooltip categories** — Spells, Buffs and debuffs, Items, Toys, Companion pets, Mounts, Transmog
  appearances, Units.
- **Units:**
  - **Player class and faction** — *Faction on the class line* (default) or *Class and faction icon on
    the level line*.
  - **Color player names by class** — on by default.

## Commands

- `/tti`, `/tti options` — open the settings.
- `/tti on`, `/tti off`, `/tti toggle` — turn all icons on or off.
- `/tti class 1|2` — player class and faction mode.
- `/tti size <n>` — minimum icon size in pixels (default 32); `/tti gap <n>` — gap between the icon and
  the text (default 6).
- `/tti reset` — back to the defaults.
- `/tti debug` — shows how the addon reads the tooltip you hover over (please attach the output to a bug
  report).

`/tooltipicon` works as the long form of `/tti`.

## How it works

The game lays out the tooltip text itself, so the text is shifted with a transparent inline texture
(`blank.tga`) in front of the first lines; the icon is a texture on the tooltip. Layout measurements are
cached for the session. Values the client hides from addons are never used in calculations: a tooltip that
cannot be read is left untouched.

## Installation

Copy the `TooltipIcon` folder to `Interface/AddOns`. The addon loads on WoW: Forever only
(`TooltipIcon_Camelot.toc`).

## License

MIT, see `LICENSE`.
