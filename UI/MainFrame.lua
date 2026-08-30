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
--
-- All styling comes from UI/Theme.lua. Nothing here should reach for a colour
-- or a font directly.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local S = APP.Solver
local R = APP.Roster
local PP = APP.PP
local Report = APP.Report
local Config = APP.Config
local Theme = APP.Theme

local UI = {}
APP.MainFrame = UI

local WIDTH, HEIGHT = 840, 580
local RAIL_W = 208
local TITLE_H = 36
local TAB_H = 26

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
	[P.HOLY_PALADIN] = "needs a holy paladin",
	[P.PROT_PALADIN] = "needs a prot paladin",
}

local function entryBlessing(entry)
	if type(entry) == "table" then return entry.b, entry.requires end
	return entry, nil
end

--------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------

function UI:Get()
	if self.frame then return self.frame end

	local f = CreateFrame("Frame", "AutoPallyPowerFrame", UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)

	Theme.fill(f, Theme.color.shell)
	Theme:Edge(f, Theme.color.edge)

	-- Title bar
	local bar = CreateFrame("Frame", nil, f)
	bar:SetHeight(TITLE_H)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	Theme.fill(bar, Theme.color.panel)
	local barEdge = bar:CreateTexture(nil, "OVERLAY")
	barEdge:SetPoint("BOTTOMLEFT")
	barEdge:SetPoint("BOTTOMRIGHT")
	barEdge:SetHeight(1)
	barEdge:SetColorTexture(Theme.color.edge[1], Theme.color.edge[2], Theme.color.edge[3], 1)

	f.mark = Theme:Icon(bar, B.icons[B.KINGS], 20)
	f.mark:SetPoint("LEFT", bar, "LEFT", 10, 0)

	f.title = Theme:Text(bar, "title", "AutoPallyPower")
	f.title:SetPoint("CENTER", bar, "CENTER", 0, 0)
	f.title:SetJustifyH("CENTER")

	f.version = Theme:Text(bar, "meta", APP.version or "", Theme.color.textFaint)
	f.version:SetPoint("LEFT", f.mark, "RIGHT", 8, 0)

	f.close = Theme:Button(bar, "X", 24, 20, function() f:Hide() end, "ghost")
	f.close:SetPoint("RIGHT", bar, "RIGHT", -8, 0)

	tinsert(UISpecialFrames, "AutoPallyPowerFrame")

	-- Tabs
	f.tabs = {}
	local x = 12
	for i, tab in ipairs(TABS) do
		local b = Theme:Tab(f, tab.label, function() UI:SelectTab(i) end)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(TITLE_H + 8))
		b.key = tab.key
		f.tabs[i] = b
		x = x + 116
	end

	f.body = Theme:Panel(f, Theme.color.panel)
	f.body:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(TITLE_H + 8 + TAB_H))
	f.body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

	self.frame = f
	self:BuildPriorities()
	self:BuildPlan()
	self:BuildTest()
	self:BuildPresets()
	self:SelectTab(1)
	return f
end

function UI:Panes()
	return { self.prioPane, self.planPane, self.testPane, self.presetPane }
end

function UI:SelectTab(index)
	local f = self.frame
	if not f then return end
	self.current = index

	for i, b in ipairs(f.tabs) do
		Theme:SetTabSelected(b, i == index)
	end
	for _, pane in ipairs(self:Panes()) do
		if pane then pane:Hide() end
	end
	local pane = self:Panes()[index]
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

local function newPane(body)
	local pane = CreateFrame("Frame", nil, body)
	pane:SetPoint("TOPLEFT", body, "TOPLEFT", 1, -1)
	pane:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -1, 1)
	return pane
end

--------------------------------------------------------------------------
-- Tab 1: Priorities
--------------------------------------------------------------------------

