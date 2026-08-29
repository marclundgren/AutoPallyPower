-- Blessing and class identifiers.
--
-- These IDs are NOT ours: they are PallyPower's own indices, taken verbatim
-- from PallyPowerValues.lua (PallyPower.Spells / PallyPower.ClassToID for the
-- BCC branch). We reuse them rather than defining a parallel numbering so that
-- assignments can be written straight into PallyPower_Assignments with no
-- translation layer to get out of sync.
local ADDON, APP = ...

local B = APP.Blessings

B.NONE       = 0
B.WISDOM     = 1
B.MIGHT      = 2
B.KINGS      = 3
B.SALVATION  = 4
B.LIGHT      = 5
B.SANCTUARY  = 6

B.ALL = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT, B.SANCTUARY }
B.MAX = 6

B.names = {
	[0] = "None",
	[1] = "Wisdom",
	[2] = "Might",
	[3] = "Kings",
	[4] = "Salvation",
	[5] = "Light",
	[6] = "Sanctuary",
}

B.shortNames = {
	[0] = "--",
	[1] = "Wis",
	[2] = "Mgt",
	[3] = "Kng",
	[4] = "Salv",
	[5] = "Lgt",
	[6] = "Sanc",
}

-- Icon paths mirror PallyPower.BlessingIcons so our UI reads identically.
B.icons = {
	[1] = "Interface\\Icons\\Spell_Holy_SealOfWisdom",
	[2] = "Interface\\Icons\\Spell_Holy_FistOfJustice",
	[3] = "Interface\\Icons\\Spell_Magic_MageArmor",
	[4] = "Interface\\Icons\\Spell_Holy_SealOfSalvation",
	[5] = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
	[6] = "Interface\\Icons\\Spell_Nature_LightningShield",
}

-- PallyPower's BCC class column order.
B.CLASS_IDS = {
	WARRIOR = 1,
	ROGUE   = 2,
	PRIEST  = 3,
	DRUID   = 4,
	PALADIN = 5,
	HUNTER  = 6,
	MAGE    = 7,
	WARLOCK = 8,
	SHAMAN  = 9,
}

B.CLASS_BY_ID = {
	[1] = "WARRIOR",
	[2] = "ROGUE",
	[3] = "PRIEST",
	[4] = "DRUID",
	[5] = "PALADIN",
	[6] = "HUNTER",
	[7] = "MAGE",
	[8] = "WARLOCK",
	[9] = "SHAMAN",
}

B.MAX_CLASSES = 9

-- Which blessings require a talent, and therefore may be absent from a given
-- paladin's spellbook. Everything else is trainable by any paladin.
--
-- Kings matters more than its hit rate suggests. Nearly every raiding paladin
-- takes it, but "nearly every" is not "every", and assigning Kings to a paladin
-- who cannot cast it produces a class column that silently goes unbuffed. So it
-- is never assumed -- only credited once a paladin's spellbook has been seen.
B.TALENT_GATED = {
	[B.KINGS] = true,      -- Protection tier 2
	[B.SANCTUARY] = true,  -- Protection tier 3
}

-- Blessings that anyone with the class can cast. Used as the conservative
-- fallback for a paladin we have not yet heard from.
B.ALWAYS_TRAINABLE = {
	[B.WISDOM] = true,
	[B.MIGHT] = true,
	[B.SALVATION] = true,
	[B.LIGHT] = true,
}

-- Blessings with an "Improved" talent behind them, and the points at full
-- rank. A paladin specced into one casts a materially stronger version, so
-- where the choice exists they should be the one to cast it.
--
-- Only these three are listed because these are the three PallyPower reports
-- talent data for (see its ScanSpells). Improved Blessing of Light exists in
-- TBC but is not broadcast, so we cannot credit it.
B.IMPROVED_MAX_RANK = {
	[B.WISDOM] = 2,     -- Improved Blessing of Wisdom   (Holy)
	[B.MIGHT] = 5,      -- Improved Blessing of Might    (Retribution)
	[B.SANCTUARY] = 2,  -- Improved Blessing of Sanctuary (Protection)
}

function B:Name(id)
	return self.names[id] or "None"
end

function B:Short(id)
	return self.shortNames[id] or "--"
end
