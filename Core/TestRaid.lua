-- Synthetic raid generator for testing without a group.
--
-- Lets you exercise the solver against arbitrary compositions from a standing
-- start: pick how many paladins, tanks and healers, and the rest fills in with
-- random DPS. Seeded, so a composition you found interesting can be reproduced.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local T = APP.TestRaid

T.defaults = {
	raidSize = 25,
	paladins = 2,
	tanks = 2,
	healers = 5,
	seed = nil,
}

-- Profiles the generator draws from, by role.
T.tankPool   = { "WARRIOR_TANK", "DRUID_TANK", "PALADIN_TANK" }
T.healerPool = { "PRIEST_HEALER", "DRUID_RESTO", "SHAMAN_RESTO", "PALADIN_HOLY" }
-- Paladins are placed by the dedicated paladin phase so that the requested
-- count is exact; they are deliberately absent from the filler pools.
T.dpsPool    = {
	"WARRIOR_DPS", "ROGUE", "HUNTER", "DRUID_FERAL_DPS", "SHAMAN_ENHANCE",
	"PRIEST_SHADOW", "MAGE", "WARLOCK", "DRUID_BALANCE", "SHAMAN_ELEMENTAL",
}

local NAME_PARTS_A = {
	"Bel", "Thar", "Gor", "Mal", "Zen", "Kel", "Dro", "Fen", "Vor", "Syl",
	"Nym", "Ard", "Bran", "Cor", "Dun", "Eld", "Fal", "Grim", "Hal", "Irn",
}
local NAME_PARTS_B = {
	"dor", "ric", "gash", "wyn", "ath", "mir", "gar", "iel", "ok", "wen",
	"dan", "us", "ax", "eth", "ion", "ulf", "ara", "im", "oth", "en",
}