function UI:BuildPriorities()
	local pane = newPane(self.frame.body)
	self.prioPane = pane

	local head = Theme:Text(pane, "label", "GROUP BY", Theme.color.textFaint)
	head:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -12)

	pane.byRole = Theme:Button(pane, "Role", 54, 20, function()
		APP.db.railGrouping = "role"; UI:RefreshPriorities()
	end)
	pane.byRole:SetPoint("LEFT", head, "RIGHT", 8, 0)

	pane.byClass = Theme:Button(pane, "Class", 54, 20, function()
		APP.db.railGrouping = "class"; UI:RefreshPriorities()
	end)
	pane.byClass:SetPoint("LEFT", pane.byRole, "RIGHT", 4, 0)

	local rail = Theme:Panel(pane, Theme.color.shell)
	rail:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -40)
	rail:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 12, 12)
	rail:SetWidth(RAIL_W)
	local railScroll, railContent = Theme:ScrollList(rail, RAIL_W - 8, HEIGHT - 190)
	railScroll:SetPoint("TOPLEFT", rail, "TOPLEFT", 4, -4)
	railScroll:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", -4, 4)
	pane.railContent = railContent

	local detail = CreateFrame("Frame", nil, pane)
	detail:SetPoint("TOPLEFT", pane, "TOPLEFT", RAIL_W + 24, -12)
	detail:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -12, 12)
	pane.detail = detail

	detail.heading = Theme:Text(detail, "heading", "")
	detail.heading:SetPoint("TOPLEFT", detail, "TOPLEFT", 2, -2)

	detail.applies = Theme:Text(detail, "meta", "", Theme.color.textDim)
	detail.applies:SetPoint("TOPLEFT", detail.heading, "BOTTOMLEFT", 0, -5)

	detail.hint = Theme:Text(detail, "meta", "Order is what you want first. Only the top N matter, where N is the paladin count.", Theme.color.textFaint)
	detail.hint:SetPoint("TOPLEFT", detail.applies, "BOTTOMLEFT", 0, -3)

	detail.rows = {}

	detail.reset = Theme:Button(detail, "Reset to default", 130, 22, function()
		local key = UI.activeProfile
		if key and P.defaults[key] then
			APP.db.profiles[key] = Config.copy(P.defaults[key])
			UI:RefreshPriorities()
		end
	end, "ghost")
	detail.reset:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", 0, 2)

	detail.addLabel = Theme:Text(detail, "label", "ADD", Theme.color.textFaint)
	detail.addLabel:SetPoint("LEFT", detail.reset, "RIGHT", 16, 0)
	detail.addButtons = {}
end

--- The list being edited for the selected profile.
function UI:ActiveList(profile)
	return profile.priority
end

