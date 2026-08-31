local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local chunk = assert(loadfile((os.getenv("APP_ROOT") or ".") .. "/Core/Roster.lua"))
chunk("AutoPallyPower", APP)

local B, S, P, R, PP = APP.Blessings, APP.Solver, APP.Profiles, APP.Roster, APP.PP

--- Stand up a party or raid the roster can scan.
-- @param opts { raid = bool, members = { {name, class, role, raidRole} }, selfSpec }
local function withGroup(opts, fn)
	local names = { "GetNumGroupMembers", "IsInRaid", "UnitExists", "GetUnitName",
	                "UnitClass", "UnitGroupRolesAssigned", "GetRaidRosterInfo" }
	local saved = {}
	for _, n in ipairs(names) do saved[n] = _G[n] end
	local savedPP, savedAssign = _G.PallyPower, _G.PallyPower_Assignments

	local members = opts.members
	local byUnit = {}
	if opts.raid then
		for i, m in ipairs(members) do byUnit["raid" .. i] = m end
	else
		byUnit.player = members[1]
		for i = 2, #members do byUnit["party" .. (i - 1)] = members[i] end
	end

	_G.GetNumGroupMembers = function() return #members end
	_G.IsInRaid = function() return opts.raid or false end
	_G.UnitExists = function(u) return byUnit[u] ~= nil end
	_G.GetUnitName = function(u) return byUnit[u] and byUnit[u].name end
	_G.UnitClass = function(u)
		local m = byUnit[u]
		if not m then return nil end
		return m.class, m.class
	end
	_G.UnitGroupRolesAssigned = function(u)
		local m = byUnit[u]
		return (m and m.role) or "NONE"
	end
	_G.GetRaidRosterInfo = function(i)
		local m = members[i]
		if not m then return nil end
		return m.name, 0, 1, 70, m.class, m.class, nil, nil, nil, m.raidRole
	end

	_G.PallyPower = { SendMessage = function() end, UpdateLayout = function() end }
	_G.PallyPower_Assignments = {}
	for _, m in ipairs(members) do
		if m.class == "PALADIN" then _G.PallyPower_Assignments[m.name] = {} end
	end

	PP.observed, PP.heard, PP.freeAssign = {}, {}, {}
	PP.selfName = opts.selfName or members[1].name
	PP.selfSpec = opts.selfSpec

	-- Capabilities are withheld until a spellbook has been seen, so a paladin
	-- with no observed data cannot be assigned Kings at all. Give each paladin
	-- what their spec would really have.
	for _, m in ipairs(members) do
		if m.class == "PALADIN" then
			local spec = m.spec or (m.name == PP.selfName and opts.selfSpec) or "HOLY"
			local info = {
				[B.WISDOM] = { rank = 1, talent = spec == "HOLY" and 2 or 0 },
				[B.MIGHT] = { rank = 1, talent = spec == "RET" and 5 or 0 },
				[B.KINGS] = { rank = 1, talent = 0 },
				[B.SALVATION] = { rank = 1, talent = 0 },
				[B.LIGHT] = { rank = 1, talent = 0 },
			}
			if spec == "PROT" then
				info[B.SANCTUARY] = { rank = 1, talent = 2 }
			end
			PP.observed[m.name] = info
			PP.heard[m.name] = true
		end
	end

	local ok, err = pcall(fn)

	for _, n in ipairs(names) do _G[n] = saved[n] end
	_G.PallyPower, _G.PallyPower_Assignments = savedPP, savedAssign
	PP.selfName, PP.selfSpec = nil, nil
	if not ok then error(err, 0) end
end

local function profileOf(result, name)
	for _, m in ipairs(result.members) do
		if m.name == name then return m.profileKey end
	end
end

