--Mileage :: damage between players (CLIENT)
--
-- BeamMP sends where another player's car is but never its dents, so each game used to
-- simulate its own damage on its copy of that car. The car's own game now decides:
--
--   * Once a second each car gets a role in its vehicle Lua (mileageDamage): "owner"
--     for this player's own cars that are not traffic or parked (after two checks in a
--     row, because the game flags new traffic a moment after it spawns), "copy" for
--     another player's car. The walking unicycle gets neither.
--   * An owner's vehicle Lua hands its changed beams to onLocalDamage; they go to the
--     server ("careerDamage") at most SENDS_PER_SECOND a second, queued.
--   * A copy asks the owner for the car's full damage ("careerDamageRequest"), again
--     until it has applied every numbered part of it (shapeApplied), and each damage
--     message from the server ("rxCareerDamage") is checked and handed to the copy's
--     vehicle Lua.
--
-- Only numbers this module has checked and formatted itself reach a vehicle command; no
-- text from another player's message is ever pasted into one.

local M = {}

local logTag = "mileage.damageSync"

local ROLES_EVERY_SECONDS = 1
local OWNER_CHECKS = 2
local SENDS_PER_SECOND = 3
local MAX_QUEUE = 30
local MAX_MESSAGE_BYTES = 32768
local MAX_BEAMS = 400
local MAX_NODES = 500
local MAX_PARTS = 64
-- A game that joins a busy server builds many copies at once; their full-damage requests
-- go out at most this many a second (the server passes 4), and one that gets no answer
-- is asked again every RETRY_SECONDS, at most REQUEST_TRIES times in all.
local REQUESTS_PER_SECOND = 3
local RETRY_SECONDS = 5
local REQUEST_TRIES = 4

local roles = {}          -- game vehicle id -> "owner" | "copy"
local ownerChecks = {}    -- game vehicle id -> checks in a row as an own player car
local outbox = {}         -- messages waiting for the server
local requests = {}       -- server vehicle ids whose full damage is still to be asked for
local awaiting = {}       -- game vehicle id -> {sid, wait, tries} until its owner answers
local sinceRoles = 0
local sinceSend = 0
local sinceRequest = 0
local warned = {}

local function warnOnce(key, msg)
	if warned[key] then return end
	warned[key] = true
	log("W", logTag, msg)
end

-- A server vehicle id exactly as the server writes it: "<player>-<vehicle>".
local function isServerVehicleID(sid)
	return type(sid) == "string" and sid:match("^%d+%-%d+$") ~= nil
end

-- The enabler's own test, which also marks traffic for other players' nametags. Without
-- it every own car counts as traffic, so nothing is sent rather than traffic damage.
local function isTrafficCar(gameVehicleID, veh)
	if not (mileageEnabler and type(mileageEnabler.isTrafficCar) == "function") then
		warnOnce("enabler", "mileageEnabler.isTrafficCar missing - this game's damage is not shared")
		return true
	end
	return mileageEnabler.isTrafficCar(gameVehicleID, veh)
end

local function queueRequest(serverVehicleID)
	for _, queued in ipairs(requests) do
		if queued == serverVehicleID then return end
	end
	table.insert(requests, serverVehicleID)
end

-- Traffic and parked cars never answer, so their copies are not asked. The server's
-- marks often arrive just after the copy is built, so this is checked again before each
-- request goes out. An enabler without the check (an older Mileage) asks for every car.
local function isRemoteTraffic(serverVehicleID)
	local enabler = mileageEnabler
	return type(enabler) == "table" and type(enabler.isRemoteTraffic) == "function"
		and enabler.isRemoteTraffic(serverVehicleID) == true
end

-- Asks a copy's owner for its full damage, again later if no answer comes.
local function requestFull(gameVehicleID, serverVehicleID)
	if isRemoteTraffic(serverVehicleID) then
		awaiting[gameVehicleID] = nil
		return
	end
	awaiting[gameVehicleID] = {sid = serverVehicleID, wait = RETRY_SECONDS, tries = 1}
	queueRequest(serverVehicleID)
end

local function retryRequests()
	for gameVehicleID, a in pairs(awaiting) do
		a.wait = a.wait - ROLES_EVERY_SECONDS
		if isRemoteTraffic(a.sid) then
			awaiting[gameVehicleID] = nil
		elseif a.wait <= 0 then
			if a.tries >= REQUEST_TRIES then
				-- An owner on an older Mileage never answers; its copy is left to the game.
				awaiting[gameVehicleID] = nil
			else
				a.tries, a.wait = a.tries + 1, RETRY_SECONDS
				queueRequest(a.sid)
			end
		end
	end
end

