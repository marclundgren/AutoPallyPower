-- A small stand-in for the WoW client, enough to load and drive the addon's UI.
--
-- The UI layer was the one part of this addon with no way to run outside the
-- game, and WoW hides errors raised in addon callbacks by default -- so a bug
-- there shows up as "nothing happens" and can only be chased by guesswork.
-- This makes buttons clickable from the test suite.
--
-- Widgets are permissive: any method we have not modelled returns a no-op
-- rather than erroring, so the stub does not have to track every frame API to
-- be useful. The handful that carry real state are implemented properly.
local stub = {}

-- Captured before the sandbox removes them, so the stub itself can still read
-- files while the code under test cannot.
local realLoadfile = loadfile
local realIo = io
local realOs = os

local widgets = {}
stub.widgets = widgets

-- The group the stubbed client is currently in. Mutable so a test can have
-- someone join or leave and then fire the event the client would.
stub.group = { members = {}, raid = false }

-- Callbacks queued by C_Timer.After, run on demand rather than by a clock, so
-- debounced work is deterministic instead of a race.
stub.timers = {}

local Widget = {}

local function noop() end

Widget.__index = function(self, key)
	local real = rawget(Widget, key)
	if real then return real end
	-- Unmodelled frame API: accept and ignore.
	return noop
end

function Widget:SetScript(name, fn) self.__scripts[name] = fn end
function Widget:GetScript(name) return self.__scripts[name] end
function Widget:HasScript() return true end

function Widget:Show() self.__shown = true end
function Widget:Hide() self.__shown = false end
function Widget:IsShown() return self.__shown and true or false end
function Widget:IsVisible() return self:IsShown() end
function Widget:SetShown(v) self.__shown = v and true or false end

function Widget:SetText(t) self.__text = t end
function Widget:GetText() return self.__text end

function Widget:SetSize(w, h) self.__w, self.__h = w, h end
function Widget:SetWidth(w) self.__w = w end
function Widget:SetHeight(h) self.__h = h end
function Widget:GetWidth() return self.__w or 100 end
function Widget:GetHeight() return self.__h or 100 end

function Widget:SetEnabled(v) self.__enabled = v and true or false end
function Widget:Enable() self.__enabled = true end
function Widget:Disable() self.__enabled = false end
function Widget:IsEnabled() return self.__enabled end

function Widget:SetVerticalScroll(v) self.__scroll = v end
function Widget:GetVerticalScroll() return self.__scroll or 0 end
function Widget:SetScrollChild(c) self.__scrollChild = c end

function Widget:GetCenter() return 0, 0 end
function Widget:GetEffectiveScale() return 1 end

function Widget:RegisterEvent(e) self.__events[e] = true end
function Widget:UnregisterEvent(e) self.__events[e] = nil end