--------------------------------------------------------------------------
print("== a prot paladin tanking a 5-man is treated as a tank ==")
do
	-- The reported bug: in a party the roster hardcoded tank = false, because
	-- MAINTANK slots are a raid-only concept. A tank in a dungeon was invisible,
	-- so a paladin fell through to the class default of holy and assigned
	-- themselves Wisdom.
	withGroup({
		raid = false,
		selfSpec = "PROT",
		members = {
			{ name = "Rageblue", class = "PALADIN", role = "TANK" },
			{ name = "Barkskin", class = "DRUID",   role = "HEALER" },
			{ name = "Cleaver",  class = "WARRIOR", role = "DAMAGER" },
			{ name = "Totemic",  class = "SHAMAN",  role = "DAMAGER" },
		},
	}, function()
		local raid = R:ScanLive(nil)
		T.eq("all four scanned", #raid.members, 4)
		T.eq("the paladin was found", #raid.paladins, 1)

		local tanks = 0
		for _, m in ipairs(raid.members) do if m.tank then tanks = tanks + 1 end end
		T.eq("the tank is seen in a party", tanks, 1)

		local result = S:Solve(raid, S.defaultConfig())
		T.eq("resolved as the prot paladin profile",
			profileOf(result, "Rageblue"), "PALADIN_TANK")

		-- With one paladin the column gets exactly the top of that list.
		local col = result.perClass[B.CLASS_IDS.PALADIN]
		T.eq("one blessing for one paladin", #col.blessings, 1)
		T.eq("and it is Kings, not Wisdom", col.blessings[1], B.KINGS)

		T.check("the tank is not given Salvation",
			not result.delivered["Rageblue"][B.SALVATION])
	end)
end

--------------------------------------------------------------------------
print("== group finder roles beat the class fallback ==")
do
	withGroup({
		raid = false,
		selfSpec = "HOLY",
		members = {
			{ name = "Healpally", class = "PALADIN", role = "HEALER" },
			{ name = "Moonkin",   class = "DRUID",   role = "DAMAGER" },
			{ name = "Treeform",  class = "DRUID",   role = "HEALER" },
			{ name = "Shadowy",   class = "PRIEST",  role = "DAMAGER" },
		},
	}, function()
		local result = S:Solve(R:ScanLive(nil), S.defaultConfig())
		T.eq("a damage druid is not assumed to be a healer",
			profileOf(result, "Moonkin"), "DRUID_BALANCE")
		T.eq("a healing druid still resolves to resto",
			profileOf(result, "Treeform"), "DRUID_RESTO")
		T.eq("a damage priest resolves to shadow",
			profileOf(result, "Shadowy"), "PRIEST_SHADOW")
		T.eq("our own holy spec is used", profileOf(result, "Healpally"), "PALADIN_HOLY")
	end)
end

--------------------------------------------------------------------------
print("== raid Main Tank slots still work, and roles cover off-tanks ==")
do
	withGroup({
		raid = true,
		selfSpec = "RET",
		members = {
			{ name = "Retpally", class = "PALADIN", role = "DAMAGER" },
			{ name = "Maintank", class = "WARRIOR", raidRole = "MAINTANK" },
			-- An off-tank in no Main Tank slot: previously invisible, now caught
			-- by the role they picked.
			{ name = "Offtank",  class = "WARRIOR", role = "TANK" },
			{ name = "Dpswarr",  class = "WARRIOR", role = "DAMAGER" },
		},
	}, function()
		local raid = R:ScanLive(nil)
		local tanks = {}
		for _, m in ipairs(raid.members) do if m.tank then tanks[m.name] = true end end
		T.check("main tank seen", tanks.Maintank)
		T.check("off-tank seen through their role", tanks.Offtank)
		T.check("the DPS warrior is not a tank", not tanks.Dpswarr)

		local result = S:Solve(raid, S.defaultConfig())
		T.check("neither tank keeps Salvation",
			not result.delivered.Maintank[B.SALVATION]
			and not result.delivered.Offtank[B.SALVATION])
		T.eq("our own ret spec is used", profileOf(result, "Retpally"), "PALADIN_RET")
	end)
end

--------------------------------------------------------------------------
print("== a member with no role at all is flagged as a guess ==")
do
	withGroup({
		raid = false,
		selfSpec = "RET",
		members = {
			{ name = "Retpally", class = "PALADIN", role = "DAMAGER" },
			{ name = "Mystery",  class = "DRUID" },
		},
	}, function()
		local result = S:Solve(R:ScanLive(nil), S.defaultConfig())
		for _, m in ipairs(result.members) do
			if m.name == "Mystery" then
				T.check("no role means a guessed profile", m.guessed == true)
			end
			if m.name == "Retpally" then
				T.check("a known paladin spec is not a guess", m.guessed == false)
			end
		end
	end)
end

T.report("roles")
