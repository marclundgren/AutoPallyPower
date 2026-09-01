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

-- Value of a blessing sitting at rank N of a member's priority list. Steeply
-- diminishing: the difference between a member's 1st and 2nd choice matters
-- far more than between their 4th and 5th.
S.DEFAULT_WEIGHTS = { 100, 60, 35, 18, 8, 3 }

-- A swap must beat this to be worth an extra global cooldown and a 10-minute
-- reapply timer. Roughly "worth more than a 4th-choice blessing".
S.DEFAULT_OVERRIDE_PENALTY = 12

-- Dominates every real score, so a tank holding Salvation is always corrected.
S.SALV_ON_TANK = -10000

-- Talent fit never outweighs what the raid actually wants: it only separates
-- sets the members value identically. All member-facing values are integers, and
-- talent weight is capped at 100 per blessing over at most six blessings, so
-- this can never overturn a real difference of even one point.
S.TALENT_TIEBREAK = 0.0001

-- How hard a pin pulls, per member in the column. A pin is a convention
-- imposed from outside the maths, so by default it is a preference the solver
-- can overrule when the alternative is clearly better for the people in that
-- column, not a constraint. Scaled per member so it does not become
-- vanishingly weak in a column of eight and overwhelming in a column of one.
--
-- Deliberately below DEFAULT_OVERRIDE_PENALTY, which gives it a rule you can
-- state plainly: a pin never justifies an extra override on its own. Set it
-- above the penalty and the pin wins every time the only thing standing
-- against it is one more click, which is a hard pin wearing a disguise.
S.DEFAULT_PIN_STRENGTH = 8

local function defaultConfig()
	return {
		weights = S.DEFAULT_WEIGHTS,
		overridePenalty = S.DEFAULT_OVERRIDE_PENALTY,
		profiles = P.defaults,
		playerProfileOverrides = {},
		pins = {},
		pinMode = "preference",
		pinStrength = S.DEFAULT_PIN_STRENGTH,
		protPaladinSalvation = true,
	}
end

--------------------------------------------------------------------------
-- Raid context
--------------------------------------------------------------------------

-- What the raid can actually supply, which gates the conditional entries in
-- the priority lists.
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
	}
end

--------------------------------------------------------------------------
-- Member priorities
--------------------------------------------------------------------------

-- Attach a rank lookup (blessing id -> position in the priority list) to each member.
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
			assignedRole = m.assignedRole,
			guessed = P:IsGuess(m, config.playerProfileOverrides),
			classID = B.CLASS_IDS[m.class],
			tank = m.tank and true or false,
			raidRole = m.raidRole,
			role = profile and profile.role or nil,
			profileKey = key,
			profileLabel = profile and profile.label or key,
			-- The profile's priority list resolved against tonight's raid:
			-- conditional entries either kept or dropped, flattened to ids.
			priority = list,
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
-- Assignment: which paladin casts which blessing
--------------------------------------------------------------------------

-- How much better this paladin casts this blessing than a paladin without the
-- talent, as a 0-100 fraction of the full talent. Normalised by each talent's
-- own max rank so that Improved Might (5 points) does not outrank Improved
-- Wisdom (2 points) purely by having more points to spend.
function S:TalentWeight(paladin, blessing)
	local max = B.IMPROVED_MAX_RANK[blessing]
	if not max then return 0 end
	local points = paladin.talents and paladin.talents[blessing] or 0
	if points <= 0 then return 0 end
	if points > max then points = max end
	return (points * 100) / max
end

--- Assign every blessing in the set to a distinct paladin who can cast it,
--- choosing the assignment that puts the most improved blessings in the hands
--- of the paladins actually specced for them.
--
-- This is a maximum-weight bipartite matching, and it is solved exactly rather
-- than greedily on purpose. Greedily handing each blessing to the best-specced
-- paladin fails the case the whole feature exists for: a paladin specced into
-- two or three improved blessings can only cast one of them here, and taking
-- their strongest in isolation can strand another paladin's talent entirely.
-- The optimum has to be found across all paladins at once.
--
-- Done as a DP over paladins with a bitmask of covered blessings. At most six
-- blessings means 64 masks, so this is exact and still trivially cheap.
-- Pins are folded into the same optimisation rather than applied afterwards.
-- In "preference" mode a pinned paladin simply scores a bonus for taking their
-- pinned blessing, so the solver keeps the freedom to overrule it. In "hard"
-- mode they may only take that blessing, or sit the column out -- never a
-- different one, since a uniform row is the whole point.
--
-- @param pins  { [paladin name] = blessing }
-- @param opts  { mode = "preference"|"hard", strength = number }
-- @return holders (blessing id -> paladin index), talent weight, pin bonus; or nil
function S:MatchBlessings(blessings, paladins, pins, opts)
	local k = #blessings
	if k == 0 then return {}, 0, 0 end

	pins = pins or {}
	opts = opts or {}
	local hard = (opts.mode == "hard")
	local strength = opts.strength or 0

	local full = 2 ^ k - 1
	local NEG = -math.huge

	local dp = {}
	for mask = 0, full do dp[mask] = NEG end
	dp[0] = 0

	-- choice[i][mask] = blessing index paladin i took to arrive at mask (0 = none)
	local choice = {}

	for i = 1, #paladins do
		local pally = paladins[i]
		local ndp, nchoice = {}, {}
		for mask = 0, full do ndp[mask] = NEG end

		for mask = 0, full do
			local base = dp[mask]
			if base > NEG then
				-- This paladin sits this column out.
				if base > ndp[mask] then
					ndp[mask] = base
					nchoice[mask] = 0
				end
				-- Or takes one blessing not yet covered.
				local pinned = pins[pally.name]
				for bi = 1, k do
					local bit = 2 ^ (bi - 1)
					if math.floor(mask / bit) % 2 == 0 then
						local blessing = blessings[bi]
						local allowed = pally.canCast and pally.canCast[blessing]
						if hard and pinned and blessing ~= pinned then
							allowed = false
						end
						if allowed then
							local w = base + self:TalentWeight(pally, blessing) * self.TALENT_TIEBREAK
							if pinned and blessing == pinned then
								w = w + strength
							end
							local nm = mask + bit
							if w > ndp[nm] then
								ndp[nm] = w
								nchoice[nm] = bi
							end
						end
					end
				end
			end
		end

		dp = ndp
		choice[i] = nchoice
	end

	if dp[full] == NEG then
		return nil
	end

	-- The DP optimises talent and pin together; report them apart so callers
	-- (and tests) can reason about each on its own terms.
	local holders, mask = {}, full
	local talentWeight, pinBonus = 0, 0
	for i = #paladins, 1, -1 do
		local bi = choice[i][mask]
		if bi and bi > 0 then
			local blessing = blessings[bi]
			holders[blessing] = i
			talentWeight = talentWeight + self:TalentWeight(paladins[i], blessing)
			if pins[paladins[i].name] == blessing then
				pinBonus = pinBonus + strength
			end
			mask = mask - 2 ^ (bi - 1)
		end
	end

	return holders, talentWeight, pinBonus
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
			memberOverrides[m.name] = { list = ovr, tank = m.tank, role = m.role }
		end
	end

	return total, memberOverrides
