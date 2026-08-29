local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T

-- Report.lua is a UI file but is pure Lua, so load it into the same namespace.
local chunk = assert(loadfile((os.getenv("APP_ROOT") or ".") .. "/UI/Report.lua"))
chunk("AutoPallyPower", APP)

local S, TR, Report = APP.Solver, APP.TestRaid, APP.Report

local raid = TR:Generate({ seed = 1337, raidSize = 25, paladins = 2, tanks = 2, healers = 5 })
local result = S:Solve(raid, S.defaultConfig())

local plan = Report:Plan(result, { plain = true })
T.check("plan renders lines", #plan > 5, "got " .. #plan)
T.check("plan mentions paladin count", plan[2]:find("2 paladins") ~= nil, plan[2])

local per = Report:PerMember(result, { plain = true })
T.check("per-member renders lines", #per > 10, "got " .. #per)

-- Every tank must appear without Salvation in the rendered output.
for _, m in ipairs(result.members) do
	if m.tank then
		T.check("tank " .. m.name .. " has no Salv delivered",
			not result.delivered[m.name][APP.Blessings.SALVATION])
	end
end

T.report("report")

print("\n----- sample output: 25-man, 2 paladins, 2 tanks, 5 healers -----\n")
for _, l in ipairs(plan) do print(l) end
print("")
for _, l in ipairs(per) do print(l) end
