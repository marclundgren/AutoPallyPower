-- Reads the live raid, or serves a simulated one in test mode.
--
-- Spec detection is the weak point of any TBC addon: the client offers no API
-- for a raid member's talent build, and inspecting 24 people is slow, range
-- limited and throttled. So we resolve a member's profile from the cheapest
-- reliable signals first and only guess as a last resort:
--
--   1. a manual assignment the user made (remembered per character)
--   2. the raid's own MAINTANK / MAINASSIST slots, which are authoritative
--   3. the class fallback profile
--
-- Getting a tank wrong is the expensive error -- it is the difference between
-- a tank holding Salvation and not -- and step 2 covers exactly that case
-- without guessing, which is why it is worth leaning on.
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

	if inRaid then
		for i = 1, numMembers do
			local name, _, subgroup, _, _, class, _, _, _, role = _G.GetRaidRosterInfo(i)
			if name then
				name = name:match("^([^-]+)") or name
				local isTank = (role == "MAINTANK") or (role == "MAINASSIST")
				members[#members + 1] = {
					name = name,
					class = class,
					subgroup = subgroup,
					tank = isTank,
					profile = savedProfiles and savedProfiles[name] or nil,
					raidRole = role,
				}
			end
		end
	else
		local units = { "player" }
		for i = 1, 4 do units[#units + 1] = "party" .. i end
		for _, unit in ipairs(units) do
			if _G.UnitExists(unit) then
				local name = _G.GetUnitName(unit, false)
				local _, class = _G.UnitClass(unit)
				if name and class then
					members[#members + 1] = {
						name = name,
						class = class,
						tank = false,
						profile = savedProfiles and savedProfiles[name] or nil,
					}
				end
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
