local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local B, PP = APP.Blessings, APP.PP

-- PallyPower's own parsers, copied verbatim from its ParseMessage. If our
-- messages do not survive these, an override silently never arrives -- which
-- is exactly the kind of failure you cannot see from inside the game.
local function parseNASSIGN(msg)
	local out = {}
	for pname, class, tname, skill in string.gmatch(string.sub(msg, 9),
			"([^@]*) ([^@]*) ([^@]*) ([^@]*)") do
		out[#out + 1] = {
			pname = pname, class = tonumber(class),
			tname = tname, skill = tonumber(skill),
		}
	end
	return out
end

local function parsePASSIGN(msg)
	local _, _, name, assign = string.find(msg, "^PASSIGN (.*)@([0-9n]*)")
	if not name then return nil end
	local row = {}
	for i = 1, B.MAX_CLASSES do
		local tmp = string.sub(assign, i, i)
		if tmp == "n" or tmp == "" then tmp = 0 end
		row[i] = tmp + 0
	end
	return name, row
end

--- Run Apply against stub globals and collect what went on the wire.
local function apply(result, opts)
	local sent = {}
	_G.PallyPower = {
		SendMessage = function(_, msg) sent[#sent + 1] = msg end,
		UpdateLayout = function() end,
	}
	_G.PallyPower_Assignments = {}
	_G.PallyPower_NormalAssignments = {}
	_G.IsInRaid = function() return true end
	_G.IsInGroup = function() return true end
	_G.IsInInstance = function() return false end
	_G.UnitIsGroupLeader = function() return true end
	_G.UnitIsGroupAssistant = function() return false end

	PP.observed, PP.heard, PP.freeAssign = {}, {}, {}
	PP.selfName = (opts or {}).selfName or "Rageblue"

	local ok, msg, stats = PP:Apply(result)
	return ok, stats, sent
end

local function cleanup()
	_G.PallyPower, _G.PallyPower_Assignments, _G.PallyPower_NormalAssignments = nil, nil, nil
	_G.IsInRaid, _G.IsInGroup, _G.IsInInstance = nil, nil, nil
	_G.UnitIsGroupLeader, _G.UnitIsGroupAssistant = nil, nil
end

--------------------------------------------------------------------------
print("== our overrides survive PallyPower's own NASSIGN parser ==")
do
	local overrides = {}
	-- More than one batch: PallyPower sends five per message and so do we.
	for i = 1, 7 do
		overrides[i] = {
			paladin = "Rageblue", classID = (i % 9) + 1,
			target = "Target" .. i, blessing = (i % 6) + 1,
		}
	end
	local result = { paladins = {}, grid = { Rageblue = {} }, overrides = overrides }

	local ok, _, sent = apply(result)
	T.check("apply succeeded", ok)

	local decoded = {}
	for _, msg in ipairs(sent) do
		if msg:sub(1, 7) == "NASSIGN" then
			for _, e in ipairs(parseNASSIGN(msg)) do
				decoded[e.pname .. "/" .. e.class .. "/" .. e.tname] = e.skill
			end
		end
	end

	T.eq("every override arrived", (function()
		local n = 0 for _ in pairs(decoded) do n = n + 1 end return n
	end)(), #overrides)

	for _, o in ipairs(overrides) do
		local key = o.paladin .. "/" .. o.classID .. "/" .. o.target
		T.eq("decoded intact: " .. key, decoded[key], o.blessing)
	end
	cleanup()
end

--------------------------------------------------------------------------
print("== batches stay within PallyPower's five-per-message shape ==")
do
	local overrides = {}
	for i = 1, 12 do
		overrides[i] = { paladin = "Rageblue", classID = 1, target = "T" .. i, blessing = 5 }
	end
	local ok, _, sent = apply({ paladins = {}, grid = { Rageblue = {} }, overrides = overrides })
	T.check("apply succeeded", ok)

	local nassign = {}
	for _, msg in ipairs(sent) do
		if msg:sub(1, 7) == "NASSIGN" then nassign[#nassign + 1] = msg end
	end
	T.check("more than one message was needed", #nassign > 1, tostring(#nassign))
	for _, msg in ipairs(nassign) do
		T.check("no message carries more than five", #parseNASSIGN(msg) <= 5, msg)
		-- Addon messages are capped at 255 characters.
		T.check("message fits the addon channel", #msg <= 240, tostring(#msg))
	end
	cleanup()
end

--------------------------------------------------------------------------
print("== the greater grid survives PallyPower's PASSIGN parser ==")
do
	local grid = { Rageblue = {} }
	for c = 1, B.MAX_CLASSES do grid.Rageblue[c] = (c % 6) + 1 end
	grid.Rageblue[3] = B.NONE  -- an empty column must decode as zero

	local ok, _, sent = apply({ paladins = {}, grid = grid, overrides = {} })
	T.check("apply succeeded", ok)

	local found = false
	for _, msg in ipairs(sent) do
		if msg:sub(1, 7) == "PASSIGN" then
			local name, row = parsePASSIGN(msg)
			T.eq("row is for the right paladin", name, "Rageblue")
			found = true
			for c = 1, B.MAX_CLASSES do
				T.eq("class " .. c .. " decoded", row[c], grid.Rageblue[c])
			end
		end
	end
	T.check("a PASSIGN was sent", found)
	cleanup()
end

--------------------------------------------------------------------------
print("== clearing an override sends a zero PallyPower reads as nil ==")
do
	local sent = {}
	_G.PallyPower = { SendMessage = function(_, m) sent[#sent + 1] = m end, UpdateLayout = function() end }
	_G.PallyPower_Assignments = {}
	-- A stale override the new plan no longer wants.
	_G.PallyPower_NormalAssignments = { Rageblue = { [1] = { Oldtarget = B.LIGHT } } }
	_G.IsInRaid = function() return true end
	_G.IsInGroup = function() return true end
	_G.IsInInstance = function() return false end
	_G.UnitIsGroupLeader = function() return true end
	_G.UnitIsGroupAssistant = function() return false end
	PP.observed, PP.heard, PP.freeAssign = {}, {}, {}
	PP.selfName = "Rageblue"

	local ok, _, stats = PP:Apply({ paladins = {}, grid = { Rageblue = {} }, overrides = {} })
	T.check("apply succeeded", ok)
	T.eq("the stale override was cleared", stats.cleared, 1)
	T.eq("and removed from the table",
		_G.PallyPower_NormalAssignments.Rageblue[1].Oldtarget, nil)

	local sawZero = false
	for _, msg in ipairs(sent) do
		if msg:find("Oldtarget", 1, true) then
			local e = parseNASSIGN(msg)[1]
			T.eq("broadcast as zero", e.skill, 0)
			sawZero = true
		end
	end
	T.check("the clear was broadcast", sawZero)
	cleanup()
end

--------------------------------------------------------------------------
print("== verify reads back what apply wrote ==")
do
	local result = {
		paladins = { { name = "Rageblue" } },
		grid = { Rageblue = { [1] = B.KINGS, [4] = B.SALVATION } },
		overrides = {
			{ paladin = "Rageblue", classID = 4, target = "Feraltank", blessing = B.LIGHT },
			{ paladin = "Rageblue", classID = 1, target = "Prottank", blessing = B.MIGHT },
		},
	}
	local ok = apply(result)
	T.check("apply succeeded", ok)

	local report = PP:Verify(result)
	T.check("verify reports everything in place", report.ok, "missing " .. #report.missing
		.. ", different " .. #report.different)
	T.eq("both overrides confirmed", report.matchedOverrides, 2)
	T.check("grid cells confirmed", report.matchedGrid >= 2)

	-- Now break one by hand and confirm verify notices.
	_G.PallyPower_NormalAssignments.Rageblue[4].Feraltank = nil
	local broken = PP:Verify(result)
	T.check("a removed override is reported", broken.ok == false)
	T.eq("as missing", #broken.missing, 1)
	T.eq("naming the target", broken.missing[1].target, "Feraltank")

	_G.PallyPower_NormalAssignments.Rageblue[4].Feraltank = B.WISDOM
	local wrong = PP:Verify(result)
	T.eq("a changed override is reported as differing", #wrong.different, 1)
	T.eq("with what is actually there", wrong.different[1].have, B.WISDOM)
	T.eq("and what was wanted", wrong.different[1].want, B.LIGHT)
	cleanup()
end

T.report("wire")
