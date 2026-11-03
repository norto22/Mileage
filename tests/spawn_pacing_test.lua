-- mileage/spawnPacing.lua: when BeamMP starts building a joining player's queued cars,
-- it builds one, then the next every quarter second, instead of all of them in one frame.
--
-- The stand-in MPVehicleGE follows BeamMP 4.23.1's queue (MPVehicleGE.lua): a queued
-- spawn sets queueWaiting; onPreRender builds every waiting car (applyQueuedEvents) once
-- the player has been slow for queueApplyTimeout seconds, or at once with no car;
-- applyPlayerQueues builds one owner's waiting cars. The game's hook dispatcher caches
-- the function it calls until extensions.hookUpdate drops the cache.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/spawnPacing.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local FRAME = 1 / 60

local logs, bm

local function newBeamMP(opts)
	opts = opts or {}
	bm = {vehicles = {}, built = {}, edits = {}, queueWaiting = false, timer = 0, slow = true, hasCar = true,
		applyTime = 3, now = 0, frame = 0, originalCalls = 0, cached = nil, meterBuilt = 0}
	local M = {}
	bm.listCalls = 0
	function M.getVehicles()
		bm.listCalls = bm.listCalls + 1
		if bm.failGetVehicles or bm.listCalls == bm.failOnCall then error("vehicle list broke") end
		return bm.vehicles
	end
	local function applyVehicleQueues(sid, v)
		if v.spawnQueue then
			v.spawnQueue = nil
			table.insert(bm.built, {sid = sid, at = bm.now, frame = bm.frame})
		end
		if v.editQueue then
			v.editQueue = nil
			table.insert(bm.edits, sid)
		end
	end
	function M.applyQueuedEvents()
		for sid, v in pairs(bm.vehicles) do
			if v.spawnQueue or v.editQueue then applyVehicleQueues(sid, v) end
		end
		bm.queueWaiting = false
	end
	function M.applyPlayerQueues(playerID)
		local empty = true
		for sid, v in pairs(bm.vehicles) do
			if v.spawnQueue or v.editQueue then
				if v.ownerID == playerID then applyVehicleQueues(sid, v) else empty = false end
			end
		end
		if empty then bm.queueWaiting = false end
	end
	function M.onPreRender(dt)
		bm.originalCalls = bm.originalCalls + 1
		if not bm.queueWaiting then return end
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

-- A spawn arriving from the server for another player's car.
local function spawn(sid, owner)
	bm.vehicles[sid] = bm.vehicles[sid] or {ownerID = owner}
	bm.vehicles[sid].spawnQueue = {data = sid}
	bm.queueWaiting = true
end

local function setup(opts)
	opts = opts or {}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	newBeamMP(opts)
	extensions = {
		mileage_compat = dofile(COMPAT),
		hookUpdate = function(name) if name == "onPreRender" then bm.cached = MPVehicleGE.onPreRender end end,
		mileage_perfMeter = {built = function() bm.meterBuilt = bm.meterBuilt + 1 end},
	}
	return dofile(SOURCE)
end

-- Runs frames through the game's cached hook.
local function run(seconds)
	for _ = 1, math.floor(seconds / FRAME + 0.5) do
		bm.now = bm.now + FRAME
		bm.frame = bm.frame + 1
		bm.cached(FRAME)
	end
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

test("off a server nothing is wrapped", function()
	local module = setup({mp = false})
	module.onCareerActive(true)
	same(MPVehicleGE.onPreRender, bm.original, "MPVehicleGE.onPreRender")
end)

test("the log says once that pacing is active", function()
	local module = setup()
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(countLines(logs, "join pacing active"), 1, "active lines")
end)