local function sendRequests(dt)
	sinceRequest = math.min(sinceRequest + dt, 1 / REQUESTS_PER_SECOND)
	while #requests > 0 and isRemoteTraffic(requests[1]) do table.remove(requests, 1) end
	if #requests == 0 or sinceRequest < 1 / REQUESTS_PER_SECOND then return end
	sinceRequest = 0
	TriggerServerEvent("careerDamageRequest", '{"v":"' .. table.remove(requests, 1) .. '"}')
end

local function forget(gameVehicleID)
	roles[gameVehicleID] = nil
	ownerChecks[gameVehicleID] = nil
	awaiting[gameVehicleID] = nil
end

local function assignRoles()
	local seen = {}
	for serverVehicleID, entry in pairs(MPVehicleGE.getVehicles()) do
		local gameVehicleID = entry.gameVehicleID
		local veh = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
		if veh and isServerVehicleID(serverVehicleID) then
			seen[gameVehicleID] = true
			local wanted = nil
			if veh.JBeam ~= "unicycle" then
				if MPVehicleGE.isOwn(gameVehicleID) then
					if isTrafficCar(gameVehicleID, veh) then
						ownerChecks[gameVehicleID] = 0
					else
						ownerChecks[gameVehicleID] = (ownerChecks[gameVehicleID] or 0) + 1
					end
					if ownerChecks[gameVehicleID] >= OWNER_CHECKS then wanted = "owner" end
				else
					wanted = "copy"
				end
			end
			if roles[gameVehicleID] ~= wanted then
				roles[gameVehicleID] = wanted
				veh:queueLuaCommand(string.format("mileageDamage.setRole(%q)", wanted or "none"))
				if wanted == "copy" then requestFull(gameVehicleID, serverVehicleID) end
			end
		end
	end
	for gameVehicleID in pairs(roles) do
		if not seen[gameVehicleID] then forget(gameVehicleID) end
	end
end

--== outgoing ================================================================

