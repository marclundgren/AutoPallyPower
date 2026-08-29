-- The assignment engine.
--
-- Model
-- -----
-- A greater blessing is cast on one member of a class and lands on every member
-- of that class in range, so the unit of decision is (class column) -> (set of
-- blessings delivered to it). Each paladin contributes at most one blessing per
-- class, and two paladins giving the same class the same blessing would just
-- overwrite each other, so the set is of distinct blessings and its size is
-- capped by the paladin count.
--
-- Crucially, class columns are independent: one paladin may give Kings to
-- warriors and Might to rogues at the same time. So we solve each column on its
-- own and the result is globally optimal, not a greedy approximation.
--
-- Per column we enumerate every subset of the six blessings (64 of them), keep
-- those small enough to staff and for which a paladin-to-blessing matching
-- exists, score each, and take the best. Ties break toward the lowest bitmask,
-- which makes the whole solve deterministic: the same raid always produces the
-- same assignment.
--
-- Overrides
-- ---------
-- The class-wide blessing is chosen by the majority of the column, which leaves
-- outliers -- most often a tank sitting in a column of DPS. A paladin can
-- replace their own greater blessing on one specific player by casting the
-- 10-minute normal version on them, which is what PallyPower's per-player row
-- does. So the second half of the solve is: for each member, is there a swap
-- worth the extra click? "Worth it" is a configurable threshold, which is what
-- keeps the override list short instead of technically-optimal-and-unusable.
--
-- Rule zero -- a tank must never keep Salvation -- is expressed as a large
-- negative value rather than a filter. That way the solver can still put
-- greater Salvation on a column of four DPS warriors and one prot warrior (the
-- right answer: one override beats three) while being unable to leave the tank
-- holding it, because the penalty only clears if an override actually removes
-- it. If no paladin can perform that override, the penalty stands and the
-- solver picks a different set on its own.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local S = APP.Solver

-- Value of a blessing sitting at rank N of a member's wishlist. Steeply
-- diminishing: the difference between a member's 1st and 2nd choice matters
-- far more than between their 4th and 5th.
S.DEFAULT_WEIGHTS = { 100, 60, 35, 18, 8, 3 }

-- A swap must beat this to be worth an extra global cooldown and a 10-minute
-- reapply timer. Roughly "worth more than a 4th-choice blessing".
S.DEFAULT_OVERRIDE_PENALTY = 12

-- Dominates every real score, so a tank holding Salvation is always corrected.
S.SALV_ON_TANK = -10000

local function defaultConfig()
	return {
		weights = S.DEFAULT_WEIGHTS,
		overridePenalty = S.DEFAULT_OVERRIDE_PENALTY,
		tankPriority = "threat",
		profiles = P.defaults,
		playerProfileOverrides = {},
	}
end

--------------------------------------------------------------------------
-- Raid context
--------------------------------------------------------------------------

-- What the raid can actually supply, which gates the conditional entries in
-- the wishlists.
function S:BuildContext(paladins, config)
	local holy, prot = false, false
	for i = 1, #paladins do
		local p = paladins[i]
		if p.spec == "HOLY" then holy = true end
		if p.canCast and p.canCast[B.SANCTUARY] then prot = true end
	end
	return {
		holyPaladin = holy,
		protPaladin = prot,
		tankPriority = config.tankPriority or "threat",
	}
end

--------------------------------------------------------------------------
-- Member wishlists
--------------------------------------------------------------------------

-- Attach a rank lookup (blessing id -> position in wishlist) to each member.
function S:PrepareMembers(members, ctx, config)
	local prepared = {}
	for i = 1, #members do
		local m = members[i]
		local key = P:ForMember(m, config.playerProfileOverrides)
		local profile = config.profiles[key] or P.defaults[key]
		local list = profile and P:Resolve(profile, ctx) or {}

		local rank = {}
		for pos = 1, #list do
			rank[list[pos]] = pos
		end

		prepared[#prepared + 1] = {
			name = m.name,
			class = m.class,
			classID = B.CLASS_IDS[m.class],
			tank = m.tank and true or false,
			profileKey = key,
			profileLabel = profile and profile.label or key,
			wishlist = list,
			rank = rank,
		}
	end

	-- Deterministic ordering so identical raids always solve identically.
	table.sort(prepared, function(a, b) return a.name < b.name end)
	return prepared
end

-- What one blessing is worth to one member.
function S:Value(member, blessing, config)
	if member.tank and blessing == B.SALVATION then
		return self.SALV_ON_TANK
	end
	local r = member.rank[blessing]
	if not r then return 0 end
	return config.weights[r] or 1
