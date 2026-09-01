-- Loads the addon's pure-Lua core outside WoW.
--
-- WoW passes (addonName, addonTable) as varargs to every file in a .toc; Lua
-- 5.1 chunks are vararg functions, so we can reproduce that exactly and load
-- the real files with no shims or modification.
local APP = {}

local ROOT = (os.getenv("APP_ROOT") or ".")

local function load(path)
	local chunk, err = loadfile(ROOT .. "/" .. path)
	if not chunk then error("failed to load " .. path .. ": " .. tostring(err)) end
	chunk("AutoPallyPower", APP)
end

load("Core/Init.lua")
load("Core/Blessings.lua")
load("Core/Profiles.lua")
load("Core/Rules.lua")
load("Core/Solver.lua")
load("Core/TestRaid.lua")
-- Pure at load time; its WoW calls all sit inside functions.
load("Core/Roster.lua")
-- Pure at load time: the adapter only touches WoW globals inside its functions.
load("Integration/PallyPower.lua")
load("Core/Config.lua")

-- Minimal test runner.
local T = { passed = 0, failed = 0, failures = {} }

function T.check(name, ok, detail)
	if ok then
		T.passed = T.passed + 1
	else
		T.failed = T.failed + 1
		T.failures[#T.failures + 1] = name .. (detail and ("  --  " .. detail) or "")
		print("  FAIL  " .. name .. (detail and ("  --  " .. detail) or ""))
	end
end

function T.eq(name, got, want)
	T.check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end

function T.report(label)
	print(("\n%s: %d passed, %d failed"):format(label, T.passed, T.failed))
	if T.failed > 0 then
		for _, f in ipairs(T.failures) do print("   * " .. f) end
		os.exit(1)
	end
end

return { APP = APP, T = T }
