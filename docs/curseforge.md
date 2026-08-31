# CurseForge listing copy

Everything CurseForge asks for, ready to paste. The **Description** is
everything below the horizontal rule; the fields above it are separate inputs
on the Create Project form.

**Project name:** `AutoPallyPower`

**Summary** (one line, 123 characters):

> A companion for PallyPower that works out your raid's blessing assignments from the composition and talents actually present.

Leading with "companion for PallyPower" is deliberate: it is the one thing a
person scanning the list needs to know, and it stops anyone installing this
expecting a replacement.

**Main category:** Buffs & Debuffs is the closest fit. Class or Raid Frames
work as additional categories if the list offers them.

**Logo:** square, 400x400, no text — lettering is illegible at list size. Must
not reproduce Blizzard artwork or in-game spell icons; CurseForge rejects
trademarked assets. The prompt used to generate it is in
[curseforge-logo-prompt.md](curseforge-logo-prompt.md).

---

AutoPallyPower is a companion for **PallyPower**. It does not replace, fork, or patch it — you need both installed.

PallyPower is excellent at *managing* paladin blessings: the grid, the timers, the raid sync, the casting. What it doesn't do is decide what the assignments should be. So before every raid somebody spends five or ten minutes clicking through the same decisions they made last week.

AutoPallyPower is the missing half. It knows what each class and spec actually wants, looks at who is in the raid tonight, and works out the assignments. Then it hands them to PallyPower.

## How it decides

Every class and spec has an ordered blessing priority — a Fury Warrior wants Salvation, then Might, then Kings; an Elemental Shaman wants Salvation, then Kings, then Wisdom. These ship as editable defaults, not hard-coded rules.

Some entries are conditional on the raid, because some blessings are worthless in the wrong one. Blessing of Light does nothing without a Holy paladin casting Holy Light on the target, so it is only ever offered when there is one. Sanctuary needs a Protection-talented paladin to exist at all.

**A tank never keeps Salvation.** That is a hard constraint, not a preference, and the solver cannot produce a plan that violates it.

Because a greater blessing hits a whole class at once, the class-wide choice follows whoever is in that column — which leaves outliers, usually a tank sitting among DPS. Those become per-player overrides: the same 10-minute normal blessings you would otherwise set by hand with the scroll wheel.

Given the same raid, it always produces the same plan.

## Talents are read, never assumed

Blessing of Kings is a talent that most, but not all, paladins take — and assigning it to the one who skipped it leaves a whole class column silently unbuffed. A paladin is credited with Kings or Sanctuary only once their spellbook has been seen: yours from the client directly, everyone else's from PallyPower's existing sync, which AutoPallyPower listens to rather than adding traffic of its own.

Improved blessings work the other way. A paladin specced into Improved Blessing of Wisdom casts a materially better one, so where there is a choice they should be the one to cast it. That is solved across all paladins at once, because a paladin specced into two improved blessings can only cast one per class — taking their best in isolation would strand someone else's talent.

## It tells you when assignments won't stick

Another paladin's client only accepts assignments from you if you are raid leader or assistant, or if they have **Free Assignment** enabled in PallyPower. Two things catch people out: in a party there is no assistant, so only the party leader counts; and inside an instance-finder group nobody counts at all.

AutoPallyPower reads each paladin's Free Assignment state from PallyPower's own broadcast, treats a paladin who has never spoken on that channel as not having it installed, and **skips** anyone it cannot set rather than writing a plan into your grid that nobody else received.

`/app verify` reads PallyPower's tables back and confirms what actually landed — useful for per-player overrides, which are otherwise one icon on one row of a pop-out list.

## Using it

Left-click the minimap button, or type `/app`.

- **Priorities** — edit the per class/spec orderings. Opens anywhere; it's policy, not tonight's roster.
- **Raid Plan** — the solved assignment and the override list. Needs a group.
- **Test Mode** — generate a synthetic raid and solve against it with no group at all.
- **Presets** — save a named copy of your priorities for the night that wants something different.

```
/app plan       solve and show the plan
/app preview    what applying would change
/app apply      push the plan into PallyPower
/app verify     check what PallyPower actually holds
/app status     what the addon sees, including who you can and cannot set
/app test 25 3 2 6      simulate a 25-man
```

## Known gaps

- Groupmates who set no group finder role are guesses — the client offers no API for another player's talents. `/app override <player> <PROFILE>` pins one permanently.
- Improved Blessing of Light exists in TBC but PallyPower does not broadcast it, so it cannot be credited.
- Priority reordering uses up/down buttons rather than drag and drop.

Source and issues: https://github.com/marclundgren/AutoPallyPower
