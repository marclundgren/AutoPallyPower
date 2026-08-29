-- Renders a solved plan as text.
--
-- Kept free of WoW API calls so it can be exercised from the test harness and
-- so the same renderer serves chat output, the results window and /app report.
local ADDON, APP = ...

local B = APP.Blessings
local Report = {}
APP.Report = Report

local COLOR = {
	head    = "|cffffd100",
	dim     = "|cff9d9d9d",
	good    = "|cff1eff00",
	warn    = "|cffff2020",
	tank    = "|cffc79c6e",
	off     = "|r",
}

-- Plain mode strips colour codes for environments that do not render them.
function Report:Colorize(color, text, plain)
	if plain then return text end
	return (COLOR[color] or "") .. text .. COLOR.off
end

local function blessingList(ids)
	if #ids == 0 then return "--" end
	local names = {}
	for i = 1, #ids do names[i] = B:Short(ids[i]) end
	return table.concat(names, " ")
end

--- Full plan report.
-- @param result solver output
-- @param opts { plain = bool }
-- @return array of lines
function Report:Plan(result, opts)
	opts = opts or {}
	local plain = opts.plain
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	local function C(c, t) return self:Colorize(c, t, plain) end

	local pallyNames = {}
	for _, p in ipairs(result.paladins) do
		pallyNames[#pallyNames + 1] = ("%s (%s)"):format(p.name, p.spec:lower())
	end

	add(C("head", "AutoPallyPower plan"))
	add(("  %d paladins: %s"):format(#result.paladins,
		#pallyNames > 0 and table.concat(pallyNames, ", ") or "none"))
	add(("  holy paladin: %s   prot paladin: %s   tank mode: %s"):format(
		result.context.holyPaladin and "yes" or "no",
		result.context.protPaladin and "yes" or "no",
		result.context.tankPriority))
	add("")

	add(C("head", "Greater blessings by class"))
	for c = 1, B.MAX_CLASSES do
		local col = result.perClass[c]
		if col and col.memberCount > 0 then
			local who = {}
			for _, blessing in ipairs(col.blessings) do
				local pi = col.holders[blessing]
				who[#who + 1] = ("%s=%s"):format(
					B:Short(blessing),
					pi and result.paladins[pi].name or "?")
			end
			add(("  %-8s (%2d)  %-22s  %s"):format(
				col.class, col.memberCount,
				blessingList(col.blessings),
				C("dim", table.concat(who, " "))))
		end
	end

	if #result.overrides > 0 then
		add("")
		add(C("head", ("Per-player overrides (%d)"):format(#result.overrides)))
		for _, o in ipairs(result.overrides) do
			local tag = o.mandatory and C("warn", "[rule zero]") or C("dim", "[upgrade]")
			add(("  %-14s %s casts %s instead of %s  %s"):format(
				o.target, o.paladin,
				B:Name(o.blessing), B:Name(o.replaces), tag))
		end
	else
		add("")
		add(C("dim", "  no per-player overrides needed"))
	end

	if #result.warnings > 0 then
		add("")
		add(C("warn", "Warnings"))
		for _, w in ipairs(result.warnings) do
			add("  " .. C("warn", w))
		end
	end

	return lines
end

--- What each raid member ends up with, grouped by class.
function Report:PerMember(result, opts)
	opts = opts or {}
	local plain = opts.plain
	local lines = {}
	local function add(s) lines[#lines + 1] = s end
	local function C(c, t) return self:Colorize(c, t, plain) end

	add(C("head", "Resulting blessings per player"))
	for c = 1, B.MAX_CLASSES do
		local col = result.perClass[c]
		if col and col.memberCount > 0 then
			add(C("dim", "  " .. col.class))
			for _, m in ipairs(col.members) do
				local got = {}
				for _, b in ipairs(B.ALL) do
					if result.delivered[m.name] and result.delivered[m.name][b] then
						got[#got + 1] = B:Short(b)
					end
				end
				local label = m.tank and C("tank", m.name .. " (tank)") or m.name
				add(("    %-24s %-20s %s"):format(
					label, table.concat(got, " "), C("dim", m.profileLabel)))
			end
		end
	end
	return lines
end

--- Short diff summary for the apply step.
function Report:Diff(changes, opts)
	opts = opts or {}
	local lines = {}
	local function add(s) lines[#lines + 1] = s end

	add(("Greater blessing cells changed: %d"):format(#changes.grid))
	for _, ch in ipairs(changes.grid) do
		add(("  %s  %s: %s -> %s"):format(
			ch.paladin, B.CLASS_BY_ID[ch.classID],
			B:Name(ch.from), B:Name(ch.to)))
	end
	add(("Overrides added: %d, removed: %d"):format(
		#changes.addedOverrides, #changes.removedOverrides))
	return lines
end
