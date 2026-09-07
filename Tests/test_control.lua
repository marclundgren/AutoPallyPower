local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local PP = APP.PP

--- Reset the observed state between cases.
local function fresh()
	PP.observed, PP.heard, PP.freeAssign = {}, {}, {}
	PP.selfName, PP.selfSpec = "Rageblue", "HOLY"
end

--- Stub just the group-shape globals ControlStatus consults.
local function withGroup(opts, fn)
	local names = { "IsInRaid", "IsInGroup", "IsInInstance",
	                "UnitIsGroupLeader", "UnitIsGroupAssistant" }
	local saved = {}
	for _, n in ipairs(names) do saved[n] = _G[n] end
	local savedCat = _G.LE_PARTY_CATEGORY_INSTANCE

	_G.LE_PARTY_CATEGORY_INSTANCE = 2
	_G.IsInRaid = function() return opts.raid or false end
	_G.IsInGroup = function(cat)
		if cat == 2 then return opts.instanceGroup or false end
		return true
	end
	_G.IsInInstance = function() return opts.inInstance or false end
	_G.UnitIsGroupLeader = function() return opts.leader or false end
	_G.UnitIsGroupAssistant = function() return opts.assistant or false end

	local ok, err = pcall(fn)

	for _, n in ipairs(names) do _G[n] = saved[n] end
	_G.LE_PARTY_CATEGORY_INSTANCE = savedCat
	if not ok then error(err, 0) end
end

--------------------------------------------------------------------------
print("== free assignment is read off PallyPower's own broadcast ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO | SYMCOUNT 0 | COOLDOWNS:n:n:n:n", nil, "Closedpally")
	PP:OnAddonMessage("PLPWR", "FREEASSIGN YES | SYMCOUNT 3 | COOLDOWNS:n:n:n:n", nil, "Openpally")

	T.eq("free assignment off recorded", PP.freeAssign["Closedpally"], false)
	T.eq("free assignment on recorded", PP.freeAssign["Openpally"], true)
	T.check("both count as running PallyPower", PP:HasPallyPower("Closedpally") and PP:HasPallyPower("Openpally"))

	-- A message on someone else's prefix must not be mistaken for theirs.
	PP:OnAddonMessage("OTHERADDON", "FREEASSIGN YES", nil, "Strangerpally")
	T.eq("other prefixes ignored", PP.freeAssign["Strangerpally"], nil)
	T.check("and do not count as PallyPower", PP:HasPallyPower("Strangerpally") == false)
end

--------------------------------------------------------------------------
print("== a paladin who never speaks has no PallyPower ==")
do
	fresh()
	T.check("silence means not installed", PP:HasPallyPower("Silentpally") == false)
	local ok, reason, why = PP:ControlStatus("Silentpally")
	T.check("not controllable", ok == false)
	T.eq("reason names the cause", reason, "NO_PALLYPOWER")
	T.check("explanation mentions PallyPower", why:find("PallyPower") ~= nil, why)

	-- Any message at all is proof enough.
	PP:OnAddonMessage("PLPWR", "SELF 7261314130nn@nnnnnnnnn", nil, "Silentpally")
	T.check("now known to have it", PP:HasPallyPower("Silentpally"))
end

--------------------------------------------------------------------------
print("== raid rank makes no difference either way ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO", nil, "Closedpally")
	PP:OnAddonMessage("PLPWR", "FREEASSIGN YES", nil, "Openpally")

	-- Tested in a live raid: leader, assistant and plain member all set
	-- assignments identically, so rank is not consulted anywhere. Every shape
	-- of group has to give the same answer.
	local shapes = {
		{ label = "party member",   raid = false, leader = false },
		{ label = "party leader",   raid = false, leader = true },
		{ label = "raid member",    raid = true,  leader = false },
		{ label = "raid assistant", raid = true,  leader = false, assistant = true },
		{ label = "raid leader",    raid = true,  leader = true },
		{ label = "instance group", raid = true,  leader = true,
		  instanceGroup = true, inInstance = true },
	}
	for _, shape in ipairs(shapes) do
		withGroup(shape, function()
			T.check(shape.label .. ": free assignment on can be set",
				PP:CanControl("Openpally"))
			T.check(shape.label .. ": free assignment off cannot",
				PP:CanControl("Closedpally") == false)
			local _, reason = PP:ControlStatus("Closedpally")
			T.eq(shape.label .. ": and says exactly why", reason, "FREE_ASSIGN_OFF")
			T.check(shape.label .. ": our own row is always ours",
				PP:CanControl("Rageblue"))
		end)
	end
