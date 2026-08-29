-- Per class+spec blessing wishlists.
--
-- Each profile is an ordered list: "if I could have N blessings, these are the
-- N I want, in this order." Entries may carry a `requires` condition that is
-- evaluated against live raid state, because some blessings are worthless in
-- the wrong raid -- Blessing of Light does nothing unless a Holy paladin is
-- actually casting Holy Light on the target, and Sanctuary cannot be cast at
-- all without a Protection-talented paladin present.
--
-- Tank profiles carry two orderings. Whether a tank wants threat or survival
-- out of their second blessing is a real judgement call that changes per guild
-- and per fight, so it is a setting (opt.tankPriority) rather than a baked-in
-- answer.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles

-- Condition keys usable in `requires`.
P.HOLY_PALADIN = "HOLY_PALADIN"
P.PROT_PALADIN = "PROT_PALADIN"

local HOLY = P.HOLY_PALADIN
local PROT = P.PROT_PALADIN

local WISDOM, MIGHT, KINGS = B.WISDOM, B.MIGHT, B.KINGS
local SALVATION, LIGHT, SANCTUARY = B.SALVATION, B.LIGHT, B.SANCTUARY

-- Shorthand for a conditional entry.
local function cond(blessing, requires)
	return { b = blessing, requires = requires }
end

-- The shipped defaults. Users can edit any of these; APP.db.profiles holds the
-- edited copy and these stay as the reset-to baseline.
P.defaults = {
	--------------------------------------------------------------------
	-- Physical DPS: salvation to stay alive under threat, then damage.
	--------------------------------------------------------------------
	WARRIOR_DPS = {
		label = "Warrior - Arms / Fury", class = "WARRIOR", role = "MELEE",
		priority = { SALVATION, MIGHT, KINGS },
	},
	ROGUE = {
		label = "Rogue", class = "ROGUE", role = "MELEE",
		priority = { SALVATION, MIGHT, KINGS },
	},

	--------------------------------------------------------------------
	-- Physical DPS with a mana bar: same, plus wisdom once the core three
	-- are covered.
	--------------------------------------------------------------------
	HUNTER = {
		label = "Hunter", class = "HUNTER", role = "MELEE",
		priority = { SALVATION, MIGHT, KINGS, WISDOM },
	},
	DRUID_FERAL_DPS = {
		label = "Druid - Feral (DPS)", class = "DRUID", role = "MELEE",
		priority = { SALVATION, MIGHT, KINGS, WISDOM },
	},
	SHAMAN_ENHANCE = {
		label = "Shaman - Enhancement", class = "SHAMAN", role = "MELEE",
		priority = { SALVATION, MIGHT, KINGS, WISDOM },
	},
	PALADIN_RET = {
		label = "Paladin - Retribution", class = "PALADIN", role = "MELEE",
		priority = { SALVATION, MIGHT, KINGS, WISDOM },
	},

	--------------------------------------------------------------------
	-- Caster DPS: no melee stats wanted, so wisdom takes might's place.
	--------------------------------------------------------------------
	PRIEST_SHADOW = {
		label = "Priest - Shadow", class = "PRIEST", role = "CASTER",
		priority = { SALVATION, KINGS, WISDOM },
	},
	MAGE = {
		label = "Mage", class = "MAGE", role = "CASTER",
		priority = { SALVATION, KINGS, WISDOM },
	},
	WARLOCK = {
		label = "Warlock", class = "WARLOCK", role = "CASTER",
		priority = { SALVATION, KINGS, WISDOM },
	},
	DRUID_BALANCE = {
		label = "Druid - Balance", class = "DRUID", role = "CASTER",
		priority = { SALVATION, KINGS, WISDOM },
	},
	SHAMAN_ELEMENTAL = {
		label = "Shaman - Elemental", class = "SHAMAN", role = "CASTER",
		priority = { SALVATION, KINGS, WISDOM },
	},

	--------------------------------------------------------------------
	-- Healers: mana first, salvation last of the three -- a healer that
	-- pulls threat off a tank has bigger problems than aggro reduction.
	--------------------------------------------------------------------
	PRIEST_HEALER = {
		label = "Priest - Holy / Discipline", class = "PRIEST", role = "HEALER",
		priority = { WISDOM, KINGS, SALVATION },
	},
	DRUID_RESTO = {
		label = "Druid - Restoration", class = "DRUID", role = "HEALER",
		priority = { WISDOM, KINGS, SALVATION },
	},
	SHAMAN_RESTO = {
		label = "Shaman - Restoration", class = "SHAMAN", role = "HEALER",
		priority = { WISDOM, KINGS, SALVATION },
	},
	PALADIN_HOLY = {
		label = "Paladin - Holy", class = "PALADIN", role = "HEALER",
		priority = { WISDOM, KINGS, SALVATION },
	},

	--------------------------------------------------------------------
	-- Tanks. Rule zero -- never salvation -- is enforced by the solver as
	-- a hard constraint, not by these lists.
	--------------------------------------------------------------------
	WARRIOR_TANK = {
		label = "Warrior - Protection", class = "WARRIOR", role = "TANK", tank = true,
		priority         = { KINGS, MIGHT, cond(LIGHT, HOLY), cond(SANCTUARY, PROT) },
		prioritySurvival = { KINGS, cond(LIGHT, HOLY), MIGHT, cond(SANCTUARY, PROT) },
	},
	DRUID_TANK = {
		label = "Druid - Feral (Tank)", class = "DRUID", role = "TANK", tank = true,
		-- Wisdom is genuinely wanted but low: ferals powershift out of form
		-- for the occasional cast and need a trickle of mana for it.
		priority         = { KINGS, MIGHT, cond(LIGHT, HOLY), WISDOM },
		prioritySurvival = { KINGS, cond(LIGHT, HOLY), MIGHT, WISDOM },
	},
	PALADIN_TANK = {
		label = "Paladin - Protection", class = "PALADIN", role = "TANK", tank = true,
		-- Sanctuary holds the second slot in both modes: it is simultaneously
		-- the threat option and a damage reduction, so it does not trade off
		-- against survival the way Might does.
		priority         = { KINGS, cond(SANCTUARY, PROT), cond(LIGHT, HOLY), WISDOM },
		prioritySurvival = { KINGS, cond(SANCTUARY, PROT), cond(LIGHT, HOLY), WISDOM },
	},
	-- Caster tanking is rare but real (spellsteal mages, warlock tanks).
	MAGE_TANK = {
		label = "Mage - Tank", class = "MAGE", role = "TANK", tank = true,
		priority         = { KINGS, WISDOM, cond(LIGHT, HOLY) },
		prioritySurvival = { KINGS, cond(LIGHT, HOLY), WISDOM },
	},
	WARLOCK_TANK = {
		label = "Warlock - Tank", class = "WARLOCK", role = "TANK", tank = true,
		priority         = { KINGS, WISDOM, cond(LIGHT, HOLY) },
		prioritySurvival = { KINGS, cond(LIGHT, HOLY), WISDOM },
	},
}

