-- Saved settings, defaults, and addon lifecycle.
local ADDON, APP = ...

local B = APP.Blessings
local P = APP.Profiles
local S = APP.Solver

local Config = {}
APP.Config = Config

--- Deep copy, used to seed the editable profile set from the shipped defaults.
local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, val in pairs(v) do out[k] = copy(val) end
	return out
end
Config.copy = copy

function Config:Defaults()
	return {
		version = 1,
		-- The user's editable copy of the priority lists. Shipped defaults stay in
		-- APP.Profiles.defaults so "reset" always has something to reset to.
		profiles = copy(P.defaults),
		-- name -> profile key, for players whose spec we cannot detect.
		playerProfileOverrides = {},
		tankPriority = "threat",
		-- How the priority list groups its profiles: "class" or "role".
		railGrouping = "class",
		overridePenalty = S.DEFAULT_OVERRIDE_PENALTY,
		weights = copy(S.DEFAULT_WEIGHTS),
		minimap = { angle = 210, hide = false },
		testMode = {
			enabled = false,
			raidSize = 25,
			paladins = 2,
			tanks = 2,
			healers = 5,
			seed = nil,
		},
		-- Named mutations layered on top of the defaults, for the night that
		-- wants something different. Names are free-form and selection is
		-- always manual -- deliberately not auto-attached to a zone or boss,
		-- since a one-off is not always named after an encounter.
		presets = {},
		activePreset = nil,
	}
end

function Config:Load()
	local db = _G.AutoPallyPowerDB
	local defaults = self:Defaults()

	if type(db) ~= "table" then
		db = defaults
	else
		-- Fill in anything added by a newer version without clobbering edits.
		for k, v in pairs(defaults) do
			if db[k] == nil then db[k] = v end
		end
		if type(db.profiles) ~= "table" then db.profiles = copy(P.defaults) end
		-- Any profile we ship that the saved copy has never seen.
		for key, profile in pairs(P.defaults) do
			if db.profiles[key] == nil then db.profiles[key] = copy(profile) end
		end
	end

	_G.AutoPallyPowerDB = db
	APP.db = db
	return db
end

--- Build the solver config from saved settings plus the active preset.
function Config:SolverConfig()
	local db = APP.db or self:Load()

	local profiles = db.profiles
	local tankPriority = db.tankPriority

	local preset = db.activePreset and db.presets[db.activePreset]
	if preset then
		-- A preset is a sparse mutation: only the profiles it names are
		-- replaced, everything else falls through to the base set.
		profiles = setmetatable({}, { __index = db.profiles })
		for key, profile in pairs(preset.profiles or {}) do
			profiles[key] = profile
		end
		if preset.tankPriority then tankPriority = preset.tankPriority end
	end

	return {
		weights = db.weights,
		overridePenalty = db.overridePenalty,
		tankPriority = tankPriority,
		profiles = profiles,
		playerProfileOverrides = db.playerProfileOverrides,
	}
end

--- Save the current raid's assignments as a named preset mutation.
function Config:SavePreset(name, profiles, tankPriority)
	local db = APP.db or self:Load()
	db.presets[name] = {
		profiles = profiles and copy(profiles) or {},
		tankPriority = tankPriority,
		created = time and time() or 0,
	}
end

function Config:DeletePreset(name)
	local db = APP.db or self:Load()
	db.presets[name] = nil
	if db.activePreset == name then db.activePreset = nil end
end

function Config:ResetProfiles()
	local db = APP.db or self:Load()
	db.profiles = copy(P.defaults)
end
