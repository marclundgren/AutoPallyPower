local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local B, S, PP, TR = APP.Blessings, APP.Solver, APP.PP, APP.TestRaid

local function caps(list)
	local c = {}
	for _, b in ipairs(list) do c[b] = true end
	return c
end
local ALL = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT, B.SANCTUARY }
local NO_KINGS = { B.WISDOM, B.MIGHT, B.SALVATION, B.LIGHT }

local function pally(name, capList, talents)
	return { name = name, spec = "RET", canCast = caps(capList), talents = talents or {},
	         capabilitiesKnown = true }
end
local function member(name, class, profile, tank)
	return { name = name, class = class, profile = profile, tank = tank or false }
end
local function cfg()
	return S.defaultConfig()
end

--------------------------------------------------------------------------
print("== Kings is never assumed for a paladin we have not heard from ==")
do
	PP.observed = {}
	local capabilities, talents, known = PP:CapabilitiesFor("Neverseen")

	T.check("unheard paladin is not credited with Kings", capabilities[B.KINGS] ~= true)
	T.check("unheard paladin is not credited with Sanctuary", capabilities[B.SANCTUARY] ~= true)
	T.check("unheard paladin keeps the trainable blessings",
		capabilities[B.WISDOM] and capabilities[B.MIGHT]
		and capabilities[B.SALVATION] and capabilities[B.LIGHT])
	T.check("reported as not known", known == false)
	T.eq("no talents claimed", next(talents), nil)

	-- A SELF broadcast carrying Kings should flip that.
	-- Six hex rank/talent pairs: wisdom, might, kings, salvation, light, sanctuary.
	PP:ParseSelf("Seenone", "SELF 726131413000@nnnnnnnnn")
	local seenCaps, seenTalents, seenKnown = PP:CapabilitiesFor("Seenone")
	T.check("a synced paladin is credited with Kings", seenCaps[B.KINGS] == true)
	T.check("reported as known", seenKnown == true)
	T.eq("improved wisdom talent read from the wire", seenTalents[B.WISDOM], 2)
	T.eq("improved might talent read from the wire", seenTalents[B.MIGHT], 1)
	PP.observed = {}
end

--------------------------------------------------------------------------
print("== improved blessings go to the paladin specced for them ==")
do
	-- One paladin has Improved Wisdom, the other does not. Both can cast both.
	local specced = pally("Wiseone", ALL, { [B.WISDOM] = 2 })
	local plain = pally("Plainone", ALL, {})

	local holders = S:MatchBlessings({ B.WISDOM, B.MIGHT }, { specced, plain })
	T.check("assignment found", holders ~= nil)
	T.eq("improved wisdom cast by the specced paladin", holders[B.WISDOM], 1)
	T.eq("might falls to the other paladin", holders[B.MIGHT], 2)
end

--------------------------------------------------------------------------
print("== the cascade: a paladin specced into two talents does not strand another ==")
do
	-- Aaron has BOTH improved wisdom and improved might. Baron has only
	-- improved might. Handing Aaron his single strongest blessing first --
	-- the greedy move -- leaves Baron on wisdom and wastes his might talent.
	-- The right answer takes Aaron off might so Baron can use it.
	local aaron = pally("Aaron", ALL, { [B.WISDOM] = 2, [B.MIGHT] = 5 })
	local baron = pally("Baron", ALL, { [B.MIGHT] = 5 })

	local holders, weight = S:MatchBlessings({ B.WISDOM, B.MIGHT }, { aaron, baron })
	T.eq("wisdom goes to the paladin who also has might", holders[B.WISDOM], 1)
	T.eq("might goes to the paladin who only has might", holders[B.MIGHT], 2)
	T.eq("both talents are used, not one", weight, 200)

	-- Three-way version: only one paladin can cover sanctuary, and they are
	-- also the best at might. Might must move to keep sanctuary covered well.
	local prot = pally("Protone", ALL, { [B.MIGHT] = 5, [B.SANCTUARY] = 2 })
	local ret  = pally("Retone", ALL, { [B.MIGHT] = 5 })
	local holy = pally("Holyone", ALL, { [B.WISDOM] = 2 })
	local h3, w3 = S:MatchBlessings({ B.WISDOM, B.MIGHT, B.SANCTUARY }, { prot, ret, holy })
	T.eq("sanctuary to the only paladin talented for it", h3[B.SANCTUARY], 1)
	T.eq("might to the other paladin talented for it", h3[B.MIGHT], 2)
	T.eq("wisdom to the holy paladin", h3[B.WISDOM], 3)
	T.eq("all three talents used", w3, 300)
end

--------------------------------------------------------------------------
print("== a set no paladin can staff is rejected ==")
do
	local noKings = pally("Nokings", NO_KINGS, {})
	T.eq("Kings alone is unassignable", S:MatchBlessings({ B.KINGS }, { noKings }), nil)
	T.check("Might alone is fine", S:MatchBlessings({ B.MIGHT }, { noKings }) ~= nil)

	-- Two blessings, one paladin: cannot cover both.
	T.eq("more blessings than paladins fails",
		S:MatchBlessings({ B.MIGHT, B.WISDOM }, { noKings }), nil)
end

