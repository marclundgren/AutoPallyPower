-- Per class+spec blessing priorities.
--
-- Each profile is an ordered priority list: "if I could have N blessings, these are the
-- N I want, in this order." Entries may carry a `requires` condition that is
-- evaluated against live raid state, because some blessings are worthless in
-- the wrong raid -- Blessing of Light does nothing unless a Holy paladin is
-- actually casting Holy Light on the target, and Sanctuary cannot be cast at
-- all without a Protection-talented paladin present.
--
-- There is one ordering per profile. An earlier version carried a second
-- "survival" ordering for tanks behind a toggle; it applied to tanks only,
-- doubled the data, and made it ambiguous which list you were editing. A guild
-- that wants a survival-first tank list can simply order it that way, or keep
-- one as a preset.
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
		priority = { KINGS, cond(LIGHT, HOLY), MIGHT, cond(SANCTUARY, PROT) },
	},
	DRUID_TANK = {
		label = "Druid - Feral (Tank)", class = "DRUID", role = "TANK", tank = true,
		-- Wisdom is genuinely wanted but low: ferals powershift out of form
		-- for the occasional cast and need a trickle of mana for it.
		priority         = { KINGS, MIGHT, cond(LIGHT, HOLY), WISDOM },
		priority = { KINGS, cond(LIGHT, HOLY), MIGHT, WISDOM },
	},
	PALADIN_TANK = {
		label = "Paladin - Protection", class = "PALADIN", role = "TANK", tank = true,
		-- Sanctuary sits second because it is simultaneously the threat option
		-- and a damage reduction, so it does not trade off the way Might does.
		priority         = { KINGS, cond(SANCTUARY, PROT), cond(LIGHT, HOLY), WISDOM },
		priority = { KINGS, cond(SANCTUARY, PROT), cond(LIGHT, HOLY), WISDOM },
	},
	-- Caster tanking is rare but real (spellsteal mages, warlock tanks).
	MAGE_TANK = {
		label = "Mage - Tank", class = "MAGE", role = "TANK", tank = true,
		priority         = { KINGS, WISDOM, cond(LIGHT, HOLY) },
		priority = { KINGS, cond(LIGHT, HOLY), WISDOM },
	},
	WARLOCK_TANK = {
		label = "Warlock - Tank", class = "WARLOCK", role = "TANK", tank = true,
		priority         = { KINGS, WISDOM, cond(LIGHT, HOLY) },
		priority = { KINGS, cond(LIGHT, HOLY), WISDOM },
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

-- Where a role is known but the spec is not. For classes whose DPS spec is
-- ambiguous -- a druid could be feral or balance, a shaman enhancement or
-- elemental -- pick the variant whose blessings serve both. Both want
-- Salvation first; the second slot is Kings for the caster build and Might for
-- the melee one, and Kings is useful to either, while Might is dead weight on
-- a caster. So an unknown DPS druid is treated as balance.
P.classHealerProfile = {
	PRIEST  = "PRIEST_HEALER",
	DRUID   = "DRUID_RESTO",
	SHAMAN  = "SHAMAN_RESTO",
	PALADIN = "PALADIN_HOLY",
}

P.classDpsProfile = {
	WARRIOR = "WARRIOR_DPS",
	ROGUE   = "ROGUE",
	HUNTER  = "HUNTER",
	MAGE    = "MAGE",
	WARLOCK = "WARLOCK",
	PRIEST  = "PRIEST_SHADOW",
	DRUID   = "DRUID_BALANCE",
	SHAMAN  = "SHAMAN_ELEMENTAL",
	PALADIN = "PALADIN_RET",
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
-- @param ctx      { holyPaladin = bool, protPaladin = bool }
-- @return array of blessing ids, best first, with unsatisfied conditions removed
function P:Resolve(profile, ctx)
	ctx = ctx or {}
	local satisfied = {
		[HOLY] = ctx.holyPaladin and true or false,
		[PROT] = ctx.protPaladin and true or false,
	}

	local source = profile.priority

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
	-- A role the player picked themselves beats a class-wide guess: it does not
	-- pin the spec, but it does rule out most of the wrong answers.
	if member.assignedRole == "HEALER" and self.classHealerProfile[member.class] then
		return self.classHealerProfile[member.class]
	end
	if member.assignedRole == "DAMAGER" and self.classDpsProfile[member.class] then
		return self.classDpsProfile[member.class]
	end
	return self.classFallback[member.class]
end

--- Did we actually know anything about this member, or fall back to the class?
function P:IsGuess(member, overrides)
	if overrides and overrides[member.name] then return false end
	if member.tank then return false end
	if member.profile and self.defaults[member.profile] then return false end
	if member.assignedRole == "HEALER" or member.assignedRole == "DAMAGER" then
		return false
	end
	return true
end

--------------------------------------------------------------------------
-- Grouping for the priority list UI
--------------------------------------------------------------------------

-- Two ways to organise twenty profiles. Grouping by role matches how the
-- priorities are actually written -- every healer shares a list -- so it is
-- the default and the one to use when editing policy. Grouping by class
-- mirrors the raid grid instead, which is what you want when one particular
-- player's buffs look wrong. Both are useful, so it stays a setting.
P.CLASS_ORDER = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN" }

P.CLASS_LABELS = {
	WARRIOR = "Warrior", ROGUE = "Rogue", PRIEST = "Priest", DRUID = "Druid",
	PALADIN = "Paladin", HUNTER = "Hunter", MAGE = "Mage", WARLOCK = "Warlock",
	SHAMAN = "Shaman",
}

-- Tanks first: they carry the hard constraint and get edited most.
P.ROLE_ORDER = { "TANK", "HEALER", "MELEE", "CASTER" }

P.ROLE_LABELS = {
	TANK = "Tanks", HEALER = "Healers", MELEE = "Physical DPS", CASTER = "Caster DPS",
}

--- The spec on its own, with the class prefix removed -- for anywhere the
--- class is already shown in its own column or heading.
--
-- Some classes carry a single profile because their blessing priorities do not
-- vary by spec at all. Naming those "All specs" rather than repeating the class
-- says something true, where "Rogue -- Rogue" says nothing.
function P:SpecLabel(profile)
	local label = profile.label or "?"
	local classLabel = self.CLASS_LABELS[profile.class]
	if not classLabel then return label end
	if label == classLabel then return "All specs" end
	local trimmed = label:match("^" .. classLabel .. "%s*%-%s*(.+)$")
	return trimmed or label
end

--- Strip the class prefix from a profile label so it does not repeat the
--- group heading it already sits under.
local function shortLabel(profile, mode)
	if mode ~= "class" then return profile.label or "?" end
	return P:SpecLabel(profile)
end

--- Ordered, grouped profile list for the priority rail.
-- @param mode "class" or "role"
-- @param profiles profile set to list (defaults to the shipped ones)
-- @return array of { key, label, items = { { key, profile, label, tank } } }
function P:GroupedList(mode, profiles)
	profiles = profiles or self.defaults
	-- Role is the fallback as well as the saved default, so a caller that
	-- forgets to pass a mode gets the same list the settings would have given.
	mode = (mode == "class") and "class" or "role"

	local classRank = {}
	for i, class in ipairs(self.CLASS_ORDER) do classRank[class] = i end

	local buckets, order = {}, {}
	local groupKeys = (mode == "class") and self.CLASS_ORDER or self.ROLE_ORDER
	for _, key in ipairs(groupKeys) do
		buckets[key] = {}
		order[#order + 1] = key
	end

	for key, profile in pairs(profiles) do
		-- setmetatable-backed preset sets can carry inherited entries; only
		-- list ones that look like real profiles.
		if type(profile) == "table" and profile.class then
			local bucket = (mode == "class") and profile.class or profile.role
			if bucket and buckets[bucket] then
				table.insert(buckets[bucket], {
					key = key,
					profile = profile,
					label = shortLabel(profile, mode),
					tank = profile.tank and true or false,
				})
			end
		end
	end

	local out = {}
	for _, key in ipairs(order) do
		local items = buckets[key]
		if #items > 0 then
			-- Within a group: class order first, then label, so the list is
			-- stable no matter how pairs() happened to iterate.
			table.sort(items, function(a, b)
				local ra = classRank[a.profile.class] or 99
				local rb = classRank[b.profile.class] or 99
				if ra ~= rb then return ra < rb end
				return a.label < b.label
			end)
			out[#out + 1] = {
				key = key,
				label = (mode == "class") and self.CLASS_LABELS[key] or self.ROLE_LABELS[key],
				items = items,
			}
		end
	end
	return out
end