-- Fallback used when a raid member's spec is unknown: the least-bad guess for
-- the class as a whole.
P.classFallback = {
	WARRIOR = "WARRIOR_DPS",
	ROGUE   = "ROGUE",
	PRIEST  = "PRIEST_HEALER",
	DRUID   = "DRUID_RESTO",
	PALADIN = "PALADIN_HOLY",
	HUNTER  = "HUNTER",
	MAGE    = "MAGE",
	WARLOCK = "WARLOCK",
	SHAMAN  = "SHAMAN_RESTO",
}

-- When the raid marks someone as a tank, that beats any spec guess.
P.classTankProfile = {
	WARRIOR = "WARRIOR_TANK",
	DRUID   = "DRUID_TANK",
	PALADIN = "PALADIN_TANK",
	MAGE    = "MAGE_TANK",
	WARLOCK = "WARLOCK_TANK",
}

-- Tail blessings appended to every non-tank profile. They are near-worthless
-- most of the time, but with five or more paladins there are spare slots and
-- something beats nothing.
P.filler = {
	cond(LIGHT, HOLY),
	cond(SANCTUARY, PROT),
}

--- Normalise an entry into { b = id, requires = key|nil }.
local function normalise(entry)
	if type(entry) == "table" then
		return entry.b, entry.requires
	end
	return entry, nil
end

--- Resolve a profile into a flat, ordered blessing list for the current raid.
-- @param profile  a table from P.defaults (or a user-edited copy)
-- @param ctx      { holyPaladin = bool, protPaladin = bool, tankPriority = "threat"|"survival" }
-- @return array of blessing ids, best first, with unsatisfied conditions removed
function P:Resolve(profile, ctx)
	ctx = ctx or {}
	local satisfied = {
		[HOLY] = ctx.holyPaladin and true or false,
		[PROT] = ctx.protPaladin and true or false,
	}

	local source = profile.priority
	if profile.tank and ctx.tankPriority == "survival" and profile.prioritySurvival then
		source = profile.prioritySurvival
	end

	local out, seen = {}, {}
	for i = 1, #source do
		local b, requires = normalise(source[i])
		if b and not seen[b] and (not requires or satisfied[requires]) then
			seen[b] = true
			out[#out + 1] = b
		end
	end

	-- Append filler for anyone who has not already listed it.
	for i = 1, #self.filler do
		local b, requires = normalise(self.filler[i])
		if b and not seen[b] and (not requires or satisfied[requires]) then
			seen[b] = true
			out[#out + 1] = b
		end
	end

	return out
end

--- Pick the profile key for a raid member.
-- Resolution order: explicit user override, then raid tank flag, then detected
-- spec, then the class fallback.
function P:ForMember(member, overrides)
	if overrides and overrides[member.name] then
		return overrides[member.name]
	end
	if member.tank and self.classTankProfile[member.class] then
		return self.classTankProfile[member.class]
	end
	if member.profile and self.defaults[member.profile] then
		return member.profile
	end
	return self.classFallback[member.class]
end
