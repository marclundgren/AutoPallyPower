local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local B, S, R = APP.Blessings, APP.Solver, APP.Rules

local function caps(list) local c = {} for _, b in ipairs(list) do c[b] = true end return c end
local ALL    = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT, B.SANCTUARY }
local NOSANC = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT }
local NOKING = { B.WISDOM, B.MIGHT, B.SALVATION, B.LIGHT }

local function pally(name, spec, capList, talents)
	return { name = name, spec = spec, canCast = caps(capList), talents = talents or {},
	         capabilitiesKnown = true }
end
local function member(name, class, profile, tank, raidRole)
	return { name = name, class = class, profile = profile,
	         tank = tank or false, raidRole = raidRole }
end
local function cfg(over)
	local c = S.defaultConfig()
	for k, v in pairs(over or {}) do c[k] = v end
	return c
end

-- A workable raid: prot paladin main tanking, plus two paladins with Kings.
local function baseRaid()
	return {
		paladins = {
			pally("Protpal", "PROT", ALL,    { [B.SANCTUARY] = 2 }),
			pally("Holypal", "HOLY", NOSANC, { [B.WISDOM] = 2 }),
			pally("Retpal",  "RET",  NOSANC, { [B.MIGHT] = 5 }),
		},
		members = {
			member("Protpal", "PALADIN", "PALADIN_TANK", true, "MAINTANK"),
			member("Holypal", "PALADIN", "PALADIN_HOLY"),
			member("Retpal",  "PALADIN", "PALADIN_RET"),
			member("Protwar", "WARRIOR", "WARRIOR_TANK", true, "MAINASSIST"),
			member("Furywar", "WARRIOR", "WARRIOR_DPS"),
			member("Armswar", "WARRIOR", "WARRIOR_DPS"),
			member("Roguea",  "ROGUE",   "ROGUE"),
			member("Holypri", "PRIEST",  "PRIEST_HEALER"),
			member("Shadowp", "PRIEST",  "PRIEST_SHADOW"),
			member("Magea",   "MAGE",    "MAGE"),
		},
	}
end

