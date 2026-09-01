local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local B, P, R, TR = APP.Blessings, APP.Profiles, APP.Roster, APP.TestRaid

--------------------------------------------------------------------------
print("== generated names come from the pool and stay usable in game ==")
do
	for _, spec in ipairs({
		{ raidSize = 10, paladins = 1, tanks = 1, healers = 2 },
		{ raidSize = 25, paladins = 3, tanks = 2, healers = 6 },
		{ raidSize = 40, paladins = 5, tanks = 3, healers = 10 },
	}) do
		for seed = 1, 20 do
			spec.seed = seed
			local raid = TR:Generate(spec)
			local label = ("n%d seed%d"):format(spec.raidSize, seed)

			local seen = {}
			for _, m in ipairs(raid.members) do
				T.check("names are unique " .. label, not seen[m.name], m.name)
				seen[m.name] = true
				T.check("name fits WoW's 12 character limit " .. label,
					#m.name <= 12, m.name)
				T.check("name starts with a capital " .. label,
					m.name:match("^%u%l") ~= nil, m.name)
			end
		end
	end
end

--------------------------------------------------------------------------
print("== a 40-man still draws real names, not fallback numbering ==")
do
	local raid = TR:Generate({ seed = 5, raidSize = 40, paladins = 4, tanks = 3, healers = 10 })
	T.eq("full forty generated", #raid.members, 40)
	local fallbacks = 0
	for _, m in ipairs(raid.members) do
		if m.name:match("^Raider%d+$") then fallbacks = fallbacks + 1 end
	end
	T.eq("no fallback numbering needed at 40", fallbacks, 0)
end

--------------------------------------------------------------------------
print("== the same seed deals the same names ==")
do
	local a = TR:Generate({ seed = 4242, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local b = TR:Generate({ seed = 4242, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	for i = 1, #a.members do
		T.eq("name " .. i .. " reproduces", b.members[i].name, a.members[i].name)
	end

	local c = TR:Generate({ seed = 4243, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local differs = false
	for i = 1, #a.members do
		if c.members[i].name ~= a.members[i].name then differs = true end
	end
	T.check("a different seed deals different names", differs)
end

--------------------------------------------------------------------------
print("== the breakdown accounts for everyone, once ==")
do
	for seed = 1, 40 do
		local raid = TR:Generate({ seed = seed, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
		local groups = R:Breakdown(raid)

		local listed, total = {}, 0
		for _, g in ipairs(groups) do
			for _, row in ipairs(g.rows) do
				T.check("nobody is listed twice", not listed[row.name], row.name)
				listed[row.name] = true
				total = total + 1
			end
		end
		T.eq("everyone is listed", total, #raid.members)
		for _, m in ipairs(raid.members) do
			T.check("member reachable in the breakdown", listed[m.name] == true, m.name)
		end
	end
end

--------------------------------------------------------------------------
print("== groups read in role order, tanks first ==")
do
	local raid = TR:Generate({ seed = 77, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local groups = R:Breakdown(raid)

	local order = {}
	for _, g in ipairs(groups) do order[#order + 1] = g.key end
	local rank = {}
	for i, key in ipairs(P.ROLE_ORDER) do rank[key] = i end
	for i = 2, #order do
		T.check("groups follow ROLE_ORDER",
			rank[order[i]] > rank[order[i - 1]], order[i - 1] .. " then " .. order[i])
	end
	T.eq("tanks lead", order[1], "TANK")

	-- Within tanks, the main tank comes first: it decides which paladin a
	-- pinned blessing lands on, so it should not be buried.
	local tanks
	for _, g in ipairs(groups) do if g.key == "TANK" then tanks = g end end
	if tanks and #tanks.rows > 1 then
		local mtSeen, afterMT = false, false
		for _, row in ipairs(tanks.rows) do
			if row.mainTank then
				T.check("no ordinary tank precedes the main tank", not afterMT, row.name)
				mtSeen = true
			else
				if mtSeen then afterMT = true end
			end
		end
	end
end

--------------------------------------------------------------------------
print("== each row carries class, spec and role ==")
do
	local raid = TR:Generate({ seed = 77, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local byName = {}
	for _, g in ipairs(R:Breakdown(raid)) do
		for _, row in ipairs(g.rows) do
			byName[row.name] = row
			T.check("class label present", row.classLabel and #row.classLabel > 0, row.name)
			T.check("spec label present", row.spec and #row.spec > 0, row.name)
			T.eq("role key matches its group", row.roleKey, g.key)
			T.check("class id resolves", row.classID ~= nil, row.name)
		end
	end

	-- Cross-check against the raid itself.
	for _, m in ipairs(raid.members) do
		local row = byName[m.name]
		T.eq("class matches the member", row.class, m.class)
		T.eq("tank flag matches", row.tank, m.tank)
		T.eq("paladin flag matches", row.isPaladin, m.class == "PALADIN")
		if m.class == "PALADIN" then
			T.check("paladins are flagged", row.isPaladin)
		end
	end

	-- Every generated member carries an explicit profile, so nothing is a guess.
	for _, row in pairs(byName) do
		T.check("a generated raid needs no spec guessing", row.guessed == false, row.name)
	end
end

--------------------------------------------------------------------------
print("== spec labels do not repeat the class ==")
do
	for key, profile in pairs(P.defaults) do
		local label = P:SpecLabel(profile)
		local classLabel = P.CLASS_LABELS[profile.class]
		T.check("spec label is non-empty", label and #label > 0, key)
		if classLabel then
			T.check("spec label never repeats the class outright",
				label ~= classLabel, key .. " -> " .. label)
			T.check("spec label drops the class prefix",
				not label:find("^" .. classLabel .. "%s*%-"), key .. " -> " .. label)
		end
	end

	-- Classes with a single profile say so, rather than echoing themselves.
	T.eq("rogue reads as all specs", P:SpecLabel(P.defaults.ROGUE), "All specs")
	T.eq("mage reads as all specs", P:SpecLabel(P.defaults.MAGE), "All specs")
	T.eq("prot warrior keeps its spec", P:SpecLabel(P.defaults.WARRIOR_TANK), "Protection")
	T.eq("feral tank keeps its spec", P:SpecLabel(P.defaults.DRUID_TANK), "Feral (Tank)")
end

--------------------------------------------------------------------------
print("== the breakdown is deterministic ==")
do
	local raid = TR:Generate({ seed = 99, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local function fingerprint()
		local parts = {}
		for _, g in ipairs(R:Breakdown(raid)) do
			for _, row in ipairs(g.rows) do
				parts[#parts + 1] = g.key .. ":" .. row.name .. ":" .. row.spec
			end
		end
		return table.concat(parts, "|")
	end
	local a, b, c = fingerprint(), fingerprint(), fingerprint()
	T.check("same raid reads the same way every time", a == b and b == c)
	T.check("fingerprint is non-trivial", #a > 100)
end

--------------------------------------------------------------------------
print("== an empty roster is handled ==")
do
	local groups = R:Breakdown({ members = {} })
	T.eq("no groups for nobody", #groups, 0)
	local none = R:Breakdown({})
	T.eq("a raid with no member list is safe", #none, 0)
end

T.report("roster")
