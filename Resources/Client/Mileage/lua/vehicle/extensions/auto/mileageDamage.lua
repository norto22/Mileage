--Mileage :: damage between players (VEHICLE)
--
-- BeamMP sends where another player's car is, never its dents, so every game simulated
-- its own damage on its copy of that car. This extension runs in every car and does one
-- of two jobs, set by mileage_damageSync in the game-engine Lua:
--
--   * owner: in the player's own cars (not traffic or parked), every half second while
--     the game's damage total moves, it sends the beams whose rest length or broken
--     state changed since its last message, with no points: a point is only where it is
--     on the owner's car, and on a copy whose wheels have turned and panels swing
--     differently a point moved there pops tyres and pulls latches apart.
--   * copy: in another player's car, it applies such a message: rest lengths set, broken
--     beams broken, deformation recorded, so the copy reshapes itself from its beams.
--     Points an older owner still sends with them are left alone.
--
-- A full send (a new owner's to everyone, or an answer to a copy built late or resynced,
-- flagged so the server passes it only to the players who asked) carries the car's whole
-- shape: every changed beam and every point, in the car's own frame (right, forward, up
-- from its reference node), from one moment, in numbered parts. The
-- copy applies it only once every part is in, the way the game restores a saved damaged
-- car (beamstate.load): every point, every beam, then one commit, so no beam is stretched
-- between moved and unmoved points.
--
-- The owner wins: a copy that disagrees with what its owner reported on any beam (broken,
-- or more than 5 mm off) for two checks in a row (damage only this game simulated) is
-- reset in place and given the owner's full damage. An owner's reset or repair sends a
-- cleared notice.
--
-- Every value from a message is checked against this car before it is used.

local M = {}

local SEND_EVERY_SECONDS = 0.5
local MAX_BEAMS = 400            -- per message
local MAX_NODES = 500            -- per part of a whole shape; keeps it under the 32 KB cap
local LENGTH_CHANGED = 0.001     -- metres of rest length that count as a change
local MAX_LENGTH = 100           -- metres; a rest length beyond this is refused
-- Metres from the reference node; further is refused. A whole shape places every point, a
-- part torn off and flung away included.
local MAX_SHAPE_OFFSET = 1000
local MAX_DEFORM = 10            -- deformation ratio; larger is refused
local MAX_PARTS = 64             -- numbered parts of one whole shape
local SET_WAIT_SECONDS = 5       -- a copy drops a set with no new part for this long

-- Owner wins: once a second a copy counts beams that disagree with what the owner
-- reported; with any beam off on two checks in a row it is reset in place and given
-- the owner's full damage, at most once every RESYNC_COOLDOWN seconds. A copy's
-- physics jitters by a few millimetres, so a beam counts from RESYNC_LENGTH off.
local CHECK_EVERY_SECONDS = 1
local RESYNC_BEAMS = 0
local RESYNC_LENGTH = 0.005      -- metres off the reported rest length
local RESYNC_CHECKS = 2
local RESYNC_COOLDOWN = 10

local abs, sqrt, floor = math.abs, math.sqrt, math.floor
local huge = math.huge

local role = nil                 -- "owner", "copy" or nil

-- Owner: rest length of each beam as built, what was last sent for each beam
-- ({len, broken}), and what is still to send.
local baseline = {}
-- Beams whose rest length the game changes on its own: hydraulics (steering and the
-- like), beams that settle just after spawn, and beams of controllers that set lengths
-- (hydraulic suspension, beam chains and segments, googly eyes). Only their breaks are
-- sent, compared and applied; their lengths are left to each game.
local lengthIgnored = {}
local sent = {}
local lastDamage = nil
local sinceSend = 0
local moreToSend = false
-- A full send still to start: "all" for every player, "answer" for the players who asked
-- (its parts are flagged and the server sends them only to those players). A full send
-- for everyone covers an answer; an answer asked for while one is being sent follows it.
local fullWanted = nil
local fullParts, fullNext, fullAnswer = nil, 1, false
local tooManyPartsLogged = false
local answerAfter = false
local answerChunkLast = false    -- the last tick sent a chunk of an answer
local clearedPending = false