--------------------------------------------------------------------------
print("== a raid where nobody specced Kings still produces a valid plan ==")
do
	local raid = {
		paladins = { pally("Nokingsa", NO_KINGS), pally("Nokingsb", NO_KINGS) },
		members = {
			member("Tankwar", "WARRIOR", "WARRIOR_TANK", true),
			member("Warrone", "WARRIOR", "WARRIOR_DPS"),
			member("Wartwoo", "WARRIOR", "WARRIOR_DPS"),
			member("Healpri", "PRIEST", "PRIEST_HEALER"),
			member("Magetwo", "MAGE", "MAGE"),
		},
	}
	local r = S:Solve(raid, cfg())

	for c = 1, B.MAX_CLASSES do
		for _, b in ipairs(r.perClass[c].blessings) do
			T.check("Kings never assigned when nobody has it", b ~= B.KINGS,
				"class " .. c)
		end
	end
	for _, o in ipairs(r.overrides) do
		T.check("Kings never used as an override either", o.blessing ~= B.KINGS)
	end
	T.check("the tank is still kept off Salvation",
		not r.delivered["Tankwar"][B.SALVATION])
	T.eq("no rule-zero warning", #r.warnings, 0)
end

--------------------------------------------------------------------------
print("== unknown talents are reported, not silently assumed ==")
do
	local unknown = pally("Mysteryone", NO_KINGS)
	unknown.capabilitiesKnown = false
	local r = S:Solve({
		paladins = { unknown },
		members = { member("Warrone", "WARRIOR", "WARRIOR_DPS") },
	}, cfg())

	local warned = false
	for _, w in ipairs(r.warnings) do
		if w:find("Mysteryone") then warned = true end
	end
	T.check("a paladin with unknown talents is named in the warnings", warned)
end

--------------------------------------------------------------------------
print("== override reasons name the kind of player ==")
do
	local raid = {
		paladins = {
			pally("Onepally", ALL, { [B.WISDOM] = 2 }),
			pally("Twopally", ALL, { [B.MIGHT] = 5 }),
		},
		members = {
			member("Tankwar", "WARRIOR", "WARRIOR_TANK", true),
			member("Warrone", "WARRIOR", "WARRIOR_DPS"),
			member("Wartwoo", "WARRIOR", "WARRIOR_DPS"),
			member("Shadowa", "PRIEST", "PRIEST_SHADOW"),
			member("Shadowb", "PRIEST", "PRIEST_SHADOW"),
			member("Healpri", "PRIEST", "PRIEST_HEALER"),
			member("Enhance", "SHAMAN", "SHAMAN_ENHANCE"),
			member("Restosh", "SHAMAN", "SHAMAN_RESTO"),
			member("Restos2", "SHAMAN", "SHAMAN_RESTO"),
		},
	}
	local r = S:Solve(raid, cfg())

	local byTarget = {}
	for _, o in ipairs(r.overrides) do byTarget[o.target] = o end

	local allowed = { TANK = true, HEALER = true, CASTER = true, PHYSICAL = true, UPGRADE = true }
	for _, o in ipairs(r.overrides) do
		T.check("reason is one of the known labels", allowed[o.reason] == true,
			tostring(o.reason))
		T.check("reason is never empty", o.reason ~= nil and o.reason ~= "")
	end

	if byTarget["Tankwar"] then
		T.eq("the tank's override reads as TANK", byTarget["Tankwar"].reason, "TANK")
	end
	if byTarget["Healpri"] then
		T.eq("a healer's override reads as HEALER", byTarget["Healpri"].reason, "HEALER")
	end
	if byTarget["Enhance"] then
		T.eq("an enhancement shaman reads as PHYSICAL", byTarget["Enhance"].reason, "PHYSICAL")
	end

	-- Mandatory implies TANK, always.
	for _, o in ipairs(r.overrides) do
		if o.mandatory then T.eq("mandatory overrides read as TANK", o.reason, "TANK") end
	end
end

--------------------------------------------------------------------------
print("== generated raids exercise paladins without Kings ==")
do
	local withoutKings, total = 0, 0
	for seed = 1, 120 do
		local raid = TR:Generate({ seed = seed, raidSize = 25, paladins = 3, tanks = 2, healers = 5 })
		for _, p in ipairs(raid.paladins) do
			total = total + 1
			if not p.canCast[B.KINGS] then withoutKings = withoutKings + 1 end
		end
		-- Whatever the talents rolled, the plan must stay valid.
		local r = S:Solve(raid, cfg())
		for _, m in ipairs(r.members) do
			if m.tank then
				T.check("tank kept off Salvation under random talents",
					not r.delivered[m.name][B.SALVATION], m.name)
			end
		end
		local byName = {}
		for _, p in ipairs(raid.paladins) do byName[p.name] = p end
		for name, row in pairs(r.grid) do
			for c = 1, B.MAX_CLASSES do
				if row[c] ~= B.NONE then
					T.check("never assigns a blessing the paladin lacks",
						byName[name].canCast[row[c]] == true, name)
				end
			end
		end
	end
	T.check("the no-Kings case actually occurred in the sample",
		withoutKings > 0, ("%d of %d paladins"):format(withoutKings, total))
end

T.report("talents")
