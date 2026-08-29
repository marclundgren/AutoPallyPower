local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local TR, B = APP.TestRaid, APP.Blessings

-- The generator's counts are settings the user will dial in, so they must be
-- exact, not approximate.
for _, spec in ipairs({
	{ paladins = 1, tanks = 1, healers = 2, raidSize = 10 },
	{ paladins = 2, tanks = 2, healers = 5, raidSize = 25 },
	{ paladins = 3, tanks = 3, healers = 7, raidSize = 25 },
	{ paladins = 5, tanks = 2, healers = 6, raidSize = 40 },
}) do
	for seed = 1, 25 do
		spec.seed = seed
		local raid = TR:Generate(spec)
		local label = ("p%d/t%d/h%d/n%d seed%d"):format(
			spec.paladins, spec.tanks, spec.healers, spec.raidSize, seed)

		T.check("exact raid size " .. label, #raid.members == spec.raidSize,
			"got " .. #raid.members)
		T.check("exact paladin count " .. label, #raid.paladins == spec.paladins,
			"got " .. #raid.paladins)

		local pallyMembers, tanks = 0, 0
		for _, m in ipairs(raid.members) do
			if m.class == "PALADIN" then pallyMembers = pallyMembers + 1 end
			if m.tank then tanks = tanks + 1 end
		end
		T.check("paladin members match paladin list " .. label,
			pallyMembers == spec.paladins, "got " .. pallyMembers)
		T.check("exact tank count " .. label, tanks == spec.tanks, "got " .. tanks)

		local seen = {}
		for _, m in ipairs(raid.members) do
			T.check("names are unique " .. label, not seen[m.name], m.name)
			seen[m.name] = true
		end
	end
end

-- Same seed must reproduce the same raid.
local a = TR:Generate({ seed = 99, raidSize = 25, paladins = 2, tanks = 2, healers = 5 })
local b = TR:Generate({ seed = 99, raidSize = 25, paladins = 2, tanks = 2, healers = 5 })
local same = true
for i = 1, #a.members do
	if a.members[i].name ~= b.members[i].name or a.members[i].profile ~= b.members[i].profile then
		same = false
	end
end
T.check("same seed reproduces the same raid", same)

T.report("testraid")
