-- PallyPower adapter.
--
-- We deliberately do not fork, patch, or wrap PallyPower. It owns the buttons,
-- the timers, the casting and the raid sync; we only decide what the
-- assignments should be and hand them over.
--
-- Reading capabilities
-- --------------------
-- PallyPower keeps its per-paladin spell data in a file-local `AllPallys`, so
-- it is not readable from outside. Rather than depend on internals we do not
-- own, we register the same "PLPWR" addon prefix and passively listen to the
-- SELF broadcasts PallyPower already sends. That tells us every paladin's
-- blessing ranks and relevant talent points, adds no traffic of our own, and
-- breaks only if their wire format changes -- which is a far more stable
-- contract than a private table.
--
-- Writing assignments
-- -------------------
-- Straight into PallyPower's SavedVariables, then broadcast over its protocol
-- so every paladin's client converges:
--   PallyPower_Assignments[pally][classID]                = greater blessing
--   PallyPower_NormalAssignments[pally][classID][target]  = per-player override
local ADDON, APP = ...

local B = APP.Blessings
local PP = APP.PP

PP.PREFIX = "PLPWR"

local function stripRealm(name)
	if not name then return nil end
	local short = name:match("^([^-]+)")
	return short or name
end

-- name -> { [blessingID] = { rank = n, talent = n } }
PP.observed = {}

--------------------------------------------------------------------------
-- Availability
--------------------------------------------------------------------------

function PP:IsAvailable()
	return _G.PallyPower ~= nil and _G.PallyPower_Assignments ~= nil
end

function PP:Assert()
	if not self:IsAvailable() then
		return false, "PallyPower is not loaded. AutoPallyPower is a companion to it, not a replacement."
	end
	return true
end

--------------------------------------------------------------------------
-- Listening to PallyPower's sync
--------------------------------------------------------------------------

--- Parse a PallyPower SELF payload into per-blessing rank/talent data.
-- Format: six hex pairs (rank, talent) or "nn" when the blessing is unknown,
-- then "@", then one digit of class assignment per class column.
function PP:ParseSelf(sender, msg)
	local numbers = msg:match("^SELF ([0-9a-fn]*)@")
	if not numbers then return nil end

	local info = {}
	for i = 1, 6 do
		local rank = numbers:sub((i - 1) * 2 + 1, (i - 1) * 2 + 1)
		local talent = numbers:sub((i - 1) * 2 + 2, (i - 1) * 2 + 2)
		if rank ~= "n" and rank ~= "" then
			info[i] = {
				rank = tonumber(rank, 16) or 0,
				talent = tonumber(talent) or 0,
			}
		end
	end
	self.observed[sender] = info
	return info
end

function PP:OnAddonMessage(prefix, message, _, sender)
	if prefix ~= self.PREFIX then return end
	sender = stripRealm(sender)
	if not sender then return end
	if message:sub(1, 4) == "SELF" then
		self:ParseSelf(sender, message)
	end
end

--------------------------------------------------------------------------
-- Scanning our own paladin
--------------------------------------------------------------------------

-- Rank-1 spell IDs, indexed to match our blessing IDs. Used only to resolve
-- the localised spell name and icon; whether the spell is actually known is
-- answered by looking that name up in the player's spellbook.
PP.SELF_SPELL_IDS = {
	[B.WISDOM] = 19742,
	[B.MIGHT] = 19740,
	[B.KINGS] = 20217,
	[B.SALVATION] = 1038,
	[B.LIGHT] = 19977,
	[B.SANCTUARY] = 20911,
}

-- Paladin talent tab order in TBC.
PP.TALENT_TABS = { [1] = "HOLY", [2] = "PROT", [3] = "RET" }

PP.selfName = nil
PP.selfSpec = nil

