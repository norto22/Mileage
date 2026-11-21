--Mileage :: one car edit per garage visit (CLIENT)
--
-- Every part tried or removed in Parts and every Apply in Tuning rebuilds the car, and BeamMP
-- sends each rebuild to every other player at once as an edit, which each of their games
-- builds again. While the Parts or Tuning screen is open for one of this player's cars, that
-- car's edits are held here instead; when the screen closes, BeamMP's own sendVehicleEdit
-- sends the finished car once, if anything was held.
--
-- BeamMP sends an edit from a local function (MPVehicleGE.lua sendVehicleEdit), which its
-- own callers reach without the module table, so the hold sits at MPGameNetwork.send and
-- takes only the 'Oc' packets of the session's car (by server vehicle id). Positions,
-- paint, spawns and every other car's edits go through as before. BeamMP builds each packet
-- in one reused buffer, so a packet is read when it is sent and never kept: the closing edit
-- is a new one, made from the car as it is then.
--
-- A session starts on Mileage's enriched start hooks (mileage/patches fires
-- onPartShoppingStartedMP and onCareerTuningStartedMP with the car), after the game's quick
-- repair before Parts or Tuning, so the repair is not held. It ends when the garage computer's
-- menu opens again (Parts and Tuning both close through career_modules_computer.openMenu),
-- when Parts' Buy completes, when the game says the Parts session is no longer open, or when
-- another garage screen (Parts, Tuning or Painting) opens. Painting and Repair are never held.
--
-- isHolding tells mileagePerPartPaint not to send the car's part paint while its screen is
-- open: the other games ask for it once the finished car reaches them.
--
-- Career stop, unload or a failure in the hold sends what was held and puts BeamMP's send
-- back; leaving the server drops it. Only BeamMP's send is changed, at runtime, and only while
-- a session is open; BeamMP's files are not changed.

local M = {}

local logTag = "mileage.editHold"

-- LuaJIT has a global unpack; Lua 5.2 and later keep it in table.
local unpack = table.unpack or unpack

local function pack(...) return {n = select("#", ...), ...} end

-- The open session: {kind, gameVehicleID, serverVehicleID, prefix, held}, or nil. prefix is
-- the start of the car's edit packet; held counts the edits kept back.
local session = nil
-- BeamMP's send while the hold is in front of it: {module, original, check}.
local wrapped = nil

local function packetText(data)
	if type(data) == "string" then return data end
	return tostring(data)
end

