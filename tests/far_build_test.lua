-- mileage/spawnPacing.lua with the far-car hold: another player's queued traffic or
-- parked car stays in BeamMP's queue while it is more than 1000 m from this game's
-- camera, and the waiting cars are built nearest first, one per pacing step. The hold is
-- in place from world-ready, so a joiner's first wave is held too, and every held car is
-- handed back to BeamMP on leaving the server, on career stop and on any error.
--
-- The stand-in MPVehicleGE follows BeamMP 4.23.1's queue as tests/spawn_pacing_test.lua
-- does: onPreRender builds every waiting car (applyQueuedEvents) once the player has been
-- slow for 3 s, or at once with no car, and the queue flag drops once it has run, whatever
-- it built; applyPlayerQueues builds one owner's waiting cars. A queued car's position is
-- the one BeamMP keeps for it (vehicle.position, updated from its owner's position
-- packets while it is not built, positionGE.lua applyPos), or a zero vector while no
-- packet has come; the spawn data's pos is where BeamMP would build it then.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/spawnPacing.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"
local ENABLER = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"

local FRAME = 1 / 60

local logs, bm

local function newBeamMP()
	bm = {vehicles = {}, built = {}, edits = {}, queueWaiting = false, timer = 0, slow = true, hasCar = true,
		applyTime = 3, now = 0, frame = 0, cached = nil, meterBuilt = 0,
		settings = {enableBlobs = true, showBlobQueued = true, blobColorQueued = "#00ff00",
			highlightQueuedPlayers = false},
		marks = {}, tags = {}, spheres = {}, counts = {}, positions = {}, json = {}, traffic = {},
		camera = {x = 0, y = 0, z = 0}}
	local M = {}
	function M.getVehicles()
		if bm.failGetVehicles then error("vehicle list broke") end
		return bm.vehicles
	end
	function M.getVehicleByServerID(sid) return bm.vehicles[sid] end
	local function getQueueCounts()
		local spawns, edits = 0, 0
		for _, v in pairs(bm.vehicles) do
			if v.spawnQueue then spawns = spawns + 1 end
			if v.editQueue then edits = edits + 1 end
		end
		return spawns, edits, {}
	end
	local function applyVehicleQueues(sid, v)
		if v.spawnQueue then
			v.spawnQueue = nil
			v.isSpawned = true
			table.insert(bm.built, {sid = sid, at = bm.now, frame = bm.frame})
		end
		if v.editQueue then
			v.editQueue = nil
			table.insert(bm.edits, sid)
		end
	end
	function M.applyQueuedEvents()
		local changed = false
		for sid, v in pairs(bm.vehicles) do
			if v.spawnQueue or v.editQueue then applyVehicleQueues(sid, v); changed = true end
		end
		if changed then UI.updateQueue(getQueueCounts()) end
		bm.queueWaiting = false
	end
	function M.applyPlayerQueues(playerID)
		local empty, changed = true, false
		for sid, v in pairs(bm.vehicles) do
			if v.spawnQueue or v.editQueue then
				if v.ownerID == playerID then applyVehicleQueues(sid, v); changed = true else empty = false end
			end
		end
		if changed then UI.updateQueue(getQueueCounts()) end
		if empty then bm.queueWaiting = false end
	end
	local function drawMarkers()
		for sid, v in pairs(bm.vehicles) do
			if not v.isLocal and v.position then
				local z = v.position.z
				if bm.settings.enableBlobs and not v.isSpawned then
					local colour
					if v.spawnQueue then
						if bm.settings.showBlobQueued then colour = "queued" end
					else
						colour = "magenta"
					end
					if colour then
						table.insert(bm.marks, {sid = sid, colour = colour})
						z = z + 1
					end
				end
				bm.tags[sid] = z
			end
		end
	end
	function M.onPreRender(dt)
		if bm.queueWaiting then
			if bm.hasCar then
				if bm.slow then
					bm.timer = bm.timer + dt
					if bm.timer >= bm.applyTime then
						M.applyQueuedEvents()
						bm.timer = 0
					end
				else
					bm.timer = 0
				end
			else
				bm.timer = 0
				M.applyQueuedEvents()
			end
		end
		drawMarkers()
	end
	MPVehicleGE = M
	bm.original = M.onPreRender
	bm.cached = M.onPreRender
	return M
