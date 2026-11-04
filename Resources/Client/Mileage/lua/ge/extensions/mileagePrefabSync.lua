--Mileage :: mission prefab sync (CLIENT)
--
-- Missions, challenges and scenarios spawn prefabs (track layouts, barriers, hay
-- bales, gates, arrow signs...). Those are local to whoever started the mission,
-- so without this everyone else drives through invisible geometry. Here the
-- starter broadcasts which prefab folder to load and the others spawn a copy.
--
-- Vehicles are stripped from the copy before spawning: BeamMP already syncs
-- vehicles, and spawning the prefab's own would duplicate them and desync
-- physics. That is what cleanPrefab/cleanPrefabOutdated do -- the first for
-- 0.32+ .prefab.json, the second for legacy .prefab (TorqueScript-ish, where
-- vehicles appear as `new BeamNGVehicle(...)` blocks).
--
-- Game APIs used: spawnPrefab, removePrefab, be:reloadCollision,
-- onMissionStartWithFade and mission.missionFolder.

local M = {}

local logTag = "mileage.prefab"

local prefabsTable = {}

-- Per-missionType counter so repeated runs of the same mission get distinct
-- prefab object names.
local iterT = {}
local iterC = 0

local prefabNames = {
	"arrive",
	"closedGates",
	"deco",
	"forwardPrefab",
	"logs",
	"loopPrefab",
	"mainPrefab",
	"obstacles",
	"obstacles2",
	"obstacles-fromFile",
	"openGates",
	"parkingLotClutter",
	"prefab",
	"ramp",
	"reversePrefab",
	"road",
	"rockslide",
	"targets",
	"vehicles"
}

local function addPrefabEntry(name, path, outdated)
	prefabsTable[name] = { path = path, outdated = outdated }
end

local function checkPrefab(prefabData, baseName, userSettings)
	local fullJson = string.format("%s/%s.prefab.json", prefabData.pPath, baseName)
	local fullLegacy = string.format("%s/%s.prefab", prefabData.pPath, baseName)
	local prefabKey = prefabData.pName .. baseName:gsub("Prefab", ""):gsub("%-", "")
	local outdated, exists = false, FS:fileExists(fullJson)
	if not exists then
		outdated = true
		exists = FS:fileExists(fullLegacy)
		if not exists then return end
	end
	-- Reversible missions ship both directions; only load the one in use.
	if baseName == "forwardPrefab" and userSettings and userSettings.reverse then return end
	if baseName == "reversePrefab" and not (userSettings and userSettings.reverse) then return end
	addPrefabEntry(prefabKey, exists and (outdated and fullLegacy or fullJson), outdated)
end

local function removeAllPrefabs(pName)
	for _, base in pairs(prefabNames) do
		local key = pName .. base:gsub("Prefab", ""):gsub("%-", "")
		if scenetree.findObject(key) then
			removePrefab(key)
		end
	end
	be:reloadCollision()
end

local function rxPrefabSync(data)
	if not data or data == "null" then return end
	local prefabData = jsonDecode(data)
	if not prefabData or not prefabData.pName then return end
	if prefabData.pLoad then
		if not prefabData.pPath then return end
		for _, base in ipairs(prefabNames) do
			checkPrefab(prefabData, base, prefabData.pSettings)
		end
	else
		removePrefab(prefabData.pName)
		removeAllPrefabs(prefabData.pName)
	end
end

local function readPrefab(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local content = f:read("*all")
	f:close()
	return content
end

local function writePrefab(path, content)
	local f = io.open(path, "w+")
	if not f then return end
	f:write(content)
	f:close()
end

-- .prefab.json: walk top-level object blocks, dropping any that declare a
-- BeamNGVehicle.
local function cleanPrefab(content)
	local result = ""
	local inSep = 1
	for _ = 1, #content do
		local outSep = content:find("}\n", inSep)
		if not outSep then break end
		local block = content:sub(inSep, outSep)
		inSep = content:find("{", outSep)
		if not block:find("BeamNGVehicle", 1) then
			result = result .. block .. "\n"
		end
		if not inSep then break end
	end
	return result
end

-- Legacy .prefab: excise each `new BeamNGVehicle(...) { ... };` block.
local function cleanPrefabOutdated(content)
	local result = ""
	local inSep = 1
	for _ = 1, #content do
		local start = content:find("   new BeamNGVehicle%(", inSep)
		if not start then
			result = result .. content:sub(inSep)
			break
		end
		result = result .. content:sub(inSep, start - 1)
		local outSep = content:find("};", start)
		if not outSep then break end
		inSep = outSep + 2
		if inSep > #content then break end
	end
	return result
end

local function processPrefab(path, name, outdated)
	local content = readPrefab(path)
	if not content then return end
	local cleanedPrefab = not outdated and cleanPrefab(content) or cleanPrefabOutdated(content)
	if cleanedPrefab then
		local ext = not outdated and ".prefab.json" or ".prefab"
		local tempPath = "settings/BeamMP/tempPrefab" .. name .. ext
		writePrefab(tempPath, cleanedPrefab)
		spawnPrefab(name, tempPath, "0 0 0", "0 0 1", "1 1 1")
	end
end

local function onAnyMissionChanged(state, mission)
	-- The stock hook fires with a nil mission in some transitions.
	if state ~= "stopped" or not mission or not mission.missionType then return end
	TriggerServerEvent("careerPrefabSync", jsonEncode({
		pName = mission.missionType .. "-" .. tostring(iterT[mission.missionType]),
		pLoad = false,
	}))
end

local function onMissionStartWithFade(mission, userSettings)
	if not mission or not mission.missionType then return end
	iterT[mission.missionType] = iterC
	TriggerServerEvent("careerPrefabSync", jsonEncode({
		pName = mission.missionType .. "-" .. tostring(iterT[mission.missionType]),
		pPath = mission.missionFolder,
		pSettings = userSettings,
		pLoad = true,
	}))
	iterC = iterC + 1
end

-- One prefab per frame: spawnPrefab is expensive, and a mission can carry a dozen of
-- them. The map's collision is rebuilt once, after the last queued prefab is placed,
-- instead of once per prefab: a joiner receives every other player's mission props at
-- once.
local placedSinceRebuild = false

local function onUpdate(dtReal, dtSim, dtRaw)
	if worldReadyState ~= 2 then return end
	for name, data in pairs(prefabsTable) do
		processPrefab(data.path, name, data.outdated)
		prefabsTable[name] = nil
		placedSinceRebuild = true
		break
	end
	if placedSinceRebuild and next(prefabsTable) == nil then
		placedSinceRebuild = false
		be:reloadCollision()
	end
end

local function onExtensionLoaded()
	AddEventHandler("rxPrefabSync", rxPrefabSync)
	log("I", logTag, "Mileage prefabSync LOADED")
end

local function onExtensionUnloaded()
	log("I", logTag, "Mileage prefabSync UNLOADED")
end

M.onAnyMissionChanged = onAnyMissionChanged
M.onMissionStartWithFade = onMissionStartWithFade

M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
