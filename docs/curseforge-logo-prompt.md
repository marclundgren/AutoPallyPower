# Logo prompt

For an image model. The constraints matter as much as the concept: CurseForge
rejects trademarked assets, so it must not reproduce Blizzard artwork or
in-game spell icons. "Paladin" also pulls image models straight toward
religious iconography, which would look generic and risk the moderation pass —
hence the explicit exclusions.

The palette is the addon's own, from `UI/Theme.lua`.

```
Design a square app icon for a World of Warcraft addon called AutoPallyPower.
It automatically works out paladin blessing assignments for a raid — think
"a plan being computed", not "a spell being cast".

Concept: a rounded-square badge on a very dark background containing a
simplified 3x3 grid of small squares, where one diagonal of squares glows
warmly as if lit — reading simultaneously as an assignment grid and as
radiating light. Flat vector, geometric, confident negative space.

Style: flat modern vector, no gradients beyond a single soft glow, no
bevels, no 3D, no drop shadows. Crisp geometry that stays legible at 64x64.

Palette:
- background: near-black with a slight violet cast (#131217)
- surface: dark violet-grey (#1C1A24)
- primary accent: warm pink (#F58CBA)
- secondary accent: muted gold (#D8A03D)
- hairline borders: #332B36

Hard constraints:
- No text, letters, or numbers anywhere in the image.
- No World of Warcraft or Blizzard artwork, logos, UI elements, or
  recreations of in-game spell icons. Entirely original geometry.
- No people, faces, hands, armour, or religious iconography — no crosses,
  no halos, no praying figures.
- Fully square, centred composition, generous margin so nothing touches
  the edges.
- Flat background, not transparent.

Output a single 400x400 PNG.
```

## If the grid reads weak

Same palette and constraints, different concept:

> a simplified shield silhouette divided into nine segments, three of them lit

Nine because that is the number of class columns the addon assigns across,
which is quietly true to what it does.
