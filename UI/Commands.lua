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

handlers.protsalv = function(args)
	local db = APP.db
	local arg = args[1]
	if arg ~= "on" and arg ~= "off" then
		out(("Prot paladin Salvation rule is %s. Use /app protsalv on|off.")
			:format(db.protPaladinSalvation and "on" or "off"))
		return
	end
	db.protPaladinSalvation = (arg == "on")
	out(("Prot paladin Salvation rule %s."):format(arg == "on" and "enabled" or "disabled"))
	if arg == "on" then
		out("A protection paladin who is tanking will carry Salvation for every class,")
		out("provided another paladin has Kings to give them.")
	end
end

handlers.pinmode = function(args)
	local db = APP.db
	local mode = args[1]
	if mode ~= "preference" and mode ~= "hard" then
		out(("Pin mode is '%s'. Use /app pinmode preference|hard."):format(db.pinMode))
		out("  preference  the solver may overrule a pin when a class clearly wants otherwise")
		out("  hard        a pinned paladin casts that blessing or nothing")
		return
	end
	db.pinMode = mode
	out(("Pin mode set to '%s'."):format(mode))
end

handlers.pin = function(args)
	local db = APP.db
	local name, blessing = args[1], args[2]
	if not name then
		local n = 0
		for pally, b in pairs(db.pins) do
			out(("  %s -> %s"):format(pally, B:Name(b)))
			n = n + 1
		end
		if n == 0 then out("No manual pins. Use /app pin <paladin> <blessing|clear>.") end
		return
	end
	if blessing == "clear" then
		db.pins[name] = nil
		return out(("Cleared pin for %s."):format(name))
	end
	local id
	for _, b in ipairs(B.ALL) do
		if B:Name(b):lower() == (blessing or ""):lower()
			or B:Short(b):lower() == (blessing or ""):lower() then
			id = b
		end
	end
	if not id then
		return out("Unknown blessing. Use one of: Wisdom, Might, Kings, Salvation, Light, Sanctuary.")
	end
	db.pins[name] = id
	out(("%s is pinned to %s for every class."):format(name, B:Name(id)))
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

handlers.roster = function()
	local db = APP.db
	local raid = R:Current(db.playerProfileOverrides)
	if raid.empty then
		return out("Not in a group. Use /app test to generate a raid first.")
	end

	-- Solve so the list can say what happens to each player, not just who is
	-- there. Without it the answer to "what is that paladin on" is a different
	-- command away.
	local result = Commands:Solve()

	local groups = R:Breakdown(raid, db.playerProfileOverrides, result)
	if #groups == 0 then
		return out("Nobody to list.")
	end

	local function blessings(list)
		if not list or #list == 0 then return "--" end
		local names = {}
		for _, b in ipairs(list) do names[#names + 1] = B:Short(b) end
		return table.concat(names, " ")
	end

	out(("%s -- %d players"):format(
		R:IsSimulated() and "Test raid" or "Raid", #raid.members))
	if result then
		out("|cff9d9d9d  name / role / class / spec  ->  receives  |  paladin casts|r")
	end

	local PALADIN_SPEC = { PROT = "protection", HOLY = "holy", RET = "retribution" }

	for _, group in ipairs(groups) do
		out(("|cffffd100%s|r |cff9d9d9d(%d)|r"):format(group.label, #group.rows))
		for _, row in ipairs(group.rows) do
			local role = row.mainTank and "|cffff8040MT|r"
				or (row.tank and "|cffc79c6eOT|r" or "  ")

			-- A paladin's talent spec only earns a mention when it differs from
			-- the profile they are treated by -- which is exactly the case that
			-- would otherwise hide the raid's only Sanctuary.
			local spec = row.spec
			local talent = PALADIN_SPEC[row.paladinSpec or ""]
			if row.isPaladin and talent and talent ~= row.spec:lower() then
				spec = ("%s |cfff58cba(%s)|r"):format(row.spec, talent)
			end

			local line = ("  %-13s %s %-9s %-22s"):format(row.name, role, row.classLabel, spec)
			if result then
				line = line .. (" %-16s"):format(blessings(row.receives))
				if row.isPaladin then
					line = line .. " |cffe0b060casts|r " .. blessings(row.casts)
					if row.pinnedTo then line = line .. " |cffe0b060(pinned)|r" end
				end
			end

			local marks = {}
			if row.isPaladin and row.canSanctuary then marks[#marks + 1] = "|cff5a8fa8sanc|r" end
			if row.isPaladin and not row.canKings then marks[#marks + 1] = "|cffe0575cno kings|r" end
			if row.guessed then marks[#marks + 1] = "|cff9d9d9dguess|r" end
			if #marks > 0 then line = line .. "  " .. table.concat(marks, " ") end

			out(line)
		end
	end
	if R:IsSimulated() then
		out(("|cff9d9d9dseed %s|r"):format(tostring(raid.seed)))
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
	out(("Priority grouping: %s"):format(db.railGrouping))
	out(("Prot paladin Salvation rule: %s"):format(db.protPaladinSalvation and "on" or "off"))
	out(("Pin mode: %s"):format(db.pinMode))
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
	out("  /app protsalv on|off             prot paladin tank carries Salvation")
	out("  /app pinmode preference|hard     how strictly pins are held")
	out("  /app pin <paladin> <blessing|clear>")
	out("  /app override <player> <PROFILE|clear>")
	out("  /app roster                  every raider by class, spec and role")
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
