-- The addon window: Priorities, Raid Plan, Test Mode, Presets.
--
-- Availability rule: only the Raid Plan tab needs a group. Priorities are
-- policy, not tonight's roster, so they open anywhere -- in a city, on an alt,
-- between raids, which is exactly when people want to argue about them. Test
-- Mode exists precisely for when you have no group. Presets are stored config.
-- Only the plan gets disabled, and it says why and points at Test Mode.
--
-- The frame is built lazily on first open rather than at load. A construction
-- bug then costs you a window, not the whole addon: a Lua error during file
-- load leaves the addon disabled with no slash commands to diagnose it.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local S = APP.Solver
local R = APP.Roster
local PP = APP.PP
local Report = APP.Report
local Config = APP.Config

local UI = {}
APP.MainFrame = UI

local WIDTH, HEIGHT = 760, 500
local RAIL_W = 210
local ROW_H = 20

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local TABS = {
	{ key = "priorities", label = "Priorities" },
	{ key = "plan",       label = "Raid Plan" },
	{ key = "test",       label = "Test Mode" },
	{ key = "presets",    label = "Presets" },
}

-- Conditions are facts about the game rather than preferences, so they are
-- attached automatically and not editable: Light does nothing without a holy
-- paladin healing the target, and Sanctuary cannot be cast without a
-- prot-talented paladin in the raid.
local INTRINSIC_CONDITION = {
	[B.LIGHT] = P.HOLY_PALADIN,
	[B.SANCTUARY] = P.PROT_PALADIN,
}

local CONDITION_TEXT = {
	[P.HOLY_PALADIN] = "only with a holy paladin",
	[P.PROT_PALADIN] = "only with a prot paladin",
}

--------------------------------------------------------------------------
-- Small builders
--------------------------------------------------------------------------

local function panel(parent, w, h)
	local f = CreateFrame("Frame", nil, parent, BACKDROP_TEMPLATE)
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		f:SetBackdropColor(0.05, 0.04, 0.05, 0.85)
		f:SetBackdropBorderColor(0.35, 0.28, 0.33, 1)
	end
	if w and h then f:SetSize(w, h) end
	return f
end

local function label(parent, text, font, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
	fs:SetText(text or "")
	if r then fs:SetTextColor(r, g, b) end
	return fs
end

--- Enable/disable that does not assume which widget API this client has.
local function setEnabled(widget, on)
	if not widget then return end
	if widget.SetEnabled then
		widget:SetEnabled(on and true or false)
	elseif on then
		widget:Enable()
	else
		widget:Disable()
	end
end

local function button(parent, text, w, h, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, h or 21)
	b:SetText(text)
	if onClick then
		-- Wrapped so a broken handler reports itself rather than reading as a
		-- dead button.
		b:SetScript("OnClick", function(...)
			return APP.SafeCall("button '" .. tostring(text) .. "'", onClick, ...)
		end)
	end
	return b
end

--- A scrolling list whose rows are created on demand and reused.
--
-- Deliberately not UIPanelScrollFrameTemplate: that template always draws its
-- scrollbar, including the two arrow buttons, whether or not there is anything
-- to scroll. Those arrows landed on top of the detail pane and covered its
-- text. A bare ScrollFrame with a mouse-wheel handler has no chrome to collide
-- with, and the lists here are short enough not to need a visible bar.
local function scrollList(parent, w, h)
	local scroll = CreateFrame("ScrollFrame", nil, parent)
	scroll:SetSize(w, h)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(w, h)
	scroll:SetScrollChild(content)
	content.rows = {}

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = math.max(0, content:GetHeight() - self:GetHeight())
		local target = self:GetVerticalScroll() - delta * 24
		if target < 0 then target = 0 end
		if target > range then target = range end
		self:SetVerticalScroll(target)
	end)

	return scroll, content
end

--------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------

