-- mileage/spawnPacing.lua: when BeamMP starts building a joining player's queued cars,
-- it builds one, then the next every quarter second, instead of all of them in one frame.
--
-- The stand-in MPVehicleGE follows BeamMP 4.23.1's queue (MPVehicleGE.lua): a queued
-- spawn sets queueWaiting; onPreRender builds every waiting car (applyQueuedEvents) once
-- the player has been slow for queueApplyTimeout seconds, or at once with no car;
-- applyPlayerQueues builds one owner's waiting cars, and both send the queue count
-- (UI.updateQueue(getQueueCounts())) when they built something. After the queue,
-- onPreRender draws each car not built yet a marker: the queued colour while it has a
-- queued spawn, magenta without one; a name tag goes 1 m above a drawn marker. The game's
-- hook dispatcher caches the function it calls until extensions.hookUpdate drops the cache.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/spawnPacing.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local FRAME = 1 / 60

local logs, bm

local function newBeamMP(opts)
	opts = opts or {}
	bm = {vehicles = {}, built = {}, edits = {}, queueWaiting = false, timer = 0, slow = true, hasCar = true,
		applyTime = 3, now = 0, frame = 0, originalCalls = 0, cached = nil, meterBuilt = 0,
		settings = {enableBlobs = true, showBlobQueued = true, blobColorQueued = "#00ff00",
			highlightQueuedPlayers = false},
		marks = {}, tags = {}, spheres = {}, counts = {}, positions = {}}
	local M = {}
	bm.listCalls = 0
	function M.getVehicles()
		bm.listCalls = bm.listCalls + 1
		if bm.failGetVehicles or bm.listCalls == bm.failOnCall then error("vehicle list broke") end
		return bm.vehicles
	end
	local function getQueueCounts()
		local spawns, edits, players = 0, 0, {}
		for _, v in pairs(bm.vehicles) do
			if v.spawnQueue then
				spawns = spawns + 1
				if bm.settings.highlightQueuedPlayers then players[v.ownerID] = true end
			end
			if v.editQueue then
				edits = edits + 1
				if bm.settings.highlightQueuedPlayers then players[v.ownerID] = true end
			end
		end
		return spawns, edits, players
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
	-- The marker and name tag of every other player's car, as BeamMP draws them.
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
		bm.originalCalls = bm.originalCalls + 1
		if bm.queueWaiting then M.applyQueue(dt) end
		drawMarkers()
	end
	function M.applyQueue(dt)
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
	if opts.noPlayerQueues then M.applyPlayerQueues = nil end
	MPVehicleGE = M
	bm.original = M.onPreRender
	bm.cached = M.onPreRender
	return M
end

-- A spawn arriving from the server for another player's car, at its own place.
local function spawn(sid, owner)
	if not bm.vehicles[sid] then
		local n = 0
		for _ in pairs(bm.positions) do n = n + 1 end
		bm.positions[sid] = vec3(10 * n, 5, 2)
		bm.vehicles[sid] = {ownerID = owner, isSpawned = false, position = bm.positions[sid]}
	end
	bm.vehicles[sid].spawnQueue = {data = sid}
	bm.queueWaiting = true
end

local function setup(opts)
	opts = opts or {}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	vec3 = function(x, y, z) return {x = x, y = y, z = z} end
	ColorF = function(r, g, b, a) return {r = r, g = g, b = b, a = a} end
	newBeamMP(opts)
	settings = {getValue = function(key) return bm.settings[key] end}
	MPHelpers = {hex2rgb = function(hex)
		local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
		return {tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255}
	end}
	debugDrawer = {drawSphere = function(_, pos, radius, colour, useZ)
		if bm.failDraw then error("drawer broke") end
		table.insert(bm.spheres, {pos = pos, radius = radius, colour = colour, useZ = useZ})
	end}
	bm.updateQueue = function(spawns, edits, players)
		local owners = {}
		for owner in pairs(players or {}) do table.insert(owners, tostring(owner)) end
		table.sort(owners)
		table.insert(bm.counts, {frame = bm.frame, spawns = spawns, edits = edits, owners = table.concat(owners, ",")})
	end
	UI = {updateQueue = bm.updateQueue}
	extensions = {
		mileage_compat = dofile(COMPAT),
		hookUpdate = function(name) if name == "onPreRender" then bm.cached = MPVehicleGE.onPreRender end end,
		mileage_perfMeter = {built = function() bm.meterBuilt = bm.meterBuilt + 1 end},
	}
	return dofile(SOURCE)
