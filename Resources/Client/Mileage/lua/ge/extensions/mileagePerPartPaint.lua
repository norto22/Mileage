--Mileage :: per-part paint sync (CLIENT)
--
-- BeamMP syncs a vehicle's overall paint but not per-part paint, which career
-- tracks in partConditions[*].visualState.paint.originalPaints. Replacement
-- parts therefore show up unpainted (or wrongly painted) on everyone else's
-- screen. This sends each part's paint over the wire and applies it vehicle-side
-- via partCondition.setPartPaints.
--
-- Game APIs used: validateVehiclePaint, partCondition.ensureConditionsInit/
-- setPartPaints, getInventoryIdFromVehicleId and originalPaints.

local M = {}

local logTag = "mileage.paint"

-- inventoryIds whose vehicle had no serverVehicleID yet; retried in onUpdate.
local pendingPaints = {}
local ensuredPartConditionsByVeh = {}

-- Paints received for another player's car before it is ready on this game: not in
-- BeamMP's list yet, or listed but not built. Keyed by the car's server id, the id both
-- games know; applied in onVehicleReady and dropped after HOLD_SECONDS, so a car that
-- never appears does not keep them. A car sends one paint per part, so they are held
-- per part, and a later paint of the same part replaces the earlier one.
--   heldPaints[serverVehicleID] = {at = <first held>, parts = {[partPath] = paintData}}
local heldPaints = {}
local heldCars = 0
local HOLD_SECONDS = 60
local HOLD_MAX_CARS = 64
local HOLD_MAX_PARTS = 512