end

--------------------------------------------------------------------------
-- Bipartite matching: which paladin casts which blessing
--------------------------------------------------------------------------

-- Kuhn's algorithm. Tiny inputs (at most 6 blessings, a handful of paladins),
-- so clarity beats asymptotics here.
local function tryAssign(blessingIdx, blessings, paladins, matchOf, seen)
	local blessing = blessings[blessingIdx]
	for pi = 1, #paladins do
		local p = paladins[pi]
		if not seen[pi] and p.canCast and p.canCast[blessing] then
			seen[pi] = true
			if matchOf[pi] == nil or tryAssign(matchOf[pi], blessings, paladins, matchOf, seen) then
				matchOf[pi] = blessingIdx
				return true
			end
		end
	end
	return false
end

--- Find a paladin for every blessing in the set.
-- @return map of blessing id -> paladin index, or nil if the set cannot be staffed
function S:MatchBlessings(blessings, paladins)
	local matchOf = {}  -- paladin index -> blessing index
	for bi = 1, #blessings do
		local seen = {}
		if not tryAssign(bi, blessings, paladins, matchOf, seen) then
			return nil
		end
	end

	local holders = {}
	for pi, bi in pairs(matchOf) do
		holders[blessings[bi]] = pi
	end
	return holders
end

--------------------------------------------------------------------------
-- Overrides
--------------------------------------------------------------------------