--- Read the player's own blessings and improved-blessing talents.
--
-- Waiting for a PallyPower broadcast to learn about ourselves is pointless and
-- actively unhelpful: PallyPower only broadcasts while in a group, so a paladin
-- sitting alone in a city has no idea what they can cast. The client knows
-- perfectly well, so we ask it directly.
--
-- Improved-blessing talents are matched by icon rather than by name, because
-- the talent shares its blessing's texture and a name match would break on any
-- non-English client.
function PP:ScanSelf()
	if not _G.UnitClass then return nil end
	local _, class = _G.UnitClass("player")
	if class ~= "PALADIN" then
		self.selfName, self.selfSpec = nil, nil
		return nil
	end

	local name = _G.UnitName and _G.UnitName("player")
	if not name then return nil end
	name = stripRealm(name)

	local info, textureOf = {}, {}
	for blessing, spellID in pairs(self.SELF_SPELL_IDS) do
		local spellName, _, texture = _G.GetSpellInfo(spellID)
		-- A name lookup only resolves for spells actually in the spellbook,
		-- which is what makes this a real check rather than a guess.
		if spellName and _G.GetSpellInfo(spellName) then
			info[blessing] = { rank = 1, talent = 0 }
			if texture then textureOf[texture] = blessing end
		end
	end

	if _G.GetNumTalentTabs and _G.GetTalentInfo then
		local best, bestPoints = nil, -1
		for tab = 1, (_G.GetNumTalentTabs() or 0) do
			if _G.GetTalentTabInfo then
				local points = select(3, _G.GetTalentTabInfo(tab))
				if type(points) == "number" and points > bestPoints then
					bestPoints, best = points, tab
				end
			end
			for index = 1, (_G.GetNumTalents(tab) or 0) do
				local talentName, texture, _, _, rank = _G.GetTalentInfo(tab, index)
				local blessing = texture and textureOf[texture]
				-- Only the three blessings that actually have an Improved talent.
				if blessing and B.IMPROVED_MAX_RANK[blessing] and type(rank) == "number" and rank > 0 then
					info[blessing].talent = rank
				end
			end
		end
		if best then self.selfSpec = self.TALENT_TABS[best] end
	end

	self.selfName = name
	self.observed[name] = info
	return info
end

--------------------------------------------------------------------------
-- Capability and spec inference
--------------------------------------------------------------------------

--- Which blessings a paladin can actually cast.
-- Presence in the spellbook is the ground truth: Kings and Sanctuary are
-- talent gated and simply absent for paladins who did not take them.
function PP:CapabilitiesFor(name)
	local info = self.observed[name]
	if not info then
		-- Unheard-from paladin: credit only what every paladin can train.
		--
		-- It is tempting to assume Kings, since almost every raiding paladin
		-- specs it. But "almost every" is the problem: assigning Kings to the
		-- one paladin who skipped it leaves a whole class column unbuffed and
		-- nothing says so. A plan that under-uses a paladin is recoverable in
		-- seconds; one that quietly drops a blessing is not.
		local caps = {}
		for blessing in pairs(B.ALWAYS_TRAINABLE) do caps[blessing] = true end
		return caps, {}, false
	end

	local caps, talents = {}, {}
	for i = 1, 6 do
		if info[i] then
			caps[i] = true
			-- PallyPower reports improved-talent ranks for Wisdom, Might and
			-- Sanctuary only; the rest come back as zero.
			talents[i] = info[i].talent or 0
		end
	end
	return caps, talents, true
end

--- Infer a paladin's spec from the talent points PallyPower reports.
--
-- PallyPower records talent ranks only for Wisdom, Might and Sanctuary (see
-- its ScanSpells), which happens to be one signal per tree:
--   Improved Blessing of Wisdom   -> Holy
--   Improved Blessing of Might    -> Retribution
--   Blessing of Sanctuary known   -> Protection
-- Not perfect, but it is free, it needs no inspection, and it is right far
-- more often than assuming.
function PP:InferSpec(name)
	-- For ourselves we counted talent points directly, which beats guessing
	-- from which improved blessings happen to be trained.
	if name and name == self.selfName and self.selfSpec then
		return self.selfSpec
	end

	local info = self.observed[name]
	if not info then return "UNKNOWN" end

	if info[B.SANCTUARY] then return "PROT" end
	local wis = info[B.WISDOM] and info[B.WISDOM].talent or 0
	local mgt = info[B.MIGHT] and info[B.MIGHT].talent or 0
	if wis > 0 and wis >= mgt then return "HOLY" end
	if mgt > 0 then return "RET" end
	return "UNKNOWN"
end

--------------------------------------------------------------------------
-- Reading the current state
--------------------------------------------------------------------------

--- Every paladin PallyPower currently knows about.
function PP:GetPaladins()
	local out = {}
	if not self:IsAvailable() then return out end

	local seen = {}
	for name in pairs(_G.PallyPower_Assignments) do
		if not seen[name] then
			seen[name] = true
			local caps, talents, known = self:CapabilitiesFor(name)
			out[#out + 1] = {
				name = name,
				spec = self:InferSpec(name),
				canCast = caps,
				talents = talents,
				capabilitiesKnown = known,
			}
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--- Snapshot of the assignments currently live, for diffing against a plan.
function PP:ReadCurrent()
	local grid, overrides = {}, {}
	if not self:IsAvailable() then return grid, overrides end

	for name, row in pairs(_G.PallyPower_Assignments) do
		grid[name] = {}
		for c = 1, B.MAX_CLASSES do
			grid[name][c] = row[c] or B.NONE
		end
	end

	local normals = _G.PallyPower_NormalAssignments or {}
	for pally, classes in pairs(normals) do
		for classID, targets in pairs(classes) do
			for target, blessing in pairs(targets) do
				if blessing and blessing ~= 0 then
					overrides[#overrides + 1] = {
						paladin = pally, classID = classID,
						target = target, blessing = blessing,
					}
				end
			end
		end
	end
	return grid, overrides
