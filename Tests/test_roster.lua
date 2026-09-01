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

--------------------------------------------------------------------------
print("== paladin rows expose talents, not just the profile ==")
do
	local raid = TR:Generate({ seed = 77, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local byName = {}
	for _, g in ipairs(R:Breakdown(raid)) do
		for _, row in ipairs(g.rows) do byName[row.name] = row end
	end

	for _, p in ipairs(raid.paladins) do
		local row = byName[p.name]
		T.check("paladin appears in the breakdown", row ~= nil, p.name)
		T.eq("talent spec is carried through", row.paladinSpec, p.spec)
		T.eq("Sanctuary capability is carried through",
			row.canSanctuary, p.canCast[B.SANCTUARY] or false)
		T.eq("Kings capability is carried through",
			row.canKings, p.canCast[B.KINGS] or false)
	end

	-- Non-paladins have no business carrying paladin fields.
	for name, row in pairs(byName) do
		if not row.isPaladin then
			T.eq("no talent spec on a non-paladin " .. name, row.paladinSpec, nil)
			T.eq("no Sanctuary flag on a non-paladin " .. name, row.canSanctuary, nil)
		end
	end
end

--------------------------------------------------------------------------
print("== a protection paladin who is not tanking is still identifiable ==")
do
	-- The regression this guards: such a paladin is profiled as retribution,
	-- because the profile follows the raid role. Without the talent spec on
	-- the row, the only person in the raid who has Sanctuary looks like an
	-- ordinary ret paladin.
	local found = 0
	for seed = 1, 40 do
		local raid = TR:Generate({ seed = seed, raidSize = 25, paladins = 5, tanks = 1, healers = 4 })
		local byName = {}
		for _, g in ipairs(R:Breakdown(raid)) do
			for _, row in ipairs(g.rows) do byName[row.name] = row end
		end
		for _, p in ipairs(raid.paladins) do
			local row = byName[p.name]
			if p.spec == "PROT" and not row.tank then
				found = found + 1
				T.eq("the profile does follow the role", row.spec, "Retribution")
				T.eq("but the talent spec still says protection", row.paladinSpec, "PROT")
				T.check("and Sanctuary is flagged", row.canSanctuary == true, p.name)
			end
		end
	end
	T.check("the case actually occurred in the sample", found > 0,
		"found " .. found .. " prot paladins not tanking")
end

--------------------------------------------------------------------------
print("== with a solved plan, rows say what happens to each player ==")
do
	local S = APP.Solver
	local raid = TR:Generate({ seed = 14, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
	local result = S:Solve(raid, S.defaultConfig())
	local groups = R:Breakdown(raid, nil, result)

	local pallyNames = {}
	for _, p in ipairs(raid.paladins) do pallyNames[p.name] = p end

	for _, g in ipairs(groups) do
		for _, row in ipairs(g.rows) do
			T.check("every player has a receives list", row.receives ~= nil, row.name)

			-- It must match what the solver actually delivered.
			local expected = {}
			for b in pairs(result.delivered[row.name] or {}) do expected[b] = true end
			local n = 0
			for _, b in ipairs(row.receives) do
				T.check("receives only what was delivered", expected[b] == true,
					row.name .. " / " .. B:Name(b))
				n = n + 1
			end
			local want = 0
			for _ in pairs(expected) do want = want + 1 end
			T.eq("receives is complete for " .. row.name, n, want)

			if row.isPaladin then
				T.check("paladins list what they cast", row.casts ~= nil, row.name)
				local seen = {}
				for _, b in ipairs(row.casts) do
					T.check("casts has no duplicates", not seen[b], row.name)
					seen[b] = true
					T.check("a paladin only casts what it can",
						pallyNames[row.name].canCast[b] == true, row.name)
				end
			else
				T.eq("non-paladins cast nothing", row.casts, nil)
			end
		end
	end
end

--------------------------------------------------------------------------
print("== a pinned paladin is marked as pinned ==")
do
	local S = APP.Solver
	-- 25-man with a prot paladin tanking fires the Salvation rule.
	local raid, result, pinnedName
	for seed = 1, 60 do
		raid = TR:Generate({ seed = seed, raidSize = 25, paladins = 3, tanks = 2, healers = 6 })
		result = S:Solve(raid, S.defaultConfig())
		if #result.appliedRules > 0 then
			pinnedName = result.appliedRules[1].paladin
			break
		end
	end
	T.check("found a raid where the rule fires", pinnedName ~= nil)

	if pinnedName then
		for _, g in ipairs(R:Breakdown(raid, nil, result)) do
			for _, row in ipairs(g.rows) do
				if row.name == pinnedName then
					T.eq("the pinned paladin is marked", row.pinnedTo, B.SALVATION)
					T.check("and Salvation is among what they cast", (function()
						for _, b in ipairs(row.casts or {}) do
							if b == B.SALVATION then return true end
						end
						return false
					end)())
				elseif row.isPaladin then
					T.eq("other paladins are not marked pinned", row.pinnedTo, nil)
				end
			end
		end
	end
end

--------------------------------------------------------------------------
print("== the breakdown still works with no plan ==")
do
	local raid = TR:Generate({ seed = 3, raidSize = 25, paladins = 2, tanks = 2, healers = 5 })
	local groups = R:Breakdown(raid)
	local total = 0
	for _, g in ipairs(groups) do
		for _, row in ipairs(g.rows) do
			total = total + 1
			T.eq("no receives without a plan", row.receives, nil)
			T.eq("no casts without a plan", row.casts, nil)
			-- Composition detail is still there, which is the point.
			T.check("class still present", row.classLabel ~= nil, row.name)
			T.check("spec still present", row.spec ~= nil, row.name)
		end
	end
	T.eq("everyone still listed", total, #raid.members)
end

T.report("roster")