--- Greedily find the per-player swaps worth making for one member.
-- Each paladin can only hold one blessing on a given target, so applying an
-- override consumes that paladin's slot for this member.
-- @return list of { paladin = idx, from = blessing, to = blessing, gain = n }, net gain
function S:ComputeOverrides(member, blessingSet, holders, paladins, config)
	-- What this member currently receives, keyed by the paladin delivering it.
	local delivered = {}
	local present = {}
	for i = 1, #blessingSet do
		local b = blessingSet[i]
		local pi = holders[b]
		if pi then
			delivered[pi] = b
			present[b] = true
		end
	end

	local overrides, netGain = {}, 0

	-- At most one swap per paladin, so this cannot loop more than #paladins times.
	for _ = 1, #paladins do
		local bestGain, bestPi, bestFrom, bestTo = nil, nil, nil, nil

		for pi, from in pairs(delivered) do
			local fromValue = self:Value(member, from, config)
			local pally = paladins[pi]
			for _, to in ipairs(B.ALL) do
				if not present[to] and pally.canCast and pally.canCast[to] then
					local gain = self:Value(member, to, config) - fromValue
					-- Strict > keeps ties deterministic: the first candidate in
					-- B.ALL order wins.
					if gain > 0 and (bestGain == nil or gain > bestGain) then
						bestGain, bestPi, bestFrom, bestTo = gain, pi, from, to
					end
				end
			end
		end

		-- Mandatory corrections (rule zero) carry a gain far above any
		-- threshold, so the same comparison handles both cases.
		if bestGain and bestGain > config.overridePenalty then
			overrides[#overrides + 1] = { paladin = bestPi, from = bestFrom, to = bestTo, gain = bestGain }
			netGain = netGain + bestGain - config.overridePenalty
			delivered[bestPi] = bestTo
			present[bestFrom] = nil
			present[bestTo] = true
		else
			break
		end
	end

	return overrides, netGain
end

--------------------------------------------------------------------------
-- Per-column solve
--------------------------------------------------------------------------

--- Score one candidate blessing set against one class column.
function S:ScoreSet(members, blessingSet, holders, paladins, config)
	local total = 0
	local memberOverrides = {}

	for i = 1, #members do
		local m = members[i]
		for j = 1, #blessingSet do
			total = total + self:Value(m, blessingSet[j], config)
		end
		local ovr, gain = self:ComputeOverrides(m, blessingSet, holders, paladins, config)
		total = total + gain
		if #ovr > 0 then
			memberOverrides[m.name] = { list = ovr, tank = m.tank }
		end
	end

	return total, memberOverrides
end

--- Solve a single class column.
function S:SolveClass(members, paladins, config)
	if #members == 0 or #paladins == 0 then
		return { blessings = {}, holders = {}, overrides = {}, score = 0 }
	end

	local maxSize = #paladins
	local best = nil

	-- Ascending mask order makes ties resolve to the smallest set, which also
	-- means fewer blessings cast for the same value.
	for mask = 0, (2 ^ B.MAX) - 1 do
		local set = {}
		for bit = 1, B.MAX do
			if math.floor(mask / (2 ^ (bit - 1))) % 2 == 1 then
				set[#set + 1] = B.ALL[bit]
			end
		end

		if #set <= maxSize then
			local holders = self:MatchBlessings(set, paladins)
			if holders then
				local score, overrides = self:ScoreSet(members, set, holders, paladins, config)
				if best == nil or score > best.score then
					best = { blessings = set, holders = holders, overrides = overrides, score = score }
				end
			end
		end
	end

	return best or { blessings = {}, holders = {}, overrides = {}, score = 0 }
end

--------------------------------------------------------------------------
-- Top level
--------------------------------------------------------------------------

--- Solve a whole raid.
-- @param raid { members = {...}, paladins = {...} }
-- @param config optional; see defaultConfig()
-- @return result table consumed by the PallyPower adapter and the UI
function S:Solve(raid, config)
	config = config or defaultConfig()
	config.weights = config.weights or S.DEFAULT_WEIGHTS
	config.overridePenalty = config.overridePenalty or S.DEFAULT_OVERRIDE_PENALTY
	config.profiles = config.profiles or P.defaults

	local paladins = {}
	for i = 1, #raid.paladins do paladins[i] = raid.paladins[i] end
	table.sort(paladins, function(a, b) return a.name < b.name end)

	local ctx = self:BuildContext(paladins, config)
	local members = self:PrepareMembers(raid.members, ctx, config)

	-- Bucket members into PallyPower's class columns.
	local byClass = {}
	for i = 1, B.MAX_CLASSES do byClass[i] = {} end
	for i = 1, #members do
		local cid = members[i].classID
		if cid then
			byClass[cid][#byClass[cid] + 1] = members[i]
		end
	end

	local result = {
		context = ctx,
		paladins = paladins,
		members = members,
		grid = {},        -- [paladinName][classID] = blessing
		overrides = {},   -- flat list for the adapter
		perClass = {},
		warnings = {},
	}

	for i = 1, #paladins do
		result.grid[paladins[i].name] = {}
		for c = 1, B.MAX_CLASSES do
			result.grid[paladins[i].name][c] = B.NONE
		end
	end

	for classID = 1, B.MAX_CLASSES do
		local columnMembers = byClass[classID]
		local solved = self:SolveClass(columnMembers, paladins, config)

		for blessing, pi in pairs(solved.holders) do
			result.grid[paladins[pi].name][classID] = blessing
		end

		for memberName, entry in pairs(solved.overrides) do
			for _, o in ipairs(entry.list) do
				result.overrides[#result.overrides + 1] = {
					paladin = paladins[o.paladin].name,
					classID = classID,
					target = memberName,
					blessing = o.to,
					replaces = o.from,
					-- Mandatory means rule zero: this override exists because a
					-- tank must not keep Salvation, not because it is an
					-- upgrade the user could reasonably skip.
					mandatory = (entry.tank and o.from == B.SALVATION) or false,
				}
			end
		end

		result.perClass[classID] = {
			classID = classID,
			class = B.CLASS_BY_ID[classID],
			memberCount = #columnMembers,
			members = columnMembers,
			blessings = solved.blessings,
			holders = solved.holders,
			score = solved.score,
		}
	end

	-- Deterministic override ordering for stable reports and diffs.
	table.sort(result.overrides, function(a, b)
		if a.classID ~= b.classID then return a.classID < b.classID end
		if a.target ~= b.target then return a.target < b.target end
		return a.blessing < b.blessing
	end)

	self:Validate(result)
	return result
end

--- Post-solve sanity checks. These are invariants, not preferences: if one of
--- these fires it is a bug in the engine, not a debatable assignment.
function S:Validate(result)
	local delivered = {}
	for i = 1, #result.members do
		delivered[result.members[i].name] = {}
	end

	for _, m in ipairs(result.members) do
		local col = result.perClass[m.classID]
		if col then
			for _, b in ipairs(col.blessings) do
				delivered[m.name][b] = true
			end
		end
	end
	for _, o in ipairs(result.overrides) do
		delivered[o.target][o.replaces] = nil
		delivered[o.target][o.blessing] = true
	end

	for _, m in ipairs(result.members) do
		if m.tank and delivered[m.name][B.SALVATION] then
			result.warnings[#result.warnings + 1] =
				("RULE ZERO VIOLATED: tank %s would keep Salvation"):format(m.name)
		end
	end

	result.delivered = delivered
	return result
end

S.defaultConfig = defaultConfig
