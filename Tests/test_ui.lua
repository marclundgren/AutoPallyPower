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
end

--------------------------------------------------------------------------
print("== every slash command runs without erroring ==")
do
	local handler = _G.SlashCmdList["AUTOPALLYPOWER"]
	for _, cmd in ipairs({ "", "help", "status", "plan", "report", "grouping role",
	                       "grouping class", "test 25 2 2 5", "test off", "preview",
	                       "override", "nonsense" }) do
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

stub.restore()

print(("\nui: %d passed, %d failed"):format(T.passed, T.failed))
if T.failed > 0 then
	for _, f in ipairs(T.failures) do print("   * " .. f) end
	os.exit(1)
end