end

-- Runs frames through the game's cached hook.
-- After each frame, `bm.check` (when set) looks at what it drew.
local function run(seconds)
	for _ = 1, math.floor(seconds / FRAME + 0.5) do
		bm.now = bm.now + FRAME
		bm.frame = bm.frame + 1
		bm.marks, bm.tags, bm.spheres = {}, {}, {}
		bm.cached(FRAME)
		if bm.check then bm.check() end
	end
end

local function waitingCars()
	local list = {}
	for sid, v in pairs(bm.vehicles) do
		if v.spawnQueue and not v.isLocal then table.insert(list, sid) end
	end
	table.sort(list)
	return list
end

local function isBuilt(sid)
	for _, b in ipairs(bm.built) do if b.sid == sid then return true end end
	return false
end

-- Each frame: every waiting car has one marker, in the queued colour (BeamMP's, or one
-- Mileage drew at its place, radius 1, green at half alpha), and its name tag 1 m above.
-- No car is left marked as built that was not, nor with its place moved.
local function everyFrameLooksQueued(failures)
	return function()
		for _, sid in ipairs(waitingCars()) do
			local v, place = bm.vehicles[sid], bm.positions[sid]
			local marks = {}
			for _, m in ipairs(bm.marks) do if m.sid == sid then table.insert(marks, m.colour) end end
			for _, sphere in ipairs(bm.spheres) do
				if sphere.pos.x == place.x and sphere.pos.y == place.y and sphere.pos.z == place.z then
					local c = sphere.colour
					local queued = sphere.radius == 1 and c.r == 0 and c.g == 1 and c.b == 0
						and math.abs(c.a - 127 / 255) < 1e-9
					table.insert(marks, queued and "queued" or "wrong sphere")
				end
			end
			local problem
			if #marks ~= 1 or marks[1] ~= "queued" then
				problem = "markers " .. table.concat(marks, "+")
			elseif bm.tags[sid] ~= place.z + 1 then
				problem = "name tag at " .. tostring(bm.tags[sid])
			end
			if problem then table.insert(failures, string.format("frame %d %s: %s", bm.frame, sid, problem)) end
		end
		for sid, v in pairs(bm.vehicles) do
			if v.isSpawned and not isBuilt(sid) then
				table.insert(failures, string.format("frame %d %s: marked as built", bm.frame, sid))
			end
			if bm.positions[sid] and v.position ~= bm.positions[sid] then
				table.insert(failures, string.format("frame %d %s: place moved", bm.frame, sid))
			end
		end
	end
end