-- From an owner car's vehicle Lua: one message of its changed beams, without the car id.
local function onLocalDamage(gameVehicleID, message)
	if roles[gameVehicleID] ~= "owner" or type(message) ~= "string" or message:sub(1, 1) ~= "{" then return end
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not isServerVehicleID(serverVehicleID) then return end
	local full = '{"v":"' .. serverVehicleID .. '",' .. message:sub(2)
	if #full > MAX_MESSAGE_BYTES then
		warnOnce("size", string.format("a damage message of %d bytes was not sent (limit %d)", #full, MAX_MESSAGE_BYTES))
		return
	end
	if #outbox >= MAX_QUEUE then
		-- Dropped changes would leave copies behind for good, so every owner car sends its
		-- full damage again instead.
		warnOnce("queue", "damage messages queued faster than they can be sent - full damage sent again")
		outbox = {}
		-- A dropped cleared notice would leave old damage on the copies, so each sends a
		-- cleared notice first.
		for ownedID, role in pairs(roles) do
			local veh = role == "owner" and be:getObjectByID(ownedID)
			if veh then veh:queueLuaCommand("mileageDamage.sendFull(1)") end
		end
	end
	table.insert(outbox, full)
end

local function sendQueued(dt)
	sinceSend = math.min(sinceSend + dt, 1 / SENDS_PER_SECOND)
	if #outbox == 0 or sinceSend < 1 / SENDS_PER_SECOND then return end
	sinceSend = 0
	TriggerServerEvent("careerDamage", table.remove(outbox, 1))
end

--== incoming ================================================================

local function isNumber(x)
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

-- A flat list of rows of four numbers, the first of each row an id, formatted as Lua
-- number text; nil when anything else is in it.
local function numberRows(list, maxRows)
	if type(list) ~= "table" or #list % 4 ~= 0 or #list / 4 > maxRows then return nil end
	local parts = {}
	for i = 1, #list do
		local x = list[i]
		if not isNumber(x) then return nil end
		if i % 4 == 1 then
			if x < 0 or x > 2147483647 or x ~= math.floor(x) then return nil end
			parts[i] = string.format("%d", x)
		else
			parts[i] = string.format("%.4f", x)
		end
	end
	return table.concat(parts, ",")
end

-- A part number of a whole shape, or the number of its parts: 1 to MAX_PARTS.
local function isPartNumber(x)
	return isNumber(x) and x >= 1 and x <= MAX_PARTS and x == math.floor(x)
end

local function rxCareerDamage(data)
	if type(data) ~= "string" or #data > MAX_MESSAGE_BYTES then return end
	-- Text from another player's game: the game's decoder may raise on a bad one.
	local ok, message = pcall(jsonDecode, data)
	if not ok or type(message) ~= "table" or not isServerVehicleID(message.v) then return end
	local gameVehicleID = MPVehicleGE.getGameVehicleID(message.v)
	if not gameVehicleID or gameVehicleID == -1 or MPVehicleGE.isOwn(gameVehicleID) then return end
	if roles[gameVehicleID] ~= "copy" then return end
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end
	local beams, nodes = numberRows(message.b, MAX_BEAMS), numberRows(message.n, MAX_NODES)
	local part, parts = message.p, message.t
	local numbered = part ~= nil or parts ~= nil
	if not beams or not nodes or (numbered and not (isPartNumber(part) and isPartNumber(parts) and part <= parts)) then
		warnOnce("malformed", "a damage message for " .. message.v .. " was not in the expected form")
		return
	end
	local cleared = message.c == 1 and 1 or 0
	local command = string.format("mileageDamage.applyDamage(%d,{%s},{%s})", cleared, beams, nodes)
	if numbered then
		-- A part of the owner's whole shape: the copy waits on until it has every part
		-- and has applied them (shapeApplied), so a set with a part lost is asked again.
		local a = awaiting[gameVehicleID]
		if a then a.wait = RETRY_SECONDS end
		command = string.format("mileageDamage.applyDamage(%d,{%s},{%s},%d,%d)", cleared, beams, nodes, part, parts)
	elseif cleared == 1 or (beams == "" and nodes == "") then
		-- A cleared notice, or an undamaged car's full damage: nothing more to wait for.
		awaiting[gameVehicleID] = nil
	end
	veh:queueLuaCommand(command)
end

-- From a copy's vehicle Lua: it has every part of its owner's whole shape and applied it.
local function shapeApplied(gameVehicleID)
	if roles[gameVehicleID] == "copy" then awaiting[gameVehicleID] = nil end
end

-- Another game built a copy of one of this game's cars, or its copy drifted: the owner
-- car answers with its full damage, flagged so only the players who asked receive it.
local function rxCareerDamageRequest(data)
	if type(data) ~= "string" or #data > 256 then return end
	local ok, request = pcall(jsonDecode, data)
	if not ok or type(request) ~= "table" or not isServerVehicleID(request.v) then return end
	local gameVehicleID = MPVehicleGE.getGameVehicleID(request.v)
	if not gameVehicleID or roles[gameVehicleID] ~= "owner" or not MPVehicleGE.isOwn(gameVehicleID) then return end
	local veh = be:getObjectByID(gameVehicleID)
	if veh then veh:queueLuaCommand("mileageDamage.answerFull()") end
end

-- From a copy's vehicle Lua: it disagrees with its owner (wantFull = 1), or the owner
-- reset it and it still carries damage (wantFull = 0). The copy is reset where it is, as
-- BeamMP applies another player's reset, and asks the owner for full damage if needed.
local function resetCopy(gameVehicleID, wantFull)
	if roles[gameVehicleID] ~= "copy" then return end
	local veh = be:getObjectByID(gameVehicleID)
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not veh or not isServerVehicleID(serverVehicleID) then return end
	local pos = veh:getPosition()
	-- The rotation BeamMP's own reset of another player's car uses (MPVehicleGE
	-- onVehicleResetted). Its spawn turns the car 180 degrees; a reset must not.
	local rot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
	veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
	veh:resetBrokenFlexMesh()
	if wantFull == 1 then
		log("I", logTag, "copy of " .. serverVehicleID .. " disagreed with its owner - reset and resynced")
		requestFull(gameVehicleID, serverVehicleID)
	end
end

--== hooks ===================================================================

local function onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	if dt < 0 then dt = 0 end
	sinceRoles = sinceRoles + dt
	if sinceRoles >= ROLES_EVERY_SECONDS then
		sinceRoles = 0
		assignRoles()
		retryRequests()
	end
	sendQueued(dt)
	sendRequests(dt)
end

-- A respawned car has a fresh vehicle Lua: it gets its role (and a copy its damage)
-- again on the next check.
local function onVehicleSpawned(gameVehicleID)
	forget(gameVehicleID)
end

local function onBeamMPServerLeave()
	roles, ownerChecks, outbox, requests, awaiting = {}, {}, {}, {}, {}
	sinceRoles, sinceSend, sinceRequest = 0, 0, 0
end

local function onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded, damage is not shared")
		return
	end
	AddEventHandler("rxCareerDamage", rxCareerDamage)
	AddEventHandler("rxCareerDamageRequest", rxCareerDamageRequest)
	log("I", logTag, "Mileage damage sync LOADED")
end

M.onLocalDamage = onLocalDamage
M.resetCopy = resetCopy
M.shapeApplied = shapeApplied
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = forget
M.onBeamMPServerLeave = onBeamMPServerLeave
M.onExtensionLoaded = onExtensionLoaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