--- Deterministic name generator: index -> stable fake character name.
local function makeName(rng, used)
	for _ = 1, 200 do
		local a = NAME_PARTS_A[rng(#NAME_PARTS_A)]
		local b = NAME_PARTS_B[rng(#NAME_PARTS_B)]
		local name = a .. b
		if not used[name] then
			used[name] = true
			return name
		end
	end
	-- Pool exhausted; fall back to numbering.
	local n = 1
	while used["Filler" .. n] do n = n + 1 end
	used["Filler" .. n] = true
	return "Filler" .. n
end

-- Roughly how often a real paladin of each spec has each talent, so generated
-- raids exercise the awkward cases instead of only the tidy ones. The Kings
-- rate in particular is deliberately not 100: the paladin who skipped Kings is
-- exactly the case the solver has to survive.
T.talentRates = {
	kings = 95,
	impWisdom   = { HOLY = 95, PROT = 10, RET = 10 },
	impMight    = { HOLY = 15, PROT = 20, RET = 80 },
	impSanctuary = { PROT = 90 },
}

--- Build a paladin's capabilities and improved-blessing talents from a spec.
-- Mirrors the shape PallyPower reports: which blessings are in the spellbook,
-- plus talent points for the three improved blessings it broadcasts.
function T:PaladinCapabilities(spec, rng)
	rng = rng or function(n) return math.random(n) end
	local function chance(pct) return pct and rng(100) <= pct end

	local caps = {
		[B.WISDOM] = true,
		[B.MIGHT] = true,
		[B.SALVATION] = true,
		[B.LIGHT] = true,
	}
	if chance(self.talentRates.kings) then
		caps[B.KINGS] = true
	end
	if spec == "PROT" then
		caps[B.SANCTUARY] = true
	end

	local talents = {}
	if chance(self.talentRates.impWisdom[spec]) then
		talents[B.WISDOM] = B.IMPROVED_MAX_RANK[B.WISDOM]
	end
	if chance(self.talentRates.impMight[spec]) then
		talents[B.MIGHT] = B.IMPROVED_MAX_RANK[B.MIGHT]
	end
	if caps[B.SANCTUARY] and chance(self.talentRates.impSanctuary[spec]) then
		talents[B.SANCTUARY] = B.IMPROVED_MAX_RANK[B.SANCTUARY]
	end

	return caps, talents
end

--- Generate a raid.
-- @param opts { raidSize, paladins, tanks, healers, seed }
-- @return { members = {...}, paladins = {...} }
function T:Generate(opts)
	opts = opts or {}
	local cfg = {}
	for k, v in pairs(self.defaults) do cfg[k] = v end
	for k, v in pairs(opts) do cfg[k] = v end

	local seed = cfg.seed or os.time()
	math.randomseed(seed)
	-- Lua 5.1's first few draws after a seed are poorly distributed on some
	-- platforms; burn a handful.
	for _ = 1, 5 do math.random() end
	local rng = function(n) return math.random(n) end

	local used = {}
	local members, paladins = {}, {}
	local tanksAdded = 0

	local function add(profileKey, isTank, forcedSpec)
		local profile = P.defaults[profileKey]
		local name = makeName(rng, used)
		local m = {
			name = name,
			class = profile.class,
			profile = profileKey,
			tank = isTank and true or false,
		}
		if isTank then
			-- Exactly one main tank; any further tanks are off-tanks, which is
			-- what the raid's MAINTANK/MAINASSIST slots look like in practice.
			tanksAdded = tanksAdded + 1
			m.raidRole = (tanksAdded == 1) and "MAINTANK" or "MAINASSIST"
		end
		members[#members + 1] = m

		if profile.class == "PALADIN" then
			local spec = forcedSpec
			if not spec then
				if profileKey == "PALADIN_HOLY" then spec = "HOLY"
				elseif profileKey == "PALADIN_TANK" then spec = "PROT"
				else spec = "RET" end
			end
			local caps, talents = self:PaladinCapabilities(spec, rng)
			paladins[#paladins + 1] = {
				name = name,
				spec = spec,
				canCast = caps,
				talents = talents,
				-- A simulated raid stands in for one PallyPower has already
				-- synced, so capabilities count as known.
				capabilitiesKnown = true,
			}
		end
		return m
	end

	-- Paladins first, so the requested count is always met.
	local pallySpecs = {}
	for i = 1, cfg.paladins do
		-- Bias toward at least one holy paladin when there is more than one,
		-- which is what real raids look like.
		if i == 1 and cfg.paladins > 1 then
			pallySpecs[i] = "HOLY"
		else
			local roll = rng(3)
			pallySpecs[i] = (roll == 1 and "HOLY") or (roll == 2 and "PROT") or "RET"
		end
	end

	local tanksLeft, healersLeft = cfg.tanks, cfg.healers

	for i = 1, cfg.paladins do
		local spec = pallySpecs[i]
		if spec == "PROT" and tanksLeft > 0 then
			add("PALADIN_TANK", true, "PROT")
			tanksLeft = tanksLeft - 1
		elseif spec == "HOLY" and healersLeft > 0 then
			add("PALADIN_HOLY", false, "HOLY")
			healersLeft = healersLeft - 1
		else
			add("PALADIN_RET", false, spec)
		end
	end

	-- Remaining tanks, then healers, then DPS to fill.
	while tanksLeft > 0 and #members < cfg.raidSize do
		local pool = {}
		for _, k in ipairs(self.tankPool) do
			if k ~= "PALADIN_TANK" then pool[#pool + 1] = k end
		end
		add(pool[rng(#pool)], true)
		tanksLeft = tanksLeft - 1
	end

	while healersLeft > 0 and #members < cfg.raidSize do
		local pool = {}
		for _, k in ipairs(self.healerPool) do
			if k ~= "PALADIN_HOLY" then pool[#pool + 1] = k end
		end
		add(pool[rng(#pool)], false)
		healersLeft = healersLeft - 1
	end

	while #members < cfg.raidSize do
		add(self.dpsPool[rng(#self.dpsPool)], false)
	end

	return { members = members, paladins = paladins, seed = seed, config = cfg }
end

--- Count members per class column, for display.
function T:ClassCounts(raid)
	local counts = {}
	for i = 1, B.MAX_CLASSES do counts[i] = 0 end
	for _, m in ipairs(raid.members) do
		local cid = B.CLASS_IDS[m.class]
		if cid then counts[cid] = counts[cid] + 1 end
	end
	return counts
end
