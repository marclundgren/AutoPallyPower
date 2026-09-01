-- Drives the real UI files through a stubbed client. This is the only test
-- that exercises MainFrame, Minimap and the command dispatcher as the game
-- would, which is where "nothing happens" bugs live.
local ROOT = os.getenv("APP_ROOT") or "."
local stub = dofile(ROOT .. "/Tests/wowstub.lua")

local T = { passed = 0, failed = 0, failures = {} }
function T.check(name, ok, detail)
	if ok then T.passed = T.passed + 1 else
		T.failed = T.failed + 1
		T.failures[#T.failures + 1] = name
		print("  FAIL  " .. name .. (detail and ("  --  " .. detail) or ""))
	end
end
function T.eq(name, got, want)
	T.check(name, got == want, ("got %s, want %s"):format(tostring(got), tostring(want)))
end

local chat = stub.install({ groupSize = 0 })
-- From here the code under test sees the same missing globals the client has.
stub.sandbox()
local APP = stub.loadAddon(ROOT)

--------------------------------------------------------------------------
print("== the addon loads cleanly and registers itself ==")
do
	T.check("namespace populated", APP.Solver ~= nil and APP.MainFrame ~= nil)
	T.check("saved settings loaded", APP.db ~= nil)
	T.check("slash command registered", _G.SlashCmdList["AUTOPALLYPOWER"] ~= nil)
	T.eq("grouping default is role", APP.db.railGrouping, "role")

	-- Our own paladin is read from the (stubbed) spellbook, not waited for.
	T.eq("self scanned", APP.PP.selfName, "Rageblue")
	T.eq("spec from talent points", APP.PP:InferSpec("Rageblue"), "HOLY")
end

--------------------------------------------------------------------------
print("== the window opens out of a group ==")
do
	local ok, err = pcall(function() APP.MainFrame:Show() end)
	T.check("window builds without error", ok, tostring(err))
	T.check("window is shown", APP.MainFrame.frame:IsShown())

	-- Priorities must be reachable with no group: they are policy, not roster.
	local ok2, err2 = pcall(function() APP.MainFrame:SelectTab(1) end)
	T.check("priorities tab selects", ok2, tostring(err2))
	T.check("priorities pane shown", APP.MainFrame.prioPane:IsShown())

	local ok3, err3 = pcall(function() APP.MainFrame:SelectTab(3) end)
	T.check("test tab selects", ok3, tostring(err3))
	T.check("test pane shown", APP.MainFrame.testPane:IsShown())
end

--------------------------------------------------------------------------
print("== clicking Generate raid actually generates a raid ==")
do
	local before = #chat
	local generate = stub.findByText("Generate raid")
	T.check("found the Generate button", generate ~= nil)

	if generate then
		local ok, err = pcall(stub.click, generate)
		T.check("click did not error", ok, tostring(err))

		-- The real bug this test exists for: the click ran but nothing changed.
		T.check("a simulated raid now exists", APP.Roster:IsSimulated() == true)

		local raid = APP.Roster.simulated
		if raid then
			T.eq("raid has the requested size", #raid.members, APP.db.testMode.raidSize)
			T.eq("raid has the requested paladins", #raid.paladins, APP.db.testMode.paladins)
		end

		-- The panel is what the user looks at; chat is easy to miss behind
		-- the window, which is exactly how this bug stayed invisible.
		local status = APP.MainFrame.testPane.status:GetText()
		T.check("the panel says a raid is active",
			status and status:find("Test raid active") ~= nil, tostring(status))
		T.check("the panel shows a reproducible seed",
			(APP.MainFrame.testPane.seed:GetText() or ""):find("Seed") ~= nil)

		-- The roster list is the point of generating a raid you cannot see:
		-- a count in the status line does not tell you who is in it.
		local content = APP.MainFrame.testPane.rosterContent
		T.check("the roster list exists", content ~= nil)
		if content and raid then
			local shownRows, shownHeads = 0, 0
			for _, row in ipairs(content.rosterRows) do
				if row:IsShown() then shownRows = shownRows + 1 end
			end
			for _, head in ipairs(content.rosterHeads) do
				if head:IsShown() then shownHeads = shownHeads + 1 end
			end
			T.eq("one row per raider", shownRows, #raid.members)
			T.check("role headings are drawn", shownHeads > 0 and shownHeads <= 4,
				tostring(shownHeads))
			T.check("the list is taller than a single row", content:GetHeight() > 40)

			-- Each visible row must actually say something.
			local blank = 0
			for _, row in ipairs(content.rosterRows) do
				if row:IsShown() then
					local name = row.name:GetText() or ""
					local class = row.class:GetText() or ""
					local spec = row.spec:GetText() or ""
					if name == "" or class == "" or spec == "" then blank = blank + 1 end
				end
			end
			T.eq("no roster row is blank", blank, 0)

			-- The three questions the roster has to answer at a glance.
			local sawMainTank, sawPaladinCasting, sawReceives = false, false, false
			for _, row in ipairs(content.rosterRows) do
				if row:IsShown() then
					if (row.role:GetText() or ""):find("MAIN TANK") then sawMainTank = true end
					local casts = row.casts:GetText() or ""
					if casts ~= "" and casts:find("%a") then sawPaladinCasting = true end
					local gets = row.receives:GetText() or ""
					if gets ~= "" then sawReceives = true end
				end
			end
			T.check("the main tank is named on its own row", sawMainTank)
			T.check("at least one paladin shows what it casts", sawPaladinCasting)
			T.check("players show what they receive", sawReceives)

			-- Only paladins cast anything.
			local pally = {}
			for _, p in ipairs(raid.paladins) do pally[p.name] = true end
			local wrongCaster = 0
			for _, row in ipairs(content.rosterRows) do
				if row:IsShown() then
					local casts = row.casts:GetText() or ""
					if casts ~= "" and not pally[row.name:GetText()] then
						wrongCaster = wrongCaster + 1
					end
				end
			end
			T.eq("nobody but a paladin is shown casting", wrongCaster, 0)

			T.check("the column header is drawn",
				(APP.MainFrame.testPane.rosterHead:GetText() or ""):find("RECEIVES") ~= nil)

			-- And the main tank has to be findable, since it decides who
			-- carries a pinned blessing.
			-- The tank marker lives in its own column beside the name, not in
			-- the trailing flags.
			local mtMarked = false
			for _, row in ipairs(content.rosterRows) do
				if row:IsShown() and (row.role:GetText() or ""):find("MAIN TANK") then
					mtMarked = true
				end
			end
			local hasMT = false
			for _, m in ipairs(raid.members) do
				if m.raidRole == "MAINTANK" then hasMT = true end
			end
			T.eq("a main tank in the raid is marked in the list", mtMarked, hasMT)
		end

		-- Leaving test mode must clear the list rather than strand a roster
		-- for a raid that no longer exists.
		APP.Commands:Handle("test off")
		APP.MainFrame:RefreshTest()
		local stillShown = 0
		for _, row in ipairs(APP.MainFrame.testPane.rosterContent.rosterRows) do
			if row:IsShown() then stillShown = stillShown + 1 end
		end
		T.eq("the roster clears when test mode ends", stillShown, 0)
		T.check("the roster heading hides too",
			not APP.MainFrame.testPane.rosterLabel:IsShown())
		T.check("the column header hides too",
			not APP.MainFrame.testPane.rosterHead:IsShown())

		-- Put it back so the rest of this block sees what it expects.
		stub.click(generate)

		local said = false
		for i = before + 1, #chat do
			if tostring(chat[i]):find("Test raid generated") then said = true end
		end
		T.check("it reported what it did", said)

		-- And no error line was printed by SafeCall.
		for i = before + 1, #chat do
			if tostring(chat[i]):find("%[APP error%]") then
				T.check("no error surfaced during generate", false, chat[i])
			end
		end
	end
end

--------------------------------------------------------------------------
print("== the plan tab solves the simulated raid ==")
do
	local before = #chat
	local ok, err = pcall(function() APP.MainFrame:SelectTab(2) end)
	T.check("plan tab selects", ok, tostring(err))
	for i = before + 1, #chat do
		if tostring(chat[i]):find("%[APP error%]") then
			T.check("no error surfaced on the plan tab", false, chat[i])
		end
	end
	T.check("apply is blocked while simulated",
		APP.MainFrame.planPane.apply:IsEnabled() == false)

	-- Stat tiles should describe the raid actually being solved.
	local stats = APP.MainFrame.planPane.stats
	local raid = APP.Roster.simulated
	local summary = APP.Roster:Summary(raid)
	T.eq("raid size tile", stats.raid.value:GetText(), tostring(#raid.members))
	T.eq("paladin tile", stats.paladins.value:GetText(), tostring(#raid.paladins))
	T.eq("tank tile", stats.tanks.value:GetText(), tostring(summary.tanks))
	T.eq("healer tile", stats.healers.value:GetText(), tostring(summary.healers))
	T.check("healer count is not zero for a raid with healers", summary.healers > 0)
end

--------------------------------------------------------------------------
print("== every slash command runs without erroring ==")
do
	local handler = _G.SlashCmdList["AUTOPALLYPOWER"]
	for _, cmd in ipairs({ "", "help", "status", "plan", "report", "grouping role",
	                       "grouping class", "test 25 2 2 5", "roster", "test off",
	                       "roster", "preview", "protsalv on", "protsalv off",
	                       "pinmode hard", "pinmode preference", "pin", "override",
	                       "nonsense" }) do
		local before = #chat
		local ok, err = pcall(handler, cmd)
		T.check("/app " .. cmd .. " does not error", ok, tostring(err))
		for i = before + 1, #chat do
			if tostring(chat[i]):find("%[APP error%]") then
				T.check("/app " .. cmd .. " surfaced no error", false, chat[i])
			end
		end
	end
end

--------------------------------------------------------------------------
print("== priority editing survives a round trip ==")
do
	APP.MainFrame:SelectTab(1)
	APP.MainFrame.activeProfile = "WARRIOR_TANK"
	local ok, err = pcall(function() APP.MainFrame:RefreshPriorities() end)
	T.check("detail renders", ok, tostring(err))

	local list = APP.db.profiles.WARRIOR_TANK.priority
	T.check("tank profile has an ordering", #list > 1)
	T.eq("no second ordering remains", APP.db.profiles.WARRIOR_TANK.prioritySurvival, nil)

	local firstBefore = list[1]
	local row = APP.MainFrame.prioPane.detail.rows[2]
	T.check("second row exists", row ~= nil)
	if row then
		stub.click(row.up)
		T.check("moving a blessing up reorders the list", list[1] ~= firstBefore)
	end
end

--------------------------------------------------------------------------
print("== presets: save, activate, delete ==")
do
	APP.MainFrame:SelectTab(4)
	local pane = APP.MainFrame.presetPane

	T.check("empty message shown with no presets", pane.empty:IsShown())

	-- The regression: the empty-state message used to borrow row 1 of the pool,
	-- so the first saved preset reused a row with no activate button and died.
	pane.box:SetText("heavy melee night")
	local before = #chat
	local saveBtn = stub.findByText("Save current as")
	T.check("found the save button", saveBtn ~= nil)

	local ok, err = pcall(stub.click, saveBtn)
	T.check("saving does not error", ok, tostring(err))
	for i = before + 1, #chat do
		if tostring(chat[i]):find("%[APP error%]") then
			T.check("no error surfaced while saving", false, chat[i])
		end
	end

	T.check("preset stored", APP.db.presets["heavy melee night"] ~= nil)
	T.check("empty message hidden", pane.empty:IsShown() == false)

	local row = pane.content.rows[1]
	T.check("the rendered row has its buttons", row ~= nil and row.activate ~= nil and row.delete ~= nil)

	if row then
		T.eq("row offers activation", row.activate:GetText(), "Activate")
		stub.click(row.activate)
		T.eq("preset activated", APP.db.activePreset, "heavy melee night")
		T.eq("row now offers deactivation", row.activate:GetText(), "Deactivate")

		stub.click(row.activate)
		T.eq("preset deactivated", APP.db.activePreset, nil)

		stub.click(row.delete)
		T.eq("preset deleted", APP.db.presets["heavy melee night"], nil)
		T.check("empty message returns", pane.empty:IsShown())
	end

	-- Saving with no name should say so rather than store a blank.
	pane.box:SetText("")
	local ok2 = pcall(stub.click, saveBtn)
	T.check("empty name does not error", ok2)
	local count = 0
	for _ in pairs(APP.db.presets) do count = count + 1 end
	T.eq("nothing stored for a blank name", count, 0)
end

--------------------------------------------------------------------------
print("== the plan recalculates when the group changes ==")
do
	local B = APP.Blessings

	-- Leave test mode so the plan is solving a live group.
	APP.Commands:Handle("test off")

	local function paladinKnows(name)
		APP.PP.observed[name] = {
			[B.WISDOM] = { rank = 1, talent = 0 }, [B.MIGHT] = { rank = 1, talent = 0 },
			[B.KINGS] = { rank = 1, talent = 0 }, [B.SALVATION] = { rank = 1, talent = 0 },
			[B.LIGHT] = { rank = 1, talent = 0 },
		}
		APP.PP.heard[name] = true
	end

	stub.setGroup({
		{ name = "Rageblue", class = "PALADIN", role = "TANK" },
		{ name = "Barkskin", class = "DRUID", role = "HEALER" },
	})
	paladinKnows("Rageblue")

	APP.MainFrame:Show()
	APP.MainFrame:SelectTab(2)
	local stats = APP.MainFrame.planPane.stats
	T.eq("plan sees the group", stats.raid.value:GetText(), "2")

	-- Someone joins. The client fires this several times for one change.
	stub.setGroup({
		{ name = "Rageblue", class = "PALADIN", role = "TANK" },
		{ name = "Barkskin", class = "DRUID", role = "HEALER" },
		{ name = "Cleaver", class = "WARRIOR", role = "DAMAGER" },
	})
	stub.timers = {}
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	T.eq("a burst of events queues one refresh, not three", #stub.timers, 1)

	stub.runTimers()
	T.eq("the plan picked up the new member", stats.raid.value:GetText(), "3")

	-- And when someone leaves.
	stub.setGroup({
		{ name = "Rageblue", class = "PALADIN", role = "TANK" },
	})
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	stub.runTimers()
	T.eq("the plan picked up the departure", stats.raid.value:GetText(), "1")
end

--------------------------------------------------------------------------
print("== a role change recalculates too ==")
do
	local stats = APP.MainFrame.planPane.stats
	stub.setGroup({
		{ name = "Rageblue", class = "PALADIN", role = "TANK" },
		{ name = "Barkskin", class = "DRUID", role = "DAMAGER" },
	})
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	stub.runTimers()
	T.eq("druid is not counted as a healer", stats.healers.value:GetText(), "0")

	-- They switch to healer in the group finder.
	stub.setGroup({
		{ name = "Rageblue", class = "PALADIN", role = "TANK" },
		{ name = "Barkskin", class = "DRUID", role = "HEALER" },
	})
	stub.fireEvent("PLAYER_ROLES_ASSIGNED")
	stub.runTimers()
	T.eq("the healer count follows the role change", stats.healers.value:GetText(), "1")
end

--------------------------------------------------------------------------
print("== /app refresh forces a recalculation and asks the group to resync ==")
do
	local sent = {}
	_G.PallyPower.SendMessage = function(_, msg) sent[#sent + 1] = msg end

	local stats = APP.MainFrame.planPane.stats
	-- Change the roster without firing any event, so only an explicit refresh
	-- can notice.
	stub.setGroup({
		{ name = "Rageblue", class = "PALADIN", role = "TANK" },
		{ name = "Barkskin", class = "DRUID", role = "HEALER" },
		{ name = "Cleaver", class = "WARRIOR", role = "DAMAGER" },
		{ name = "Totemic", class = "SHAMAN", role = "DAMAGER" },
	})
	T.eq("panel is still showing the old roster", stats.raid.value:GetText(), "2")

	local before = #chat
	local ok, err = pcall(APP.Commands.Handle, APP.Commands, "refresh")
	T.check("refresh does not error", ok, tostring(err))
	for i = before + 1, #chat do
		if tostring(chat[i]):find("%[APP error%]") then
			T.check("no error surfaced on refresh", false, chat[i])
		end
	end

	T.eq("refresh recalculated immediately", stats.raid.value:GetText(), "4")

	local askedForResync = false
	for _, msg in ipairs(sent) do
		if msg == "REQ" then askedForResync = true end
	end
	T.check("it asked the group to resend their talents", askedForResync)

	-- Replies arrive late, so it solves again once they have had time to land.
	T.check("a follow-up pass is queued", #stub.timers > 0)
	stub.runTimers()
	T.eq("still correct after the follow-up", stats.raid.value:GetText(), "4")
end

--------------------------------------------------------------------------
print("== a hidden window does not do the work ==")
do
	APP.MainFrame.frame:Hide()
	stub.timers = {}
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	T.eq("nothing scheduled while closed", #stub.timers, 0)

	APP.MainFrame:Show()
	APP.MainFrame:SelectTab(1)
	stub.timers = {}
	stub.fireEvent("GROUP_ROSTER_UPDATE")
	T.eq("nothing scheduled while on another tab", #stub.timers, 0)
end

stub.restore()

print(("\nui: %d passed, %d failed"):format(T.passed, T.failed))
if T.failed > 0 then
	for _, f in ipairs(T.failures) do print("   * " .. f) end
	os.exit(1)
end