local function noFailures(failures)
	same(#failures, 0, "frames wrong, first: " .. tostring(failures[1]))
end

local function builtCount() return #bm.built end

local function framesWithTwo()
	local perFrame, n = {}, 0
	for _, b in ipairs(bm.built) do
		perFrame[b.frame] = (perFrame[b.frame] or 0) + 1
		if perFrame[b.frame] == 2 then n = n + 1 end
	end
	return n
end

--== pacing ==================================================================

test("six queued cars: BeamMP's rule builds the first after 3 s, the rest follow one every quarter second", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(2.9)
	same(builtCount(), 0, "built before BeamMP's 3 s")
	run(0.2)
	same(builtCount(), 1, "built once BeamMP starts")
	local first = bm.built[1].at
	run(1.4)
	same(builtCount(), 6, "built 1.4 s later")
	same(framesWithTwo(), 0, "frames that built two cars")
	for i = 2, 6 do
		local gap = bm.built[i].at - bm.built[i - 1].at
		expect(gap > 0.24 and gap < 0.27, "gap before car " .. i .. ": " .. gap)
	end
	expect(bm.built[6].at - first < 1.3, "the last car within 1.3 s of the first")
	same(bm.meterBuilt, 6, "cars the meter heard of")
end)

test("while the player keeps driving fast nothing is built, as in BeamMP", function()
	local module = setup()
	module.onCareerActive(true)
	bm.slow = false
	for i = 0, 3 do spawn("1-" .. i, 1) end
	run(10)
	same(builtCount(), 0, "built while driving fast")
	bm.slow = true
	run(3.05)
	same(builtCount(), 1, "built once slow for 3 s")
end)

test("with no car of their own a joiner's game builds the waiting cars one every quarter second", function()
	local module = setup()
	module.onCareerActive(true)
	bm.hasCar = false
	for i = 0, 4 do spawn("2-" .. i, 2) end
	run(FRAME)
	same(builtCount(), 1, "built in the first frame")
	run(1.05)
	same(builtCount(), 5, "built after 1.05 s")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

test("cars of two players waiting together are all built, one at a time", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 2 do spawn("1-" .. i, 1) end
	for i = 0, 2 do spawn("3-" .. i, 3) end
	run(3.05)
	run(1.5)
	same(builtCount(), 6, "built")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

test("an edit of a car already built goes through with BeamMP's own rule and is never held", function()
	local module = setup()
	module.onCareerActive(true)
	bm.vehicles["1-9"] = {ownerID = 1, editQueue = "{}"}
	bm.queueWaiting = true
	for i = 0, 3 do spawn("1-" .. i, 1) end
	run(3.05)
	same(#bm.edits, 1, "edits applied when BeamMP starts")
	same(builtCount(), 1, "cars built with it")
end)

test("the player's own queued car is never held", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 3 do spawn("1-" .. i, 1) end
	bm.vehicles["0-0"] = {ownerID = 0, isLocal = true, spawnQueue = {data = "own"}}
	run(3.05)
	local ownBuilt = false
	for _, b in ipairs(bm.built) do if b.sid == "0-0" then ownBuilt = true end end
	expect(ownBuilt, "the own car was built when BeamMP started")
end)

test("a car removed while it waits is never built and the others still are", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 4 do spawn("1-" .. i, 1) end
	run(3.05)
	same(builtCount(), 1, "first car")
	bm.vehicles["1-3"] = nil
	run(1.5)
	same(builtCount(), 4, "built")
	for _, b in ipairs(bm.built) do expect(b.sid ~= "1-3", "the removed car was built") end
end)

test("a car spawned again while waiting is built once with its newest spawn", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 2 do spawn("1-" .. i, 1) end
	run(3.05)
	spawn("1-2", 1)
	run(1)
	same(builtCount(), 3, "built")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

--== the game's hook cache ===================================================

test("a dispatcher that cached BeamMP's function calls the wrap after it is put in place and BeamMP's after it is taken away", function()
	local module = setup()
	same(bm.cached, bm.original, "cached before")
	module.onCareerActive(true)
	expect(bm.cached ~= bm.original, "the dispatcher calls the wrap")
	same(bm.cached, MPVehicleGE.onPreRender, "the dispatcher calls what MPVehicleGE holds")
	module.onBeamMPServerLeave()
	same(MPVehicleGE.onPreRender, bm.original, "BeamMP's function back")
	same(bm.cached, bm.original, "the dispatcher calls BeamMP's function again")
end)

--== stepping aside ==========================================================

test("an error while building puts every queued car back, BeamMP builds them at once and pacing stays off", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(3.05)
	same(builtCount(), 1, "first car")
	bm.failGetVehicles = true
	local ok, err = pcall(run, FRAME)
	expect(ok, "did not raise: " .. tostring(err))
	bm.failGetVehicles = false
	run(FRAME)
	same(builtCount(), 6, "every waiting car built once pacing stopped")
	same(countLines(logs, "join pacing failed"), 1, "error lines")
	for i = 0, 3 do spawn("2-" .. i, 2) end
	run(3.05)
	same(builtCount(), 10, "a later join is built at once")
	module.onCareerActive(true)
	for i = 0, 3 do spawn("4-" .. i, 4) end
	run(3.05)
	same(builtCount(), 11, "paced again after the next career start")
end)

test("a vehicle list that fails right after BeamMP's call still puts every moved car back and pacing goes on", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 4 do spawn("1-" .. i, 1) end
	run(1)
	-- The frame's first list read moves four cars aside; the second, after BeamMP's call, fails.
	bm.failOnCall = bm.listCalls + 2
	run(FRAME)
	local waiting = 0
	for _, v in pairs(bm.vehicles) do if v.spawnQueue then waiting = waiting + 1 end end
	same(waiting, 5, "cars still queued after the failure")
	run(4)
	same(builtCount(), 5, "built")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

test("an error in BeamMP's own function puts the queued cars back and is raised as BeamMP's", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 3 do spawn("1-" .. i, 1) end
	local original = bm.original
	-- BeamMP's function fails once while three cars are moved aside.
	local fail = true
	MPVehicleGE.onPreRender = nil
	module.onBeamMPServerLeave()
	MPVehicleGE.onPreRender = function(dt)
		if fail then fail = false; error("BeamMP broke") end
		return original(dt)
	end
	bm.original = MPVehicleGE.onPreRender
	module.onCareerActive(true)
	local ok, err = pcall(run, FRAME)
	expect(not ok and tostring(err):find("BeamMP broke", 1, true), "BeamMP's error raised: " .. tostring(err))
	local waiting = 0
	for _, v in pairs(bm.vehicles) do if v.spawnQueue then waiting = waiting + 1 end end
	same(waiting, 4, "cars still queued")
end)

test("without MPVehicleGE.applyPlayerQueues the log says so once and BeamMP builds as before", function()
	local module = setup({noPlayerQueues = true})
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(MPVehicleGE.onPreRender, bm.original, "nothing wrapped")
	same(countLines(logs, "MPVehicleGE.applyPlayerQueues missing"), 1, "warnings")
	for i = 0, 3 do spawn("1-" .. i, 1) end
	run(3.05)
	same(builtCount(), 4, "built at once")
end)

test("leaving the server while cars wait lets BeamMP build them and puts its function back", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(3.05)
	module.onCareerActive(false)
	same(builtCount(), 6, "built when the career ended")
	same(MPVehicleGE.onPreRender, bm.original, "BeamMP's function back")
end)

-- Rejects pacing that stops at the cars it saw when building started, or that lets
-- BeamMP's own call and a paced release build in the same frame.
test("a player joining while cars are built one at a time has their cars built too, one per frame", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(3.05)
	same(builtCount(), 1, "first car")
	run(0.3)
	for i = 0, 2 do spawn("2-" .. i, 2) end
	run(4)
	same(builtCount(), 9, "built")
	same(framesWithTwo(), 0, "frames that built two cars")
end)

test("off a server nothing is wrapped", function()
	local module = setup({mp = false})
	module.onCareerActive(true)
	same(MPVehicleGE.onPreRender, bm.original, "MPVehicleGE.onPreRender")
end)

-- BeamMP applies a waiting car's spawn and then its edit; an edit applied to a car not
-- built yet is dropped and the car keeps its old parts.
test("an edit queued on a car still waiting is applied only once that car is built", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 2 do spawn("1-" .. i, 1) end
	bm.vehicles["1-2"].editQueue = '{"vcf":"new parts"}'
	bm.queueWaiting = true
	local editedBeforeBuilt = false
	for _ = 1, math.floor(5 / FRAME) do
		run(FRAME)
		local built, edited = false, false
		for _, b in ipairs(bm.built) do if b.sid == "1-2" then built = true end end
		for _, sid in ipairs(bm.edits) do if sid == "1-2" then edited = true end end
		if edited and not built then editedBeforeBuilt = true end
	end
	same(builtCount(), 3, "built")
	expect(not editedBeforeBuilt, "the edit of 1-2 was applied while it was still waiting")
	local edited = false
	for _, sid in ipairs(bm.edits) do if sid == "1-2" then edited = true end end
	expect(edited, "the edit of 1-2 was applied")
end)

test("a vehicle list that fails right after BeamMP built the first car still gets the rest built", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(2.99)
	same(builtCount(), 0, "built before BeamMP starts")
	-- Once BeamMP has built the first car, the next three list reads fail: the rest of
	-- that frame.
	local failuresLeft = 3
	local real = MPVehicleGE.getVehicles
	MPVehicleGE.getVehicles = function()
		if #bm.built >= 1 and failuresLeft > 0 then
			failuresLeft = failuresLeft - 1
			error("vehicle list broke")
		end
		return bm.vehicles
	end
	run(0.1)
	same(failuresLeft, 0, "list reads that failed")
	MPVehicleGE.getVehicles = real
	run(1)
	same(builtCount(), 6, "every car built")
	same(countLines(logs, "join pacing failed"), 1, "error lines")
end)

test("a failure before BeamMP starts building leaves BeamMP's own rule to build them", function()
	local module = setup()
	module.onCareerActive(true)
	bm.slow = false
	for i = 0, 3 do spawn("1-" .. i, 1) end
	run(1)
	bm.failGetVehicles = true
	run(FRAME)
	bm.failGetVehicles = false
	run(2)
	same(builtCount(), 0, "built while the player drives fast")
	bm.slow = true
	run(3.05)
	same(builtCount(), 4, "built by BeamMP's own rule, at once")
end)

test("the log says once that pacing is active", function()
	local module = setup()
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(countLines(logs, "join pacing active"), 1, "active lines")
end)

--== #141: waiting cars look queued =============================================

test("#141: six cars waiting: every waiting car shows one queued marker and its name tag 1 m up, every frame", function()
	local module = setup()
	module.onCareerActive(true)
	local failures = {}
	bm.check = everyFrameLooksQueued(failures)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(5)
	same(builtCount(), 6, "built")
	noFailures(failures)
end)

test("#141: with markers off or queued markers hidden nothing is drawn and no name tag moves", function()
	for _, key in ipairs({"enableBlobs", "showBlobQueued"}) do
		local module = setup()
		module.onCareerActive(true)
		bm.settings[key] = false
		local failures = {}
		bm.check = function()
			if #bm.spheres > 0 or #bm.marks > 0 then
				table.insert(failures, string.format("%s off, frame %d: markers drawn", key, bm.frame))
			end
			for sid, z in pairs(bm.tags) do
				if bm.positions[sid] and z ~= bm.positions[sid].z then
					table.insert(failures, string.format("%s off, frame %d %s: name tag at %s", key, bm.frame, sid, z))
				end
			end
		end
		for i = 0, 5 do spawn("1-" .. i, 1) end
		run(5)
		same(builtCount(), 6, key .. " off: built")
		noFailures(failures)
	end
end)

test("#141: a car removed while it waits is left as BeamMP had it, and the others still look queued", function()
	local module = setup()
	module.onCareerActive(true)
	local failures = {}
	bm.check = everyFrameLooksQueued(failures)
	for i = 0, 4 do spawn("1-" .. i, 1) end
	run(1)
	local removed = bm.vehicles["1-3"]
	bm.vehicles["1-3"] = nil
	run(4)
	same(removed.isSpawned, false, "the removed car's built flag")
	same(removed.position, bm.positions["1-3"], "the removed car's place")
	same(builtCount(), 4, "built")
	noFailures(failures)
end)

test("#141: a waiting car BeamMP already marked as built (a respawn) gets no marker and keeps its name tag", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 3 do spawn("1-" .. i, 1) end
	bm.vehicles["1-3"].isSpawned = true
	local drawnFor3, tagMoved = 0, false
	bm.check = function()
		local place = bm.positions["1-3"]
		for _, sphere in ipairs(bm.spheres) do if sphere.pos.x == place.x then drawnFor3 = drawnFor3 + 1 end end
		if bm.vehicles["1-3"].spawnQueue and bm.tags["1-3"] ~= place.z then tagMoved = true end
		if bm.vehicles["1-3"].isSpawned ~= true then tagMoved = true end
	end
	run(1)
	same(drawnFor3, 0, "markers drawn for the respawn")
	expect(not tagMoved, "the respawn's name tag or built flag changed")
end)

test("#141: without BeamMP's helpers, ColorF or the debug drawer no marker is drawn, one line says so, and pacing goes on", function()
	for _, missing in ipairs({"MPHelpers", "ColorF", "debugDrawer"}) do
		local module = setup()
		module.onCareerActive(true)
		_G[missing] = nil
		local failures = {}
		bm.check = function()
			for _, m in ipairs(bm.marks) do
				if m.colour ~= "queued" then table.insert(failures, missing .. " missing: BeamMP drew " .. m.colour) end
			end
			if #bm.spheres > 0 then table.insert(failures, missing .. " missing: Mileage drew a marker") end
			for sid, v in pairs(bm.vehicles) do
				if v.isSpawned and not isBuilt(sid) then table.insert(failures, missing .. " missing: " .. sid .. " marked as built") end
			end
		end
		for i = 0, 5 do spawn("1-" .. i, 1) end
		run(5)
		same(builtCount(), 6, missing .. " missing: built")
		same(framesWithTwo(), 0, missing .. " missing: frames that built two cars")
		same(countLines(logs, "queued markers"), 1, missing .. " missing: lines")
		noFailures(failures)
	end
end)

test("#141: an error drawing a marker stops pacing: BeamMP builds every car and none stays marked as built", function()
	local module = setup()
	module.onCareerActive(true)
	bm.failDraw = true
	for i = 0, 5 do spawn("1-" .. i, 1) end
	local ok, err = pcall(run, 3.1)
	expect(ok, "raised: " .. tostring(err))
	same(builtCount(), 6, "built by BeamMP's own rule")
	same(countLines(logs, "join pacing failed"), 1, "error lines")
	for sid, v in pairs(bm.vehicles) do
		same(v.position, bm.positions[sid], sid .. " place")
	end
end)

test("#141: a queued colour changed in BeamMP's settings during a join is used from the next frame", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(0.5)
	bm.settings.blobColorQueued = "#0000ff"
	run(FRAME)
	same(#bm.spheres, 5, "markers Mileage drew")
	for _, sphere in ipairs(bm.spheres) do
		local c = sphere.colour
		expect(c.r == 0 and c.g == 0 and c.b == 1, string.format("marker colour %s,%s,%s", c.r, c.g, c.b))
	end
end)

test("#141: a waiting car whose place moves keeps its marker and name tag over its new place", function()
	local module = setup()
	module.onCareerActive(true)
	local failures = {}
	bm.check = everyFrameLooksQueued(failures)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(0.5)
	for _, sid in ipairs(waitingCars()) do bm.positions[sid].z = bm.positions[sid].z + 4 end
	run(0.5)
	noFailures(failures)
end)

--== #141: the waiting count ====================================================

-- Counts sent to BeamMP's UI, per frame, checked against the cars waiting after it.
local function everyCountComplete(failures)
	local seen = 0
	return function()
		local inFrame = 0
		for i = seen + 1, #bm.counts do
			local c = bm.counts[i]
			inFrame = inFrame + 1
			local waiting = #waitingCars()
			if c.spawns ~= waiting then
				table.insert(failures, string.format("frame %d: count %d with %d waiting", bm.frame, c.spawns, waiting))
			end
		end
		if inFrame > 1 then table.insert(failures, string.format("frame %d: %d counts sent", bm.frame, inFrame)) end
		seen = #bm.counts
		if UI.updateQueue ~= bm.updateQueue then
			table.insert(failures, string.format("frame %d: UI.updateQueue is not BeamMP's", bm.frame))
		end
	end
end

test("#141: six cars waiting: each count sent while they are built shows every car still to come, once a frame", function()
	local module = setup()
	module.onCareerActive(true)
	local failures = {}
	bm.check = everyCountComplete(failures)
	for i = 0, 5 do spawn("1-" .. i, 1) end
	run(2.9)
	same(#bm.counts, 0, "counts sent before BeamMP builds anything")
	run(2)
	same(builtCount(), 6, "built")
	same(#bm.counts, 6, "counts sent, one per car built")
	same(bm.counts[1].spawns, 5, "the first count")
	same(bm.counts[6].spawns, 0, "the last count")
	noFailures(failures)
end)

test("#141: the count includes held cars' queued edits and, with queued players highlighted, their owners", function()
	local module = setup()
	module.onCareerActive(true)
	bm.settings.highlightQueuedPlayers = true
	for i = 0, 2 do spawn("1-" .. i, 1) end
	for i = 0, 1 do spawn("2-" .. i, 2) end
	bm.vehicles["2-1"].editQueue = "{}"
	run(3.05)
	same(builtCount(), 1, "built")
	local c = bm.counts[#bm.counts]
	same(c.spawns, 4, "spawns counted")
	same(c.edits, 1, "edits counted")
	same(c.owners, "1,2", "owners listed")
end)

test("#141: UI.updateQueue is BeamMP's again after an error in BeamMP's call, and after pacing is removed", function()
	local module = setup()
	module.onCareerActive(true)
	for i = 0, 3 do spawn("1-" .. i, 1) end
	local original = bm.original
	module.onBeamMPServerLeave()
	local fail = true
	MPVehicleGE.onPreRender = function(dt)
		if fail then fail = false; UI.updateQueue(0, 0); error("BeamMP broke") end
		return original(dt)
	end
	bm.original = MPVehicleGE.onPreRender
	module.onCareerActive(true)
	local ok = pcall(run, FRAME)
	expect(not ok, "BeamMP's error raised")
	same(UI.updateQueue, bm.updateQueue, "UI.updateQueue after BeamMP's error")
	same(bm.counts[#bm.counts].spawns, 4, "the count sent once the cars were back")
	module.onCareerActive(true)
	run(3.05)
	module.onCareerActive(false)
	same(UI.updateQueue, bm.updateQueue, "UI.updateQueue after pacing is removed")
end)