end

-- A spawn for another player's car arriving from the server. opts.at is its distance
-- east of the origin, opts.traffic its mark on the server (nil: none known yet),
-- opts.unplaced gives BeamMP no position for it yet, only the spawn data's.
local function spawn(sid, owner, opts)
	opts = opts or {}
	local at = opts.at or 0
	if not bm.vehicles[sid] then
		bm.positions[sid] = opts.unplaced and vec3(0, 0, 0) or vec3(at, 0, 2)
		bm.vehicles[sid] = {ownerID = owner, isSpawned = false, position = bm.positions[sid]}
	end
	local data = string.format('{"jbm":"covet","pos":[%s,0,2]}', at)
	bm.json[data] = {jbm = "covet", pos = {at, 0, 2}}
	bm.vehicles[sid].spawnQueue = {serverVehicleID = sid, data = data}
	bm.traffic[sid] = opts.traffic
	bm.queueWaiting = true
end

-- BeamMP's position packets for a car not built yet move the place it keeps for it.
local function moveTo(sid, at)
	local p = MPVehicleGE.getVehicleByServerID(sid).position
	p.x, p.y, p.z = at, 0, 2
end

local function globals(opts)
	opts = opts or {}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	vec3 = function(x, y, z) return {x = x, y = y, z = z} end
	ColorF = function(r, g, b, a) return {r = r, g = g, b = b, a = a} end
	jsonDecode = function(text) return bm.json[text] end
	newBeamMP()
	settings = {getValue = function(key) return bm.settings[key] end}
	MPHelpers = {hex2rgb = function() return {0, 1, 0} end}
	debugDrawer = {drawSphere = function(_, pos, radius, colour)
		table.insert(bm.spheres, {pos = pos, radius = radius, colour = colour})
	end}
	bm.updateQueue = function(spawns, edits)
		table.insert(bm.counts, {frame = bm.frame, spawns = spawns, edits = edits})
	end
	UI = {updateQueue = bm.updateQueue}
	core_camera = {getPosition = function()
		if bm.failCamera then error("camera broke") end
		return bm.camera and vec3(bm.camera.x, bm.camera.y, bm.camera.z)
	end}
	be = nil
	mileageEnabler = nil
	extensions = {
		mileage_compat = dofile(COMPAT),
		hookUpdate = function(name) if name == "onPreRender" then bm.cached = MPVehicleGE.onPreRender end end,
		mileage_perfMeter = {built = function() bm.meterBuilt = bm.meterBuilt + 1 end},
	}
end

-- spawnPacing with a stand-in enabler that reads the marks the test sets.
local function setup(opts)
	globals(opts)
	extensions.mileageEnabler = {isRemoteTraffic = function(sid)
		if bm.failMarks then error("marks broke") end
		return bm.traffic[sid] == true
	end}
	return dofile(SOURCE)
end

local function run(seconds)
	for _ = 1, math.floor(seconds / FRAME + 0.5) do
		bm.now = bm.now + FRAME
		bm.frame = bm.frame + 1
		bm.marks, bm.tags, bm.spheres = {}, {}, {}
		bm.cached(FRAME)
		if bm.enabler then bm.enabler.onUpdate(FRAME) end
		if bm.check then bm.check() end
	end
end

local function builtCount() return #bm.built end

local function isBuilt(sid)
	for _, b in ipairs(bm.built) do if b.sid == sid then return true end end
	return false
end