function UI:Get()
	if self.frame then return self.frame end

	local f = CreateFrame("Frame", "AutoPallyPowerFrame", UIParent, BACKDROP_TEMPLATE)
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end

	f.title = label(f, "AutoPallyPower", "GameFontNormalLarge")
	f.title:SetPoint("TOP", f, "TOP", 0, -14)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

	-- Escape closes it, like every other panel in the game.
	tinsert(UISpecialFrames, "AutoPallyPowerFrame")

	-- Tabs
	f.tabs = {}
	local x = 16
	for i, tab in ipairs(TABS) do
		local b = CreateFrame("Button", nil, f)
		b:SetSize(96, 24)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -40)
		b.text = label(b, tab.label, "GameFontNormalSmall")
		b.text:SetPoint("CENTER")
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetAllPoints()
		b.bg:SetColorTexture(0.12, 0.09, 0.11, 0.9)
		b.key = tab.key
		b:SetScript("OnClick", function() UI:SelectTab(i) end)
		f.tabs[i] = b
		x = x + 100
	end

	f.body = panel(f, WIDTH - 40, HEIGHT - 92)
	f.body:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -68)

	self.frame = f
	self:BuildPriorities()
	self:BuildPlan()
	self:BuildTest()
	self:BuildPresets()
	self:SelectTab(1)
	return f
end

function UI:SelectTab(index)
	local f = self.frame
	if not f then return end
	self.current = index

	for i, b in ipairs(f.tabs) do
		if i == index then
			b.bg:SetColorTexture(0.30, 0.20, 0.12, 1)
			b.text:SetTextColor(1, 0.85, 0.55)
		else
			b.bg:SetColorTexture(0.12, 0.09, 0.11, 0.9)
			b.text:SetTextColor(0.62, 0.56, 0.60)
		end
	end

	for _, pane in ipairs({ self.prioPane, self.planPane, self.testPane, self.presetPane }) do
		if pane then pane:Hide() end
	end

	local pane = ({ self.prioPane, self.planPane, self.testPane, self.presetPane })[index]
	if pane then pane:Show() end

	if index == 1 then self:RefreshPriorities()
	elseif index == 2 then self:RefreshPlan()
	elseif index == 3 then self:RefreshTest()
	elseif index == 4 then self:RefreshPresets() end
end

function UI:Toggle()
	local f = self:Get()
	if f:IsShown() then f:Hide() else f:Show(); self:SelectTab(self.current or 1) end
end

function UI:Show(tabIndex)
	local f = self:Get()
	f:Show()
	self:SelectTab(tabIndex or self.current or 1)
end

--------------------------------------------------------------------------
-- Tab 1: Priorities
--------------------------------------------------------------------------

function UI:BuildPriorities()
	local body = self.frame.body
	local pane = CreateFrame("Frame", nil, body)
	pane:SetAllPoints()
	self.prioPane = pane

	local groupLabel = label(pane, "Group by", "GameFontDisableSmall")
	groupLabel:SetPoint("TOPLEFT", pane, "TOPLEFT", 10, -8)

	pane.byRole = button(pane, "Role", 52, 19, function()
		APP.db.railGrouping = "role"; UI:RefreshPriorities()
	end)
	pane.byRole:SetPoint("LEFT", groupLabel, "RIGHT", 6, 0)

	pane.byClass = button(pane, "Class", 52, 19, function()
		APP.db.railGrouping = "class"; UI:RefreshPriorities()
	end)
	pane.byClass:SetPoint("LEFT", pane.byRole, "RIGHT", 3, 0)

	local railScroll, railContent = scrollList(pane, RAIL_W, body:GetHeight() - 46)
	railScroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 8, -32)
	pane.railContent = railContent

	local detail = CreateFrame("Frame", nil, pane)
	detail:SetPoint("TOPLEFT", pane, "TOPLEFT", RAIL_W + 26, -8)
	detail:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -8, 8)
	pane.detail = detail

	detail.heading = label(detail, "", "GameFontNormal")
	detail.heading:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -2)

	detail.applies = label(detail, "", "GameFontDisableSmall")
	detail.applies:SetPoint("TOPLEFT", detail.heading, "BOTTOMLEFT", 0, -3)

	detail.rows = {}

	detail.reset = button(detail, "Reset to default", 120, 20, function()
		local key = UI.activeProfile
		if key and P.defaults[key] then
			APP.db.profiles[key] = Config.copy(P.defaults[key])
			UI:RefreshPriorities()
		end
	end)
	detail.reset:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", 0, 4)

	detail.addLabel = label(detail, "Add:", "GameFontDisableSmall")
	detail.addLabel:SetPoint("LEFT", detail.reset, "RIGHT", 12, 0)
	detail.addButtons = {}
end

--- The list being edited for the selected profile.
function UI:ActiveList(profile)
	return profile.priority
end

local function entryBlessing(entry)
	if type(entry) == "table" then return entry.b, entry.requires end
	return entry, nil
