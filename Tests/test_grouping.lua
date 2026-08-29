local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local P = APP.Profiles

local function flatten(groups)
	local keys = {}
	for _, g in ipairs(groups) do
		for _, item in ipairs(g.items) do keys[#keys + 1] = item.key end
	end
	return keys
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

--------------------------------------------------------------------------
print("== both groupings list every profile exactly once ==")
do
	local total = count(P.defaults)
	for _, mode in ipairs({ "class", "role" }) do
		local groups = P:GroupedList(mode)
		local keys = flatten(groups)
		T.eq(mode .. ": every profile appears", #keys, total)

		local seen = {}
		for _, k in ipairs(keys) do
			T.check(mode .. ": no profile listed twice", not seen[k], k)
			seen[k] = true
		end
		for key in pairs(P.defaults) do
			T.check(mode .. ": profile is reachable", seen[key] == true, key)
		end
	end
end

--------------------------------------------------------------------------
print("== class grouping follows the raid grid's column order ==")
do
	local groups = P:GroupedList("class")
	local labels = {}
	for _, g in ipairs(groups) do labels[#labels + 1] = g.key end
	local want = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN" }
	T.eq("same number of class groups", #labels, #want)
	for i = 1, #want do
		T.eq("class group " .. i, labels[i], want[i])
	end

	-- Headings should not be repeated in their own items.
	for _, g in ipairs(groups) do
		for _, item in ipairs(g.items) do
			T.check("label does not repeat its class heading",
				not item.label:find("^" .. g.label .. " %-"), g.label .. " / " .. item.label)
		end
	end
end

--------------------------------------------------------------------------
print("== role grouping puts tanks first and buckets correctly ==")
do
	local groups = P:GroupedList("role")
	T.eq("tanks lead", groups[1].key, "TANK")

	local byKey = {}
	for _, g in ipairs(groups) do byKey[g.key] = g end
	T.eq("four role groups", #groups, 4)

	for _, item in ipairs(byKey.TANK.items) do
		T.check("everything under Tanks is a tank profile", item.profile.tank == true, item.key)
		T.check("no tank profile offers Salvation", (function()
			for _, entry in ipairs(item.profile.priority) do
				local b = type(entry) == "table" and entry.b or entry
				if b == APP.Blessings.SALVATION then return false end
			end
			return true
		end)(), item.key)
	end
	for _, item in ipairs(byKey.HEALER.items) do
		T.eq("healers bucket by role", item.profile.role, "HEALER")
	end

	-- Role grouping keeps the full label, since the class is no longer implied.
	local found = false
	for _, item in ipairs(byKey.TANK.items) do
		if item.key == "WARRIOR_TANK" then
			T.eq("role mode keeps the class in the label", item.label, "Warrior - Protection")
			found = true
		end
	end
	T.check("found the prot warrior under Tanks", found)
end

--------------------------------------------------------------------------
print("== grouping is deterministic ==")
do
	for _, mode in ipairs({ "class", "role" }) do
		local a = table.concat(flatten(P:GroupedList(mode)), ",")
		local b = table.concat(flatten(P:GroupedList(mode)), ",")
		local c = table.concat(flatten(P:GroupedList(mode)), ",")
		T.check(mode .. ": same order every call", a == b and b == c)
	end
end

--------------------------------------------------------------------------
print("== an unknown mode falls back to class rather than erroring ==")
do
	local groups = P:GroupedList("nonsense")
	T.eq("falls back to class grouping", groups[1].key, "WARRIOR")
	local nilMode = P:GroupedList(nil)
	T.eq("nil falls back too", nilMode[1].key, "WARRIOR")
end

T.report("grouping")