-- Paint requests for another player's car that became ready before the server's state of
-- it arrived (#87). Their traffic and parked cars have no paints, and the server's state
-- is what says which cars those are, so the request waits for it: sent once the state
-- shows the car is not traffic, dropped if it is, and sent anyway after
-- STATE_WAIT_SECONDS, as a server that sends no states needs.
--   waitingRequests[serverVehicleID] = {gid = <game vehicle id>, at = <first ready>}
local waitingRequests = {}
local STATE_WAIT_SECONDS = 5

local function clampHelper(value)
	return clamp(tonumber(value) or 0, 0, 1)
end

local function copyPaint(paint)
	local base = paint.baseColor or {}
	return {
		baseColor = { base[1] or 1, base[2] or 1, base[3] or 1, base[4] or 1 },
		metallic = paint.metallic or 0,
		roughness = paint.roughness or 0.5,
		clearcoat = paint.clearcoat or 0,
		clearcoatRoughness = paint.clearcoatRoughness or 0
	}
end

local function sanitizePaint(paint)
	local sanitized = copyPaint(paint) or {}
	validateVehiclePaint(sanitized)
	local base = sanitized.baseColor or {}
	sanitized.baseColor = {
		clampHelper(base[1]),
		clampHelper(base[2]),
		clampHelper(base[3]),
		clampHelper(base[4] or 1)
	}
	sanitized.metallic = clampHelper(sanitized.metallic)
	sanitized.roughness = clampHelper(sanitized.roughness)
	sanitized.clearcoat = clampHelper(sanitized.clearcoat)
	sanitized.clearcoatRoughness = clampHelper(sanitized.clearcoatRoughness)
	return sanitized
end

-- A vehicle always carries three paint layers; fill missing ones by repeating
-- the last provided layer.
local function sanitizePaints(paints)
	local sanitized = {}
	local lastPaint = nil
	for i = 1, 3 do
		local paint = paints[i] or lastPaint or paints[1]
		if not paint then break end
		local sanitizedPaint = sanitizePaint(paint)
		if not sanitizedPaint then break end
		sanitized[i] = sanitizedPaint
		lastPaint = paint
	end
	if tableIsEmpty(sanitized) then return nil end
	if not sanitized[2] then sanitized[2] = copyPaint(sanitized[1]) end
	if not sanitized[3] then sanitized[3] = copyPaint(sanitized[2] or sanitized[1]) end
	return sanitized
end

-- Paint has to cross into the vehicle Lua VM, and queueLuaCommand takes a
-- string, so the tables are serialised as Lua literals.
local function paintsToLuaLiteral(paints)
	if tableIsEmpty(paints) then
		return '{ {baseColor={1, 1, 1, 1}, metallic = 0, roughness = 0.5 , clearcoat = 0, clearcoatRoughness = 0 } }'
	end
	local segments = {}
	for i = 1, #paints do
		local paint = paints[i] or {}
		local base = paint.baseColor or {}
		segments[#segments + 1] = string.format(
			'{baseColor = {%s, %s, %s, %s}, metallic = %s, roughness = %s, clearcoat = %s, clearcoatRoughness = %s}',
			string.format('%.6f', base[1] or 0),
			string.format('%.6f', base[2] or 0),
			string.format('%.6f', base[3] or 0),
			string.format('%.6f', base[4] or 1),
			string.format('%.6f', paint.metallic or 0),
			string.format('%.6f', paint.roughness or 0),
			string.format('%.6f', paint.clearcoat or 0),
			string.format('%.6f', paint.clearcoatRoughness or 0)
		)
	end
	return '{' .. table.concat(segments, ',') .. '}'
end

local function identifiersToLuaLiteral(identifiers)
	if type(identifiers) ~= "table" or tableIsEmpty(identifiers) then return "{}" end
	local segments = {}
	for i = 1, #identifiers do
		local identifier = identifiers[i]
		if identifier and identifier ~= '' then
			segments[#segments + 1] = string.format('%q', identifier)
		end
	end
	if tableIsEmpty(segments) then return '{}' end
	return '{' .. table.concat(segments, ',') .. '}'
end

-- Part naming differs between the sender's and receiver's part trees, so try
-- several identifiers and let the vehicle side match whichever it knows.
local function buildIdentifiers(partPath, partName, slotPath)
	local ids = {}
	if partPath and partPath ~= "" then ids[#ids + 1] = partPath end
	if partName and partName ~= "" and partName ~= partPath then ids[#ids + 1] = partName end
	if slotPath and slotPath ~= "" then ids[#ids + 1] = slotPath end
	return ids
end

local function ensureVehiclePartConditionInitialized(vehObj, gameVehicleID)
	if not vehObj or not vehObj.queueLuaCommand then return end
	local id = gameVehicleID or (vehObj.getID and vehObj:getID())
	if not id or id == -1 then return end
	if ensuredPartConditionsByVeh[id] then return end
	vehObj:queueLuaCommand([=[if partCondition and partCondition.ensureConditionsInit then
		partCondition.ensureConditionsInit(0, 1, 1)
	end]=])
	ensuredPartConditionsByVeh[id] = true
end

local function queuePartPaintCommands(vehObj, identifiers, paints)
	if not vehObj or not paints or not identifiers or #identifiers == 0 then return end
	vehObj:queueLuaCommand(string.format([[
		local identifiers = %s
		local paints = %s
		if partCondition then
			if partCondition.ensureConditionsInit then
				partCondition.ensureConditionsInit(0, 1, 1)
			end
			if partCondition.setPartPaints then
				for _, identifier in ipairs(identifiers) do
					partCondition.setPartPaints(identifier, paints, 0)
				end
			end
		end
		]],
		identifiersToLuaLiteral(identifiers),
		paintsToLuaLiteral(paints)
	))
end

-- true when the paint was queued on the car, false when the car has no engine object
-- yet (so the paint can wait for it), nil when the paint itself cannot be used.
local function setPartPaintRemote(gameVehicleID, partPath, paints, partName, slotPath)
	if not paints then return nil end
	local vehObj = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
	if not vehObj then return false end
	paints = sanitizePaints(paints)
	if not paints then return nil end
	local identifiers = buildIdentifiers(partPath, partName, slotPath)
	if #identifiers == 0 then return nil end
	ensureVehiclePartConditionInitialized(vehObj, gameVehicleID)
	queuePartPaintCommands(vehObj, identifiers, paints)
	return true
end

local function applyPartPaintRemote(data)
	if not data then return nil end
	return setPartPaintRemote(data.gameVehicleID, data.partPath, data.paints, data.partName, data.slotPath)
end

local function holdPaint(paintData)
	local serverVehicleID = paintData.serverVehicleID
	local entry = heldPaints[serverVehicleID]
	if not entry then
		if heldCars >= HOLD_MAX_CARS then return end
		entry = {at = os.clockhp(), parts = {}, count = 0}
		heldPaints[serverVehicleID] = entry
		heldCars = heldCars + 1
	end
	local part = tostring(paintData.partPath)
	if not entry.parts[part] then
		if entry.count >= HOLD_MAX_PARTS then return end
		entry.count = entry.count + 1
	end
	entry.parts[part] = paintData
end

local function dropHeld(serverVehicleID)
	if heldPaints[serverVehicleID] then
		heldPaints[serverVehicleID] = nil
		heldCars = heldCars - 1
	end
end

local function forgetHeldPart(serverVehicleID, partPath)
	local entry = heldPaints[serverVehicleID]
	local part = tostring(partPath)
	if not entry or not entry.parts[part] then return end
	entry.parts[part] = nil
	entry.count = entry.count - 1
	if entry.count == 0 then dropHeld(serverVehicleID) end
end

-- Applies what was held for a car that is now ready; anything that still finds no
-- engine object stays held.
local function applyHeldPaints(serverVehicleID, gameVehicleID)
	local entry = heldPaints[serverVehicleID]
	if not entry then return end
	for part, paintData in pairs(entry.parts) do
		paintData.gameVehicleID = gameVehicleID
		if applyPartPaintRemote(paintData) ~= false then
			entry.parts[part] = nil
			entry.count = entry.count - 1
		end
	end
	if entry.count == 0 then dropHeld(serverVehicleID) end
end

local function sendPartPaints(inventoryId, serverVehicleID, originID)
	local vehicle = career_modules_inventory.getVehicles()[inventoryId]
	if not vehicle or not vehicle.partConditions then return end
	for part, partData in pairs(vehicle.partConditions) do
		if partData.visualState and partData.visualState.paint then
			local data = {}
			data.partPath = part
			data.slotPath, data.partName = string.match(data.partPath, "(.*/)([^/]+)$")
			data.paints = partData.visualState.paint.originalPaints
			data.serverVehicleID = serverVehicleID
			if originID then data.originID = originID end
			TriggerServerEvent("perPartPainting", jsonEncode(data))
		end
	end
end

-- Resolves the vehicle once and queues at most one retry, so pendingPaints cannot
-- grow with the number of vehicles in the session.
local function onInventorySpawnVehicleMP(inventoryId, gameVehicleID)
	if not inventoryId then return end
	if gameVehicleID then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID then
			sendPartPaints(inventoryId, serverVehicleID)
			return
		end
	end
	table.insert(pendingPaints, inventoryId)
end

-- A paint for a car this game has not got yet, or has listed but not built, is held
-- until the car is ready (onVehicleReady). The paint can arrive first: the owner sends it
-- as soon as the car spawns on their game.
local function rxRemotePartPaint(data)
	local paintData = jsonDecode(data)
	if type(paintData) ~= "table" or type(paintData.serverVehicleID) ~= "string" then return end
	paintData.gameVehicleID = nil
	if MPVehicleGE.getVehicles()[paintData.serverVehicleID] then
		paintData.gameVehicleID = MPVehicleGE.getGameVehicleID(paintData.serverVehicleID)
		local applied = applyPartPaintRemote(paintData)
		-- An older paint of this part still held must not be applied over this one later.
		if applied then forgetHeldPart(paintData.serverVehicleID, paintData.partPath) end
		if applied ~= false then return end
	end
	holdPaint(paintData)
end

local function rxRequestPartPaints(data)
	local requestData = jsonDecode(data)
	if not requestData or not requestData.serverVehicleID then return end
	local gameVehicleID = MPVehicleGE.getGameVehicleID(requestData.serverVehicleID)
	if not gameVehicleID then return end
	local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(gameVehicleID)
	if not inventoryId then return end
	sendPartPaints(inventoryId, requestData.serverVehicleID, requestData.originID)
end

-- Whether the server says another player's car is their traffic or a parked car; nil
-- while its state has not arrived. An enabler that cannot tell (an older Mileage) gives
-- an answer at once, as before.
local function remoteTraffic(serverVehicleID)
	local enabler = mileageEnabler
	if type(enabler) ~= "table" then return false end
	if type(enabler.hasRemoteState) == "function" and not enabler.hasRemoteState(serverVehicleID) then
		return nil
	end
	return type(enabler.isRemoteTraffic) == "function" and enabler.isRemoteTraffic(serverVehicleID) == true
end

local function requestPaints(serverVehicleID)
	TriggerServerEvent("requestPartPaints", jsonEncode({serverVehicleID = serverVehicleID}))
end

local function onVehicleReady(gameVehicleID)
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not serverVehicleID then return end
	if not MPVehicleGE.isOwn(gameVehicleID) then
		applyHeldPaints(serverVehicleID, gameVehicleID)
		-- Someone else's vehicle appeared; ask its owner for the part paints. Their
		-- traffic and parked cars have none.
		local traffic = remoteTraffic(serverVehicleID)
		if traffic == nil then
			local waiting = waitingRequests[serverVehicleID]
			if not waiting or waiting.gid ~= gameVehicleID then
				waitingRequests[serverVehicleID] = {gid = gameVehicleID, at = os.clockhp()}
			end
		elseif not traffic then
			waitingRequests[serverVehicleID] = nil
			requestPaints(serverVehicleID)
		end
	else
		local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(gameVehicleID)
		if inventoryId then sendPartPaints(inventoryId, serverVehicleID) end
	end
end

local function onVehicleDestroyed(vehId)
	ensuredPartConditionsByVeh[vehId] = nil
	for serverVehicleID, waiting in pairs(waitingRequests) do
		if waiting.gid == vehId then waitingRequests[serverVehicleID] = nil end
	end
end

-- Sends or drops each waiting request once the car's state is known or the wait is over.
-- A car no longer in BeamMP's list under the same game id is forgotten.
local function updateWaitingRequests(now)
	for serverVehicleID, waiting in pairs(waitingRequests) do
		if MPVehicleGE.getGameVehicleID(serverVehicleID) ~= waiting.gid then
			waitingRequests[serverVehicleID] = nil
		else
			local traffic = remoteTraffic(serverVehicleID)
			if traffic == true then
				waitingRequests[serverVehicleID] = nil
			elseif traffic == false or now - waiting.at >= STATE_WAIT_SECONDS then
				waitingRequests[serverVehicleID] = nil
				requestPaints(serverVehicleID)
			end
		end
	end
end

-- Re-broadcast after anything that can change a part's paint.
local function broadcastForInventoryId(inventoryId)
	if not inventoryId then return end
	local gameVehicleID = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
	if not gameVehicleID then return end
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if serverVehicleID then sendPartPaints(inventoryId, serverVehicleID) end
end

local function onPartShoppingStartedMP(targetVehicleID, inventoryId)
	broadcastForInventoryId(inventoryId)
end

local function onPartShoppingPartInstalledMP(partData)
	if partData then broadcastForInventoryId(partData.inventoryId) end
end

local function onPartShoppingTransactionCompleteMP(inventoryId)
	broadcastForInventoryId(inventoryId)
end

local function onUpdate()
	local now = os.clockhp()
	for serverVehicleID, entry in pairs(heldPaints) do
		if now - entry.at > HOLD_SECONDS then dropHeld(serverVehicleID) end
	end
	-- A request needs no loaded world, and a game that is joining has none yet.
	updateWaitingRequests(now)

	if worldReadyState ~= 2 then return end

	for i = #pendingPaints, 1, -1 do
		local inventoryId = pendingPaints[i]
		local gameVehicleID = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
		if gameVehicleID then
			local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
			if serverVehicleID then
				sendPartPaints(inventoryId, serverVehicleID)
				table.remove(pendingPaints, i)
			end
		end
	end
end

-- Leaving the server: nothing held belongs to the next server's cars.
local function onBeamMPServerLeave()
	heldPaints, heldCars = {}, 0
	waitingRequests = {}
end

local function onExtensionLoaded()
	AddEventHandler("rxRequestPartPaints", rxRequestPartPaints)
	AddEventHandler("rxRemotePartPaint", rxRemotePartPaint)
	log("I", logTag, "Mileage perPartPaint LOADED")
end

local function onExtensionUnloaded()
	log("I", logTag, "Mileage perPartPaint UNLOADED")
end

-- Enriched hooks from mileage_patches (the stock ones carry no vehicle id).
M.onInventorySpawnVehicleMP = onInventorySpawnVehicleMP
M.onPartShoppingStartedMP = onPartShoppingStartedMP
M.onPartShoppingPartInstalledMP = onPartShoppingPartInstalledMP
M.onPartShoppingTransactionCompleteMP = onPartShoppingTransactionCompleteMP

M.onVehicleReady = onVehicleReady
M.onVehicleDestroyed = onVehicleDestroyed

M.onUpdate = onUpdate
M.onBeamMPServerLeave = onBeamMPServerLeave

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