end

function UI:RefreshPriorities()
	local pane = self.prioPane
	if not pane then return end
	local db = APP.db
	local mode = db.railGrouping

	-- Rail
	local content = pane.railContent
	local y, index = 0, 0
	local groups = P:GroupedList(mode, db.profiles)

	for _, widget in ipairs(content.rows) do widget:Hide() end

	local function rowAt(i)
		local row = content.rows[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetSize(RAIL_W - 22, ROW_H)
			row.text = label(row, "", "GameFontNormalSmall")
			row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
			row.text:SetJustifyH("LEFT")
			row.hl = row:CreateTexture(nil, "BACKGROUND")
			row.hl:SetAllPoints()
			row.hl:SetColorTexture(0.35, 0.25, 0.15, 0.8)
			content.rows[i] = row
		end
		row:Show()
		return row
	end

	for _, group in ipairs(groups) do
		index = index + 1
		local head = rowAt(index)
		head:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		head.text:SetText(group.label)
		head.text:SetTextColor(0.85, 0.72, 0.35)
		head.hl:Hide()
		head:SetScript("OnClick", nil)
		head:EnableMouse(false)
		y = y + ROW_H

		for _, item in ipairs(group.items) do
			index = index + 1
			local row = rowAt(index)
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -y)
			row.text:SetText(item.label)
			row:EnableMouse(true)
			if item.key == self.activeProfile then
				row.hl:Show()
				row.text:SetTextColor(1, 1, 1)
			else
				row.hl:Hide()
				row.text:SetTextColor(0.78, 0.74, 0.76)
			end
			local key = item.key
			row:SetScript("OnClick", function()
				UI.activeProfile = key
				UI:RefreshPriorities()
			end)
			y = y + ROW_H
		end
	end
	content:SetHeight(math.max(y, 1))

	-- Default selection
	if not self.activeProfile or not db.profiles[self.activeProfile] then
		local first = groups[1] and groups[1].items[1]
		self.activeProfile = first and first.key or nil
	end

	setEnabled(pane.byRole, mode ~= "role")
	setEnabled(pane.byClass, mode ~= "class")

	self:RefreshDetail()
end