end

--- Solve a single class column.
function S:SolveClass(members, paladins, config, pins)
	if #members == 0 or #paladins == 0 then
		return { blessings = {}, holders = {}, overrides = {}, score = 0, ranked = 0, talentWeight = 0 }
	end

	local maxSize = #paladins
	local best = nil

	local pinOpts = {
		mode = config.pinMode or "preference",
		-- Scaled by column size so the pull is comparable to the member values
		-- it is competing against.
		strength = (config.pinStrength or self.DEFAULT_PIN_STRENGTH) * #members,
	}

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
			local holders, talentWeight, pinBonus = self:MatchBlessings(set, paladins, pins, pinOpts)
			if holders then
				local score, overrides = self:ScoreSet(members, set, holders, paladins, config)
				local ranked = score + (talentWeight or 0) * self.TALENT_TIEBREAK + (pinBonus or 0)
				if best == nil or ranked > best.ranked then
					best = {
						blessings = set, holders = holders, overrides = overrides,
						score = score, ranked = ranked,
						talentWeight = talentWeight or 0, pinBonus = pinBonus or 0,
					}
				end
			end
		end
	end

	return best or { blessings = {}, holders = {}, overrides = {}, score = 0, ranked = 0, talentWeight = 0 }
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

	-- Rules run before the solve: they decide the conventions the solve then
	-- works within, rather than adjusting its output afterwards.
	local pins, appliedRules = APP.Rules:Pins(members, paladins, config)

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
		pins = pins,
		appliedRules = appliedRules,
		pinMode = config.pinMode or "preference",
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
		local solved = self:SolveClass(columnMembers, paladins, config, pins)

		for blessing, pi in pairs(solved.holders) do
			result.grid[paladins[pi].name][classID] = blessing
		end

		for memberName, entry in pairs(solved.overrides) do
			for _, o in ipairs(entry.list) do
				local mandatory = (entry.tank and o.from == B.SALVATION) or false
				result.overrides[#result.overrides + 1] = {
					paladin = paladins[o.paladin].name,
					classID = classID,
					target = memberName,
					blessing = o.to,
					replaces = o.from,
					-- Mandatory means a tank must not keep Salvation, as opposed
					-- to an upgrade the user could reasonably skip.
					mandatory = mandatory,
					reason = self:OverrideReason(entry, mandatory),
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

--- Why this player is being singled out, phrased as the thing a raid leader
--- would say out loud rather than as an internal category.
function S:OverrideReason(entry, mandatory)
	if mandatory or entry.role == "TANK" then return "TANK" end
	if entry.role == "HEALER" then return "HEALER" end
	if entry.role == "CASTER" then return "CASTER" end
	if entry.role == "MELEE" then return "PHYSICAL" end
	return "UPGRADE"
end

--- Post-solve sanity checks. These are invariants, not preferences: if one of
--- these fires it is a bug in the engine, not a debatable assignment.
function S:Validate(result)
	-- A paladin we have not yet heard from is credited only with the blessings
	-- every paladin can train. Kings in particular is withheld until seen, so
	-- say so rather than quietly producing a Kings-less plan.
	local assumed = {}
	for _, p in ipairs(result.paladins) do
		if p.capabilitiesKnown == false then
			assumed[#assumed + 1] = p.name
		end
	end
	if #assumed > 0 then
		result.warnings[#result.warnings + 1] =
			("Talents unknown for %s -- assuming no Kings or Sanctuary until PallyPower syncs them.")
				:format(table.concat(assumed, ", "))
	end

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
