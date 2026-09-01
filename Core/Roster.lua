-- Reads the live raid, or serves a simulated one in test mode.
--
-- Spec detection is the weak point of any TBC addon: the client offers no API
-- for a raid member's talent build, and inspecting 24 people is slow, range
-- limited and throttled. So we resolve a member's profile from the cheapest
-- reliable signals first and only guess as a last resort:
--
--   1. a manual assignment the user made (remembered per character)
--   2. their assigned role, from the raid's MAINTANK / MAINASSIST slots or the
--      role they picked in the group finder
--   3. for paladins, their actual spec -- ours from our own talents, everyone
--      else's from PallyPower's sync
--   4. the class fallback profile
--
-- Getting a tank wrong is the expensive error: it is the difference between a
-- tank holding Salvation and not. Roles cover that without guessing, and
-- crucially they work in a party, where MAINTANK slots do not exist at all.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local R = {}
APP.Roster = R

R.simulated = nil   -- set by test mode

function R:IsSimulated()
	return self.simulated ~= nil
end

function R:SetSimulated(raid)
	self.simulated = raid
end

function R:ClearSimulated()
	self.simulated = nil
end

--- Scan the live group.
function R:ScanLive(savedProfiles)
	local members, paladins = {}, {}

	local numMembers = (_G.GetNumGroupMembers and _G.GetNumGroupMembers()) or 0
	if numMembers == 0 then
		return { members = members, paladins = paladins, live = true, empty = true }
	end

	local inRaid = _G.IsInRaid and _G.IsInRaid()

	--- The role a player picked in the group finder. Present in a party as well
	-- as a raid, which is the whole reason to consult it: MAINTANK slots are a
	-- raid-only concept, so without this a tank in a 5-man is invisible.
	local function assignedRole(unit)
		if not unit or not _G.UnitGroupRolesAssigned then return nil end
		local role = _G.UnitGroupRolesAssigned(unit)
		if role == "NONE" then return nil end
		return role
	end

	--- For a paladin we can know the spec exactly rather than guessing: our own
	-- from our talent points, everyone else's from PallyPower's broadcast.
	local PALADIN_SPEC_PROFILE = {
		HOLY = "PALADIN_HOLY", PROT = "PALADIN_TANK", RET = "PALADIN_RET",
	}
	local function paladinProfile(name, class)
		if class ~= "PALADIN" then return nil end
		local spec = APP.PP:InferSpec(name)
		return PALADIN_SPEC_PROFILE[spec]
	end

	local function addMember(name, class, unit, opts)
		if not name or not class then return end
		name = name:match("^([^-]+)") or name
		opts = opts or {}

		local role = assignedRole(unit)
		local profile = (savedProfiles and savedProfiles[name]) or paladinProfile(name, class)

		-- A protection paladin is tanking, whether or not they set a role.
		local specTank = (profile == "PALADIN_TANK")

		members[#members + 1] = {
			name = name,
			class = class,
			subgroup = opts.subgroup,
			tank = opts.raidTank or (role == "TANK") or specTank or false,
			assignedRole = role,
			profile = profile,
			raidRole = opts.raidRole,
			unit = unit,
		}
	end

	if inRaid then
		for i = 1, numMembers do
			local name, _, subgroup, _, _, class, _, _, _, role = _G.GetRaidRosterInfo(i)
			addMember(name, class, "raid" .. i, {
				subgroup = subgroup,
				raidRole = role,
				raidTank = (role == "MAINTANK") or (role == "MAINASSIST"),
			})
		end
	else
		local units = { "player" }
		for i = 1, 4 do units[#units + 1] = "party" .. i end
		for _, unit in ipairs(units) do
			if _G.UnitExists(unit) then
				local _, class = _G.UnitClass(unit)
				addMember(_G.GetUnitName(unit, false), class, unit)
			end
		end
	end

	-- Paladin capability data comes from the PallyPower adapter, which is the
	-- only place that knows who can cast what.
	local ppPaladins = APP.PP:GetPaladins()
	local inGroup = {}
	for _, m in ipairs(members) do
		if m.class == "PALADIN" then inGroup[m.name] = true end
	end
	for _, p in ipairs(ppPaladins) do
		if inGroup[p.name] then
			paladins[#paladins + 1] = p
		end
	end

	return { members = members, paladins = paladins, live = true }
end

--- The raid the solver should run against right now.
function R:Current(savedProfiles)
	if self:IsSimulated() then
		return self.simulated
	end
	return self:ScanLive(savedProfiles)
end

--- Summarise a raid for display.
function R:Summary(raid)
	local counts, tanks, healers = {}, 0, 0
	for i = 1, B.MAX_CLASSES do counts[i] = 0 end
	for _, m in ipairs(raid.members) do
		local cid = B.CLASS_IDS[m.class]
		if cid then counts[cid] = counts[cid] + 1 end
		if m.tank then tanks = tanks + 1 end
		local key = P:ForMember(m, nil)
		local profile = P.defaults[key]
		if profile and profile.role == "HEALER" then healers = healers + 1 end
	end
	return {
		size = #raid.members,
		paladins = #raid.paladins,
		tanks = tanks,
		healers = healers,
		classCounts = counts,
	}
end

--- Who is in the raid, grouped by role, with each player's class and spec.
--
-- Works for a live group and a generated one alike. For a live raid a spec we
-- had to guess at is flagged, because "why is that druid getting Might" is
-- almost always answered by "we guessed their spec wrong".
--
-- @param raid      { members = {...} }
-- @param overrides optional manual profile assignments
-- @return array of { key, label, rows = { {...} } } in tank, healer, melee, caster order
function R:Breakdown(raid, overrides)
	local buckets = {}
	for _, key in ipairs(P.ROLE_ORDER) do buckets[key] = {} end

	local classRank = {}
	for i, class in ipairs(P.CLASS_ORDER) do classRank[class] = i end

	for _, m in ipairs(raid.members or {}) do
		local key = P:ForMember(m, overrides)
		local profile = P.defaults[key]
		local roleKey = profile and profile.role or "MELEE"
		local bucket = buckets[roleKey] or buckets.MELEE

		bucket[#bucket + 1] = {
			name = m.name,
			class = m.class,
			classLabel = P.CLASS_LABELS[m.class] or m.class,
			classID = B.CLASS_IDS[m.class],
			spec = profile and P:SpecLabel(profile) or "Unknown",
			profileKey = key,
			roleKey = roleKey,
			tank = m.tank and true or false,
			-- Main tank and off-tank both count as tanks for blessings, but the
			-- distinction decides which paladin carries a pinned blessing, so it
			-- is worth seeing.
			raidRole = m.raidRole,
			mainTank = (m.raidRole == "MAINTANK"),
			guessed = P:IsGuess(m, overrides),
			isPaladin = (m.class == "PALADIN"),
		}
	end

	local out = {}
	for _, key in ipairs(P.ROLE_ORDER) do
		local rows = buckets[key]
		if #rows > 0 then
			table.sort(rows, function(a, b)
				-- Main tanks lead their group; otherwise class order, then name,
				-- so the same raid always reads the same way.
				if a.mainTank ~= b.mainTank then return a.mainTank end
				local ra = classRank[a.class] or 99
				local rb = classRank[b.class] or 99
				if ra ~= rb then return ra < rb end
				return a.name < b.name
			end)
			out[#out + 1] = { key = key, label = P.ROLE_LABELS[key], rows = rows }
		end
	end
	return out
end
