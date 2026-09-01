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

Every class/spec has an ordered blessing priority — "if I could have N blessings, these
are the N I want." A Fury Warrior wants Salvation, then Might, then Kings. An
Elemental Shaman wants Salvation, then Kings, then Wisdom. These ship as
editable defaults, not hard-coded rules.

Some entries are conditional on the raid, because some blessings are worthless
in the wrong one. Blessing of Light does nothing without a Holy paladin casting
Holy Light on the target, so it is only ever offered when there is one.
Sanctuary needs a Protection-talented paladin to exist at all.

**A tank never keeps Salvation.** This is a hard constraint, not a preference,
and the solver cannot produce a plan that violates it. Rather than show tanks a
rule they cannot edit, Salvation is simply absent from tank priorities.

## Talents are read, never assumed

Blessing of Kings is a talent. Almost every raiding paladin takes it — but
"almost every" is the problem, and assigning Kings to the one paladin who
skipped it leaves a whole class column unbuffed with nothing to say so. A
paladin is credited with Kings or Sanctuary only once PallyPower has synced
their spellbook; until then the plan says so rather than guessing.

Improved blessings work the other way. A paladin specced into Improved Blessing
of Wisdom casts a materially better one, so where there is a choice they should
be the one to cast it. Deciding that is a matching problem across every paladin
at once rather than a per-paladin pick: a paladin specced into two or three
improved blessings can only cast one for a given class, and handing them their
strongest in isolation can strand another paladin's talent entirely. The solver
finds the assignment that puts the most talents to use overall.

Because a greater blessing hits a whole class at once, the class-wide choice is
made by whoever is in that column — which leaves outliers, usually a tank
sitting among DPS. Those become per-player overrides: the same 10-minute normal
blessing you would otherwise set by hand with the scroll wheel. The solver
weighs each override against a configurable threshold, so the list stays short
enough to actually use.

Given the same raid, it always produces the same plan.

## How a player's spec is decided

The client offers no API for another player's talents, so a profile is resolved
from the cheapest reliable signals first:

1. a manual assignment you made — `/app override <player> <PROFILE>`
2. their role: the raid's Main Tank / Main Assist slots, or the role they picked
   in the group finder — which works in a party, where Main Tank slots do not
   exist at all
3. for paladins, their real spec — yours from your own talents, everyone else's
   from PallyPower's sync
4. the class default

Anyone resolved by step 4 is named on the Raid Plan tab and marked `(guess)` in
`/app report`, so a surprising assignment is explicable rather than mysterious.

Where a role is known but the spec is not, and the class has both a melee and a
caster DPS build, the caster profile is used. Both want Salvation first, and the
second slot is then Kings — useful to either build, where Might would be dead
weight on a caster.

## When your assignments will not stick

Another paladin's client only accepts assignments you set for them if you are
raid leader or assistant, or if they have ticked **Free Assignment** in
PallyPower's own window. Two details are easy to get caught by:

- **In a party there is no assistant.** PallyPower credits only the party
  leader, so being in a party you did not make counts for nothing.
- **Inside an instance-finder group it credits nobody at all.** Free Assignment
  is the only route there.

AutoPallyPower reads this rather than guessing. It learns each paladin's Free
Assignment state from the broadcast PallyPower already sends, and treats a
paladin who has never spoken on that channel as not having the addon installed.

`/app status` shows your own authority plus, for each paladin, whether they are
running PallyPower, their Free Assignment state, and whether you can set them.
The Raid Plan tab warns before you apply, and `/app apply` **skips** anyone it
cannot set rather than writing a plan into your own grid that nobody else
received.

## Rules and pins

Most of the engine works by solving each class column independently, which is
what makes it exactly optimal. A **pin** deliberately breaks that: it holds one
paladin to one blessing across every column. That is a convention imposed from
outside the maths, so it has to earn its place.

One rule ships, on by default. **A protection paladin who is tanking carries
Salvation for the whole raid.** The reasoning is that Salvation is the one
blessing that paladin cannot use — rule zero forbids it, and their own greater
blessing is spent overriding themselves onto Sanctuary regardless, since nobody
else can cast it. Meanwhile Salvation is first choice for nearly every DPS. So
giving it to the paladin who cannot benefit frees the others to sit on Wisdom
and Might, which are the blessings that carry Improved talents.

The rule declines rather than misfiring. It needs a protection paladin who is
actually tanking, and at least one *other* paladin who actually has Kings to
hand them — a second paladin is not enough if they skipped the talent. With two
protection paladins tanking, the one in the main tank slot is chosen.

Measured across 322 generated raids meeting the preconditions: never worse for
what players receive, better in 45, at a cost of roughly one extra override
every eighteen raids.

Pins come in two strengths. **Preference** (the default) lets the solver
overrule a pin where a column clearly wants otherwise; it holds in 99% of
columns and costs +18 overrides across those 322 raids. **Hard** means the
pinned paladin casts that blessing or nothing at all; it holds in 100% of
columns and costs +62. Both deliver identical blessings, so preference buys the
same result for a third of the clicks.

Pin strength is deliberately set below the override threshold, which gives it a
rule you can state plainly: a pin never justifies an extra override on its own.
Set it higher and it becomes a hard pin wearing a disguise.

You can also pin by hand — `/app pin <paladin> <blessing>` — which takes
precedence over any rule.

## Commands

```
/app plan       solve the current raid and show the plan
/app report     show what each player would end up with
/app preview    show what applying would change
/app verify     check what PallyPower actually holds
/app refresh    recalculate, and ask the group to resend their talents
/app apply      push the plan into PallyPower
/app test 25 2 2 5      simulate a 25-man: 2 paladins, 2 tanks, 5 healers
/app test off   back to the live raid
/app grouping class|role         how the priority list is grouped
/app protsalv on|off             prot paladin tank carries Salvation
/app pinmode preference|hard     how strictly pins are held
/app pin <paladin> <blessing|clear>
/app override <player> <PROFILE|clear>
/app roster     every raider by class, spec, role, and what they get
/app status     what the addon currently sees
```

Test mode generates a synthetic raid so you can see the engine work without
being in a group. Applying is disabled while it is on.

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

## Keeping the plan current

The Raid Plan recalculates on its own when someone joins, leaves, or changes
their group finder role. A burst of events is coalesced into a single pass, and
nothing is recomputed while the window is closed or showing another tab.

A spec change on someone else's character is not something the client reports,
so that has to be asked for. **Refresh** on the Raid Plan tab, or `/app
refresh`, sends PallyPower's own `REQ`, which makes every paladin rebroadcast
their talents and Free Assignment state; the plan solves immediately and again
once the replies have landed. It is deliberately manual, because it makes every
paladin in the raid rebroadcast.

The panel timestamps each recalculation, so a stale view is visible rather than
assumed.

## Confirming an override landed

A greater blessing is visible on PallyPower's grid the moment it lands. A
per-player override is not: it is one icon on one row of the pop-out player
list for that class, so "did that actually work" is hard to answer by looking.

`/app verify` reads PallyPower's live tables back and compares them to the
plan, reporting anything missing or different by name. `/app apply` runs the
same check automatically and says so.

How PallyPower uses them: a paladin's client reads only its own row of
`PallyPower_NormalAssignments`, and `GetSpellID` returns that override in place
of the class-wide greater blessing for that one player. So the override changes
what their own class button casts on that target -- a 10-minute normal
blessing instead of the 30-minute greater one.

