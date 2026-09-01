-- Minimap button with a right-click menu.
--
-- Hand-rolled rather than pulled from LibDBIcon: this is the only library
-- surface we would need, and a companion addon that adds no embedded libraries
-- is one less thing to conflict with PallyPower's own Ace3 embed.
local ADDON, APP = ...

local Minimap = {}
APP.Minimap = Minimap

local BUTTON_NAME = "AutoPallyPowerMinimapButton"

local function positionButton(button, angle)
	local radius = 80
	local rad = math.rad(angle)
	button:SetPoint("CENTER", _G.Minimap, "CENTER",
		radius * math.cos(rad), radius * math.sin(rad))
end

local menuItems = {
	{ text = "Open window",          cmd = "ui" },
	{ text = "Plan current raid",    cmd = "plan" },
	{ text = "Per-player result",    cmd = "report" },
	{ text = "Preview changes",      cmd = "preview" },
	{ text = "Apply to PallyPower",  cmd = "apply" },
	{ separator = true },
	{ text = "Generate test raid",   cmd = "test" },
	{ text = "Leave test mode",      cmd = "test off" },
	{ separator = true },
	{ text = "Status",               cmd = "status" },
	{ text = "Help",                 cmd = "help" },
}

function Minimap:Create()
	if _G[BUTTON_NAME] then return _G[BUTTON_NAME] end

	local db = APP.db
	local button = CreateFrame("Button", BUTTON_NAME, _G.Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetTexture("Interface\\Icons\\Spell_Holy_GreaterBlessingofKings")
	icon:SetPoint("CENTER", button, "CENTER", -1, 1)
	button.icon = icon

	positionButton(button, db and db.minimap and db.minimap.angle or 210)

	-- Dragging around the minimap edge.
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function(s)
			local mx, my = _G.Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = _G.Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			local angle = math.deg(math.atan2(py - my, px - mx))
			positionButton(s, angle)
			if APP.db then APP.db.minimap.angle = angle end
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("AutoPallyPower")
		GameTooltip:AddLine("Left-click: open AutoPallyPower", 1, 1, 1)
		GameTooltip:AddLine("Right-click: menu", 1, 1, 1)
		if APP.Roster and APP.Roster:IsSimulated() then
			GameTooltip:AddLine("Test mode is on", 1, 0.4, 0.4)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	button:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			Minimap:ShowMenu(self)
		elseif APP.MainFrame then
			APP.MainFrame:Toggle()
		end
	end)

	self.button = button
	return button
end

function Minimap:ShowMenu(anchor)
	if not self.menuFrame then
		self.menuFrame = CreateFrame("Frame", BUTTON_NAME .. "Menu", UIParent, "UIDropDownMenuTemplate")
	end

	local function initialize(_, level)
		if level ~= 1 then return end
		local title = UIDropDownMenu_CreateInfo()
		title.text = "AutoPallyPower"
		title.isTitle = true
		title.notCheckable = true
		UIDropDownMenu_AddButton(title, level)

		for _, item in ipairs(menuItems) do
			local info = UIDropDownMenu_CreateInfo()
			if item.separator then
				info.disabled = true
				info.notCheckable = true
				info.text = ""
			else
				info.text = item.text
				info.notCheckable = true
				info.func = function()
					CloseDropDownMenus()
					APP.Commands:Handle(item.cmd)
				end
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end

	UIDropDownMenu_Initialize(self.menuFrame, initialize, "MENU")
	ToggleDropDownMenu(1, nil, self.menuFrame, anchor, 0, 0)
end

function Minimap:Toggle()
	if not self.button then return end
	if self.button:IsShown() then
		self.button:Hide()
		if APP.db then APP.db.minimap.hide = true end
	else
		self.button:Show()
		if APP.db then APP.db.minimap.hide = false end
	end
end
