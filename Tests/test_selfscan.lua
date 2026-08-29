local h = dofile((os.getenv("APP_ROOT") or ".") .. "/Tests/harness.lua")
local APP, T = h.APP, h.T
local B, PP, Config = APP.Blessings, APP.PP, APP.Config

-- A stand-in for the parts of the WoW client ScanSelf actually asks about.
-- Textures are deliberately shared between a blessing and its Improved talent,
-- which is the real client's behaviour and the thing the icon match relies on.
local TEXTURE = {
	[B.WISDOM]    = "Interface\\Icons\\Spell_Holy_SealOfWisdom",
	[B.MIGHT]     = "Interface\\Icons\\Spell_Holy_FistOfJustice",
	[B.KINGS]     = "Interface\\Icons\\Spell_Magic_MageArmor",
	[B.SALVATION] = "Interface\\Icons\\Spell_Holy_SealOfSalvation",
	[B.LIGHT]     = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
	[B.SANCTUARY] = "Interface\\Icons\\Spell_Nature_LightningShield",
}
local SPELLNAME = {
	[B.WISDOM] = "Blessing of Wisdom", [B.MIGHT] = "Blessing of Might",
	[B.KINGS] = "Blessing of Kings",   [B.SALVATION] = "Blessing of Salvation",
	[B.LIGHT] = "Blessing of Light",   [B.SANCTUARY] = "Blessing of Sanctuary",
}
local BY_ID = {}
for blessing, id in pairs(PP.SELF_SPELL_IDS) do BY_ID[id] = blessing end

--- Install stubs, run fn, restore.
-- @param opts { class, name, known = {blessing...}, talents = {[tab]={{blessing,rank}}},
--               points = {tab -> pointsSpent} }
local function withClient(opts, fn)
	local saved = {}
	local names = { "UnitClass", "UnitName", "GetSpellInfo", "GetNumTalentTabs",
	                "GetNumTalents", "GetTalentInfo", "GetTalentTabInfo" }
	for _, n in ipairs(names) do saved[n] = _G[n] end

	local known = {}
	for _, b in ipairs(opts.known or {}) do known[SPELLNAME[b]] = b end

	_G.UnitClass = function() return "Paladin", opts.class or "PALADIN" end
	_G.UnitName = function() return opts.name or "Testpally" end
	_G.GetSpellInfo = function(arg)
		if type(arg) == "number" then
			local b = BY_ID[arg]
			if not b then return nil end
			-- The real API resolves an ID whether or not you know the spell.
			return SPELLNAME[b], nil, TEXTURE[b]
		end
		local b = known[arg]
		if not b then return nil end
		return SPELLNAME[b], nil, TEXTURE[b]
	end
	_G.GetNumTalentTabs = function() return 3 end
	_G.GetNumTalents = function(tab) return #((opts.talents or {})[tab] or {}) end
	_G.GetTalentInfo = function(tab, index)
		local entry = ((opts.talents or {})[tab] or {})[index]
		if not entry then return nil end
		local blessing, rank = entry[1], entry[2]
		return "Improved " .. SPELLNAME[blessing], TEXTURE[blessing], 1, 1, rank, 5
	end
	_G.GetTalentTabInfo = function(tab)
		return "Tab" .. tab, "icon", (opts.points or {})[tab] or 0
	end

	PP.observed, PP.selfName, PP.selfSpec = {}, nil, nil
	local ok, err = pcall(fn)

	for _, n in ipairs(names) do _G[n] = saved[n] end
	PP.observed, PP.selfName, PP.selfSpec = {}, nil, nil
	if not ok then error(err, 0) end
end

--------------------------------------------------------------------------
print("== our own spellbook is read directly, not waited for ==")
do
	withClient({
		name = "Rageblue",
		known = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT },
		talents = { [1] = { { B.WISDOM, 2 } } },
		points = { [1] = 41, [2] = 8, [3] = 12 },
	}, function()
		local info = PP:ScanSelf()
		T.check("scan returned info", info ~= nil)
		T.eq("self name recorded", PP.selfName, "Rageblue")

		local caps, talents, known = PP:CapabilitiesFor("Rageblue")
		T.check("no longer 'assumed' -- we looked", known == true)
		T.check("Kings credited because it is in the spellbook", caps[B.KINGS] == true)
		T.check("Sanctuary absent because it is not", caps[B.SANCTUARY] ~= true)
		T.eq("Improved Blessing of Wisdom read from talents", talents[B.WISDOM], 2)
		T.eq("spec from talent points, not guesswork", PP:InferSpec("Rageblue"), "HOLY")
	end)
