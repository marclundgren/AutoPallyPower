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

handlers.ui = function()
	if APP.MainFrame then APP.MainFrame:Toggle() end
end

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

	local applied, message, stats = PP:Apply(result)
	if not applied then return out(message) end

	out(("Applied: %d paladin rows, %d greater blessing changes, %d overrides set, %d cleared.")
		:format(stats.rows, stats.cells, stats.overrides, stats.cleared))

	-- Read it straight back. An override is one icon on one row of a pop-out
	-- list, so without this "did that work" is genuinely hard to answer.
	local report = PP:Verify(result)
	if report.ok then
		out(("|cff1eff00Verified:|r %d greater cells, %d overrides now match the plan.")
			:format(report.matchedGrid, report.matchedOverrides))
	else
		out(("|cffff2020Verify found %d missing and %d differing.|r Run /app verify for detail.")
			:format(#report.missing, #report.different))
	end

	if stats.blocked and #stats.blocked > 0 then
		out(("|cffff2020Skipped %d paladin(s)|r -- their client would have ignored it:")
			:format(#stats.blocked))
		for _, b in ipairs(stats.blocked) do
			out(("   %s -- %s"):format(b.name, b.why))
		end
		out("|cff9d9d9dFix either way: get raid assist, or ask them to tick Free Assignment")
		out("in PallyPower's own window. In a party only the party leader counts.|r")
	end
	if #result.warnings > 0 then
		for _, w in ipairs(result.warnings) do out("|cffff2020" .. w .. "|r") end
	end
end

handlers.refresh = function()
	PP:ScanSelf()

	-- Pull fresh talents and free-assign state from everyone. Their replies
	-- land over the next second or so, so solve now for an immediate answer and
	-- again once the responses have had time to arrive.
	local asked = PP:RequestSync()

	if APP.MainFrame then APP.MainFrame:RefreshNow() end

	if asked then
		out("Refreshed, and asked the group to resend their talents.")
		if C_Timer and C_Timer.After then
			C_Timer.After(2, function()
				APP.SafeCall("refresh follow-up", function()
					if APP.MainFrame then APP.MainFrame:RefreshNow() end
				end)
			end)
		end
	else
		out("Refreshed.")
	end
end

handlers.verify = function()
	local ok, msg = PP:Assert()
	if not ok then return out(msg) end
	if R:IsSimulated() then
		return out("Test mode is on; there is nothing live to verify against.")
	end

	local result, err = Commands:Solve()
	if not result then return out(err) end

	local report = PP:Verify(result)
	out(("Verify: %d greater blessing cells and %d overrides match what PallyPower holds.")
		:format(report.matchedGrid, report.matchedOverrides))

	if #report.skipped > 0 then
		out(("|cff9d9d9dNot checked (you cannot set them): %s|r")
			:format(table.concat(report.skipped, ", ")))
	end

	for _, m in ipairs(report.missing) do
		out(("|cffff2020missing|r  %s: %s on %s is not set")
			:format(m.paladin, B:Name(m.blessing), m.target))
	end
	for _, d in ipairs(report.different) do
		if d.kind == "override" then
			out(("|cffff2020differs|r  %s: %s has %s, plan wants %s")
				:format(d.paladin, d.target, B:Name(d.have), B:Name(d.want)))
		else
			out(("|cffff2020differs|r  %s: %s column has %s, plan wants %s")
				:format(d.paladin, B.CLASS_BY_ID[d.classID] or d.classID,
					B:Name(d.have), B:Name(d.want)))
		end
	end

	if report.ok then
		out("|cff1eff00Everything the plan asked for is in place.|r")
		if report.matchedOverrides > 0 then
			out("|cff9d9d9dOverrides show in PallyPower on the per-player pop-out for that class.|r")
		end
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
	out(("Your authority: %s"):format(PP:HaveAuthority()
		and "|cff1eff00leader or assistant -- you can set anyone|r"
		or "|cffff2020none -- you can only set paladins with Free Assignment on|r"))

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

		if p.name ~= PP.selfName then
			local mark = p.canControl and "|cff1eff00can set|r" or "|cffff2020cannot set|r"
			out(("      PallyPower: %s   free assign: %s   %s -- %s"):format(
				p.hasPallyPower and "yes" or "|cffff2020not seen|r",
				p.freeAssign == true and "on" or (p.freeAssign == false and "off" or "unknown"),
				mark, p.controlWhy))
		end
	end
end

handlers.help = function()
	out("AutoPallyPower commands:")
	out("  /app                         open the window")
	out("  /app plan                    solve the current raid and show the plan")
	out("  /app report                  show what each player would end up with")
	out("  /app preview                 show what applying would change")
	out("  /app verify                  check what PallyPower actually holds")
	out("  /app refresh                 recalculate, and resync the group")
	out("  /app apply                   push the plan into PallyPower")
	out("  /app test [n] [pal] [tank] [heal] [seed]   simulate a raid")
	out("  /app test off                back to the live raid")
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
	-- Bare /app opens the window; the text commands stay for when you want
	-- output you can paste somewhere.
	if not cmd or cmd == "" then cmd = "ui" end

	local handler = handlers[cmd:lower()]
	if not handler then
		out(("Unknown command '%s'."):format(cmd))
		return handlers.help()
	end
	APP.SafeCall("/app " .. cmd, handler, parts)
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
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ROLES_ASSIGNED")

frame:SetScript("OnEvent", function(_, event, arg1, ...)
	return APP.SafeCall("event " .. tostring(event), function(...)
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

		-- Read our own talents straight away rather than waiting for the first
		-- world event, so /app status is right the moment the addon loads.
		PP:ScanSelf()

		if APP.Minimap then APP.Minimap:Create() end

		if not PP:IsAvailable() then
			out("|cffff2020PallyPower not found.|r AutoPallyPower is a companion to it.")
		else
			out("loaded. /app for commands.")
		end

	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = arg1, ...
		PP:OnAddonMessage(prefix, message, channel, sender)

	elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
		-- Someone joined, left, or changed role. These fire in bursts, so the
		-- refresh is coalesced rather than run once per event.
		if APP.MainFrame then APP.MainFrame:ScheduleRefresh() end

	else
		-- Talents and spellbook can both change under us; rescanning is cheap.
		PP:ScanSelf()
		if APP.MainFrame then APP.MainFrame:ScheduleRefresh() end
	end
	end, ...)
end)
