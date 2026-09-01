-- Visual language for the addon window.
--
-- WoW's default frame art -- the gold DialogBox border, the stone buttons --
-- is heavy and dates the interface. This builds a flatter, darker surface out
-- of plain coloured textures instead: solid fills, hairline borders, and a
-- coloured stripe down the left of anything that belongs to a category.
--
-- The whole style lives here rather than being sprinkled through MainFrame, so
-- changing the palette is one file and every screen follows.
local ADDON, APP = ...

local Theme = {}
APP.Theme = Theme

--------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------

-- Neutrals carry a slight violet bias rather than being pure grey, which keeps
-- them from reading as unconsidered next to the accent.
Theme.color = {
	shell      = { 0.055, 0.050, 0.068 },
	panel      = { 0.078, 0.073, 0.094 },
	card       = { 0.110, 0.104, 0.132 },
	cardHover  = { 0.140, 0.132, 0.166 },
	raised     = { 0.165, 0.156, 0.196 },

	edge       = { 0.200, 0.190, 0.240 },
	edgeSoft   = { 0.145, 0.138, 0.175 },

	text       = { 0.925, 0.915, 0.945 },
	textDim    = { 0.560, 0.540, 0.610 },
	textFaint  = { 0.380, 0.365, 0.435 },

	-- Paladin pink: the class colour, and specific to this addon's subject.
	accent     = { 0.960, 0.549, 0.729 },
	accentDeep = { 0.420, 0.220, 0.320 },

	good       = { 0.360, 0.780, 0.480 },
	warn       = { 0.950, 0.640, 0.260 },
	bad        = { 0.900, 0.340, 0.360 },
	info       = { 0.420, 0.640, 0.850 },
}

-- Canonical class colours, used as data encoding only.
Theme.classColor = {
	WARRIOR = { 0.78, 0.61, 0.43 }, ROGUE   = { 1.00, 0.96, 0.41 },
	PRIEST  = { 0.90, 0.90, 0.90 }, DRUID   = { 1.00, 0.49, 0.04 },
	PALADIN = { 0.96, 0.55, 0.73 }, HUNTER  = { 0.67, 0.83, 0.45 },
	MAGE    = { 0.41, 0.80, 0.94 }, WARLOCK = { 0.58, 0.51, 0.79 },
	SHAMAN  = { 0.14, 0.56, 0.87 },
}

-- Override reasons, so the stripe on a card says what kind of player it is
-- before you have read a word of it.
Theme.reasonColor = {
	TANK     = Theme.color.bad,
	HEALER   = Theme.color.good,
	CASTER   = Theme.color.info,
	PHYSICAL = Theme.color.warn,
	UPGRADE  = Theme.color.textDim,
}

local FONT_BODY = "Fonts\\FRIZQT__.TTF"
local FONT_META = "Fonts\\ARIALN.TTF"

-- Font object first, then SetFont: if a client rejects the path we still get
-- readable text rather than an invisible frame.
Theme.font = {
	title   = { object = "GameFontNormalLarge", file = FONT_BODY, size = 15 },
	heading = { object = "GameFontNormal",      file = FONT_BODY, size = 13 },
	value   = { object = "GameFontHighlight",   file = FONT_BODY, size = 13 },
	body    = { object = "GameFontHighlightSmall", file = FONT_BODY, size = 12 },
	label   = { object = "GameFontDisableSmall",   file = FONT_META, size = 11 },
	meta    = { object = "GameFontDisableSmall",   file = FONT_META, size = 10 },
	tab     = { object = "GameFontNormalSmall",    file = FONT_BODY, size = 12 },
}

--------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------

local function fill(frame, color, layer)
	local tex = frame:CreateTexture(nil, layer or "BACKGROUND")
	tex:SetAllPoints()
	tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
	return tex
end
Theme.fill = fill

--- Hairline border drawn as four textures, so there is no edge art to scale.
function Theme:Edge(frame, color, thickness)
	thickness = thickness or 1
	color = color or self.color.edge
	local edges = {}
	local function line(p1, p2, w, h)
		local tex = frame:CreateTexture(nil, "BORDER")
		tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
		tex:SetPoint(p1)
		tex:SetPoint(p2)
		if w then tex:SetWidth(w) end
		if h then tex:SetHeight(h) end
		return tex
	end
	edges.top    = line("TOPLEFT", "TOPRIGHT", nil, thickness)
	edges.bottom = line("BOTTOMLEFT", "BOTTOMRIGHT", nil, thickness)
	edges.left   = line("TOPLEFT", "BOTTOMLEFT", thickness, nil)
	edges.right  = line("TOPRIGHT", "BOTTOMRIGHT", thickness, nil)
	return edges
end

--- Text in one of the named styles.
function Theme:Text(parent, style, text, color)
	local spec = self.font[style] or self.font.body
	local fs = parent:CreateFontString(nil, "OVERLAY", spec.object)
	if fs.SetFont and spec.file then
		fs:SetFont(spec.file, spec.size, "")
	end
	local c = color or self.color.text
	fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
	fs:SetText(text or "")
	fs:SetJustifyH("LEFT")
	return fs