-- Copy: the owner's last reported state of each beam ({len, broken}), and whether the
-- owner has been heard from at all.
local reported = {}
local heard = false
local refusedLogged = false
local sinceCheck = 0
local checksOver = 0
local sinceResync = huge
-- The copy is read only when something could have changed: its damage total moved, a
-- report arrived, or it disagreed last time.
local checkedDamage, lastCount, reportsChanged = nil, 0, false
-- A whole shape still arriving ({total, parts = {{beams, nodes}, ...}, quiet = seconds
-- since its latest part}), and ordinary dents that arrived meanwhile, newer than it.
local pendingSet = nil
local heldDents = {}

--== the car's own frame ======================================================

-- Origin at the reference node, right/forward/up unit vectors from the car's direction.
local function carFrame()
	local refNodes = v.data.refNodes and v.data.refNodes[0]
	local ref = refNodes and refNodes.ref or 0
	local o = obj:getNodePosition(ref)
	local f = obj:getDirectionVector()
	local u = obj:getDirectionVectorUp()
	if not (o and f and u) then return nil end
	local rx, ry, rz = f.y * u.z - f.z * u.y, f.z * u.x - f.x * u.z, f.x * u.y - f.y * u.x
	local rl = sqrt(rx * rx + ry * ry + rz * rz)
	local fl = sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
	if rl < 1e-6 or fl < 1e-6 then return nil end
	rx, ry, rz = rx / rl, ry / rl, rz / rl
	local fx, fy, fz = f.x / fl, f.y / fl, f.z / fl
	local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
	return {ox = o.x, oy = o.y, oz = o.z, rx = rx, ry = ry, rz = rz, fx = fx, fy = fy, fz = fz,
		ux = ux, uy = uy, uz = uz}
end

local function toCarFrame(fr, p)
	local dx, dy, dz = p.x - fr.ox, p.y - fr.oy, p.z - fr.oz
	return dx * fr.rx + dy * fr.ry + dz * fr.rz,
		dx * fr.fx + dy * fr.fy + dz * fr.fz,
		dx * fr.ux + dy * fr.uy + dz * fr.uz
end

local function fromCarFrame(fr, lx, ly, lz)
	return vec3(fr.ox + fr.rx * lx + fr.fx * ly + fr.ux * lz,
		fr.oy + fr.ry * lx + fr.fy * ly + fr.uy * lz,
		fr.oz + fr.rz * lx + fr.fz * ly + fr.uz * lz)
end

--== owner ===================================================================

local function isBroken(cid)
	return obj:beamIsBroken(cid) and true or false
end

