# AutoPallyPower

A companion addon for [PallyPower](https://github.com/AznamirWoW/PallyPower) (TBC Classic).

PallyPower is excellent at *managing* paladin blessings — the grid, the timers,
the raid sync, the casting. What it does not do is decide what the assignments
should be. So before every raid somebody spends five or ten minutes clicking
through the same decisions they made last week.

AutoPallyPower is the missing half: it knows what each class and spec actually
wants, looks at who is in the raid tonight, and works out the assignments. Then
it hands them to PallyPower, which does what it already does well.

It does not replace, fork, or patch PallyPower. Install both.

## How it decides

Every class/spec has an ordered wishlist — "if I could have N blessings, these
are the N I want." A Fury Warrior wants Salvation, then Might, then Kings. An
Elemental Shaman wants Salvation, then Kings, then Wisdom. These ship as
editable defaults, not hard-coded rules.

Some entries are conditional on the raid, because some blessings are worthless
in the wrong one. Blessing of Light does nothing without a Holy paladin casting
Holy Light on the target, so it is only ever offered when there is one.
Sanctuary needs a Protection-talented paladin to exist at all.

**Rule zero: a tank never keeps Salvation.** This is a hard constraint, not a
preference, and the solver cannot produce a plan that violates it.

Because a greater blessing hits a whole class at once, the class-wide choice is
made by whoever is in that column — which leaves outliers, usually a tank
sitting among DPS. Those become per-player overrides: the same 10-minute normal
blessing you would otherwise set by hand with the scroll wheel. The solver
weighs each override against a configurable threshold, so the list stays short
enough to actually use.

Given the same raid, it always produces the same plan.

## Commands

```
/app plan       solve the current raid and show the plan
/app report     show what each player would end up with
/app preview    show what applying would change
/app apply      push the plan into PallyPower
/app test 25 2 2 5      simulate a 25-man: 2 paladins, 2 tanks, 5 healers
/app test off   back to the live raid
/app tankmode threat|survival
/app override <player> <PROFILE|clear>
/app status     what the addon currently sees
```

Test mode generates a synthetic raid so you can see the engine work without
being in a group. Applying is disabled while it is on.

## Tank mode

Whether a tank's second blessing should be Might (threat) or Light (survival)
is a real judgement call that changes per guild and per fight, so it is a
setting rather than a baked-in answer. `threat` is the default.

## Installing

Copy or clone this repository into your AddOns folder. The folder **must** be
named exactly `AutoPallyPower` to match `AutoPallyPower.toc`, or WoW will not
load it.

## Development setup

Keep the repo wherever you work and symlink it into AddOns, so `git pull`
updates the addon the game actually loads and you never copy files by hand.

**macOS / Linux**

```sh
git clone https://github.com/marclundgren/AutoPallyPower.git ~/Dev/AutoPallyPower

# Adjust for your install: _classic_ for TBC/Wrath Classic,
# _classic_era_ for Classic Era, _retail_ for retail.
WOW_ADDONS="/Applications/World of Warcraft/_classic_/Interface/AddOns"

ln -s ~/Dev/AutoPallyPower "$WOW_ADDONS/AutoPallyPower"
ls -l "$WOW_ADDONS/AutoPallyPower"   # should show the arrow to ~/Dev
```

**Windows** — from a Command Prompt. A junction (`/J`) is used rather than a
symlink (`/D`) because it does not require an elevated prompt.

```bat
git clone https://github.com/marclundgren/AutoPallyPower.git %USERPROFILE%\Dev\AutoPallyPower

mklink /J "C:\Program Files (x86)\World of Warcraft\_classic_\Interface\AddOns\AutoPallyPower" "%USERPROFILE%\Dev\AutoPallyPower"
```

The link target is the repository root, because that is where the `.toc` lives.

After pulling changes, `/reload` in game picks them up. New or removed files in
the `.toc` need a full client restart, since WoW only reads the `.toc` at
launch.

## Tests

The engine is pure Lua with no WoW API calls, so it runs under `lua5.1` — the
same version the game ships.

```sh
./Tests/run_all.sh
```

No WoW client, and no group, required.