end

--- A flat surface.
function Theme:Panel(parent, color, edgeColor)
	local f = CreateFrame("Frame", nil, parent)
	f.bg = fill(f, color or self.color.panel)
	f.edges = self:Edge(f, edgeColor or self.color.edgeSoft)
	return f
end

--- A panel with a coloured stripe down its left edge, which is how the
--- category of a row reads at a glance.
function Theme:Card(parent, stripeColor, color)
	local f = self:Panel(parent, color or self.color.card)
	if stripeColor then
		f.stripe = f:CreateTexture(nil, "ARTWORK")
		f.stripe:SetPoint("TOPLEFT")
		f.stripe:SetPoint("BOTTOMLEFT")
		f.stripe:SetWidth(3)
		f.stripe:SetColorTexture(stripeColor[1], stripeColor[2], stripeColor[3], 1)
	end
	return f
end

function Theme:SetStripe(card, color)
	if not card.stripe then return end
	card.stripe:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
end

--------------------------------------------------------------------------
-- Controls
--------------------------------------------------------------------------

--- A flat button. `kind` is "default", "primary", "ghost" or "danger".
function Theme:Button(parent, text, width, height, onClick, kind)
	kind = kind or "default"
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width or 90, height or 22)
	b.__kind = kind

	b.bg = fill(b, self.color.raised)
	b.edges = self:Edge(b, self.color.edge)

	local fs = self:Text(b, "body", text)
	fs:SetPoint("CENTER")
	fs:SetJustifyH("CENTER")
	-- SetFontString means Button:SetText and :GetText work natively, so callers
	-- and tests can treat this like any other button.
	if b.SetFontString then b:SetFontString(fs) end
	b.label = fs
	b:SetText(text or "")

	b.__enabled = true
	self:StyleButton(b)

	b:SetScript("OnEnter", function(self)
		if self.__enabled then
			self.bg:SetColorTexture(Theme.color.cardHover[1], Theme.color.cardHover[2],
				Theme.color.cardHover[3], 1)
			if self.__kind == "primary" then
				self.bg:SetColorTexture(Theme.color.accentDeep[1] * 1.4,
					Theme.color.accentDeep[2] * 1.4, Theme.color.accentDeep[3] * 1.4, 1)
			end
		end
	end)
	b:SetScript("OnLeave", function(self) Theme:StyleButton(self) end)

	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

--- Repaint a button for its kind and enabled state.
function Theme:StyleButton(b)
	local c, text = self.color.raised, self.color.text
	if b.__kind == "primary" then
		c, text = self.color.accentDeep, self.color.accent
	elseif b.__kind == "ghost" then
		c, text = self.color.panel, self.color.textDim
	elseif b.__kind == "danger" then
		c, text = { 0.22, 0.09, 0.10 }, self.color.bad
	end
	if b.__enabled == false then
		c, text = self.color.panel, self.color.textFaint
	end
	if b.bg then b.bg:SetColorTexture(c[1], c[2], c[3], 1) end
	if b.label then b.label:SetTextColor(text[1], text[2], text[3], 1) end
end

--- Enable/disable that also repaints, and does not assume which widget API
--- this client has.
function Theme:SetEnabled(b, on)
	if not b then return end
	b.__enabled = on and true or false
	if b.SetEnabled then
		b:SetEnabled(b.__enabled)
	elseif b.__enabled then
		b:Enable()
	else
		b:Disable()
	end
	self:StyleButton(b)
end