function UI:RefreshPriorities()
	local pane = self.prioPane
	if not pane then return end
	local db = APP.db
	local mode = db.railGrouping
	local content = pane.railContent

	for _, widget in ipairs(content.rows) do widget:Hide() end

	local groups = P:GroupedList(mode, db.profiles)
	if not self.activeProfile or not db.profiles[self.activeProfile] then
		local first = groups[1] and groups[1].items[1]
		self.activeProfile = first and first.key or nil
	end

	local function rowAt(i)
		local row = content.rows[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetSize(RAIL_W - 16, 21)
			row.bg = Theme.fill(row, Theme.color.card)
			row.stripe = row:CreateTexture(nil, "ARTWORK")
			row.stripe:SetPoint("TOPLEFT")
			row.stripe:SetPoint("BOTTOMLEFT")
			row.stripe:SetWidth(2)
			row.text = Theme:Text(row, "body", "")
			row.text:SetPoint("LEFT", row, "LEFT", 10, 0)
			content.rows[i] = row
		end
		row:Show()
		return row
	end

	local y, index = 2, 0
	for _, group in ipairs(groups) do
		index = index + 1
		local head = rowAt(index)
		head:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		head.text:SetText(group.label:upper())
		head.text:SetTextColor(Theme.color.textFaint[1], Theme.color.textFaint[2], Theme.color.textFaint[3])
		head.bg:SetColorTexture(0, 0, 0, 0)
		head.stripe:SetColorTexture(0, 0, 0, 0)
		head:EnableMouse(false)
		head:SetScript("OnClick", nil)
		y = y + 20

		for _, item in ipairs(group.items) do
			index = index + 1
			local row = rowAt(index)
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
			row.text:SetText(item.label)
			row:EnableMouse(true)

			local cc = Theme.classColor[item.profile.class] or Theme.color.accent
			local selected = (item.key == self.activeProfile)
			if selected then
				row.bg:SetColorTexture(Theme.color.raised[1], Theme.color.raised[2], Theme.color.raised[3], 1)
				row.text:SetTextColor(Theme.color.text[1], Theme.color.text[2], Theme.color.text[3])
			else
				row.bg:SetColorTexture(0, 0, 0, 0)
				row.text:SetTextColor(Theme.color.textDim[1], Theme.color.textDim[2], Theme.color.textDim[3])
			end
			row.stripe:SetColorTexture(cc[1], cc[2], cc[3], selected and 1 or 0.55)

			local key = item.key
			row:SetScript("OnClick", function()
				UI.activeProfile = key
				UI:RefreshPriorities()
			end)
			row:SetScript("OnEnter", function(self)
				if not selected then
					self.bg:SetColorTexture(Theme.color.card[1], Theme.color.card[2], Theme.color.card[3], 1)
				end
			end)
			row:SetScript("OnLeave", function(self)
				if not selected then self.bg:SetColorTexture(0, 0, 0, 0) end
			end)
			y = y + 21
		end
		y = y + 4
	end
	content:SetHeight(math.max(y, 1))

	Theme:SetEnabled(pane.byRole, mode ~= "role")
	Theme:SetEnabled(pane.byClass, mode ~= "class")

	self:RefreshDetail()
end

function UI:RefreshDetail()
	local detail = self.prioPane.detail
	local db = APP.db
	local key = self.activeProfile
	local profile = key and db.profiles[key]
	if not profile then return end

	local cc = Theme.classColor[profile.class] or Theme.color.accent
	detail.heading:SetText(profile.label or key)
	detail.heading:SetTextColor(cc[1], cc[2], cc[3])
	detail.applies:SetText(profile.tank
		and ("Applies to any %s in a tank role, main tank or off tank."):format((profile.class or ""):lower())
		or "")

	local list = self:ActiveList(profile)
	for _, row in ipairs(detail.rows) do row:Hide() end

	local inList = {}
	for i, entry in ipairs(list) do
		local blessing, requires = entryBlessing(entry)
		inList[blessing] = true

		local row = detail.rows[i]
		if not row then
			row = Theme:Card(detail, Theme.color.accent)
			row:SetSize(520, 30)
			row.rank = Theme:Text(row, "meta", "", Theme.color.textFaint)
			row.rank:SetPoint("LEFT", row, "LEFT", 10, 0)
			row.icon = Theme:Icon(row, nil, 20)
			row.icon:SetPoint("LEFT", row, "LEFT", 26, 0)
			row.name = Theme:Text(row, "body", "")
			row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
			row.cond = Theme:Pill(row, "", Theme.color.textDim)
			row.cond:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
			row.up = Theme:Button(row, "^", 24, 20, nil, "ghost")
			row.up:SetPoint("RIGHT", row, "RIGHT", -86, 0)
			row.down = Theme:Button(row, "v", 24, 20, nil, "ghost")
			row.down:SetPoint("RIGHT", row, "RIGHT", -58, 0)
			row.remove = Theme:Button(row, "x", 24, 20, nil, "danger")
			row.remove:SetPoint("RIGHT", row, "RIGHT", -30, 0)
			detail.rows[i] = row
		end

		row:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -52 - (i - 1) * 34)
		row:Show()
		row.rank:SetText(tostring(i))
		row.icon:SetIcon(B.icons[blessing])
		row.name:SetText(B:Name(blessing))
		Theme:SetStripe(row, cc)

		if requires then
			row.cond:SetPillText(CONDITION_TEXT[requires] or "conditional", Theme.color.textDim)
			row.cond:Show()
		else
			row.cond:Hide()
		end

		local pos = i
		Theme:SetEnabled(row.up, i > 1)
		row.up:SetScript("OnClick", function()
			list[pos], list[pos - 1] = list[pos - 1], list[pos]
			UI:RefreshDetail()
		end)
		Theme:SetEnabled(row.down, i < #list)
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
				btn = Theme:Button(detail, "", 58, 20, nil, "default")
				detail.addButtons[n] = btn
			end
			btn:SetText(B:Short(blessing))
			btn:ClearAllPoints()
			btn:SetPoint("LEFT", detail.addLabel, "RIGHT", 8 + (n - 1) * 62, 0)
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

local STAT_KEYS = {
	{ key = "raid",     caption = "RAID" },
	{ key = "paladins", caption = "PALADINS" },
	{ key = "holy",     caption = "HOLY" },
	{ key = "prot",     caption = "PROT" },
	{ key = "tanks",    caption = "TANKS" },
	{ key = "overrides", caption = "OVERRIDES" },
}

function UI:BuildPlan()
	local pane = newPane(self.frame.body)
	pane:Hide()
	self.planPane = pane

	pane.stats = {}
	local x = 12
	for _, spec in ipairs(STAT_KEYS) do
		local tile = Theme:Stat(pane, 118, spec.caption, "--")
		tile:SetPoint("TOPLEFT", pane, "TOPLEFT", x, -12)
		pane.stats[spec.key] = tile
		x = x + 124
	end

	pane.warn = Theme:Card(pane, Theme.color.bad)
	pane.warn:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -64)
	pane.warn:SetPoint("RIGHT", pane, "RIGHT", -12, 0)
	pane.warn:SetHeight(28)
	pane.warn.text = Theme:Text(pane.warn, "body", "", Theme.color.bad)
	pane.warn.text:SetPoint("LEFT", pane.warn, "LEFT", 10, 0)
	pane.warn:Hide()

	pane.notice = Theme:Text(pane, "heading", "", Theme.color.textDim)
	pane.notice:SetPoint("CENTER", pane, "CENTER", 0, 26)
	pane.notice:SetJustifyH("CENTER")

	pane.hint = Theme:Text(pane, "body", "", Theme.color.textFaint)
	pane.hint:SetPoint("TOP", pane.notice, "BOTTOM", 0, -8)
	pane.hint:SetJustifyH("CENTER")

	pane.goTest = Theme:Button(pane, "Open Test Mode", 140, 24, function() UI:SelectTab(3) end, "primary")
	pane.goTest:SetPoint("TOP", pane.hint, "BOTTOM", 0, -12)

	local scroll, content = Theme:ScrollList(pane, WIDTH - 60, HEIGHT - 220)
	scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -100)
	scroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -12, 44)
	pane.content = content
	content.gridRows = {}
	content.gridHeads = {}
	content.ovrRows = {}

	pane.preview = Theme:Button(pane, "Preview changes", 130, 24, function()
		APP.Commands:Handle("preview")
	end, "default")
	pane.preview:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 12, 12)

	pane.apply = Theme:Button(pane, "Apply to PallyPower", 160, 24, function()
		APP.Commands:Handle("apply")
		UI:RefreshPlan()
	end, "primary")
	pane.apply:SetPoint("LEFT", pane.preview, "RIGHT", 8, 0)

	pane.applyNote = Theme:Text(pane, "meta", "", Theme.color.textFaint)
	pane.applyNote:SetPoint("LEFT", pane.apply, "RIGHT", 12, 0)