end

--------------------------------------------------------------------------
-- Writing assignments
--------------------------------------------------------------------------

--- Can we legitimately set assignments for paladins other than ourselves?
-- Mirrors PallyPower's own CanControl rule, so we refuse rather than emit
-- broadcasts every other client will silently discard.
function PP:CanControlOthers()
	if _G.UnitIsGroupLeader and _G.UnitIsGroupLeader("player") then return true end
	if _G.UnitIsGroupAssistant and _G.UnitIsGroupAssistant("player") then return true end
	return false
end

--- Compute the difference between a solved plan and what is live right now.
function PP:Diff(result)
	local currentGrid, currentOverrides = self:ReadCurrent()

	local changes = { grid = {}, addedOverrides = {}, removedOverrides = {} }

	for name, row in pairs(result.grid) do
		for c = 1, B.MAX_CLASSES do
			local want = row[c] or B.NONE
			local have = (currentGrid[name] and currentGrid[name][c]) or B.NONE
			if want ~= have then
				changes.grid[#changes.grid + 1] =
					{ paladin = name, classID = c, from = have, to = want }
			end
		end
	end

	local wanted = {}
	for _, o in ipairs(result.overrides) do
		wanted[o.paladin .. "/" .. o.classID .. "/" .. o.target] = o
	end
	local have = {}
	for _, o in ipairs(currentOverrides) do
		have[o.paladin .. "/" .. o.classID .. "/" .. o.target] = o
	end

	for key, o in pairs(wanted) do
		local existing = have[key]
		if not existing or existing.blessing ~= o.blessing then
			changes.addedOverrides[#changes.addedOverrides + 1] = o
		end
	end
	for key, o in pairs(have) do
		if not wanted[key] then
			changes.removedOverrides[#changes.removedOverrides + 1] = o
		end
	end

	return changes
end

--- Push a solved plan into PallyPower.
-- @param result solver output
-- @param opts { dryRun = bool, clearStaleOverrides = bool }
-- @return ok, message, stats
function PP:Apply(result, opts)
	opts = opts or {}
	local ok, err = self:Assert()
	if not ok then return false, err end

	local stats = { rows = 0, cells = 0, overrides = 0, cleared = 0 }
	local diff = self:Diff(result)

	if opts.dryRun then
		return true, "dry run", {
			rows = 0,
			cells = #diff.grid,
			overrides = #diff.addedOverrides,
			cleared = #diff.removedOverrides,
			diff = diff,
		}
	end

	local assignments = _G.PallyPower_Assignments
	local normals = _G.PallyPower_NormalAssignments
	if not normals then
		normals = {}
		_G.PallyPower_NormalAssignments = normals
	end

	-- Greater blessings: write the row, then broadcast it in one PASSIGN
	-- message rather than nine ASSIGNs.
	for name, row in pairs(result.grid) do
		assignments[name] = assignments[name] or {}
		local encoded = {}
		for c = 1, B.MAX_CLASSES do
			local blessing = row[c] or B.NONE
			if assignments[name][c] ~= blessing then
				stats.cells = stats.cells + 1
			end
			assignments[name][c] = blessing
			encoded[c] = (blessing == B.NONE) and "n" or tostring(blessing)
		end
		stats.rows = stats.rows + 1
		_G.PallyPower:SendMessage("PASSIGN " .. name .. "@" .. table.concat(encoded))
	end

	-- Clear overrides the new plan no longer wants, so a stale Blessing of
	-- Light does not survive a composition change.
	if opts.clearStaleOverrides ~= false then
		for _, o in ipairs(diff.removedOverrides) do
			if normals[o.paladin] and normals[o.paladin][o.classID] then
				normals[o.paladin][o.classID][o.target] = nil
				stats.cleared = stats.cleared + 1
				_G.PallyPower:SendMessage(
					("NASSIGN %s %d %s 0"):format(o.paladin, o.classID, o.target))
			end
		end
	end

	-- Per-player overrides, batched five per message the way PallyPower does.
	local batch = {}
	local function flush()
		if #batch == 0 then return end
		_G.PallyPower:SendMessage("NASSIGN " .. table.concat(batch, "@"))
		batch = {}
	end

	for _, o in ipairs(result.overrides) do
		normals[o.paladin] = normals[o.paladin] or {}
		normals[o.paladin][o.classID] = normals[o.paladin][o.classID] or {}
		normals[o.paladin][o.classID][o.target] = o.blessing
		stats.overrides = stats.overrides + 1
		batch[#batch + 1] = ("%s %d %s %d"):format(o.paladin, o.classID, o.target, o.blessing)
		if #batch >= 5 then flush() end
	end
	flush()

	if _G.PallyPower.UpdateLayout then
		_G.PallyPower:UpdateLayout()
	end

	return true, "applied", stats
end
