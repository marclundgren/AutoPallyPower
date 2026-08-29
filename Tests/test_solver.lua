local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local B, S, TR = APP.Blessings, APP.Solver, APP.TestRaid

local function caps(t)
	local c = {}
	for _, b in ipairs(t) do c[b] = true end
	return c
end

local ALL_CAPS  = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT, B.SANCTUARY }
local NO_SANC   = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT }

local function pally(name, spec, capList)
	return { name = name, spec = spec, canCast = caps(capList or NO_SANC) }
end

local function member(name, class, profile, tank)
	return { name = name, class = class, profile = profile, tank = tank or false }
end

local function cfg(overrides)
	local c = S.defaultConfig()
	for k, v in pairs(overrides or {}) do c[k] = v end
	return c
end

local function columnOf(result, class)
	return result.perClass[B.CLASS_IDS[class]]
end

local function hasBlessing(list, b)
	for _, v in ipairs(list) do if v == b then return true end end
	return false
end

--------------------------------------------------------------------------
print("== the four-warrior case ==")
-- Three DPS warriors and one prot warrior, one paladin. The paladin has a
-- single greater blessing to spend on the whole column.
do
	local raid = {
		paladins = { pally("Solopally", "RET") },
		members = {
			member("Warrone",   "WARRIOR", "WARRIOR_DPS"),
			member("Wartwo",    "WARRIOR", "WARRIOR_DPS"),
			member("Warthree",  "WARRIOR", "WARRIOR_DPS"),
			member("Tankwar",   "WARRIOR", "WARRIOR_TANK", true),
		},
	}
	local r = S:Solve(raid, cfg())
	local col = columnOf(r, "WARRIOR")

	T.eq("one greater blessing for one paladin", #col.blessings, 1)
	T.check("greater blessing serves the DPS majority (Salvation)",
		col.blessings[1] == B.SALVATION,
		"got " .. B:Name(col.blessings[1] or 0))

	T.eq("exactly one override emitted", #r.overrides, 1)
	local o = r.overrides[1]
	T.eq("override targets the tank", o.target, "Tankwar")
	T.eq("override replaces Salvation", o.replaces, B.SALVATION)
	T.eq("override gives the tank Kings", o.blessing, B.KINGS)
	T.check("override is flagged mandatory", o.mandatory == true)
	T.eq("no warnings", #r.warnings, 0)
end

--------------------------------------------------------------------------
print("== rule zero holds across random raids ==")
do
	local violations, checked = 0, 0
	for seed = 1, 200 do
		local raid = TR:Generate({
			seed = seed,
			raidSize = 25,
			paladins = 1 + (seed % 4),
			tanks = 1 + (seed % 3),
			healers = 2 + (seed % 5),
		})
		local r = S:Solve(raid, cfg())
		if #r.warnings > 0 then violations = violations + 1 end
		for _, m in ipairs(r.members) do
			if m.tank then
				checked = checked + 1
				if r.delivered[m.name][B.SALVATION] then violations = violations + 1 end
			end
		end
	end
	T.check("checked a meaningful number of tanks", checked > 300, "checked " .. checked)
	T.eq("no tank anywhere keeps Salvation", violations, 0)
end

--------------------------------------------------------------------------
print("== determinism ==")
do
	local raid = TR:Generate({ seed = 4242, raidSize = 25, paladins = 3, tanks = 2, healers = 5 })

	local function fingerprint(r)
		local parts = {}
		local names = {}
		for _, p in ipairs(r.paladins) do names[#names + 1] = p.name end
		table.sort(names)
		for _, n in ipairs(names) do
			for c = 1, B.MAX_CLASSES do
				parts[#parts + 1] = n .. ":" .. c .. "=" .. r.grid[n][c]
			end
		end
		for _, o in ipairs(r.overrides) do
			parts[#parts + 1] = ("O:%s/%s/%d"):format(o.target, o.paladin, o.blessing)
		end
		return table.concat(parts, "|")
	end

	local a = fingerprint(S:Solve(raid, cfg()))
	local b = fingerprint(S:Solve(raid, cfg()))
	local c = fingerprint(S:Solve(raid, cfg()))
	T.check("same raid solves identically every time", a == b and b == c)
	T.check("fingerprint is non-trivial", #a > 50)
end

--------------------------------------------------------------------------
print("== Blessing of Light is conditional on a holy paladin ==")
do
	-- Five paladins, none holy: Light should never be handed out, even though
	-- there are far more blessing slots than useful blessings.
	local raid = {
		paladins = {
			pally("Retone", "RET"), pally("Rettwo", "RET"), pally("Retthree", "RET"),
			pally("Protone", "PROT", ALL_CAPS), pally("Retfour", "RET"),
		},
		members = {
			member("Tankwar", "WARRIOR", "WARRIOR_TANK", true),
			member("Warrone", "WARRIOR", "WARRIOR_DPS"),
			member("Healpri", "PRIEST", "PRIEST_HEALER"),
		},
	}
	local r = S:Solve(raid, cfg())
	T.check("context says no holy paladin", r.context.holyPaladin == false)
	local lightSeen = false
	for c = 1, B.MAX_CLASSES do
		if hasBlessing(r.perClass[c].blessings, B.LIGHT) then lightSeen = true end
	end
	T.check("Light never assigned without a holy paladin", not lightSeen)

	-- Same raid, one paladin swapped to holy: now Light becomes usable.
	raid.paladins[1] = pally("Retone", "HOLY")
	local r2 = S:Solve(raid, cfg())
	T.check("context now sees a holy paladin", r2.context.holyPaladin == true)
	T.check("tank column now includes Light",
		hasBlessing(r2.perClass[B.CLASS_IDS.WARRIOR].blessings, B.LIGHT))
end

--------------------------------------------------------------------------
print("== Sanctuary requires a protection paladin ==")
do
	local raid = {
		paladins = { pally("Retone", "RET"), pally("Rettwo", "RET") },
		members = { member("Tankwar", "WARRIOR", "WARRIOR_TANK", true) },
	}
	local r = S:Solve(raid, cfg())
	T.check("no prot paladin in context", r.context.protPaladin == false)
	T.check("Sanctuary not assigned",
		not hasBlessing(r.perClass[B.CLASS_IDS.WARRIOR].blessings, B.SANCTUARY))

	raid.paladins[2] = pally("Prottwo", "PROT", ALL_CAPS)
	local r2 = S:Solve(raid, cfg())
	T.check("prot paladin detected", r2.context.protPaladin == true)
end

--------------------------------------------------------------------------
print("== priority lists are honoured when there is room ==")
do
	-- Three paladins means each class column gets three blessings, which is
	-- exactly the depth of most priority lists.
	local raid = {
		paladins = { pally("Holyone", "HOLY"), pally("Rettwo", "RET"), pally("Retthree", "RET") },
		members = {
			member("Healpri", "PRIEST", "PRIEST_HEALER"),
			member("Healpr2", "PRIEST", "PRIEST_HEALER"),
			member("Magetwo", "MAGE", "MAGE"),
			member("Magethr", "MAGE", "MAGE"),
			member("Roguone", "ROGUE", "ROGUE"),
			member("Roguetw", "ROGUE", "ROGUE"),
		},
	}
	local r = S:Solve(raid, cfg())

	local priest = columnOf(r, "PRIEST")
	T.check("healer priests get Wisdom", hasBlessing(priest.blessings, B.WISDOM))
	T.check("healer priests get Kings", hasBlessing(priest.blessings, B.KINGS))
	T.check("healer priests get Salvation", hasBlessing(priest.blessings, B.SALVATION))

	local mage = columnOf(r, "MAGE")
	T.check("mages get Salvation", hasBlessing(mage.blessings, B.SALVATION))
	T.check("mages get Kings", hasBlessing(mage.blessings, B.KINGS))
	T.check("mages get Wisdom", hasBlessing(mage.blessings, B.WISDOM))
	T.check("mages get no Might", not hasBlessing(mage.blessings, B.MIGHT))

	local rogue = columnOf(r, "ROGUE")
	T.check("rogues get Salvation", hasBlessing(rogue.blessings, B.SALVATION))
	T.check("rogues get Might", hasBlessing(rogue.blessings, B.MIGHT))
	T.check("rogues get Kings", hasBlessing(rogue.blessings, B.KINGS))
	T.check("rogues get no Wisdom", not hasBlessing(rogue.blessings, B.WISDOM))
end

--------------------------------------------------------------------------
print("== structural invariants ==")
do
	for seed = 1, 60 do
		local raid = TR:Generate({ seed = seed * 7, paladins = 1 + (seed % 5), tanks = 2, healers = 5 })
		local r = S:Solve(raid, cfg())

		-- No paladin gives the same class two blessings, and no blessing is
		-- delivered twice to the same column.
		for c = 1, B.MAX_CLASSES do
			local seen = {}
			for _, b in ipairs(r.perClass[c].blessings) do
				if seen[b] then T.check("no duplicate blessing in column", false, "class " .. c) end
				seen[b] = true
			end
			if #r.perClass[c].blessings > #raid.paladins then
				T.check("column never exceeds paladin count", false, "class " .. c)
			end
		end

		-- Every assignment must be castable by the paladin holding it.
		local byName = {}
		for _, p in ipairs(raid.paladins) do byName[p.name] = p end
		for name, row in pairs(r.grid) do
			for c = 1, B.MAX_CLASSES do
				local b = row[c]
				if b ~= B.NONE and not byName[name].canCast[b] then
					T.check("paladin can cast what it is assigned", false,
						name .. " class " .. c .. " blessing " .. b)
				end
			end
		end
		for _, o in ipairs(r.overrides) do
			if not byName[o.paladin].canCast[o.blessing] then
				T.check("override is castable by its paladin", false, o.paladin)
			end
		end
	end
	T.check("invariants held over 60 generated raids", true)
end

--------------------------------------------------------------------------
print("== degenerate inputs ==")
do
	local r = S:Solve({ paladins = {}, members = { member("Lonewar", "WARRIOR", "WARRIOR_DPS") } }, cfg())
	T.eq("no paladins yields no overrides", #r.overrides, 0)
	T.eq("no paladins yields no warnings", #r.warnings, 0)

	local r2 = S:Solve({ paladins = { pally("Solo", "RET") }, members = {} }, cfg())
	T.eq("empty raid yields no overrides", #r2.overrides, 0)
end


--------------------------------------------------------------------------
print("== the mandatory flag means rule zero, not merely 'replaced Salvation' ==")
do
	-- A healer priest alongside shadow priests will be overridden off
	-- Salvation onto Wisdom. That is an upgrade, not a rule-zero correction.
	local raid = {
		paladins = { pally("Holyone", "HOLY"), pally("Rettwo", "RET") },
		members = {
			member("Shadowa", "PRIEST", "PRIEST_SHADOW"),
			member("Shadowb", "PRIEST", "PRIEST_SHADOW"),
			member("Healpri", "PRIEST", "PRIEST_HEALER"),
			member("Tankwar", "WARRIOR", "WARRIOR_TANK", true),
			member("Warrone", "WARRIOR", "WARRIOR_DPS"),
			member("Wartwoo", "WARRIOR", "WARRIOR_DPS"),
		},
	}
	local r = S:Solve(raid, cfg())

	local mandatoryTargets, upgradeTargets = {}, {}
	for _, o in ipairs(r.overrides) do
		if o.mandatory then mandatoryTargets[o.target] = true
		else upgradeTargets[o.target] = true end
	end

	T.check("no non-tank is ever flagged mandatory", mandatoryTargets["Healpri"] ~= true)
	for _, o in ipairs(r.overrides) do
		if o.mandatory then
			local isTank = (o.target == "Tankwar")
			T.check("mandatory overrides only target tanks", isTank, o.target)
			T.eq("mandatory overrides always replace Salvation", o.replaces, B.SALVATION)
		end
	end
	T.check("the tank is still corrected off Salvation",
		not r.delivered["Tankwar"][B.SALVATION])
end

T.report("solver")