end

--------------------------------------------------------------------------
print("== a paladin who skipped Kings is reported without it ==")
do
	withClient({
		name = "Nokings",
		known = { B.WISDOM, B.MIGHT, B.SALVATION, B.LIGHT },
		points = { [1] = 0, [2] = 0, [3] = 61 },
	}, function()
		PP:ScanSelf()
		local caps, _, known = PP:CapabilitiesFor("Nokings")
		T.check("scanned, so known", known == true)
		T.check("Kings correctly absent", caps[B.KINGS] ~= true)
		T.check("trainable blessings all present",
			caps[B.WISDOM] and caps[B.MIGHT] and caps[B.SALVATION] and caps[B.LIGHT])
		T.eq("retribution from talent points", PP:InferSpec("Nokings"), "RET")
	end)
end

--------------------------------------------------------------------------
print("== protection paladin picks up Sanctuary and its talent ==")
do
	withClient({
		name = "Protpally",
		known = { B.WISDOM, B.MIGHT, B.KINGS, B.SALVATION, B.LIGHT, B.SANCTUARY },
		talents = { [2] = { { B.SANCTUARY, 2 }, { B.MIGHT, 0 } } },
		points = { [1] = 5, [2] = 48, [3] = 8 },
	}, function()
		PP:ScanSelf()
		local caps, talents = PP:CapabilitiesFor("Protpally")
		T.check("Sanctuary castable", caps[B.SANCTUARY] == true)
		T.eq("Improved Sanctuary rank", talents[B.SANCTUARY], 2)
		T.eq("a zero-rank talent is not credited", talents[B.MIGHT], 0)
		T.eq("protection from talent points", PP:InferSpec("Protpally"), "PROT")
	end)
end

--------------------------------------------------------------------------
print("== a non-paladin scans to nothing rather than erroring ==")
do
	withClient({ class = "WARRIOR", name = "Notapally" }, function()
		T.eq("scan returns nil", PP:ScanSelf(), nil)
		T.eq("no self name claimed", PP.selfName, nil)
	end)
end

--------------------------------------------------------------------------
print("== talent APIs missing does not break the spellbook read ==")
do
	withClient({
		name = "Barepally",
		known = { B.WISDOM, B.MIGHT, B.KINGS },
		points = { [1] = 10 },
	}, function()
		local savedTabs = _G.GetNumTalentTabs
		_G.GetNumTalentTabs = nil
		local info = PP:ScanSelf()
		_G.GetNumTalentTabs = savedTabs

		T.check("still scanned the spellbook", info ~= nil)
		local caps, _, known = PP:CapabilitiesFor("Barepally")
		T.check("capabilities still known", known == true)
		T.check("Kings still credited", caps[B.KINGS] == true)
		T.eq("spec falls back to unknown", PP:InferSpec("Barepally"), "UNKNOWN")
	end)
end

--------------------------------------------------------------------------
print("== saved settings migrate to role grouping ==")
do
	_G.AutoPallyPowerDB = { version = 1, railGrouping = "class", tankPriority = "threat" }
	local db = Config:Load()
	T.eq("old saved copy moved to role", db.railGrouping, "role")
	T.eq("version bumped", db.version, 2)

	-- A deliberate later choice must survive.
	_G.AutoPallyPowerDB = { version = 2, railGrouping = "class" }
	local db2 = Config:Load()
	T.eq("an explicit choice at the new version is kept", db2.railGrouping, "class")

	_G.AutoPallyPowerDB = nil
	local fresh = Config:Load()
	T.eq("fresh install defaults to role", fresh.railGrouping, "role")
	_G.AutoPallyPowerDB = nil
end

T.report("selfscan")