--- A tab. Selection reads as a lighter surface plus an accent underline.
function Theme:Tab(parent, text, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(112, 26)
	b.bg = fill(b, self.color.panel)

	local fs = self:Text(b, "tab", text, self.color.textDim)
	fs:SetPoint("CENTER")
	fs:SetJustifyH("CENTER")
	if b.SetFontString then b:SetFontString(fs) end
	b.label = fs
	b:SetText(text or "")

	b.underline = b:CreateTexture(nil, "OVERLAY")
	b.underline:SetPoint("BOTTOMLEFT")
	b.underline:SetPoint("BOTTOMRIGHT")
	b.underline:SetHeight(2)
	b.underline:SetColorTexture(self.color.accent[1], self.color.accent[2], self.color.accent[3], 1)
	b.underline:Hide()

	b:SetScript("OnEnter", function(self)
		if not self.__selected then
			self.label:SetTextColor(Theme.color.text[1], Theme.color.text[2], Theme.color.text[3])
		end
	end)
	b:SetScript("OnLeave", function(self)
		if not self.__selected then
			self.label:SetTextColor(Theme.color.textDim[1], Theme.color.textDim[2], Theme.color.textDim[3])
		end
	end)
	if onClick then b:SetScript("OnClick", onClick) end
	return b
end

function Theme:SetTabSelected(tab, selected)
	tab.__selected = selected and true or false
	if selected then
		tab.bg:SetColorTexture(self.color.card[1], self.color.card[2], self.color.card[3], 1)
		tab.label:SetTextColor(self.color.text[1], self.color.text[2], self.color.text[3])
		tab.underline:Show()
	else
		tab.bg:SetColorTexture(self.color.panel[1], self.color.panel[2], self.color.panel[3], 1)
		tab.label:SetTextColor(self.color.textDim[1], self.color.textDim[2], self.color.textDim[3])
		tab.underline:Hide()
	end
end

--- A caption over a value, the unit the reference design leans on hardest.
function Theme:Stat(parent, width, captionText, valueText)
	local f = self:Card(parent)
	f:SetSize(width or 96, 46)
	f.caption = self:Text(f, "label", captionText, self.color.textDim)
	f.caption:SetPoint("TOPLEFT", f, "TOPLEFT", 9, -8)
	f.value = self:Text(f, "value", valueText, self.color.text)
	f.value:SetPoint("TOPLEFT", f.caption, "BOTTOMLEFT", 0, -3)
	return f
end

--- A small rounded-off label used for conditions and reasons.
function Theme:Pill(parent, text, color)
	local f = CreateFrame("Frame", nil, parent)
	f:SetHeight(15)
	f.bg = fill(f, { color[1] * 0.28, color[2] * 0.28, color[3] * 0.28, 0.9 })
	f.edges = self:Edge(f, { color[1] * 0.5, color[2] * 0.5, color[3] * 0.5 })
	f.label = self:Text(f, "meta", text, color)
	f.label:SetPoint("CENTER")
	f.SetPillText = function(self, t, c)
		self.label:SetText(t)
		if c then
			self.label:SetTextColor(c[1], c[2], c[3])
			self.bg:SetColorTexture(c[1] * 0.28, c[2] * 0.28, c[3] * 0.28, 0.9)
		end
		self:SetWidth(math.max(28, (self.label:GetStringWidth() or 30) + 14))
	end
	f:SetPillText(text, color)
	return f
end

--- A horizontal stacked bar, for showing a raid's class breakdown.
function Theme:StackBar(parent, width, height)
	local f = self:Panel(parent, self.color.shell)
	f:SetSize(width, height or 18)
	f.segments = {}

	--- @param parts array of { value = n, color = {r,g,b}, label = "" }
	function f:SetParts(parts)
		for _, seg in ipairs(self.segments) do seg:Hide() end
		local total = 0
		for _, p in ipairs(parts) do total = total + (p.value or 0) end
		if total <= 0 then return end

		local x, inner = 0, self:GetWidth() - 2
		for i, p in ipairs(parts) do
			local seg = self.segments[i]
			if not seg then
				seg = CreateFrame("Frame", nil, self)
				seg.bg = Theme.fill(seg, Theme.color.card)
				seg.label = Theme:Text(seg, "meta", "", { 0.05, 0.05, 0.06 })
				seg.label:SetPoint("CENTER")
				seg.label:SetJustifyH("CENTER")
				self.segments[i] = seg
			end
			local w = math.max(1, math.floor(inner * (p.value or 0) / total))
			seg:SetSize(w, self:GetHeight() - 2)
			seg:ClearAllPoints()
			seg:SetPoint("TOPLEFT", self, "TOPLEFT", 1 + x, -1)
			seg.bg:SetColorTexture(p.color[1], p.color[2], p.color[3], 1)
			-- Only label a segment wide enough to read.
			seg.label:SetText(w >= 16 and tostring(p.value) or "")
			seg:Show()
			x = x + w
		end
	end

	return f
end

--- Scrolling region with no chrome: the template scrollbar always draws its
--- arrows, which collide with whatever sits beside it.
function Theme:ScrollList(parent, width, height)
	local scroll = CreateFrame("ScrollFrame", nil, parent)
	scroll:SetSize(width, height)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(width, height)
	scroll:SetScrollChild(content)
	content.rows = {}

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = math.max(0, content:GetHeight() - self:GetHeight())
		local target = self:GetVerticalScroll() - delta * 26
		if target < 0 then target = 0 end
		if target > range then target = range end
		self:SetVerticalScroll(target)
	end)

	return scroll, content
end

--- A 24px blessing icon with a hairline border.
function Theme:Icon(parent, texture, size)
	local f = CreateFrame("Frame", nil, parent)
	size = size or 24
	f:SetSize(size, size)
	f.tex = f:CreateTexture(nil, "ARTWORK")
	f.tex:SetPoint("TOPLEFT", 1, -1)
	f.tex:SetPoint("BOTTOMRIGHT", -1, 1)
	if f.tex.SetTexCoord then f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	if texture then f.tex:SetTexture(texture) end
	f.edges = self:Edge(f, self.color.edge)
	f.SetIcon = function(self, path) self.tex:SetTexture(path) end
	return f
end
