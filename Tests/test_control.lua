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
print("== in a party, only the party leader carries authority ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO", nil, "Closedpally")

	-- This is the case that prompted all of it: a party, free assignment off,
	-- and no way to set their row.
	withGroup({ raid = false, leader = false }, function()
		T.check("no authority as a party member", PP:HaveAuthority() == false)
		local ok, reason = PP:ControlStatus("Closedpally")
		T.check("cannot set them", ok == false)
		T.eq("and says exactly why", reason, "FREE_ASSIGN_OFF")
	end)

	withGroup({ raid = false, leader = true }, function()
		T.check("party leader has authority", PP:HaveAuthority())
		local ok, reason = PP:ControlStatus("Closedpally")
		T.check("can set them", ok)
		T.eq("by authority", reason, "AUTHORITY")
	end)

	-- PallyPower credits no assistant in a party, so neither do we.
	withGroup({ raid = false, leader = false, assistant = true }, function()
		T.check("assistant means nothing in a party", PP:HaveAuthority() == false)
	end)
end

--------------------------------------------------------------------------
print("== in a raid, assistant is enough ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO", nil, "Closedpally")

	withGroup({ raid = true, leader = false, assistant = true }, function()
		T.check("raid assistant has authority", PP:HaveAuthority())
		T.check("can set a closed paladin", PP:CanControl("Closedpally"))
	end)
	withGroup({ raid = true, leader = false, assistant = false }, function()
		T.check("plain raid member has none", PP:HaveAuthority() == false)
		T.check("cannot set a closed paladin", PP:CanControl("Closedpally") == false)
	end)
end

--------------------------------------------------------------------------
print("== inside an instance group nobody carries authority ==")
do
	fresh()
	PP:OnAddonMessage("PLPWR", "FREEASSIGN NO", nil, "Closedpally")
	PP:OnAddonMessage("PLPWR", "FREEASSIGN YES", nil, "Openpally")

	withGroup({ raid = true, leader = true, instanceGroup = true, inInstance = true }, function()
		T.check("leading an instance group is not enough", PP:HaveAuthority() == false)
		T.check("closed paladin still blocked", PP:CanControl("Closedpally") == false)
		T.check("free assignment still works", PP:CanControl("Openpally"))
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