local function newWidget(kind, name, parent)
	local w = setmetatable({
		__kind = kind, __name = name, __parent = parent,
		__scripts = {}, __events = {}, __shown = true,
		__enabled = true, __text = "",
	}, Widget)
	widgets[#widgets + 1] = w
	return w
end
stub.newWidget = newWidget

function Widget:CreateFontString(name)
	return newWidget("FontString", name, self)
end
function Widget:CreateTexture(name)
	return newWidget("Texture", name, self)
end

--- Replace the group and, optionally, make it a raid.
function stub.setGroup(members, raid)
	stub.group.members = members or {}
	stub.group.raid = raid and true or false
	-- PallyPower remembers a row per paladin; the adapter reads its keys.
	_G.PallyPower_Assignments = _G.PallyPower_Assignments or {}
	for _, m in ipairs(stub.group.members) do
		if m.class == "PALADIN" then
			_G.PallyPower_Assignments[m.name] = _G.PallyPower_Assignments[m.name] or {}
		end
	end
end

--- Unit id -> member, for whichever group shape we are in.
local function unitMap()
	local map = {}
	if stub.group.raid then
		for i, m in ipairs(stub.group.members) do map["raid" .. i] = m end
	else
		local members = stub.group.members
		if members[1] then map.player = members[1] end
		for i = 2, #members do map["party" .. (i - 1)] = members[i] end
	end
	return map
end

--- Deliver an event to every frame registered for it.
function stub.fireEvent(event, ...)
	for _, w in ipairs(widgets) do
		if w.__events and w.__events[event] and w.__scripts.OnEvent then
			w.__scripts.OnEvent(w, event, ...)
		end
	end
end

--- Run everything C_Timer.After queued. Returns how many ran.
-- Loops so a timer that queues another still settles.
function stub.runTimers()
	local ran = 0
	for _ = 1, 10 do
		local due = stub.timers
		if #due == 0 then break end
		stub.timers = {}
		for _, t in ipairs(due) do
			t.fn()
			ran = ran + 1
		end
	end
	return ran
end

--- Fire a widget's OnClick the way the client would.
function stub.click(widget, mouseButton)
	local fn = widget and widget.__scripts and widget.__scripts.OnClick
	if not fn then
		error("widget has no OnClick: " .. tostring(widget and widget.__text), 2)
	end
	if widget.__enabled == false then
		error("clicked a disabled widget: " .. tostring(widget.__text), 2)
	end
	return fn(widget, mouseButton or "LeftButton")
end

--- Find a created widget by its visible text.
function stub.findByText(text)
	for _, w in ipairs(widgets) do
		if w.__text == text then return w end
	end
	return nil
end

--- Remove what the WoW sandbox does not provide.
--
-- Without this the stub runs under stock Lua, where os and math.randomseed
-- exist -- and it will happily pass code that dies in the client. Both of this
-- addon\'s silent in-game failures were exactly that, so the stub takes them
-- away.
function stub.sandbox()
	stub.__removed = {
		os = _G.os, io = _G.io, require = _G.require,
		dofile = _G.dofile, loadfile = _G.loadfile,
		randomseed = math.randomseed,
	}
	_G.os, _G.io, _G.require, _G.dofile, _G.loadfile = nil, nil, nil, nil, nil
	math.randomseed = nil
end

--- Put them back, so the test runner can still exit and report.
function stub.restore()
	local r = stub.__removed
	if not r then return end
	_G.os, _G.io, _G.require = r.os, r.io, r.require
	_G.dofile, _G.loadfile = r.dofile, r.loadfile
	math.randomseed = r.randomseed
	stub.__removed = nil
end

--- Install the globals the addon touches. Returns the chat log table.
function stub.install(opts)
	opts = opts or {}
    local chat = {}

	_G.CreateFrame = function(kind, name, parent, template)
		local w = newWidget(kind, name, parent)
		if name then _G[name] = w end
		return w
	end

	_G.UIParent = newWidget("Frame", "UIParent")
	_G.Minimap = newWidget("Frame", "Minimap")
	_G.GameTooltip = newWidget("Frame", "GameTooltip")
	_G.UISpecialFrames = {}
	_G.BackdropTemplateMixin = nil
	_G.SlashCmdList = {}

	_G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, msg) chat[#chat + 1] = msg end,
	}

	_G.tinsert = table.insert
	_G.tremove = table.remove
	_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

	_G.UIDropDownMenu_CreateInfo = function() return {} end
	_G.UIDropDownMenu_AddButton = noop
	_G.UIDropDownMenu_Initialize = noop
	_G.ToggleDropDownMenu = noop
	_G.CloseDropDownMenus = noop
	_G.GetCursorPosition = function() return 0, 0 end

	_G.C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }
	_G.ChatThrottleLib = { SendAddonMessage = noop }

	_G.time = function() return 1788000000 end
	_G.GetTime = function() return 1000.0 end

	stub.group.members = opts.members or {}
	stub.group.raid = opts.inRaid and true or false
	stub.timers = {}

	_G.C_Timer = {
		After = function(delay, fn)
			stub.timers[#stub.timers + 1] = { delay = delay, fn = fn }
		end,
	}

	_G.GetNumGroupMembers = function() return #stub.group.members end
	_G.IsInRaid = function() return stub.group.raid end
	_G.IsInGroup = function() return #stub.group.members > 0 end
	_G.UnitExists = function(u) return unitMap()[u] ~= nil end
	_G.GetUnitName = function(u)
		local m = unitMap()[u]
		return m and m.name
	end
	_G.UnitGroupRolesAssigned = function(u)
		local m = unitMap()[u]
		return (m and m.role) or "NONE"
	end
	_G.GetRaidRosterInfo = function(i)
		local m = stub.group.members[i]
		if not m then return nil end
		return m.name, 0, 1, 70, m.class, m.class, nil, nil, nil, m.raidRole
	end
	_G.UnitIsGroupLeader = function() return opts.leader and true or false end
	_G.UnitIsGroupAssistant = function() return false end

	_G.UnitClass = function(u)
		if u and u ~= "player" then
			local m = unitMap()[u]
			if m then return m.class, m.class end
		end
		return "Paladin", opts.playerClass or "PALADIN"
	end
	_G.UnitName = function(u)
		if u and u ~= "player" then
			local m = unitMap()[u]
			if m then return m.name end
		end
		return opts.playerName or "Rageblue"
	end
	_G.date = function() return "12:00:00" end

	_G.PallyPower = { SendMessage = function() end, UpdateLayout = function() end }
	_G.PallyPower_Assignments = {}
	_G.PallyPower_NormalAssignments = {}

	-- A paladin who knows everything but Sanctuary, with Improved Wisdom.
	local names = {
		[19742] = { "Blessing of Wisdom", "tex-wis" },
		[19740] = { "Blessing of Might", "tex-mgt" },
		[20217] = { "Blessing of Kings", "tex-kng" },
		[1038]  = { "Blessing of Salvation", "tex-salv" },
		[19977] = { "Blessing of Light", "tex-lgt" },
		[20911] = { "Blessing of Sanctuary", "tex-sanc" },
	}
	local known = opts.knownSpells or {
		["Blessing of Wisdom"] = "tex-wis",
		["Blessing of Might"] = "tex-mgt",
		["Blessing of Kings"] = "tex-kng",
		["Blessing of Salvation"] = "tex-salv",
		["Blessing of Light"] = "tex-lgt",
	}
	_G.GetSpellInfo = function(arg)
		if type(arg) == "number" then
			local e = names[arg]
			if not e then return nil end
			return e[1], nil, e[2]
		end
		local tex = known[arg]
		if not tex then return nil end
		return arg, nil, tex
	end
	_G.GetSpellSubtext = function() return "Rank 1" end
	_G.IsSpellKnown = function() return true end

	_G.GetNumTalentTabs = function() return 3 end
	_G.GetNumTalents = function(tab) return tab == 1 and 1 or 0 end
	_G.GetTalentInfo = function(tab, i)
		if tab == 1 and i == 1 then
			return "Improved Blessing of Wisdom", "tex-wis", 1, 1, 2, 2
		end
	end
	_G.GetTalentTabInfo = function(tab)
		return "Tab" .. tab, "icon", ({ 41, 8, 12 })[tab] or 0
	end

	_G.GetItemCount = function() return 0 end
	_G.GetRealZoneText = function() return "Ironforge" end

	return chat
end

--- Load every Lua file the .toc lists, in order, then fire ADDON_LOADED.
function stub.loadAddon(root)
	local APP = {}
	local files = {}
	local f = assert(realIo.open(root .. "/AutoPallyPower.toc", "r"))
	for line in f:lines() do
		local t = line:match("^%s*(.-)%s*$")
		if t ~= "" and t:sub(1, 1) ~= "#" and t:match("%.lua$") then
			files[#files + 1] = t:gsub("\\", "/")
		end
	end
	f:close()

	for _, rel in ipairs(files) do
		local chunk, err = realLoadfile(root .. "/" .. rel)
		if not chunk then error("load failed " .. rel .. ": " .. tostring(err)) end
		local ok, runErr = pcall(chunk, "AutoPallyPower", APP)
		if not ok then error("error while loading " .. rel .. ": " .. tostring(runErr)) end
	end

	-- Deliver the events a real login would, in order.
	for _, event in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED" }) do
		for _, w in ipairs(widgets) do
			if w.__events and w.__events[event] and w.__scripts.OnEvent then
				w.__scripts.OnEvent(w, event, event == "ADDON_LOADED" and "AutoPallyPower" or nil)
			end
		end
	end

	return APP, files
end

return stub
