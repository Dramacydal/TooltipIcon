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
| Currencies — character window, vendors, currency links | currency icon |
| Transmog appearances — wardrobe and the transmogrifier | item icon |
| Units — players, NPCs and pets | portrait |

## Features

- Icon inside the tooltip instead of next to it.
- A master switch and a checkbox for every tooltip category in the settings.
- Size of the icon, the gap between the icon and the text, an optional icon border, optional round
  portraits.
- **Name only** option for spells, items, toys, companion pets, mounts and units: only the name stays
  next to the icon, the other lines go below it.
- **Items:** the item properties (binding, item level, slot, Unique, Conjured Item, Quest Item,
  Crafting Reagent, Cosmetic, Toy, bag size) are shown next to the icon.
- **Talents:** the rank (`Rank 0/5`) is shown next to the icon.
- **Units:**
  - NPCs: the faction and the creature type are shown next to the portrait; `PvP` and `Skinnable` are
    shown on the same lines as the faction and the level.
  - Players: the class and the faction are shown either on one line, or as a class icon and a faction
    crest before the level (their sizes and shifts are adjustable); `PvP` is shown next to the name.
  - Pets: the owner, the level and the creature type are shown next to the portrait; `PvP` is shown next
    to the name.
  - Optional class color for player names.
- **Battlegrounds and combat:** the game hides most data of enemy players there (class, race, and in
  some cases the text itself). The addon shows what the client allows: the portrait, the name, the level,
  the guild, the faction, the `PvP` mark. An option skips these tooltips completely.
- Works in every client language; the settings are localized (enUS, ruRU, deDE, frFR, esES, esMX, zhCN).

## Settings

Esc → Options → AddOns → TooltipIcon, or `/tti`.

- **Show icons in tooltips** — master switch.
- **Minimum icon size**, **Gap between the icon and the text**, **Show the icon border**.
- **Tooltip categories** — Spells, Buffs and debuffs, Items, Toys, Companion pets, Mounts, Transmog
  appearances, Currencies, Units. Spells, Items, Toys, Companion pets, Mounts and Units have a
  **Name only next to the icon** option.
- **Units:**
  - **Player class and faction** — *Class and faction icon on the level line* (default) or *Faction on
    the class line*.
  - **Color player names by class** — on by default.
  - **Show round portraits** — off by default.
  - **Skip enemy players and pets in battlegrounds (Unstable)** — off by default.
  - **Faction icon size / shift** and **Class icon size / shift** — size 10–32 and shift −10…10 pixels of
    the icons on the level line.
- **Reset to Defaults** — a button at the end of the page: every option back to its default (same as
  `/tti reset`).

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

## Installation

Copy the `TooltipIcon` folder to `Interface/AddOns`. The addon loads on WoW: Forever only
(`TooltipIcon_Camelot.toc`).

## License

MIT, see `LICENSE`.