function UI:RefreshDetail()
	local detail = self.prioPane.detail
	local db = APP.db
	local key = self.activeProfile
	local profile = key and db.profiles[key]
	if not profile then return end

	detail.heading:SetText(profile.label or key)
	detail.applies:SetText(profile.tank
		and ("Applies to any %s in a tank role -- main tank or off tank.")
			:format((profile.class or ""):lower())
		or "")

	local list = self:ActiveList(profile)
	local top = -40

	for _, row in ipairs(detail.rows) do row:Hide() end

	local inList = {}
	for i, entry in ipairs(list) do
		local blessing, requires = entryBlessing(entry)
		inList[blessing] = true

		local row = detail.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, detail)
			row:SetSize(430, 24)
			row.rank = label(row, "", "GameFontNormalSmall")
			row.rank:SetPoint("LEFT", row, "LEFT", 2, 0)
			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(18, 18)
			row.icon:SetPoint("LEFT", row, "LEFT", 20, 0)
			row.name = label(row, "", "GameFontHighlightSmall")
			row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
			row.cond = label(row, "", "GameFontDisableSmall", 0.72, 0.60, 0.82)
			row.cond:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
			row.up = button(row, "^", 22, 18)
			row.up:SetPoint("RIGHT", row, "RIGHT", -74, 0)
			row.down = button(row, "v", 22, 18)
			row.down:SetPoint("RIGHT", row, "RIGHT", -50, 0)
			row.remove = button(row, "x", 22, 18)
			row.remove:SetPoint("RIGHT", row, "RIGHT", -26, 0)
			detail.rows[i] = row
		end

		row:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, top - (i - 1) * 25)
		row:Show()
		row.rank:SetText(tostring(i))
		row.icon:SetTexture(B.icons[blessing])
		row.name:SetText(B:Name(blessing))
		row.cond:SetText(requires and CONDITION_TEXT[requires] or "")

		local pos = i
		setEnabled(row.up, i > 1)
		row.up:SetScript("OnClick", function()
			list[pos], list[pos - 1] = list[pos - 1], list[pos]
			UI:RefreshDetail()
		end)
		setEnabled(row.down, i < #list)
		row.down:SetScript("OnClick", function()
			list[pos], list[pos + 1] = list[pos + 1], list[pos]
			UI:RefreshDetail()
		end)
		row.remove:SetScript("OnClick", function()
			table.remove(list, pos)
			UI:RefreshDetail()
		end)
	end

	-- Add buttons for blessings not already listed. Salvation is never offered
	-- for a tank profile: a tank keeping Salvation is the one thing the solver
	-- treats as a correctness failure, so it is not presented as a choice.
	for _, b in ipairs(detail.addButtons) do b:Hide() end
	local n = 0
	for _, blessing in ipairs(B.ALL) do
		local blocked = profile.tank and blessing == B.SALVATION
		if not inList[blessing] and not blocked then
			n = n + 1
			local btn = detail.addButtons[n]
			if not btn then
				btn = button(detail, "", 62, 19)
				detail.addButtons[n] = btn
			end
			btn:SetText(B:Short(blessing))
			btn:ClearAllPoints()
			btn:SetPoint("LEFT", detail.addLabel, "RIGHT", 6 + (n - 1) * 65, 0)
			btn:Show()
			local blessingID = blessing
			btn:SetScript("OnClick", function()
				local requires = INTRINSIC_CONDITION[blessingID]
				list[#list + 1] = requires and { b = blessingID, requires = requires } or blessingID
				UI:RefreshDetail()
			end)
		end
	end
end

--------------------------------------------------------------------------
-- Tab 2: Raid Plan
--------------------------------------------------------------------------

function UI:BuildPlan()
	local body = self.frame.body
	local pane = CreateFrame("Frame", nil, body)
	pane:SetAllPoints()
	pane:Hide()
	self.planPane = pane

	pane.summary = label(pane, "", "GameFontNormalSmall")
	pane.summary:SetPoint("TOPLEFT", pane, "TOPLEFT", 10, -8)
	pane.summary:SetJustifyH("LEFT")

	pane.notice = label(pane, "", "GameFontDisableLarge")
	pane.notice:SetPoint("CENTER", pane, "CENTER", 0, 20)
	pane.notice:SetJustifyH("CENTER")

	pane.hint = label(pane, "", "GameFontDisableSmall")
	pane.hint:SetPoint("TOP", pane.notice, "BOTTOM", 0, -8)

	pane.goTest = button(pane, "Open Test Mode", 130, 22, function() UI:SelectTab(3) end)
	pane.goTest:SetPoint("TOP", pane.hint, "BOTTOM", 0, -10)

	local scroll, content = scrollList(pane, body:GetWidth() - 40, body:GetHeight() - 74)
	scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 10, -30)
	pane.content = content

	pane.preview = button(pane, "Preview changes", 120, 22, function()
		APP.Commands:Handle("preview")
	end)
	pane.preview:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 10, 4)

	pane.apply = button(pane, "Apply to PallyPower", 150, 22, function()
		APP.Commands:Handle("apply")
		UI:RefreshPlan()
	end)
	pane.apply:SetPoint("LEFT", pane.preview, "RIGHT", 6, 0)
end