local function captureBaseline()
	baseline, lengthIgnored = {}, {}
	for _, beam in pairs(v.data.beams or {}) do
		if beam.cid then
			baseline[beam.cid] = obj:getBeamRestLength(beam.cid)
			if type(beam.beamPrecompressionTime) == "number" and beam.beamPrecompressionTime > 0 then
				lengthIgnored[beam.cid] = true
			end
		end
	end
	for _, hydro in pairs(v.data.hydros or {}) do
		if hydro.beamCID then lengthIgnored[hydro.beamCID] = true end
	end
	-- The game's controllers that set beam lengths themselves (BeamNG.drive 0.40.4.0,
	-- lua/vehicle/controller): hydraulic suspension names its beams, the others tag them.
	local names, tags = {}, {}
	for _, c in pairs(v.data.controller or {}) do
		if c.fileName == "hydraulicSuspension" then
			for _, h in pairs(v.data[c.hydraulicBeams or "hydraulicsData"] or {}) do
				if type(h) == "table" and h.beamName then names[h.beamName] = true end
			end
		elseif c.fileName == "mechanics/beamChain" then
			if c.beamTag then tags[c.beamTag] = true end
		elseif c.fileName == "mechanics/beamSegments" then
			if c.segmentBeamTag then tags[c.segmentBeamTag] = true end
			if c.sensorBeamTag then tags[c.sensorBeamTag] = true end
		elseif c.fileName == "propAnimation/googlyEyes" then
			tags[c.eyeBeamTag or "eyeBeam"] = true
			tags[c.eyeLimiterBeamTag or "eyeLimiterBeam"] = true
			tags[c.eyeAttachmentBeamTag or "eyeAttachmentBeam"] = true
		end
	end
	if next(names) == nil and next(tags) == nil then return end
	for _, beam in pairs(v.data.beams or {}) do
		local tagged = false
		if type(beam.tag) == "table" then
			for _, t in pairs(beam.tag) do tagged = tagged or tags[t] == true end
		else
			tagged = beam.tag ~= nil and tags[beam.tag] == true
		end
		if beam.cid and (tagged or (beam.name and names[beam.name])) then lengthIgnored[beam.cid] = true end
	end
end

-- true when a beam's rest length is more than `tolerance` off refLen and counts.
local function lengthOff(cid, len, refLen, tolerance)
	return not lengthIgnored[cid] and abs(len - refLen) > tolerance
end

local function sentState(cid)
	local s = sent[cid]
	if s then return s.len, s.broken end
	return baseline[cid], false
end

local function builtState(cid)
	return baseline[cid], false
end

-- Beam ids whose rest length or broken state differ from `against`, in id order.
local function changedBeams(against)
	local list = {}
	for _, beam in pairs(v.data.beams or {}) do
		local cid = beam.cid
		if cid then
			local len = obj:getBeamRestLength(cid)
			local refLen, refBroken = against(cid)
			if len and refLen and (lengthOff(cid, len, refLen, LENGTH_CHANGED) or isBroken(cid) ~= refBroken) then
				table.insert(list, cid)
			end
		end
	end
	table.sort(list)
	return list
end

local function beamRow(cid)
	local len, broken = obj:getBeamRestLength(cid), isBroken(cid)
	local deform = beamstate.deformedBeams and beamstate.deformedBeams[cid] or 0
	return string.format("%d,%.4f,%d,%.3f", cid, len, broken and 1 or 0, deform), len, broken
end

local function pointRow(fr, n)
	local lx, ly, lz = toCarFrame(fr, obj:getNodePosition(n))
	return string.format("%d,%.3f,%.3f,%.3f", n, lx, ly, lz)
end

-- One message of ordinary dents from list[first..]: at most MAX_BEAMS beams and no
-- points (an empty list, which older copies still expect). Returns the message and the
-- index of the first beam it left out.
local function packMessage(list, first)
	local beams = {}
	local i = first
	while i <= #list and #beams < MAX_BEAMS do
		local cid = list[i]
		local row, len, broken = beamRow(cid)
		table.insert(beams, row)
		sent[cid] = {len = len, broken = broken}
		i = i + 1
	end
	return '{"c":0,"b":[' .. table.concat(beams, ",") .. '],"n":[]}', i
end

