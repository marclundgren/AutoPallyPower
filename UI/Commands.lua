-- Slash commands and addon lifecycle.
--
-- Everything the addon does is reachable from /app before any of the visual UI
-- exists, which keeps the engine testable in a real raid without waiting on
-- the interface.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local S = APP.Solver
local R = APP.Roster
local PP = APP.PP
local Report = APP.Report
local Config = APP.Config

local Commands = {}
APP.Commands = Commands

local function out(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[APP]|r " .. tostring(msg))
end
APP.Print = out

local function outLines(lines)
	for _, l in ipairs(lines) do
		DEFAULT_CHAT_FRAME:AddMessage(l)
	end
end

--------------------------------------------------------------------------
-- Solving
--------------------------------------------------------------------------

--- Solve whatever raid is current (live, or simulated in test mode).
function Commands:Solve()
	local db = APP.db
	-- Cheap, and it means our own talents are never the stale part of a plan.
	PP:ScanSelf()
	local raid = R:Current(db.playerProfileOverrides)

	if raid.empty then
		return nil, "Not in a group. Use /app test to try a simulated raid."
	end
	if #raid.paladins == 0 then
		return nil, "No paladins found. PallyPower needs to have seen at least one."
	end

	local result = S:Solve(raid, Config:SolverConfig())
	APP.lastResult = result
	APP.lastRaid = raid
	return result
end

--------------------------------------------------------------------------
-- Command handlers
--------------------------------------------------------------------------

local handlers = {}

handlers.plan = function()
	local result, err = Commands:Solve()
	if not result then return out(err) end
	outLines(Report:Plan(result))
	if R:IsSimulated() then
		out("|cff9d9d9dsimulated raid -- /app apply is disabled in test mode|r")
	end
end

handlers.report = function()
	local result = APP.lastResult
	if not result then
		local err
		result, err = Commands:Solve()
		if not result then return out(err) end
	end
	outLines(Report:PerMember(result))
end

handlers.preview = function()
	local result, err = Commands:Solve()
	if not result then return out(err) end
	if R:IsSimulated() then
		return out("Test mode is on; there is nothing live to compare against.")
	end
	local ok, msg = PP:Assert()
	if not ok then return out(msg) end

	local changes = PP:Diff(result)
	outLines(Report:Diff(changes))
end

handlers.apply = function()
	local result, err = Commands:Solve()
	if not result then return out(err) end

	if R:IsSimulated() then
		return out("Test mode is on. Turn it off with /app test off before applying.")
	end
	local ok, msg = PP:Assert()
	if not ok then return out(msg) end

	if #result.paladins > 1 and not PP:CanControlOthers() then
		out("|cffff2020You are not raid leader or assistant.|r Other paladins' clients will")
		out("ignore assignments you set for them. Your own row will still apply.")
	end

	local applied, message, stats = PP:Apply(result)
	if not applied then return out(message) end

	out(("Applied: %d paladin rows, %d greater blessing changes, %d overrides set, %d cleared.")
		:format(stats.rows, stats.cells, stats.overrides, stats.cleared))
	if #result.warnings > 0 then
		for _, w in ipairs(result.warnings) do out("|cffff2020" .. w .. "|r") end
	end
end

handlers.test = function(args)
	local db = APP.db
	local sub = args[1]

	if sub == "off" then
		R:ClearSimulated()
		db.testMode.enabled = false
		return out("Test mode off. Using the live raid.")
	end

	-- /app test [size] [paladins] [tanks] [healers] [seed]
	local t = db.testMode
	t.raidSize = tonumber(args[1]) or t.raidSize
	t.paladins = tonumber(args[2]) or t.paladins
	t.tanks    = tonumber(args[3]) or t.tanks
	t.healers  = tonumber(args[4]) or t.healers
	t.seed     = tonumber(args[5]) or nil

	local raid = APP.TestRaid:Generate({
		raidSize = t.raidSize,
		paladins = t.paladins,
		tanks = t.tanks,
		healers = t.healers,
		seed = t.seed,
	})
	R:SetSimulated(raid)
	t.enabled = true

	local sum = R:Summary(raid)
	out(("Test raid generated (seed %d): %d players, %d paladins, %d tanks, %d healers.")
		:format(raid.seed, sum.size, sum.paladins, sum.tanks, sum.healers))
	out("Run /app plan to see what it would assign.")
end

handlers.tankmode = function(args)
	local db = APP.db
	local mode = args[1]
	if mode ~= "threat" and mode ~= "survival" then
		return out(("Tank mode is '%s'. Use /app tankmode threat|survival."):format(db.tankPriority))
	end
	db.tankPriority = mode
	out(("Tank mode set to '%s'. %s"):format(mode,
		mode == "threat" and "Tanks favour Might/Sanctuary for threat."
		or "Tanks favour Blessing of Light for survivability (needs a holy paladin)."))
end

handlers.grouping = function(args)
	local db = APP.db
	local mode = args[1]
	if mode ~= "class" and mode ~= "role" then
		out(("Priority list groups by '%s'. Use /app grouping class|role."):format(db.railGrouping))
		return
	end
	db.railGrouping = mode
	out(("Priority list now groups by %s."):format(mode))

	for _, group in ipairs(P:GroupedList(mode, db.profiles)) do
		local names = {}
		for _, item in ipairs(group.items) do names[#names + 1] = item.label end
		out(("  |cffffd100%s|r  %s"):format(group.label, table.concat(names, ", ")))
	end
end

handlers.override = function(args)
	local db = APP.db
	local name, profileKey = args[1], args[2]
	if not name then
		local n = 0
		for player, key in pairs(db.playerProfileOverrides) do
			out(("  %s -> %s"):format(player, key))
			n = n + 1
		end
		if n == 0 then out("No manual spec overrides set.") end
		return
	end
	if profileKey == "clear" then
		db.playerProfileOverrides[name] = nil
		return out(("Cleared spec override for %s."):format(name))
	end
	if not P.defaults[profileKey] then
		out(("Unknown profile '%s'. Known profiles:"):format(tostring(profileKey)))
		local keys = {}
		for key in pairs(P.defaults) do keys[#keys + 1] = key end
		table.sort(keys)
		out("  " .. table.concat(keys, ", "))
		return
	end
	db.playerProfileOverrides[name] = profileKey
	out(("%s is now treated as %s."):format(name, P.defaults[profileKey].label))
end

handlers.status = function()
	local db = APP.db
	PP:ScanSelf()
	out(("PallyPower detected: %s"):format(PP:IsAvailable() and "yes" or "no"))
	out(("Test mode: %s"):format(R:IsSimulated() and "on" or "off"))
	out(("Tank mode: %s"):format(db.tankPriority))
	out(("Priority grouping: %s"):format(db.railGrouping))
	out(("Override threshold: %d"):format(db.overridePenalty))
	local pallys = PP:GetPaladins()
	local inGroup = (_G.GetNumGroupMembers and _G.GetNumGroupMembers() or 0) > 0
	out(("Paladins known to PallyPower: %d"):format(#pallys))
	if not inGroup then
		-- PallyPower only broadcasts while grouped, so out of a group this list
		-- is whatever it remembered from previous raids, not who is with you.
		out("|cff9d9d9d  (remembered from previous raids -- PallyPower only syncs while grouped)|r")
	end
	for _, p in ipairs(pallys) do
		local caps = {}
		for _, b in ipairs(B.ALL) do
			if p.canCast[b] then caps[#caps + 1] = B:Short(b) end
		end
		local note = ""
		if p.name == PP.selfName then
			note = "  |cff1eff00(you, read from your spellbook)|r"
		elseif not p.capabilitiesKnown then
			note = "  |cff9d9d9d(assumed -- not synced yet)|r"
		end
		out(("  %s  spec=%s  can cast: %s%s"):format(
			p.name, p.spec, table.concat(caps, " "), note))
	end
end

handlers.help = function()
	out("AutoPallyPower commands:")
	out("  /app plan                    solve the current raid and show the plan")
	out("  /app report                  show what each player would end up with")
	out("  /app preview                 show what applying would change")
	out("  /app apply                   push the plan into PallyPower")
	out("  /app test [n] [pal] [tank] [heal] [seed]   simulate a raid")
	out("  /app test off                back to the live raid")
	out("  /app tankmode threat|survival")
	out("  /app grouping class|role         how the priority list is grouped")
	out("  /app override <player> <PROFILE|clear>")
	out("  /app status                  what the addon currently sees")
end

--------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------

function Commands:Handle(input)
	input = (input or ""):match("^%s*(.-)%s*$")
	local parts = {}
	for word in input:gmatch("%S+") do parts[#parts + 1] = word end

	local cmd = table.remove(parts, 1)
	if not cmd or cmd == "" then cmd = "plan" end

	local handler = handlers[cmd:lower()]
	if not handler then
		out(("Unknown command '%s'."):format(cmd))
		return handlers.help()
	end
	handler(parts)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("CHARACTER_POINTS_CHANGED")

frame:SetScript("OnEvent", function(_, event, arg1, ...)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		Config:Load()

		-- Listen in on PallyPower's own sync so we learn every paladin's
		-- blessing ranks and talents without adding traffic.
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			C_ChatInfo.RegisterAddonMessagePrefix(PP.PREFIX)
		elseif RegisterAddonMessagePrefix then
			RegisterAddonMessagePrefix(PP.PREFIX)
		end

		SLASH_AUTOPALLYPOWER1 = "/app"
		SLASH_AUTOPALLYPOWER2 = "/autopallypower"
		SlashCmdList["AUTOPALLYPOWER"] = function(msg) Commands:Handle(msg) end

		if APP.Minimap then APP.Minimap:Create() end

		if not PP:IsAvailable() then
			out("|cffff2020PallyPower not found.|r AutoPallyPower is a companion to it.")
		else
			out("loaded. /app for commands.")
		end

	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = arg1, ...
		PP:OnAddonMessage(prefix, message, channel, sender)

	else
		-- Talents and spellbook can both change under us; rescanning is cheap.
		PP:ScanSelf()
	end
end)
