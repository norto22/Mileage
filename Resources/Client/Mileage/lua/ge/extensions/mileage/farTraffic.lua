--Mileage :: far-away traffic
--
-- BeamMP builds every car another player's game owns on this game too, their traffic and
-- parked cars included, wherever on the map they are. Another player's traffic far from
-- here cannot be seen, yet this game still simulates and draws it. While the career runs
-- on a server, this extension holds such cars hidden on this game only, and mileageEnabler
-- reads it:
--
--   * another player's traffic or parked car is hidden once it is more than HIDE_DISTANCE
--     from this game's camera, and that player is too;
--   * it shows again once that player comes within HIDE_DISTANCE.
--
-- "That player" is the nearest of their shown cars that are not traffic: the car they
-- drive, or one they left parked. A hidden car's position is not kept up to date on this
-- game (BeamMP applies positions only to a car that is switched on), so a hidden car
-- comes back by its owner's distance. Each game places its traffic around its own
-- player, so a car whose owner is near is near too. A player must be HIDE_DISTANCE +
-- OWNER_MARGIN away before any of their cars is hidden, so a car does not flicker as its
-- owner drives along the limit.
--
-- The other players' games are not told and the server is not asked for anything; a car
-- whose owner hid it, or one hidden for a parking challenge, stays hidden as before. A
-- player whose own cars this game cannot place keeps all their cars showing.

local M = {}

local logTag = "mileage.farTraffic"

local HIDE_DISTANCE = 1000 -- metres from this game's camera
local OWNER_MARGIN = 100   -- metres past HIDE_DISTANCE an owner must be before hiding
local CHECK_EVERY = 1      -- seconds between checks

-- Server vehicle ids of the cars held hidden here.
local hidden = {}
local active = false
local sinceCheck = CHECK_EVERY
local failureLogged = false

-- A position as a plain {x, y, z}: game positions are vec3 values (cdata under LuaJIT),
-- so their fields are read under pcall; nil when they cannot be read.
local function point(p)
	if p == nil then return nil end
	local ok, x, y, z = pcall(function() return tonumber(p.x), tonumber(p.y), tonumber(p.z) end)
	if not ok or not x or not y or not z then return nil end
	return {x = x, y = y, z = z}
end

local function distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function positionOf(veh)
	local ok, pos = pcall(function() return veh:getPosition() end)
	return ok and point(pos) or nil
end

-- Where this game looks from: the camera (it follows a car the player spectates), else
-- the car the player drives.
local function viewPoint()
	local camera = rawget(_G, "core_camera")
	if type(camera) == "table" and type(camera.getPosition) == "function" then
		local ok, pos = pcall(camera.getPosition)
		local here = ok and point(pos)
		if here then return here end
	end
	local ok, gameVehicleID = pcall(function() return be:getPlayerVehicleID(0) end)
	if not ok or not gameVehicleID or gameVehicleID == -1 then return nil end
	local veh = be:getObjectByID(gameVehicleID)
	return veh and positionOf(veh) or nil
end

local function isRemoteTraffic(serverVehicleID)
	local enabler = mileageEnabler
	return type(enabler) == "table" and type(enabler.isRemoteTraffic) == "function"
		and enabler.isRemoteTraffic(serverVehicleID) == true
end

local function ownerOf(serverVehicleID)
	return type(serverVehicleID) == "string" and string.match(serverVehicleID, "^(%d+)%-") or nil
end

local function reapply()
	local enabler = mileageEnabler
	if type(enabler) == "table" and type(enabler.reapplyRemoteStates) == "function" then
		local ok, err = pcall(enabler.reapplyRemoteStates)
		if not ok then log("E", logTag, "could not put other players' cars right: " .. tostring(err)) end
	end
end

local function showAll(why)
	if next(hidden) == nil then return end
	hidden = {}
	log("D", logTag, "other players' traffic shown again (" .. why .. ")")
	reapply()
end

-- Works out which of the other players' traffic and parked cars to hold hidden.
local function check()
	local here = viewPoint()
	if not here then
		showAll("no camera or car position")
		return
	end
	local vehicles = MPVehicleGE.getVehicles()
	-- Every other player's distance: their nearest shown car that is not traffic.
	local ownerDistance = {}
	local traffic = {}
	for serverVehicleID, entry in pairs(vehicles) do
		local gameVehicleID = entry.gameVehicleID
		local veh = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
		if veh and not MPVehicleGE.isOwn(gameVehicleID) then
			if isRemoteTraffic(serverVehicleID) then
				traffic[serverVehicleID] = veh
			elseif veh:getActive() then
				local owner, pos = ownerOf(serverVehicleID), positionOf(veh)
				if owner and pos then
					local d = distance(here, pos)
					if not ownerDistance[owner] or d < ownerDistance[owner] then ownerDistance[owner] = d end
				end
			end
		end
	end
	local changed = false
	local now = {}
	for serverVehicleID, veh in pairs(traffic) do
		local ownerAway = ownerDistance[ownerOf(serverVehicleID)]
		local keep
		if hidden[serverVehicleID] then
			-- Its own position is stale: it comes back with its owner.
			keep = ownerAway ~= nil and ownerAway > HIDE_DISTANCE
		else
			-- Shown, so its position is current; a car hidden for another reason waits.
			local pos = veh:getActive() and positionOf(veh)
			keep = pos ~= nil and ownerAway ~= nil and ownerAway > HIDE_DISTANCE + OWNER_MARGIN
				and distance(here, pos) > HIDE_DISTANCE
		end
		if keep then now[serverVehicleID] = true end
		if (keep and true or false) ~= (hidden[serverVehicleID] and true or false) then changed = true end
	end
	-- A car gone from this game, or no longer traffic, is simply dropped.
	for serverVehicleID in pairs(hidden) do
		if not now[serverVehicleID] and not traffic[serverVehicleID] then changed = true end
	end
	hidden = now
	if changed then
		local count = 0
		for _ in pairs(hidden) do count = count + 1 end
		log("D", logTag, string.format("%d of other players' traffic and parked cars hidden here (over %d m away)",
			count, HIDE_DISTANCE))
		reapply()
	end
end

--- true while another player's traffic or parked car is held hidden on this game.
function M.isHidden(serverVehicleID)
	return hidden[serverVehicleID] == true
end

--== hooks ===================================================================

function M.onCareerActive(on)
	local compat = extensions.mileage_compat
	active = on == true and compat ~= nil and compat.isMPSession() == true
	sinceCheck, failureLogged = CHECK_EVERY, false
	if not active then showAll("career not active") end
end

function M.onUpdate(dtReal)
	if not active then return end
	local dt = tonumber(dtReal)
	if not dt or dt < 0 then dt = 0 end
	sinceCheck = sinceCheck + dt
	if sinceCheck < CHECK_EVERY then return end
	sinceCheck = 0
	local ok, err = pcall(check)
	if not ok then
		if not failureLogged then
			failureLogged = true
			log("E", logTag, "far traffic check failed, every car is shown: " .. tostring(err))
		end
		showAll("check failed")
	end
end

function M.onBeamMPServerLeave()
	active = false
	showAll("left the server")
end

function M.onExtensionUnloaded()
	active = false
	showAll("unloaded")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