end

local function hideAll(list) for _, w in ipairs(list) do w:Hide() end end

function UI:RefreshPlan()
	local pane = self.planPane
	if not pane then return end
	local content = pane.content

	hideAll(content.gridRows); hideAll(content.gridHeads); hideAll(content.ovrRows)

	local simulated = R:IsSimulated()
	local inGroup = (GetNumGroupMembers and GetNumGroupMembers() or 0) > 0

	if not simulated and not inGroup then
		for _, tile in pairs(pane.stats) do tile.value:SetText("--") end
		pane.warn:Hide()
		pane.notice:SetText("Not in a group")
		pane.hint:SetText("The plan needs a roster to solve against.\nPriorities and Test Mode work anywhere.")
		pane.notice:Show(); pane.hint:Show(); pane.goTest:Show()
		Theme:SetEnabled(pane.preview, false)
		Theme:SetEnabled(pane.apply, false)
		pane.applyNote:SetText("")
		return
	end
	pane.notice:Hide(); pane.hint:Hide(); pane.goTest:Hide()

	local result, err = APP.Commands:Solve()
	if not result then
		pane.notice:SetText(err or "Could not solve.")
		pane.notice:Show()
		Theme:SetEnabled(pane.preview, false)
		Theme:SetEnabled(pane.apply, false)
		return
	end

	local tanks = 0
	for _, m in ipairs(result.members) do if m.tank then tanks = tanks + 1 end end
	pane.stats.raid.value:SetText(tostring(#result.members))
	pane.stats.paladins.value:SetText(tostring(#result.paladins))
	pane.stats.tanks.value:SetText(tostring(tanks))
	pane.stats.overrides.value:SetText(tostring(#result.overrides))

	local function yesNo(tile, on)
		tile.value:SetText(on and "yes" or "no")
		local c = on and Theme.color.good or Theme.color.textFaint
		tile.value:SetTextColor(c[1], c[2], c[3])
	end
	yesNo(pane.stats.holy, result.context.holyPaladin)
	yesNo(pane.stats.prot, result.context.protPaladin)

	Theme:SetEnabled(pane.preview, not simulated)
	Theme:SetEnabled(pane.apply, not simulated)
	pane.applyNote:SetText(simulated and "Disabled: this is a simulated raid." or "")

	-- Who will not receive what we send, and why.
	local blocked = {}
	if not simulated then
		for _, p in ipairs(result.paladins) do
			local ok, _, why = PP:ControlStatus(p.name)
			if not ok then blocked[#blocked + 1] = ("%s (%s)"):format(p.name, why) end
		end
	end
	if #blocked > 0 then
		pane.warn.text:SetText(("Cannot set %d of %d paladins:  %s")
			:format(#blocked, #result.paladins, table.concat(blocked, ",  ")))
		pane.warn:Show()
	else
		pane.warn:Hide()
	end

	-- The grid, one row per paladin, one icon per class column.
	local classes = {}
	for c = 1, B.MAX_CLASSES do
		if result.perClass[c] and result.perClass[c].memberCount > 0 then
			classes[#classes + 1] = c
		end
	end

	local NAME_W, CELL = 150, 34
	local y = 4

	for i, classID in ipairs(classes) do
		local head = content.gridHeads[i]
		if not head then
			head = CreateFrame("Frame", nil, content)
			head:SetSize(CELL, 30)
			head.name = Theme:Text(head, "meta", "")
			head.name:SetPoint("TOP", head, "TOP", 0, -2)
			head.name:SetJustifyH("CENTER")
			head.count = Theme:Text(head, "meta", "", Theme.color.textFaint)
			head.count:SetPoint("TOP", head.name, "BOTTOM", 0, -1)
			head.count:SetJustifyH("CENTER")
			content.gridHeads[i] = head
		end
		head:SetPoint("TOPLEFT", content, "TOPLEFT", NAME_W + (i - 1) * CELL, -y)
		local class = B.CLASS_BY_ID[classID]
		local cc = Theme.classColor[class] or Theme.color.text
		head.name:SetText(class:sub(1, 3))
		head.name:SetTextColor(cc[1], cc[2], cc[3])
		head.count:SetText(tostring(result.perClass[classID].memberCount))
		head:Show()
	end
	y = y + 34

	for pi, pally in ipairs(result.paladins) do
		local row = content.gridRows[pi]
		if not row then
			row = Theme:Card(content, Theme.color.accent)
			row:SetSize(NAME_W + B.MAX_CLASSES * CELL, 30)
			row.name = Theme:Text(row, "body", "")
			row.name:SetPoint("LEFT", row, "LEFT", 10, 3)
			row.spec = Theme:Text(row, "meta", "", Theme.color.textFaint)
			row.spec:SetPoint("LEFT", row, "LEFT", 10, -8)
			row.cells = {}
			content.gridRows[pi] = row
		end
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		row:Show()

		local ok = PP:ControlStatus(pally.name)
		row.name:SetText(pally.name)
		local nameColor = ok and Theme.color.text or Theme.color.bad
		row.name:SetTextColor(nameColor[1], nameColor[2], nameColor[3])
		row.spec:SetText((pally.spec or "?"):lower() .. (ok and "" or "  cannot set"))
		Theme:SetStripe(row, ok and Theme.classColor.PALADIN or Theme.color.bad)

		for i, classID in ipairs(classes) do
			local cell = row.cells[i]
			if not cell then
				cell = Theme:Icon(row, nil, 24)
				row.cells[i] = cell
			end
			cell:ClearAllPoints()
			cell:SetPoint("LEFT", row, "LEFT", NAME_W + (i - 1) * CELL + 4, 0)
			local blessing = result.grid[pally.name] and result.grid[pally.name][classID] or B.NONE
			if blessing == B.NONE then
				cell.tex:SetTexture(nil)
				cell.tex:SetColorTexture(Theme.color.panel[1], Theme.color.panel[2], Theme.color.panel[3], 1)
			else
				cell:SetIcon(B.icons[blessing])
			end
			cell:Show()
		end
		for i = #classes + 1, #row.cells do row.cells[i]:Hide() end
		y = y + 34
	end

	y = y + 10

	-- Overrides as cards, striped by the kind of player they serve.
	for i, o in ipairs(result.overrides) do
		local row = content.ovrRows[i]
		if not row then
			row = Theme:Card(content, Theme.color.textDim)
			row:SetSize(WIDTH - 90, 30)
			row.who = Theme:Text(row, "body", "")
			row.who:SetPoint("LEFT", row, "LEFT", 12, 0)
			row.who:SetWidth(120)
			row.fromIcon = Theme:Icon(row, nil, 20)
			row.fromIcon:SetPoint("LEFT", row, "LEFT", 140, 0)
			row.arrow = Theme:Text(row, "meta", ">", Theme.color.textFaint)
			row.arrow:SetPoint("LEFT", row.fromIcon, "RIGHT", 6, 0)
			row.toIcon = Theme:Icon(row, nil, 20)
			row.toIcon:SetPoint("LEFT", row.arrow, "RIGHT", 6, 0)
			row.reason = Theme:Pill(row, "", Theme.color.textDim)
			row.reason:SetPoint("LEFT", row.toIcon, "RIGHT", 12, 0)
			row.by = Theme:Text(row, "meta", "", Theme.color.textFaint)
			row.by:SetPoint("LEFT", row.reason, "RIGHT", 12, 0)
			content.ovrRows[i] = row
		end
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		row:Show()

		local color = Theme.reasonColor[o.reason] or Theme.color.textDim
		Theme:SetStripe(row, color)
		row.who:SetText(o.target)
		row.fromIcon:SetIcon(B.icons[o.replaces])
		row.toIcon:SetIcon(B.icons[o.blessing])
		row.reason:SetPillText(o.reason or "UPGRADE", color)
		row.by:SetText(("%s casts %s"):format(o.paladin, B:Name(o.blessing)))
		y = y + 34
	end

	content:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------
-- Tab 3: Test Mode
--------------------------------------------------------------------------

local TEST_FIELDS = {
	{ key = "raidSize", label = "RAID SIZE", min = 1, max = 40 },
	{ key = "paladins", label = "PALADINS",  min = 0, max = 8 },
	{ key = "tanks",    label = "TANKS",     min = 0, max = 6 },
	{ key = "healers",  label = "HEALERS",   min = 0, max = 12 },
}

function UI:BuildTest()
	local pane = newPane(self.frame.body)
	pane:Hide()
	self.testPane = pane

	local intro = Theme:Text(pane, "body", "Generate a raid to solve against, with no group required.", Theme.color.textDim)
	intro:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -12)

	pane.fields = {}
	local x = 12
	for _, field in ipairs(TEST_FIELDS) do
		local card = Theme:Card(pane)
		card:SetSize(150, 62)
		card:SetPoint("TOPLEFT", pane, "TOPLEFT", x, -38)

		card.caption = Theme:Text(card, "label", field.label, Theme.color.textDim)
		card.caption:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)

		card.minus = Theme:Button(card, "-", 22, 20, function()
			local t = APP.db.testMode
			t[field.key] = math.max(field.min, (t[field.key] or 0) - 1)
			UI:RefreshTest()
		end, "ghost")
		card.minus:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 8)

		card.value = Theme:Text(card, "title", "0")
		card.value:SetPoint("LEFT", card.minus, "RIGHT", 12, 0)
		card.value:SetWidth(34)
		card.value:SetJustifyH("CENTER")

		card.plus = Theme:Button(card, "+", 22, 20, function()
			local t = APP.db.testMode
			t[field.key] = math.min(field.max, (t[field.key] or 0) + 1)
			UI:RefreshTest()
		end, "ghost")
		card.plus:SetPoint("LEFT", card.value, "RIGHT", 12, 0)

		pane.fields[field.key] = card
		x = x + 156
	end

	pane.barLabel = Theme:Text(pane, "label", "CLASS BREAKDOWN", Theme.color.textFaint)
	pane.barLabel:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -114)

	pane.bar = Theme:StackBar(pane, WIDTH - 74, 22)
	pane.bar:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -132)

	pane.legend = Theme:Text(pane, "meta", "", Theme.color.textDim)
	pane.legend:SetPoint("TOPLEFT", pane.bar, "BOTTOMLEFT", 0, -8)
	pane.legend:SetWidth(WIDTH - 74)
	pane.legend:SetJustifyH("LEFT")

	pane.generate = Theme:Button(pane, "Generate raid", 130, 24, function()
		local t = APP.db.testMode
		APP.Commands:Handle(("test %d %d %d %d"):format(
			t.raidSize, t.paladins, t.tanks, t.healers))
		UI:RefreshTest()
	end, "primary")
	pane.generate:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -196)

	pane.solve = Theme:Button(pane, "Solve and show plan", 160, 24, function()
		UI:SelectTab(2)
	end, "default")
	pane.solve:SetPoint("LEFT", pane.generate, "RIGHT", 8, 0)

	pane.leave = Theme:Button(pane, "Leave test mode", 140, 24, function()
		APP.Commands:Handle("test off")
		UI:RefreshTest()
	end, "ghost")
	pane.leave:SetPoint("LEFT", pane.solve, "RIGHT", 8, 0)

	pane.status = Theme:Text(pane, "body", "", Theme.color.textDim)
	pane.status:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -234)

	pane.seed = Theme:Text(pane, "meta", "", Theme.color.textFaint)
	pane.seed:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -254)
end

function UI:RefreshTest()
	local pane = self.testPane
	if not pane then return end
	local t = APP.db.testMode

	for key, card in pairs(pane.fields) do
		card.value:SetText(tostring(t[key] or 0))
	end

	local simulated = R:IsSimulated()
	Theme:SetEnabled(pane.leave, simulated)
	Theme:SetEnabled(pane.solve, simulated)

	if simulated then
		local raid = R.simulated
		local sum = R:Summary(raid)
		local parts, legend = {}, {}
		for c = 1, B.MAX_CLASSES do
			local n = sum.classCounts[c] or 0
			if n > 0 then
				local class = B.CLASS_BY_ID[c]
				parts[#parts + 1] = { value = n, color = Theme.classColor[class] or Theme.color.text }
				legend[#legend + 1] = ("%s %d"):format(class:sub(1, 1) .. class:sub(2):lower(), n)
			end
		end
		pane.bar:SetParts(parts)
		pane.legend:SetText(table.concat(legend, "    "))
		pane.status:SetText(("|cff5cc86eTest raid active|r   %d players, %d paladins, %d tanks, %d healers")
			:format(sum.size, sum.paladins, sum.tanks, sum.healers))
		pane.seed:SetText(("Seed %s  -  reproduce with  /app test %d %d %d %d %s"):format(
			tostring(raid.seed), t.raidSize, t.paladins, t.tanks, t.healers, tostring(raid.seed)))
	else
		pane.bar:SetParts({})
		pane.legend:SetText("")
		pane.status:SetText("No test raid generated yet.")
		pane.seed:SetText("")
	end
end

--------------------------------------------------------------------------
-- Tab 4: Presets
--------------------------------------------------------------------------

function UI:BuildPresets()
	local pane = newPane(self.frame.body)
	pane:Hide()
	self.presetPane = pane

	local intro = Theme:Text(pane, "body", "A preset is a saved copy of your priorities, for the night that wants something different.", Theme.color.textDim)
	intro:SetPoint("TOPLEFT", pane, "TOPLEFT", 12, -12)

	local hint = Theme:Text(pane, "meta", "Names are yours -- a boss, a comp, a night. Selection is always manual.", Theme.color.textFaint)
	hint:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -4)

	local boxFrame = Theme:Panel(pane, Theme.color.shell)
	boxFrame:SetSize(240, 24)
	boxFrame:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -14)

	pane.box = CreateFrame("EditBox", nil, boxFrame)
	pane.box:SetPoint("TOPLEFT", boxFrame, "TOPLEFT", 8, -2)
	pane.box:SetPoint("BOTTOMRIGHT", boxFrame, "BOTTOMRIGHT", -8, 2)
	pane.box:SetAutoFocus(false)
	pane.box:SetMaxLetters(40)
	if pane.box.SetFontObject then pane.box:SetFontObject("GameFontHighlightSmall") end

	pane.save = Theme:Button(pane, "Save current as", 130, 24, function()
		local name = pane.box:GetText()
		if not name or name == "" then
			APP.Print("Type a name first.")
			return
		end
		Config:SavePreset(name, APP.db.profiles)
		pane.box:SetText("")
		UI:RefreshPresets()
		APP.Print(("Saved preset '%s'."):format(name))
	end, "primary")
	pane.save:SetPoint("LEFT", boxFrame, "RIGHT", 8, 0)

	local scroll, content = Theme:ScrollList(pane, WIDTH - 60, HEIGHT - 240)
	scroll:SetPoint("TOPLEFT", boxFrame, "BOTTOMLEFT", 0, -14)
	scroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -12, 12)
	pane.content = content

	-- Its own widget rather than a borrowed row. Sharing the row pool meant the
	-- empty-state row was created without the activate and delete buttons, and
	-- the first saved preset then reused that slot and died reaching for them.
	pane.empty = Theme:Text(content, "body", "No presets saved yet.", Theme.color.textFaint)
	pane.empty:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
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
		content:SetHeight(24)
		return
	end
	pane.empty:Hide()

	local y = 2
	for i, name in ipairs(names) do
		local active = (db.activePreset == name)
		local row = content.rows[i]
		if not row then
			row = Theme:Card(content, Theme.color.textDim)
			row:SetSize(WIDTH - 90, 34)
			row.text = Theme:Text(row, "body", "")
			row.text:SetPoint("LEFT", row, "LEFT", 12, 0)
			row.activate = Theme:Button(row, "", 92, 22, nil, "default")
			row.activate:SetPoint("RIGHT", row, "RIGHT", -104, 0)
			row.delete = Theme:Button(row, "Delete", 84, 22, nil, "danger")
			row.delete:SetPoint("RIGHT", row, "RIGHT", -12, 0)
			content.rows[i] = row
		end
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		row:Show()

		Theme:SetStripe(row, active and Theme.color.good or Theme.color.textFaint)
		row.text:SetText(active and (name .. "   (active)") or name)
		local tc = active and Theme.color.good or Theme.color.text
		row.text:SetTextColor(tc[1], tc[2], tc[3])

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
		y = y + 38
	end
	content:SetHeight(math.max(y, 1))
end