local function waitingCars()
	local list = {}
	for sid, v in pairs(bm.vehicles) do
		if v.spawnQueue and not v.isLocal then table.insert(list, sid) end
	end
	table.sort(list)
	return list
end

local function framesWithTwo()
	local perFrame, n = {}, 0
	for _, b in ipairs(bm.built) do
		perFrame[b.frame] = (perFrame[b.frame] or 0) + 1
		if perFrame[b.frame] == 2 then n = n + 1 end
	end
	return n
end

-- Every frame: each waiting car, held or not, shows one queued marker at its place and
-- its name tag 1 m up; no car is left marked as built or moved; each count BeamMP's UI
-- gets counts every waiting car.
local function everyFrameLooksQueued(failures)
	local seen = 0
	return function()
		for _, sid in ipairs(waitingCars()) do
			local place = bm.positions[sid]
			local marks = 0
			for _, m in ipairs(bm.marks) do if m.sid == sid then marks = marks + 1 end end
			for _, sphere in ipairs(bm.spheres) do
				if sphere.pos.x == place.x and sphere.pos.y == place.y and sphere.pos.z == place.z then marks = marks + 1 end
			end
			if marks ~= 1 then
				table.insert(failures, string.format("frame %d %s: %d markers", bm.frame, sid, marks))
			elseif bm.tags[sid] ~= place.z + 1 then
				table.insert(failures, string.format("frame %d %s: name tag at %s", bm.frame, sid, tostring(bm.tags[sid])))
			end
		end
		for sid, v in pairs(bm.vehicles) do
			if v.isSpawned and not isBuilt(sid) then
				table.insert(failures, string.format("frame %d %s: marked as built", bm.frame, sid))
			end
			if v.position ~= bm.positions[sid] then
				table.insert(failures, string.format("frame %d %s: place moved", bm.frame, sid))
			end
		end
		for i = seen + 1, #bm.counts do
			if bm.counts[i].spawns ~= #waitingCars() then
				table.insert(failures, string.format("frame %d: count %d with %d waiting", bm.frame,
					bm.counts[i].spawns, #waitingCars()))
			end
		end
		seen = #bm.counts
		if UI.updateQueue ~= bm.updateQueue then
			table.insert(failures, string.format("frame %d: UI.updateQueue is not BeamMP's", bm.frame))
		end
	end
end

local function noFailures(failures)
	same(#failures, 0, "frames wrong, first: " .. tostring(failures[1]))
end

-- 20 far traffic and parked cars of players 1 and 2, 1500 m to 5300 m away: 1-0 .. 1-9
-- and 2-0 .. 2-9, 1-0 the nearest.
local function twentyFar()
	for i = 0, 9 do
		spawn("1-" .. i, 1, {at = 1500 + 200 * i, traffic = true})
		spawn("2-" .. i, 2, {at = 3500 + 200 * i, traffic = true})
	end
end

local function waitingFar()
	local n = 0
	for i = 0, 9 do
		for _, owner in ipairs({1, 2}) do
			if bm.vehicles[owner .. "-" .. i].spawnQueue then n = n + 1 end
		end
	end
	return n
end

--== A6: far traffic stays queued ================================================

test("A6: 30 queued cars, 20 of them traffic beyond 1 km: the 10 near ones are built, the 20 far ones stay queued", function()
	local module = setup()
	module.onCareerActive(true)
	local failures = {}
	bm.check = everyFrameLooksQueued(failures)
	twentyFar()
	for i = 0, 9 do spawn("3-" .. i, 3, {at = 20 + 90 * i, traffic = i % 2 == 0}) end
	run(3.05)
	run(4)
	same(builtCount(), 10, "built")
	for i = 0, 9 do expect(isBuilt("3-" .. i), "near car 3-" .. i .. " built") end
	same(waitingFar(), 20, "far cars still in BeamMP's queue")
	same(framesWithTwo(), 0, "frames that built two cars")
	same(bm.counts[#bm.counts].spawns, 20, "the last count shows the held cars")
	noFailures(failures)
	run(20)
	same(builtCount(), 10, "built 20 s later")
end)

--== A7: a far car that comes near is built, nearest first =========================

test("A7: a held car whose BeamMP position moves to 900 m is built at the next pacing step, alone", function()
	local module = setup()
	module.onCareerActive(true)
	twentyFar()
	spawn("3-0", 3, {at = 100, traffic = true})
	run(3.05)
	run(2)
	same(builtCount(), 1, "the near car built")
	moveTo("2-4", 900)
	run(0.3)
	same(builtCount(), 2, "built after the move")
	same(bm.built[2].sid, "2-4", "the car that came near")
	run(5)
	same(builtCount(), 2, "built 5 s later")
end)

test("A7: three near cars at 50, 400 and 200 m are built nearest first", function()
	local module = setup()
	module.onCareerActive(true)
	spawn("1-0", 1, {at = 50})
	spawn("1-1", 1, {at = 400, traffic = true})
	spawn("1-2", 1, {at = 200, traffic = true})
	run(3.05)
	run(1)
	same(builtCount(), 3, "built")
	same(bm.built[1].sid, "1-0", "first")
	same(bm.built[2].sid, "1-2", "second")
	same(bm.built[3].sid, "1-1", "third")
end)

test("A7: the player drives toward the held cars: they are built nearest first, one per pacing step, while driving", function()
	local module = setup()
	module.onCareerActive(true)
	twentyFar()
	spawn("3-0", 3, {at = 100})
	run(3.05)
	same(builtCount(), 1, "the near car built")
	bm.slow = false
	-- The camera drives east at 100 m/s for 20 s: from 0 to 2000 m.
	for _ = 1, 20 do
		bm.camera.x = bm.camera.x + 100
		run(1)
	end
	-- Every car that came within 1 km of the drive is built, in the order it came near:
	-- 1-0 .. 1-7 (1500 .. 2900 m).
	same(waitingFar(), 12, "far cars still held after the drive")
	for i = 2, 9 do same(bm.built[i].sid, "1-" .. (i - 2), "car built " .. i .. "th") end
	-- A jump to 3450 m brings seven within 1 km at once: 1-8, 1-9 (3100, 3300 m) and
	-- 2-0 .. 2-4 (3500 .. 4300 m), built nearest first, one per pacing step.
	bm.camera.x = 3450
	run(2.5)
	same(waitingFar(), 5, "far cars still held after the jump")
	for i = 5, 9 do expect(bm.vehicles["2-" .. i].spawnQueue ~= nil, "2-" .. i .. " still held") end
	local order = {"2-0", "1-9", "2-1", "1-8", "2-2", "2-3", "2-4"}
	for i, sid in ipairs(order) do same(bm.built[9 + i].sid, sid, "car built " .. (9 + i) .. "th") end
	same(framesWithTwo(), 0, "frames that built two cars")
	for i = 3, #bm.built do
		local gap = bm.built[i].at - bm.built[i - 1].at
		expect(gap > 0.24, "gap before car " .. i .. ": " .. gap)
	end
end)

test("A7: a held car BeamMP has no position for yet is placed by its spawn data", function()
	local module = setup()
	module.onCareerActive(true)
	spawn("1-0", 1, {at = 3000, traffic = true, unplaced = true})
	spawn("1-1", 1, {at = 300, traffic = true, unplaced = true})
	spawn("1-2", 1, {at = 100})
	run(3.05)
	run(2)
	same(builtCount(), 2, "built")
	expect(isBuilt("1-1") and isBuilt("1-2"), "the near ones built")
	moveTo("1-0", 600)
	run(0.3)
	expect(isBuilt("1-0"), "built once its owner's packets place it near")
end)

test("A7: all queued cars far when BeamMP starts building: one that comes near later is still built", function()
	local module = setup()
	module.onCareerActive(true)
	twentyFar()
	run(3.05)
	run(5)
	same(builtCount(), 0, "built while all are far")
	same(bm.queueWaiting, false, "BeamMP's queue flag after its rule ran")
	moveTo("1-3", 800)
	run(0.3)
	same(builtCount(), 1, "built once near")
	same(bm.built[1].sid, "1-3", "the car that came near")
end)

test("A7: without a camera the player's car is where the distance is taken from", function()
	local module = setup()
	core_camera = nil
	local car = {getPosition = function() return vec3(5000, 0, 0) end}
	be = {getPlayerVehicleID = function() return 7 end, getObjectByID = function(_, id) return id == 7 and car or nil end}
	module.onCareerActive(true)
	spawn("1-0", 1, {at = 200, traffic = true})
	spawn("1-1", 1, {at = 4500, traffic = true})
	run(3.05)
	run(2)
	same(builtCount(), 1, "built")
	expect(isBuilt("1-1"), "the car near the player's car built")
end)

test("A7: a car no longer marked traffic leaves the hold and is built", function()
	local module = setup()
	module.onCareerActive(true)
	spawn("1-0", 1, {at = 4000, traffic = true})
	spawn("1-1", 1, {at = 100})
	run(3.05)
	run(2)
	same(builtCount(), 1, "built")
	bm.traffic["1-0"] = false
	run(0.3)
	expect(isBuilt("1-0"), "built once its owner took it out of traffic")
end)

--== A8: other players' own cars are built as today ===============================

test("A8: a player's own car at 5 km and a car with no known mark at 3 km are both built", function()
	local module = setup()
	module.onCareerActive(true)
	spawn("1-0", 1, {at = 5000, traffic = false})
	spawn("2-0", 2, {at = 3000})
	spawn("3-0", 3, {at = 2000, traffic = true})
	run(3.05)
	run(2)
	same(builtCount(), 2, "built")
	expect(isBuilt("1-0"), "the player's own car built")
	expect(isBuilt("2-0"), "the unmarked car built")
	expect(not isBuilt("3-0"), "the far traffic car held")
end)

test("A8: with no enabler to read marks from nothing is held", function()
	local module = setup()
	extensions.mileageEnabler = nil
	module.onCareerActive(true)
	twentyFar()
	run(3.05)
	run(6)
	same(builtCount(), 20, "built")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

--== T4: from world-ready, with the real enabler ====================================

-- spawnPacing and the real enabler; the enabler's server events are recorded.
local function setupJoin()
	globals()
	bm.serverEvents = {}
	function TriggerServerEvent(name, data) table.insert(bm.serverEvents, {name = name, data = data}) end
	local handlers = {}
	function AddEventHandler(name, fn) handlers[name] = fn end
	jsonEncode = function() return "{}" end
	MPConfig = {getNickname = function() return "joiner" end}
	extensions.core_input_actionFilter = {setGroup = function() end, addAction = function() end}
	worldReadyState = 0
	local enabler = dofile(ENABLER)
	enabler.onExtensionLoaded()
	extensions.mileageEnabler = enabler
	bm.enabler = enabler
	local pacing = dofile(SOURCE)
	return pacing, enabler, handlers
end

-- The game's world-ready steps, to every extension.
local function worldReady(pacing, enabler)
	for state = 1, 2 do
		worldReadyState = state
		enabler.onWorldReadyState(state)
		pacing.onWorldReadyState(state)
	end
end

local function sent(name)
	local n = 0
	for _, e in ipairs(bm.serverEvents) do if e.name == name then n = n + 1 end end
	return n
end

-- The server's answer to careerVehSyncRequested: every car's state, traffic marks included.
local function answerList(handlers)
	local list, parts = {}, {}
	for sid, mark in pairs(bm.traffic) do
		list[sid] = {active = true, traffic = mark}
		table.insert(parts, sid)
	end
	local text = "list:" .. table.concat(parts, ",")
	bm.json[text] = list
	handlers.rxCareerVehSync(text)
end

test("T4: world-ready 1 asks the server for every car's state; world-ready 2 does not ask again", function()
	local pacing, enabler = setupJoin()
	worldReadyState = 1
	enabler.onWorldReadyState(1)
	same(sent("careerVehSyncRequested"), 1, "car-state list requests at world-ready 1")
	worldReadyState = 2
	enabler.onWorldReadyState(2)
	same(sent("careerSyncRequested"), 1, "settings requests")
	same(sent("careerVehSyncRequested"), 1, "car-state list requests once world-ready 2 came")
end)

test("T4: off a server world-ready 1 asks for nothing; world-ready 2 still asks with the settings", function()
	local pacing, enabler = setupJoin()
	MPCoreNetwork.isMPSession = function() return false end
	worldReadyState = 1
	enabler.onWorldReadyState(1)
	same(sent("careerVehSyncRequested"), 0, "list requests at world-ready 1")
	worldReadyState = 2
	enabler.onWorldReadyState(2)
	same(sent("careerVehSyncRequested"), 1, "list requests at world-ready 2")
end)

-- Ten cars of players 1 to 3 with no mark yet: 1-0 .. 1-5 will be marked far traffic,
-- 2-0 (40 m) and 2-1 (3000 m) players' own cars, 3-0 (300 m) near traffic, 3-1 (150 m)
-- a player's own car.
local function tenUnmarked()
	for i = 0, 5 do spawn("1-" .. i, 1, {at = 2000 + 100 * i}) end
	spawn("2-0", 2, {at = 40})
	spawn("2-1", 2, {at = 3000})
	spawn("3-0", 3, {at = 300})
	spawn("3-1", 3, {at = 150})
end

local function markTen()
	for i = 0, 5 do bm.traffic["1-" .. i] = true end
	bm.traffic["2-0"], bm.traffic["2-1"], bm.traffic["3-0"], bm.traffic["3-1"] = false, false, true, false
end

test("T4 join race: 10 unmarked cars at world-ready 1, the list 0.8 s later marks 6 far traffic: none built before it, then the 4 others at once, nearest first", function()
	local pacing, enabler, handlers = setupJoin()
	bm.hasCar = false
	tenUnmarked()
	worldReadyState = 1
	enabler.onWorldReadyState(1)
	pacing.onWorldReadyState(1)
	local failures = {}
	bm.check = everyFrameLooksQueued(failures)
	run(0.8)
	same(builtCount(), 0, "built before the list came")
	noFailures(failures)
	markTen()
	answerList(handlers)
	local answeredAt = bm.now
	run(1.2)
	same(builtCount(), 4, "built after the list")
	local order = {"2-0", "3-1", "3-0", "2-1"}
	for i, sid in ipairs(order) do same(bm.built[i].sid, sid, "car built " .. i .. "th") end
	expect(bm.built[1].at - answeredAt < 2.5 * FRAME, "first car built " .. (bm.built[1].at - answeredAt) .. " s after the list")
	same(framesWithTwo(), 0, "frames that built two cars")
	worldReadyState = 2
	enabler.onWorldReadyState(2)
	pacing.onWorldReadyState(2)
	same(sent("careerVehSyncRequested"), 1, "list requests")
	run(3)
	same(builtCount(), 4, "built 3 s later")
	for i = 0, 5 do expect(bm.vehicles["1-" .. i].spawnQueue ~= nil, "1-" .. i .. " still held") end
end)

test("T4 join race: no list answer ever comes: after 5 s the unmarked cars build as before, nearest first", function()
	local pacing, enabler = setupJoin()
	bm.hasCar = false
	tenUnmarked()
	worldReady(pacing, enabler)
	run(4.9)
	same(builtCount(), 0, "built within 5 s of the request")
	run(3)
	same(builtCount(), 10, "built once the wait is over")
	same(bm.built[1].sid, "2-0", "the nearest first")
	same(bm.built[10].sid, "2-1", "the farthest last")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

--== a car built before its batched state ===========================================

-- The enabler alone, with another player's car 1-0 (game id 9) built on this game.
local function builtRemoteCar()
	local pacing, enabler, handlers = setupJoin()
	bm.enabler = nil
	local veh = {active = true}
	function veh:getActive() return self.active end
	function veh:setActive(on) self.active = on == 1 end
	function veh:queueLuaCommand() end
	be = {getObjectByID = function(_, id) return id == 9 and veh or nil end, getPlayerVehicleID = function() return -1 end}
	MPVehicleGE.isOwn = function() return false end
	MPVehicleGE.getServerVehicleID = function(id) return id == 9 and "1-0" or nil end
	bm.vehicles["1-0"] = {ownerID = 1, gameVehicleID = 9, isSpawned = true, position = vec3(0, 0, 0)}
	return enabler, handlers, veh
end

local function ticks(enabler, seconds)
	for _ = 1, math.floor(seconds / FRAME + 0.5) do enabler.onUpdate(FRAME) end
end

test("a car built 0.1 s before its batched state arrives asks for no list and takes the state", function()
	local enabler, handlers, veh = builtRemoteCar()
	enabler.onVehicleSpawned(9)
	ticks(enabler, 0.1)
	bm.json["one"] = {["1-0"] = {active = false, traffic = true}}
	handlers.rxCareerVehSync("one")
	same(veh.active, false, "the car's state applied")
	ticks(enabler, 3)
	same(sent("careerVehSyncRequested"), 0, "list requests")
end)

test("a state that never comes gives exactly one list request, 0.6 s after the car is built", function()
	local enabler = builtRemoteCar()
	enabler.onVehicleSpawned(9)
	ticks(enabler, 0.55)
	same(sent("careerVehSyncRequested"), 0, "list requests within 0.55 s")
	ticks(enabler, 0.1)
	same(sent("careerVehSyncRequested"), 1, "list requests at 0.65 s")
	ticks(enabler, 3)
	same(sent("careerVehSyncRequested"), 1, "list requests 3 s later")
end)

test("several cars built together without their states give one list request, within the second's limit", function()
	local enabler = builtRemoteCar()
	MPVehicleGE.getServerVehicleID = function(id) return "1-" .. id end
	for id = 1, 5 do enabler.onVehicleSpawned(id) end
	ticks(enabler, 3)
	same(sent("careerVehSyncRequested"), 1, "list requests")
end)

test("A6/T4: world-ready with no car of their own and 20 far traffic cars queued: none is built before the player comes near", function()
	local pacing, enabler, handlers = setupJoin()
	bm.hasCar = false
	twentyFar()
	spawn("3-0", 3, {at = 50})
	worldReady(pacing, enabler)
	answerList(handlers)
	local failures = {}
	bm.check = everyFrameLooksQueued(failures)
	run(10)
	same(builtCount(), 1, "built before the career starts")
	expect(isBuilt("3-0"), "the near car built")
	same(waitingFar(), 20, "far cars still queued")
	noFailures(failures)
	-- The career starts: the hold stays in place.
	pacing.onCareerActive(true)
	run(2)
	same(builtCount(), 1, "built after the career starts")
	-- The player is placed 1400 m east: 1-0 .. 1-4 (1500 .. 2300 m) come within 1 km.
	bm.camera.x = 1400
	run(2)
	same(builtCount(), 6, "built once the player is near some")
	for i = 0, 4 do same(bm.built[i + 2].sid, "1-" .. i, "car built " .. (i + 2) .. "th") end
	same(framesWithTwo(), 0, "frames that built two cars")
end)

test("A9/T4: an error inside the hold while 12 cars are held puts all 12 back in BeamMP's queue and BeamMP builds them", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 11 do spawn("1-" .. i, 1, {at = 2000 + 100 * i, traffic = true}) end
	spawn("2-0", 2, {at = 10})
	run(3.05)
	run(1)
	same(builtCount(), 1, "built before the error")
	bm.failMarks = true
	local ok, err = pcall(run, FRAME)
	expect(ok, "raised: " .. tostring(err))
	same(builtCount(), 13, "built once the hold failed")
	same(#waitingCars(), 0, "cars left in the queue")
	same(countLines(logs, "join pacing failed"), 1, "error lines")
	for sid, v in pairs(bm.vehicles) do same(v.position, bm.positions[sid], sid .. " place") end
	same(UI.updateQueue, bm.updateQueue, "UI.updateQueue")
	-- Pacing stays off until the next career start.
	bm.failMarks = false
	spawn("3-0", 3, {at = 5000, traffic = true})
	run(3.05)
	expect(isBuilt("3-0"), "a far car built by BeamMP while pacing is off")
	module.onCareerActive(true)
	spawn("4-0", 4, {at = 5000, traffic = true})
	run(4)
	expect(not isBuilt("4-0"), "held again after the next career start")
end)

test("A9: an error from BeamMP's vehicle list while cars are held hands them all back and BeamMP builds them", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 11 do spawn("1-" .. i, 1, {at = 2000 + 100 * i, traffic = true}) end
	run(3.05)
	run(1)
	same(builtCount(), 0, "built before the error")
	bm.failGetVehicles = true
	run(FRAME)
	bm.failGetVehicles = false
	run(FRAME)
	same(builtCount(), 12, "built")
	same(countLines(logs, "join pacing failed"), 1, "error lines")
end)

test("A9/T4: leaving the server with held cars hands them back to BeamMP's queue and leaves no hold installed", function()
	local pacing, enabler, handlers = setupJoin()
	for i = 0, 11 do spawn("1-" .. i, 1, {at = 2000 + 100 * i, traffic = true}) end
	worldReady(pacing, enabler)
	answerList(handlers)
	pacing.onCareerActive(true)
	run(5)
	same(builtCount(), 0, "built while held")
	pacing.onBeamMPServerLeave()
	enabler.onBeamMPServerLeave()
	same(MPVehicleGE.onPreRender, bm.original, "BeamMP's function back")
	same(bm.cached, bm.original, "the dispatcher calls BeamMP's function")
	same(UI.updateQueue, bm.updateQueue, "UI.updateQueue")
	same(#waitingCars(), 12, "cars back in BeamMP's queue")
	same(builtCount(), 0, "built while leaving")
	for sid, v in pairs(bm.vehicles) do
		same(v.isSpawned, false, sid .. " built flag")
		same(v.position, bm.positions[sid], sid .. " place")
	end
	-- A rejoin's world-ready holds again.
	bm.vehicles, bm.built = {}, {}
	bm.serverEvents = {}
	for i = 0, 2 do spawn("5-" .. i, 5, {at = 4000, traffic = true}) end
	spawn("5-3", 5, {at = 10})
	worldReady(pacing, enabler)
	same(sent("careerVehSyncRequested"), 1, "list requested again on the rejoin")
	answerList(handlers)
	bm.hasCar = false
	run(3)
	same(builtCount(), 1, "built on the rejoin")
	expect(isBuilt("5-3"), "the near car")
end)

test("A9: career stop with held cars hands them back and BeamMP builds them", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1, {at = 2000 + 100 * i, traffic = true}) end
	run(5)
	same(builtCount(), 0, "built while held")
	module.onCareerActive(false)
	same(builtCount(), 6, "built on career stop")
	same(MPVehicleGE.onPreRender, bm.original, "BeamMP's function back")
end)

test("T4: world-ready off a server wraps nothing", function()
	local module = setup({mp = false})
	module.onWorldReadyState(2)
	same(MPVehicleGE.onPreRender, bm.original, "MPVehicleGE.onPreRender")
end)

-- Later test files get the game's globals as they found them.
core_camera, be, mileageEnabler = nil, nil, nil