-- true for an edit packet ("Oc:<serverVehicleID>:<data>") of the session's car.
local function isHeldEdit(s, data)
	local text = packetText(data)
	return text:sub(1, #s.prefix) == s.prefix
end

local function unwrap()
	local w = wrapped
	wrapped = nil
	-- A send wrapped again over ours is left in place; ours under it passes everything
	-- once no session is open.
	if w and w.module.send == w.check then w.module.send = w.original end
end

-- Sends the car of a session that held something, as BeamMP's Sync button does.
local function sendHeldEdit(s, why)
	if s.held == 0 then return end
	local mp = MPVehicleGE
	local gameVehicleID = s.gameVehicleID
	if type(mp) ~= "table" or type(mp.sendVehicleEdit) ~= "function" then
		log("W", logTag, "BeamMP's sendVehicleEdit is gone, the held edit of " .. s.serverVehicleID .. " is dropped")
		return
	end
	if not be:getObjectByID(gameVehicleID) or not mp.isOwn(gameVehicleID) then
		log("I", logTag, "car " .. s.serverVehicleID .. " is gone, its held edit is dropped (" .. why .. ")")
		return
	end
	local ok, err = pcall(mp.sendVehicleEdit, gameVehicleID)
	if not ok then
		log("E", logTag, "could not send the held edit of " .. s.serverVehicleID .. ": " .. tostring(err))
		return
	end
	log("I", logTag, string.format("sent car %s once for %d held edits (%s)", s.serverVehicleID, s.held, why))
end

-- Ends the open session: BeamMP's send is put back first, so the closing edit goes out.
local function finish(send, why)
	local s = session
	session = nil
	unwrap()
	if not s then return end
	if send then
		sendHeldEdit(s, why)
	elseif s.held > 0 then
		log("I", logTag, string.format("dropped %d held edits of %s (%s)", s.held, s.serverVehicleID, why))
	end
end

local function makeCheck(original)
	return function(data, ...)
		local s = session
		if not s then return original(data, ...) end
		local ok, held = pcall(isHeldEdit, s, data)
		if ok then
			if not held then return original(data, ...) end
			s.held = s.held + 1
			return
		end
		-- The packet goes on as BeamMP sent it, then what was held, and edits flow again.
		log("E", logTag, "edit hold failed, edits are sent as BeamMP sends them: " .. tostring(held))
		session = nil
		unwrap()
		local results = pack(pcall(original, data, ...))
		sendHeldEdit(s, "the hold failed")
		if not results[1] then error(results[2], 0) end
		return unpack(results, 2, results.n)
	end
end

local function wrap()
	local net = rawget(_G, "MPGameNetwork")
	if wrapped and wrapped.module == net and net.send == wrapped.check then return true end
	wrapped = nil
	local compat = extensions.mileage_compat
	local original = compat and compat.pickOrWarn(net, "MPGameNetwork", "send",
		"every garage change is sent to other players at once")
	if not original then return false end
	local check = makeCheck(original)
	wrapped = {module = net, original = original, check = check}
	net.send = check
	return true
end

local function startSession(kind, gameVehicleID)
	if session then finish(true, "another garage screen opened") end
	local compat = extensions.mileage_compat
	if not (compat and compat.isMPSession()) then return end
	if type(gameVehicleID) ~= "number" then return end
	local mp = MPVehicleGE
	if not compat.pickOrWarn(mp, "MPVehicleGE", "sendVehicleEdit",
			"every garage change is sent to other players at once") then
		return
	end
	if type(mp.getServerVehicleID) ~= "function" or type(mp.isOwn) ~= "function" then return end
	if not mp.isOwn(gameVehicleID) then return end
	local serverVehicleID = mp.getServerVehicleID(gameVehicleID)
	if type(serverVehicleID) ~= "string" then
		log("D", logTag, "car " .. gameVehicleID .. " has no server id yet, its edits are not held")
		return
	end
	if not wrap() then return end
	session = {kind = kind, gameVehicleID = gameVehicleID, serverVehicleID = serverVehicleID,
		prefix = "Oc:" .. serverVehicleID .. ":", held = 0}
	log("D", logTag, "holding the edits of " .. serverVehicleID .. " while " .. kind .. " is open")
end

local function guarded(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		log("E", logTag, "edit hold failed, edits are sent as BeamMP sends them: " .. tostring(err))
		pcall(finish, true, "the hold failed")
	end
end

--- true while the edits of this game vehicle are held (its Parts or Tuning screen is open):
--- the other games still have the car as it was before the screen opened.
function M.isHolding(gameVehicleID)
	return session ~= nil and session.gameVehicleID == gameVehicleID
end

--== hooks ===================================================================

function M.onPartShoppingStartedMP(gameVehicleID)
	guarded(startSession, "Parts", gameVehicleID)
end

function M.onCareerTuningStartedMP(gameVehicleID)
	guarded(startSession, "Tuning", gameVehicleID)
end

function M.onVehiclePaintingUiOpenedMP()
	if session then guarded(finish, true, "Painting opened") end
end

function M.onPartShoppingTransactionComplete()
	if session and session.kind == "Parts" then guarded(finish, true, "Parts closed") end
end

-- Closing Parts or Tuning opens the garage computer's menu again. 0.39 renamed the hook;
-- both names are heard.
function M.onComputerMenuOpened()
	if session then guarded(finish, true, session.kind .. " closed") end
end
M.onComputerOpened = M.onComputerMenuOpened

local function partsClosed()
	local shopping = career_modules_partShopping
	if type(shopping) ~= "table" or type(shopping.isShoppingSessionActive) ~= "function" then return false end
	return shopping.isShoppingSessionActive() ~= true
end

function M.onUpdate()
	if session and session.kind == "Parts" then
		local ok, closed = pcall(partsClosed)
		if not ok or closed then guarded(finish, true, "Parts closed") end
	end
end

function M.onCareerActive(active)
	if not active and session then guarded(finish, true, "career not active") end
end

function M.onBeamMPServerLeave()
	pcall(finish, false, "left the server")
end

function M.onExtensionLoaded()
	log("I", logTag, "Mileage edit hold LOADED")
end

function M.onExtensionUnloaded()
	pcall(finish, true, "unloaded")
	log("I", logTag, "Mileage edit hold UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