end

--------------------------------------------------------------------------
print("== a paladin who has not said either way is not assumed open ==")
do
	fresh()
	-- They are running PallyPower -- they sent SELF -- but never broadcast a
	-- free assignment state. Guessing "open" here would write a row into our
	-- own grid that their client may have thrown away.
	PP:OnAddonMessage("PLPWR", "SELF 7261314130nn@nnnnnnnnn", nil, "Quietpally")
	withGroup({ raid = true, leader = true }, function()
		local ok, reason = PP:ControlStatus("Quietpally")
		T.check("not controllable on an unknown state", ok == false)
		T.eq("and named as unknown rather than closed", reason, "UNKNOWN")
	end)
end

--------------------------------------------------------------------------
print("== we can always set ourselves ==")
do
	fresh()
	withGroup({ raid = false, leader = false }, function()
		T.check("own row is always controllable", PP:CanControl("Rageblue"))
		local ok, reason = PP:ControlStatus("Rageblue")
		T.check("and reported as such", ok)
		T.eq("reason is self", reason, "SELF")
	end)
end

--------------------------------------------------------------------------
print("== the report sorts problems to the top ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN YES", nil, "Openpally")
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO", nil, "Closedpally")

	withGroup({ raid = false, leader = false }, function()
		local report = PP:ControlReport({ "Openpally", "Rageblue", "Closedpally", "Silentpally" })
		T.eq("everyone reported", #report, 4)
		T.check("blocked paladins come first", report[1].canControl == false)
		T.check("second is also blocked", report[2].canControl == false)
		T.check("controllable ones come after", report[3].canControl == true)

		local byName = {}
		for _, r in ipairs(report) do byName[r.name] = r end
		T.eq("closed paladin flagged", byName.Closedpally.reason, "FREE_ASSIGN_OFF")
		T.eq("missing addon flagged", byName.Silentpally.reason, "NO_PALLYPOWER")
		T.eq("open paladin fine", byName.Openpally.reason, "FREE_ASSIGN")
		T.eq("we are fine", byName.Rageblue.reason, "SELF")
	end)
end

--------------------------------------------------------------------------
print("== apply skips paladins it cannot set, and says so ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO", nil, "Closedpally")
	PP:OnAddonMessage("PLPWR", "FREEASSIGN YES", nil, "Openpally")

	local sent = {}
	_G.PallyPower = {
		SendMessage = function(_, msg) sent[#sent + 1] = msg end,
		UpdateLayout = function() end,
	}
	_G.PallyPower_Assignments = {}
	_G.PallyPower_NormalAssignments = {}

	local B = APP.Blessings
	local result = {
		paladins = {},
		grid = {
			Rageblue    = { [1] = B.KINGS },
			Openpally   = { [1] = B.MIGHT },
			Closedpally = { [1] = B.SALVATION },
		},
		overrides = {
			{ paladin = "Closedpally", classID = 1, target = "Tankwar", blessing = B.LIGHT },
			{ paladin = "Openpally", classID = 1, target = "Tankwar", blessing = B.KINGS },
		},
	}

	withGroup({ raid = false, leader = false }, function()
		local ok, _, stats = PP:Apply(result)
		T.check("apply succeeded", ok)
		T.eq("one paladin skipped", #stats.blocked, 1)
		T.eq("the right one", stats.blocked[1].name, "Closedpally")
		T.eq("for the right reason", stats.blocked[1].reason, "FREE_ASSIGN_OFF")

		-- The point of skipping: our own grid must not claim an assignment
		-- that no other client received.
		T.eq("blocked row not written locally", _G.PallyPower_Assignments.Closedpally, nil)
		T.check("allowed rows written",
			_G.PallyPower_Assignments.Openpally ~= nil and _G.PallyPower_Assignments.Rageblue ~= nil)

		local mentionedBlocked = false
		for _, msg in ipairs(sent) do
			if msg:find("Closedpally", 1, true) then mentionedBlocked = true end
		end
		T.check("nothing broadcast for the blocked paladin", mentionedBlocked == false)

		T.eq("its override was skipped too",
			_G.PallyPower_NormalAssignments.Closedpally, nil)
		T.check("the allowed override was kept",
			_G.PallyPower_NormalAssignments.Openpally ~= nil)
	end)

	_G.PallyPower, _G.PallyPower_Assignments, _G.PallyPower_NormalAssignments = nil, nil, nil
end

T.report("control")