local function slice(rows, first, last)
	return table.concat(rows, ",", first, math.min(last, #rows))
end

-- The car's whole shape at this moment, as numbered messages: every beam changed since
-- the car was built and every point of the car, at most MAX_BEAMS beams and MAX_NODES
-- points a part, so a copy can apply it all at once with no seam between moved and
-- unmoved points. An answer (flagged) reaches only the players who asked, so it leaves
-- `sent`, what every player has, as it was. Returns {} for an undamaged car, nil while
-- the car's frame cannot be read, false for a car too big for MAX_PARTS parts.
local function wholeShape(flagged)
	local fr = carFrame()
	if not fr then return nil end
	local list = changedBeams(builtState)
	if #list == 0 then return {} end
	local pointIds = {}
	for n in pairs(v.data.nodes or {}) do table.insert(pointIds, n) end
	table.sort(pointIds)
	local parts = math.max(math.ceil(#list / MAX_BEAMS), math.ceil(#pointIds / MAX_NODES))
	if parts > MAX_PARTS then
		if not tooManyPartsLogged then
			tooManyPartsLogged = true
			log("W", "mileage.damage", string.format("this car's damage needs %d parts (limit %d) and is not sent whole", parts, MAX_PARTS))
		end
		return false
	end
	local beams, points = {}, {}
	for k, cid in ipairs(list) do
		local row, len, broken = beamRow(cid)
		beams[k] = row
		if not flagged then sent[cid] = {len = len, broken = broken} end
	end
	for k, n in ipairs(pointIds) do points[k] = pointRow(fr, n) end
	local messages = {}
	for p = 1, parts do
		messages[p] = string.format('%s"c":0,"p":%d,"t":%d,"b":[%s],"n":[%s]}', flagged and '{"f":1,' or '{', p, parts,
			slice(beams, (p - 1) * MAX_BEAMS + 1, p * MAX_BEAMS), slice(points, (p - 1) * MAX_NODES + 1, p * MAX_NODES))
	end
	return messages
end

local function send(message)
	obj:queueGameEngineLua(string.format("mileage_damageSync.onLocalDamage(%d,%q)", obj:getID(), message))
end

local function forgetSent()
	sent = {}
	moreToSend = false
	fullParts = nil
end

-- One message per half-second tick: a cleared notice first, then a full-damage answer,
-- then the beams changed since the last message.
local function ownerTick()
	local damage = beamstate.damage or 0
	if lastDamage and lastDamage > 0 and damage <= 0 then
		-- The game's damage total drops to nothing only on a reset or repair.
		forgetSent()
		clearedPending = true
	end

	if clearedPending then
		clearedPending = false
		forgetSent()
		lastDamage = damage
		send('{"c":1,"b":[],"n":[]}')
		return
	end

	if fullWanted then
		local parts = wholeShape(fullWanted == "answer")
		-- No frame to measure the points in yet: the next tick tries again.
		if parts == nil then return end
		fullAnswer = fullWanted == "answer"
		if not fullAnswer then answerAfter = false end
		fullWanted = nil
		-- false: too big to send whole, so nothing is sent and copies keep what they have.
		fullParts, fullNext = parts or nil, 1
		if parts and #parts == 0 then
			-- An undamaged car still answers, so the copy knows its owner is listening.
			fullParts = nil
			send(fullAnswer and '{"f":1,"c":0,"b":[],"n":[]}' or '{"c":0,"b":[],"n":[]}')
			return
		end
	end
	-- An answer reaches only the players who asked, so while one is being sent, changes
	-- for everyone go out every other tick instead of waiting for it to end.
	local changesWaiting = damage ~= lastDamage or moreToSend
	if fullParts and not (fullAnswer and changesWaiting and answerChunkLast) then
		send(fullParts[fullNext])
		fullNext = fullNext + 1
		answerChunkLast = fullAnswer
		if fullNext > #fullParts then
			fullParts = nil
			answerChunkLast = false
			-- Beams sent early in the transfer may have changed since, and an answer's
			-- beams reached only who asked: compare again.
			moreToSend = true
			if answerAfter then
				answerAfter = false
				fullWanted = "answer"
			end
		end
		-- A full send for everyone carries the changes; an answer does not.
		if not fullAnswer then lastDamage = damage end
		return
	end
	answerChunkLast = false

	if damage == lastDamage and not moreToSend then return end
	lastDamage = damage
	local list = changedBeams(sentState)
	if #list == 0 then
		moreToSend = false
		return
	end
	local message, nextIndex = packMessage(list, 1)
	if message then send(message) end
	moreToSend = nextIndex <= #list
end

--== copy ====================================================================

-- Beams on this copy whose physical state disagrees with what the owner reported (or,
-- for a beam it never reported, with the car as built): broken here while reported whole,
-- or more than RESYNC_LENGTH off the rest length. Every beam is read, because the game's
-- damage tracker lists only beams with deform triggers. Stops counting past `limit`.
-- `tolerance` defaults to RESYNC_LENGTH.
local function disagreeingBeams(limit, tolerance)
	tolerance = tolerance or RESYNC_LENGTH
	local count = 0
	for _, beam in pairs(v.data.beams or {}) do
		local cid = beam.cid
		local r = cid and reported[cid]
		local refLen, refBroken = baseline[cid], false
		if r then refLen, refBroken = r.len, r.broken end
		if refLen then
			if obj:beamIsBroken(cid) then
				if not refBroken then count = count + 1 end
			else
				local len = obj:getBeamRestLength(cid)
				if len and lengthOff(cid, len, refLen, tolerance) then count = count + 1 end
			end
			if limit and count > limit then return count end
		end
	end
	return count
end

local function isNumber(x)
	return type(x) == "number" and x == x and x > -huge and x < huge
end

local function isId(x)
	return isNumber(x) and x >= 0 and x == floor(x)
end

local function refused(what)
	if refusedLogged then return end
	refusedLogged = true
	log("W", "mileage.damage", "refused part of another player's damage message: " .. what)
end

-- Why a point row {id, x, y, z} of a whole shape, in the car's own frame, cannot be
-- used, or nil.
local function pointProblem(cid, x, y, z)
	if not (isId(cid) and v.data.nodes[cid]) then return "unknown point " .. tostring(cid) end
	if not (isNumber(x) and isNumber(y) and isNumber(z) and abs(x) <= MAX_SHAPE_OFFSET
			and abs(y) <= MAX_SHAPE_OFFSET and abs(z) <= MAX_SHAPE_OFFSET) then
		return "point offset out of range"
	end
	return nil
end

-- Why a beam row {id, rest length, broken 0/1, deformation} cannot be used, or nil.
local function beamProblem(cid, len, broken, deform)
	if not (isId(cid) and v.data.beams[cid]) then return "unknown beam " .. tostring(cid) end
	if not (isNumber(len) and len > 0 and len <= MAX_LENGTH) then return "rest length out of range" end
	if not (broken == 0 or broken == 1) then return "broken flag not 0 or 1" end
	if not (isNumber(deform) and deform >= 0 and deform <= MAX_DEFORM) then return "deformation out of range" end
	return nil
end

-- nodes is {id, x, y, z, ...} in the car's own frame; a row that cannot be used is skipped.
local function placePoints(fr, nodes)
	for i = 1, #nodes - 3, 4 do
		local cid, x, y, z = nodes[i], nodes[i + 1], nodes[i + 2], nodes[i + 3]
		local problem = pointProblem(cid, x, y, z)
		if problem then
			refused(problem)
		else
			obj:setNodePosition(cid, fromCarFrame(fr, x, y, z))
		end
	end
end

-- beams is {id, rest length, broken 0/1, deformation, ...}; a row that cannot be used is
-- skipped.
local function setBeams(beams)
	for i = 1, #beams - 3, 4 do
		local cid, len, broken, deform = beams[i], beams[i + 1], beams[i + 2], beams[i + 3]
		local problem = beamProblem(cid, len, broken, deform)
		if problem then
			refused(problem)
		else
			if not lengthIgnored[cid] then obj:setBeamLength(cid, len) end
			if broken == 1 and not obj:beamIsBroken(cid) then obj:breakBeam(cid) end
			if deform > 0 and not beamstate.deformedBeams[cid] then beamstate.onBeamDeformed(cid, deform) end
			reported[cid] = {len = len, broken = broken == 1}
			reportsChanged = true
		end
	end
end

-- Why a whole set cannot be applied as one shape, or nil: any row it cannot use.
local function setProblem(set)
	for p = 1, set.total do
		local beams, nodes = set.parts[p][1], set.parts[p][2]
		for i = 1, #nodes - 3, 4 do
			local problem = pointProblem(nodes[i], nodes[i + 1], nodes[i + 2], nodes[i + 3])
			if problem then return problem end
		end
		for i = 1, #beams - 3, 4 do
			local problem = beamProblem(beams[i], beams[i + 1], beams[i + 2], beams[i + 3])
			if problem then return problem end
		end
	end
	return nil
end

local function applyHeldDents()
	local held = heldDents
	heldDents = {}
	for _, beams in ipairs(held) do setBeams(beams) end
end

-- An incomplete set is never applied: the copy is still waiting for the owner's answer
-- and asks again. Dents held for it are newer than what the car has, so they go on now.
local function dropSet()
	pendingSet = nil
	applyHeldDents()
end

-- Every part is in: the whole shape goes on the way the game restores a saved damaged
-- car (beamstate.load), every point, then every beam, then one commit, so no beam is
-- stretched between moved and unmoved points. A set with any row the copy cannot use is
-- not applied at all, so the copy never reports a shape it applied only in part.
local function applySet()
	local fr = carFrame()
	if not fr then return dropSet() end
	local problem = setProblem(pendingSet)
	if problem then
		refused(problem)
		return dropSet()
	end
	local set = pendingSet
	pendingSet = nil
	reported = {}
	for p = 1, set.total do placePoints(fr, set.parts[p][2]) end
	for p = 1, set.total do setBeams(set.parts[p][1]) end
	obj:commitLoad()
	reportsChanged = true
	obj:queueGameEngineLua(string.format("mileage_damageSync.shapeApplied(%d)", obj:getID()))
	applyHeldDents()
end

-- Part `part` of `parts` of the owner's whole shape. Parts arrive in order; one out of
-- order means one was lost.
local function receivePart(beams, nodes, part, parts)
	if not (isId(part) and isId(parts) and part >= 1 and part <= parts and parts <= MAX_PARTS) then
		refused("part number")
		return
	end
	if part == 1 then
		if pendingSet then dropSet() end
		pendingSet = {total = parts, parts = {}, quiet = 0}
	elseif not (pendingSet and pendingSet.total == parts and #pendingSet.parts == part - 1) then
		if pendingSet then dropSet() end
		return
	end
	pendingSet.parts[part] = {beams, nodes}
	pendingSet.quiet = 0
	if part == parts then applySet() end
end

-- Applies the owner's damage: beams is {id, rest length, broken 0/1, deformation, ...},
-- nodes {id, x, y, z, ...} in the car's own frame. cleared = 1 when the owner reset or
-- repaired the car. part and parts number a part of the owner's whole shape, the only
-- message whose points are placed: ordinary dents set their beams as they come.
local function applyDamage(cleared, beams, nodes, part, parts)
	if role ~= "copy" then return end
	heard = true
	if cleared == 1 then
		-- The owner reset or repaired the car: a set or dents still arriving are older.
		pendingSet, heldDents = nil, {}
		-- A broken beam cannot be mended in place, so a copy with any damage (judged
		-- against the car as built) is reset too.
		reported = {}
		reportsChanged = true
		-- Any change from the car as built counts here, however small: after a repair the
		-- owner's car has none, so neither may the copy.
		if disagreeingBeams(0, LENGTH_CHANGED) > 0 then
			obj:queueGameEngineLua(string.format("mileage_damageSync.resetCopy(%d,0)", obj:getID()))
		end
		return
	end
	if type(beams) ~= "table" or type(nodes) ~= "table" then return end
	if part ~= nil or parts ~= nil then
		receivePart(beams, nodes, part, parts)
	elseif pendingSet then
		table.insert(heldDents, beams)
	else
		setBeams(beams)
	end
end

-- Only after the owner has been heard from: an owner on an older Mileage, or a traffic
-- car, never reports, and its copy is left to the game.
local function copyCheck()
	if not heard then return end
	local damage = beamstate.damage or 0
	if damage ~= checkedDamage or reportsChanged or lastCount > RESYNC_BEAMS then
		checkedDamage, reportsChanged = damage, false
		lastCount = disagreeingBeams(RESYNC_BEAMS)
	end
	if lastCount > RESYNC_BEAMS then
		checksOver = checksOver + 1
	else
		checksOver = 0
	end
	if checksOver >= RESYNC_CHECKS and sinceResync >= RESYNC_COOLDOWN then
		checksOver = 0
		sinceResync = 0
		-- Counted in full for the log, which says how far the copy had drifted.
		obj:queueGameEngineLua(string.format("mileage_damageSync.resetCopy(%d,1,%d)", obj:getID(), disagreeingBeams()))
	end
end

--== roles and hooks =========================================================

local function setRole(newRole)
	if newRole ~= "owner" and newRole ~= "copy" then newRole = nil end
	if newRole == role then return end
	role = newRole
	forgetSent()
	lastDamage, sinceSend, fullWanted, clearedPending = nil, 0, nil, false
	fullAnswer, answerAfter, answerChunkLast = false, false, false
	reported, heard, sinceCheck, checksOver, sinceResync = {}, false, 0, 0, huge
	pendingSet, heldDents = nil, {}
	checkedDamage, lastCount, reportsChanged = nil, 0, false
	if role and next(baseline) == nil then captureBaseline() end
	if role == "owner" then
		-- Copies built before this car became an owner asked too early: everyone gets its
		-- full damage once, an undamaged car an empty message, so they know it reports.
		fullWanted = "all"
	end
end

-- Every player gets this car's full damage: it became an owner, or (clearFirst = 1) this
-- game dropped queued messages, and a cleared notice goes first so copies start again
-- from the car as built and nothing dropped is left on them.
local function sendFull(clearFirst)
	if role ~= "owner" then return end
	fullWanted = "all"
	if clearFirst == 1 then clearedPending = true end
end

-- Another game asked for this car's damage (it built a copy, or its copy drifted): an
-- answer only the players who asked receive.
local function answerFull()
	if role ~= "owner" or fullWanted == "all" then return end
	if fullParts and not fullAnswer then
		-- A full send for everyone is under way; the answer follows it.
		answerAfter = true
		return
	end
	fullWanted = "answer"
end

local function updateGFX(dt)
	if role == "owner" then
		sinceSend = sinceSend + (dt or 0)
		if sinceSend >= SEND_EVERY_SECONDS then
			sinceSend = 0
			ownerTick()
		end
	elseif role == "copy" then
		if pendingSet then
			pendingSet.quiet = pendingSet.quiet + (dt or 0)
			if pendingSet.quiet >= SET_WAIT_SECONDS then dropSet() end
		end
		sinceResync = sinceResync + (dt or 0)
		sinceCheck = sinceCheck + (dt or 0)
		if sinceCheck >= CHECK_EVERY_SECONDS then
			sinceCheck = 0
			copyCheck()
		end
	end
end

local function onReset()
	if role == "owner" then
		forgetSent()
		lastDamage = 0
		clearedPending = true
	elseif role == "copy" then
		reported = {}
		checksOver, lastCount, reportsChanged = 0, 0, true
	end
end

local function onExtensionLoaded()
	captureBaseline()
end

M.setRole = setRole
M.sendFull = sendFull
M.answerFull = answerFull
M.applyDamage = applyDamage
M.updateGFX = updateGFX
M.onReset = onReset
M.onExtensionLoaded = onExtensionLoaded

return M