--------------------------------------------------------------------------
print("== the rule fires for a protection paladin who is tanking ==")
do
	local r = S:Solve(baseRaid(), cfg())
	T.eq("one rule applied", #r.appliedRules, 1)
	T.eq("it is the prot tank salvation rule", r.appliedRules[1].rule, "PROT_TANK_SALVATION")
	T.eq("it pins the prot paladin", r.appliedRules[1].paladin, "Protpal")
	T.eq("to Salvation", r.appliedRules[1].blessing, B.SALVATION)

	-- Every populated column should have that paladin on Salvation.
	local held, populated = 0, 0
	for c = 1, B.MAX_CLASSES do
		if r.perClass[c].memberCount > 0 then
			populated = populated + 1
			if r.grid["Protpal"][c] == B.SALVATION then held = held + 1 end
		end
	end
	T.check("populated columns exist", populated > 0)
	T.eq("the pinned paladin carries Salvation everywhere", held, populated)
end

--------------------------------------------------------------------------
print("== the tank still ends up correct, including the self-Sanctuary ==")
do
	local r = S:Solve(baseRaid(), cfg())

	T.check("the prot paladin does not keep Salvation",
		not r.delivered["Protpal"][B.SALVATION])
	T.check("the prot paladin gets Kings from someone else",
		r.delivered["Protpal"][B.KINGS] == true)
	T.check("the prot paladin gets Sanctuary",
		r.delivered["Protpal"][B.SANCTUARY] == true)

	-- And it is genuinely self-cast, since nobody else can.
	local selfSanc = false
	for _, o in ipairs(r.overrides) do
		if o.target == "Protpal" and o.blessing == B.SANCTUARY then
			T.eq("Sanctuary is cast by the prot paladin themselves", o.paladin, "Protpal")
			selfSanc = true
		end
	end
	T.check("a self Sanctuary override was emitted", selfSanc)
	T.eq("no warnings", #r.warnings, 0)
end

--------------------------------------------------------------------------
print("== preconditions: the rule declines rather than misfiring ==")
do
	-- Disabled by setting.
	local off = S:Solve(baseRaid(), cfg({ protPaladinSalvation = false }))
	T.eq("no rules when turned off", #off.appliedRules, 0)

	-- Prot paladin present but not tanking.
	local raid = baseRaid()
	raid.members[1] = member("Protpal", "PALADIN", "PALADIN_RET", false)
	local notTanking = S:Solve(raid, cfg())
	T.eq("declines when the prot paladin is not tanking", #notTanking.appliedRules, 0)

	-- Nobody else has Kings, so the promise cannot be kept.
	local noKings = baseRaid()
	noKings.paladins = {
		pally("Protpal", "PROT", ALL, { [B.SANCTUARY] = 2 }),
		pally("Holypal", "HOLY", NOKING, { [B.WISDOM] = 2 }),
	}
	table.remove(noKings.members, 3)   -- drop Retpal to match the paladin list
	local r2 = S:Solve(noKings, cfg())
	T.eq("declines when no other paladin has Kings", #r2.appliedRules, 0)

	-- Lone paladin: nobody to hand over Kings.
	local solo = baseRaid()
	solo.paladins = { pally("Protpal", "PROT", ALL, { [B.SANCTUARY] = 2 }) }
	local r3 = S:Solve(solo, cfg())
	T.eq("declines with a single paladin", #r3.appliedRules, 0)
	T.check("and the lone tank still avoids Salvation",
		not r3.delivered["Protpal"][B.SALVATION])
end

--------------------------------------------------------------------------
print("== with two protection paladin tanks, the main tank is chosen ==")
do
	local raid = baseRaid()
	-- Alphabetically first, but only an off-tank: must NOT win.
	table.insert(raid.paladins, pally("Anotherpal", "PROT", ALL, { [B.SANCTUARY] = 2 }))
	table.insert(raid.members, member("Anotherpal", "PALADIN", "PALADIN_TANK", true, "MAINASSIST"))

	local r = S:Solve(raid, cfg())
	T.eq("exactly one paladin is pinned", #r.appliedRules, 1)
	T.eq("the main tank is pinned, not the off-tank", r.appliedRules[1].paladin, "Protpal")
	T.check("the off-tank is free to hold other blessings", (function()
		for c = 1, B.MAX_CLASSES do
			local b = r.grid["Anotherpal"][c]
			if b ~= B.NONE and b ~= B.SALVATION then return true end
		end
		return false
	end)())

	-- Swap the roles: now the other one should be picked.
	for _, m in ipairs(raid.members) do
		if m.name == "Protpal" then m.raidRole = "MAINASSIST" end
		if m.name == "Anotherpal" then m.raidRole = "MAINTANK" end
	end
	local r2 = S:Solve(raid, cfg())
	T.eq("the pin follows the main tank slot", r2.appliedRules[1].paladin, "Anotherpal")
end

--------------------------------------------------------------------------
print("== preference can be overruled where hard cannot ==")
do
	-- A column of nothing but tanks is the case where Salvation is actively
	-- wrong, so the two modes should part company here.
	local raid = {
		paladins = {
			pally("Protpal", "PROT", ALL,    { [B.SANCTUARY] = 2 }),
			pally("Holypal", "HOLY", NOSANC, { [B.WISDOM] = 2 }),
			pally("Retpal",  "RET",  NOSANC, { [B.MIGHT] = 5 }),
		},
		members = {
			member("Protpal", "PALADIN", "PALADIN_TANK", true, "MAINTANK"),
			member("Holypal", "PALADIN", "PALADIN_HOLY"),
			member("Retpal",  "PALADIN", "PALADIN_RET"),
			-- Every warrior in the raid is a tank.
			member("Protwar", "WARRIOR", "WARRIOR_TANK", true, "MAINASSIST"),
			member("Protwa2", "WARRIOR", "WARRIOR_TANK", true, "MAINASSIST"),
			member("Protwa3", "WARRIOR", "WARRIOR_TANK", true, "MAINASSIST"),
		},
	}
	local WAR = B.CLASS_IDS.WARRIOR

	local pref = S:Solve(raid, cfg({ pinMode = "preference" }))
	local hard = S:Solve(raid, cfg({ pinMode = "hard" }))

	T.eq("preference mode is recorded", pref.pinMode, "preference")
	T.eq("hard mode is recorded", hard.pinMode, "hard")

	local prefWar = pref.grid["Protpal"][WAR]
	local hardWar = hard.grid["Protpal"][WAR]

	T.check("preference lets the pinned paladin take a useful blessing here",
		prefWar ~= B.SALVATION, "got " .. B:Name(prefWar))
	T.check("hard mode never gives the pinned paladin a different blessing",
		hardWar == B.SALVATION or hardWar == B.NONE, "got " .. B:Name(hardWar))
	T.check("the two modes genuinely differ on this column", prefWar ~= hardWar,
		("both gave %s"):format(B:Name(prefWar)))

	-- Whichever mode, no tank may keep Salvation.
	for _, r in ipairs({ pref, hard }) do
		for _, m in ipairs(r.members) do
			if m.tank then
				T.check("tank kept off Salvation in both modes",
					not r.delivered[m.name][B.SALVATION], m.name)
			end
		end
	end
end

--------------------------------------------------------------------------
print("== hard mode holds the pin across every column ==")
do
	local raid = baseRaid()
	local r = S:Solve(raid, cfg({ pinMode = "hard" }))
	for c = 1, B.MAX_CLASSES do
		local b = r.grid["Protpal"][c]
		T.check("pinned paladin holds only Salvation or nothing",
			b == B.SALVATION or b == B.NONE, ("class %d gave %s"):format(c, B:Name(b)))
	end
end

--------------------------------------------------------------------------
print("== a manual pin beats the automatic rule ==")
do
	local raid = baseRaid()
	local r = S:Solve(raid, cfg({ pins = { Protpal = B.WISDOM } }))

	local manual
	for _, rule in ipairs(r.appliedRules) do
		if rule.paladin == "Protpal" then manual = rule end
	end
	T.check("the manual pin is the one recorded", manual ~= nil)
	T.eq("manual pin wins over the rule", manual.blessing, B.WISDOM)
	T.eq("and it is marked as manual", manual.rule, "MANUAL")
	T.eq("the rule did not also pin the same paladin", r.pins["Protpal"], B.WISDOM)
end

--------------------------------------------------------------------------
print("== a pin never buys an extra override by itself ==")
do
	-- The property that separates a preference from a hard pin in disguise.
	-- If pin strength ever rises above the override penalty, a pin wins every
	-- time the only thing opposing it is one more click.
	T.check("default pin strength stays below the override penalty",
		S.DEFAULT_PIN_STRENGTH < S.DEFAULT_OVERRIDE_PENALTY,
		("pin %d vs penalty %d"):format(S.DEFAULT_PIN_STRENGTH, S.DEFAULT_OVERRIDE_PENALTY))

	local c = S.defaultConfig()
	T.check("the shipped config keeps that relationship",
		c.pinStrength < c.overridePenalty,
		("pin %d vs penalty %d"):format(c.pinStrength, c.overridePenalty))
end

T.report("rules")