function UI:RefreshPlan()
	local pane = self.planPane
	if not pane then return end

	local simulated = R:IsSimulated()
	local inGroup = (GetNumGroupMembers and GetNumGroupMembers() or 0) > 0

	for _, row in ipairs(pane.content.rows) do row:Hide() end

	if not simulated and not inGroup then
		pane.summary:SetText("")
		pane.notice:SetText("Not in a group")
		pane.hint:SetText("The plan needs a roster to solve against.\nPriorities and Test Mode work anywhere.")
		pane.notice:Show(); pane.hint:Show(); pane.goTest:Show()
		setEnabled(pane.preview, false)
		setEnabled(pane.apply, false)
		return
	end

	pane.notice:Hide(); pane.hint:Hide(); pane.goTest:Hide()

	local result, err = APP.Commands:Solve()
	if not result then
		pane.summary:SetText(err or "Could not solve.")
		setEnabled(pane.preview, false)
		setEnabled(pane.apply, false)
		return
	end

	pane.summary:SetText(("%d paladins  |  holy: %s  |  prot: %s%s"):format(
		#result.paladins,
		result.context.holyPaladin and "yes" or "no",
		result.context.protPaladin and "yes" or "no",
		simulated and "  |  |cffff6060SIMULATED|r" or ""))

	-- Applying a simulated plan would write a fictional raid into PallyPower.
	setEnabled(pane.preview, not simulated)
	setEnabled(pane.apply, not simulated)

	local lines = {}
	for _, line in ipairs(Report:Plan(result)) do lines[#lines + 1] = line end
	lines[#lines + 1] = ""
	for _, line in ipairs(Report:PerMember(result)) do lines[#lines + 1] = line end

	local content = pane.content
	local y = 0
	for i, text in ipairs(lines) do
		local row = content.rows[i]
		if not row then
			row = label(content, "", "GameFontHighlightSmall")
			row:SetJustifyH("LEFT")
			content.rows[i] = row
		end
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
		row:SetText(text)
		row:Show()
		y = y + 13
	end
	content:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------
-- Tab 3: Test Mode
--------------------------------------------------------------------------

local TEST_FIELDS = {
	{ key = "raidSize", label = "Raid size", min = 1,  max = 40 },
	{ key = "paladins", label = "Paladins",  min = 0,  max = 8 },
	{ key = "tanks",    label = "Tanks",     min = 0,  max = 6 },
	{ key = "healers",  label = "Healers",   min = 0,  max = 12 },
}

function UI:BuildTest()
	local body = self.frame.body
	local pane = CreateFrame("Frame", nil, body)
	pane:SetAllPoints()
	pane:Hide()
	self.testPane = pane

	local intro = label(pane, "Generate a raid to solve against, with no group required.", "GameFontNormalSmall")
	intro:SetPoint("TOPLEFT", pane, "TOPLEFT", 10, -10)

	pane.fields = {}
	local y = -38
	for _, field in ipairs(TEST_FIELDS) do
		local row = CreateFrame("Frame", nil, pane)
		row:SetSize(300, 24)
		row:SetPoint("TOPLEFT", pane, "TOPLEFT", 14, y)

		row.label = label(row, field.label, "GameFontNormalSmall")
		row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
		row.label:SetWidth(90)
		row.label:SetJustifyH("LEFT")

		row.minus = button(row, "-", 22, 20, function()
			local t = APP.db.testMode
			t[field.key] = math.max(field.min, (t[field.key] or 0) - 1)
			UI:RefreshTest()
		end)
		row.minus:SetPoint("LEFT", row.label, "RIGHT", 4, 0)

		row.value = label(row, "", "GameFontHighlight")
		row.value:SetPoint("LEFT", row.minus, "RIGHT", 8, 0)
		row.value:SetWidth(30)
		row.value:SetJustifyH("CENTER")

		row.plus = button(row, "+", 22, 20, function()
			local t = APP.db.testMode
			t[field.key] = math.min(field.max, (t[field.key] or 0) + 1)
			UI:RefreshTest()
		end)
		row.plus:SetPoint("LEFT", row.value, "RIGHT", 8, 0)

		pane.fields[field.key] = row
		y = y - 28
	end

	pane.seed = label(pane, "", "GameFontDisableSmall")
	pane.seed:SetPoint("TOPLEFT", pane, "TOPLEFT", 14, y - 6)

	pane.generate = button(pane, "Generate raid", 120, 22, function()
		local t = APP.db.testMode
		APP.Commands:Handle(("test %d %d %d %d"):format(
			t.raidSize, t.paladins, t.tanks, t.healers))
		UI:RefreshTest()
	end)
	pane.generate:SetPoint("TOPLEFT", pane, "TOPLEFT", 14, y - 30)

	pane.solve = button(pane, "Solve and show plan", 150, 22, function()
		UI:SelectTab(2)
	end)
	pane.solve:SetPoint("LEFT", pane.generate, "RIGHT", 6, 0)

	pane.leave = button(pane, "Leave test mode", 130, 22, function()
		APP.Commands:Handle("test off")
		UI:RefreshTest()
	end)
	pane.leave:SetPoint("LEFT", pane.solve, "RIGHT", 6, 0)

	pane.status = label(pane, "", "GameFontNormalSmall")
	pane.status:SetPoint("TOPLEFT", pane, "TOPLEFT", 14, y - 62)
	pane.status:SetJustifyH("LEFT")
end

function UI:RefreshTest()
	local pane = self.testPane
	if not pane then return end
	local t = APP.db.testMode

	for key, row in pairs(pane.fields) do
		row.value:SetText(tostring(t[key] or 0))
	end

	local simulated = R:IsSimulated()
	setEnabled(pane.leave, simulated)
	setEnabled(pane.solve, simulated)

	if simulated then
		local raid = R.simulated
		local sum = R:Summary(raid)
		pane.seed:SetText(("Seed %s -- reproduce with /app test %d %d %d %d %s"):format(
			tostring(raid.seed), t.raidSize, t.paladins, t.tanks, t.healers, tostring(raid.seed)))
		pane.status:SetText(("|cff1eff00Test raid active|r  %d players, %d paladins, %d tanks, %d healers")
			:format(sum.size, sum.paladins, sum.tanks, sum.healers))
	else
		pane.seed:SetText("")
		pane.status:SetText("|cff9d9d9dNo test raid generated yet.|r")
	end
end

--------------------------------------------------------------------------
-- Tab 4: Presets
--------------------------------------------------------------------------

function UI:BuildPresets()
	local body = self.frame.body
	local pane = CreateFrame("Frame", nil, body)
	pane:SetAllPoints()
	pane:Hide()
	self.presetPane = pane

	local intro = label(pane, "A preset is a saved copy of your priorities, for the night that wants something different.", "GameFontNormalSmall")
	intro:SetPoint("TOPLEFT", pane, "TOPLEFT", 10, -10)
	intro:SetWidth(body:GetWidth() - 30)
	intro:SetJustifyH("LEFT")

	local hint = label(pane, "Names are yours -- a boss, a comp, a night. Selection is always manual.", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -4)

	pane.box = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
	pane.box:SetSize(200, 20)
	pane.box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 6, -12)
	pane.box:SetAutoFocus(false)
	pane.box:SetMaxLetters(40)

	pane.save = button(pane, "Save current as", 120, 22, function()
		local name = pane.box:GetText()
		if not name or name == "" then
			APP.Print("Type a name first.")
			return
		end
		Config:SavePreset(name, APP.db.profiles)
		pane.box:SetText("")
		UI:RefreshPresets()
		APP.Print(("Saved preset '%s'."):format(name))
	end)
	pane.save:SetPoint("LEFT", pane.box, "RIGHT", 8, 0)

	local scroll, content = scrollList(pane, body:GetWidth() - 40, body:GetHeight() - 120)
	scroll:SetPoint("TOPLEFT", pane.box, "BOTTOMLEFT", -6, -12)
	pane.content = content

	-- Its own widget rather than a borrowed row. Sharing the row pool meant the
	-- empty-state row was created without the activate and delete buttons, and
	-- the first saved preset then reused that slot and died reaching for them.
	pane.empty = label(content, "No presets saved yet.", "GameFontDisableSmall")
	pane.empty:SetPoint("TOPLEFT", content, "TOPLEFT", 4, 0)
end

function UI:RefreshPresets()
	local pane = self.presetPane
	if not pane then return end
	local db = APP.db
	local content = pane.content

	for _, row in ipairs(content.rows) do row:Hide() end

	local names = {}
	for name in pairs(db.presets or {}) do names[#names + 1] = name end
	table.sort(names)

	if #names == 0 then
		pane.empty:Show()
		content:SetHeight(20)
		return
	end
	pane.empty:Hide()

	local y = 0
	for i, name in ipairs(names) do
		local row = content.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, content)
			row:SetSize(content:GetWidth() - 10, 24)
			row.text = label(row, "", "GameFontHighlightSmall")
			row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
			row.activate = button(row, "", 90, 20)
			row.activate:SetPoint("RIGHT", row, "RIGHT", -80, 0)
			row.delete = button(row, "Delete", 70, 20)
			row.delete:SetPoint("RIGHT", row, "RIGHT", -4, 0)
			content.rows[i] = row
		end
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		row:Show()

		local active = (db.activePreset == name)
		row.text:SetText(active and ("|cff1eff00" .. name .. "  (active)|r") or name)
		row.activate:SetText(active and "Deactivate" or "Activate")
		row.activate:SetScript("OnClick", function()
			-- Not `active and nil or name`: in Lua that always yields name,
			-- so the toggle could only ever activate.
			if active then
				db.activePreset = nil
			else
				db.activePreset = name
			end
			UI:RefreshPresets()
		end)
		row.delete:SetScript("OnClick", function()
			Config:DeletePreset(name)
			UI:RefreshPresets()
		end)
		y = y + 26
	end
	content:SetHeight(math.max(y, 1))
end
