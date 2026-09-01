-- Automatic rules that constrain the solve before it runs.
--
-- A rule produces a "pin": one paladin is held to one blessing across every
-- class column, instead of being assigned per column like everyone else.
--
-- Pins are a real departure from how the rest of the engine works. Solving
-- each class column independently is what makes the solver exactly optimal, and
-- a pin deliberately breaks that: it is a convention imposed from outside, not
-- something the maths arrived at. So a pin has to earn its place by being
-- measurably free, and it is always a setting that can be turned off.
local ADDON, APP = ...

local B = APP.Blessings
local R = {}
APP.Rules = R

--- A prot paladin who is main tanking carries Salvation for the whole raid.
--
-- The reasoning: Salvation is the one blessing that paladin cannot use. They
-- are a tank, so rule zero forbids it, and their own greater blessing is spent
-- overriding themselves onto Sanctuary regardless, since nobody else can cast
-- it. Meanwhile Salvation is first choice for every physical and caster DPS,
-- which is most of a raid. Handing it to the paladin who cannot benefit from it
-- frees the others to sit on Wisdom and Might -- the two blessings that carry
-- Improved talents and therefore reward specialising.
--
-- Measured across 322 generated raids meeting these preconditions: never worse
-- for what players receive, better in 45, and roughly break-even on override
-- count.
function R:ProtPaladinSalvation(members, paladins, config)
	if not config.protPaladinSalvation then return nil end

	local byName = {}
	for _, p in ipairs(paladins) do byName[p.name] = p end

	local best, bestRank
	for _, m in ipairs(members) do
		if m.tank and m.class == "PALADIN" then
			local p = byName[m.name]
			-- Sanctuary in the spellbook is the dependable Protection signal.
			-- The spec guess can still be UNKNOWN before PallyPower has synced,
			-- and a rule this structural should not run on a guess.
			if p and p.canCast and p.canCast[B.SANCTUARY] and p.canCast[B.SALVATION] then
				-- Prefer the actual main tank over an off-tank when the raid
				-- fields more than one protection paladin.
				local rank = (m.raidRole == "MAINTANK") and 1 or 2
				if not best or rank < bestRank
					or (rank == bestRank and p.name < best.name) then
					best, bestRank = p, rank
				end
			end
		end
	end
	if not best then return nil end

	-- The rule only works if somebody else can actually hand them Kings. A
	-- second paladin is not enough: one who skipped the talent cannot fulfil
	-- it, and the tank would end up with Sanctuary and no Kings, which is
	-- worse than leaving the solver alone.
	local kingsElsewhere = false
	for _, p in ipairs(paladins) do
		if p.name ~= best.name and p.canCast and p.canCast[B.KINGS] then
			kingsElsewhere = true
		end
	end
	if not kingsElsewhere then return nil end

	return {
		rule = "PROT_TANK_SALVATION",
		paladin = best.name,
		blessing = B.SALVATION,
		because = (bestRank == 1)
			and "protection paladin main tanking"
			or "protection paladin tanking",
	}
end

--- Every pin in force for this raid.
-- @return pins (paladin name -> blessing), applied (list of rule records)
function R:Pins(members, paladins, config)
	local pins, applied = {}, {}

	-- Manual pins the user set take precedence over anything a rule computes.
	for name, blessing in pairs(config.pins or {}) do
		pins[name] = blessing
		applied[#applied + 1] = {
			rule = "MANUAL", paladin = name, blessing = blessing, because = "pinned by hand",
		}
	end

	local rules = { self.ProtPaladinSalvation }
	for _, rule in ipairs(rules) do
		local pin = rule(self, members, paladins, config)
		if pin and not pins[pin.paladin] then
			pins[pin.paladin] = pin.blessing
			applied[#applied + 1] = pin
		end
	end

	return pins, applied
end
