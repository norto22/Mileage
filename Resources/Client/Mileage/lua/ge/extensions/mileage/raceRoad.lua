--Mileage :: the race road of a race spot route (CLIENT)
--
-- A race spot route (mileage/spotRoutes.lua) gives its checkpoints, often hundreds of
-- metres apart, and the walls of its course: the barriers that close it in the game's own
-- quick race, which Mileage does not place in the world. The race road is, leg by leg, the
-- shortest road of the game's road map between consecutive checkpoints that crosses no
-- wall, with one-way rules ignored, as on a closed course. A leg with no such road takes
-- the shortest road with the walls ignored, and the log says so. Each road is worked out
-- once per route and kept until the player leaves the server.
--
-- road(route) gives {nodes, points, legs, closing, length, fallbacks}: nodes and points
-- run from the grid through every checkpoint of one lap; legs[i] is the road to checkpoint
-- i (legs[1] from the grid), closing the road from the finish back to checkpoint 1 on a
-- route of more than one lap.
--
-- check() works out the road of every route and logs one line each: whether every leg
-- found a road that crosses no wall, whether the road passes every checkpoint within its
-- radius plus CHECKPOINT_SLACK, in order, every lap, and whether its length is within
-- reason of the route's. It runs once at each career start on a server, and from the
-- game's console as mileage_raceRoad.check().

local M = {}

local logTag = "mileage.raceRoad"

-- As spotRace and the server count a checkpoint.
local CHECKPOINT_SLACK = 10
-- The road's length against the route's (straight between checkpoints) that is in reason.
local LENGTH_LOW, LENGTH_HIGH = 0.9, 3
-- The walls are bucketed in squares this big, so an edge is tested against nearby ones only.
local CELL_METRES = 50
-- A checkpoint takes the nearest road node it can reach without crossing a wall, within this.
local SNAP_METRES = 60

-- road(route) results by route id; false when the map had no roads.
local cache = {}
-- The road map as readMap gives it, read once for every route.
local roadMap = nil

local function compat()
	local c = extensions.mileage_compat
	if type(c) == "table" then return c end
	return nil
end

local function routes()
	local r = extensions.mileage_spotRoutes
	if type(r) == "table" and type(r.routes) == "table" then return r.routes end
	return {}
end

local function xyz(p)
	return {x = p.x, y = p.y, z = p.z}
end

local function distance(a, b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

--== walls ===================================================================

local function cellOf(v)
	return math.floor(v / CELL_METRES)
end

-- The walls in buckets: {[cx] = {[cy] = {wall, ...}}}.
local function bucketWalls(walls)
	local grid = {}
	for _, w in ipairs(walls or {}) do
		if type(w) == "table" and #w == 4 then
			for cx = cellOf(math.min(w[1], w[3])), cellOf(math.max(w[1], w[3])) do
				for cy = cellOf(math.min(w[2], w[4])), cellOf(math.max(w[2], w[4])) do
					grid[cx] = grid[cx] or {}
					grid[cx][cy] = grid[cx][cy] or {}
					table.insert(grid[cx][cy], w)
				end
			end
		end
	end
	return grid
end

local function orient(ax, ay, bx, by, cx, cy)
	return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

-- Whether the flat segment a-b crosses or touches the wall w.
local function crosses(ax, ay, bx, by, w)
	local d1 = orient(w[1], w[2], w[3], w[4], ax, ay)
	local d2 = orient(w[1], w[2], w[3], w[4], bx, by)
	local d3 = orient(ax, ay, bx, by, w[1], w[2])
	local d4 = orient(ax, ay, bx, by, w[3], w[4])
	if d1 == 0 and d2 == 0 then
		-- On one line: they cross where their spans along it overlap or touch.
		local along = math.abs(bx - ax) >= math.abs(by - ay) and 1 or 2
		local a1, a2 = math.min(ax, bx), math.max(ax, bx)
		local w1, w2 = math.min(w[1], w[3]), math.max(w[1], w[3])
		if along == 2 then
			a1, a2 = math.min(ay, by), math.max(ay, by)
			w1, w2 = math.min(w[2], w[4]), math.max(w[2], w[4])
		end
		return a1 <= w2 and w1 <= a2
	end
	return d1 * d2 <= 0 and d3 * d4 <= 0
end

local function blockedBy(grid, a, b)
	local seen = {}
	for cx = cellOf(math.min(a.x, b.x)), cellOf(math.max(a.x, b.x)) do
		local column = grid[cx]
		if column then
			for cy = cellOf(math.min(a.y, b.y)), cellOf(math.max(a.y, b.y)) do
				for _, w in ipairs(column[cy] or {}) do
					if not seen[w] then
						seen[w] = true
						if crosses(a.x, a.y, b.x, b.y, w) then return true end
					end
				end
			end
		end
	end
	return false
end

--== the road map ============================================================

-- The game's road map as {names, pos = {[name] = {x, y, z}}, links = {[name] = {name, ...}}},
-- every link both ways, or nil.
local function readMap()
	local c = compat()
	local nodes = c and c.getMapNodes()
	if type(nodes) ~= "table" then return nil end
	local pos, links = {}, {}
	for name, node in pairs(nodes) do
		local p = type(node) == "table" and node.pos
		local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
		if ok and type(x) == "number" then
			pos[name] = {x = x, y = y, z = z}
			links[name] = links[name] or {}
		end
	end
	for name, node in pairs(nodes) do
		if pos[name] and type(node.links) == "table" then
			for other in pairs(node.links) do
				if pos[other] and other ~= name then
					links[name][other] = true
					links[other][name] = true
				end
			end
		end
	end
	local any = next(pos) ~= nil
	return any and {pos = pos, links = links} or nil
end

-- The nearest node to p whose straight line to p crosses no wall, within SNAP_METRES;
-- else the nearest node.
local function snap(map, grid, p)
	local best, bestD, open, openD = nil, nil, nil, nil
	for name, q in pairs(map.pos) do
		local d = distance(p, q)
		if not bestD or d < bestD then best, bestD = name, d end
		if d <= SNAP_METRES and (not openD or d < openD) and not blockedBy(grid, p, q) then open, openD = name, d end
	end
	return open or best
end

-- A binary heap of {cost, name}.
local function push(heap, item)
	table.insert(heap, item)
	local i = #heap
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent][1] <= heap[i][1] then break end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function pop(heap)
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, small = i * 2, i * 2 + 1, i
			if heap[l] and heap[l][1] < heap[small][1] then small = l end
			if heap[r] and heap[r][1] < heap[small][1] then small = r end
			if small == i then break end
			heap[small], heap[i] = heap[i], heap[small]
			i = small
		end
	end
	return top
end

-- The shortest road from node a to node b as node names, skipping blocked links
-- (blocked[x][y]), or nil.
local function shortest(map, a, b, blocked)
	if a == b then return {a} end
	local goal = map.pos[b]
	local cost, from, done = {[a] = 0}, {}, {}
	local heap = {}
	push(heap, {distance(map.pos[a], goal), a})
	while #heap > 0 do
		local item = pop(heap)
		local name = item[2]
		if name == b then
			local path = {b}
			while from[path[1]] do table.insert(path, 1, from[path[1]]) end
			return path
		end
		if not done[name] then
			done[name] = true
			for other in pairs(map.links[name]) do
				if not done[other] and not (blocked and blocked[name] and blocked[name][other]) then
					local c = cost[name] + distance(map.pos[name], map.pos[other])
					if not cost[other] or c < cost[other] then
						cost[other], from[other] = c, name
						push(heap, {c + distance(map.pos[other], goal), other})
					end
				end
			end
		end
	end
	return nil
end

-- Every link of the map that crosses a wall, both ways.
local function blockedLinks(map, grid)
	local blocked = {}
	if next(grid) == nil then return blocked end
	for name, others in pairs(map.links) do
		for other in pairs(others) do
			if name < other and blockedBy(grid, map.pos[name], map.pos[other]) then
				blocked[name] = blocked[name] or {}
				blocked[other] = blocked[other] or {}
				blocked[name][other], blocked[other][name] = true, true
			end
		end
	end
	return blocked
end

local function pathLength(map, names)
	local total = 0
	for i = 2, #names do total = total + distance(map.pos[names[i - 1]], map.pos[names[i]]) end
	return total
end

-- The road from node a to node b that crosses no wall; else the walls-ignored road
-- (fallback); else, where no road joins them at all, straight from a to b (unreached too).
local function legOf(map, blocked, a, b)
	local names = shortest(map, a, b, blocked)
	local fallback, unreached = false, false
	if not names then
		fallback = true
		names = shortest(map, a, b, nil)
		if not names then names, unreached = {a, b}, true end
	end
	local points = {}
	for i, name in ipairs(names) do points[i] = xyz(map.pos[name]) end
	return {nodes = names, points = points, fallback = fallback, unreached = unreached, length = pathLength(map, names)}
end

local function work(route)
	roadMap = roadMap or readMap()
	local map = roadMap
	if not map then return nil end
	local grid = bucketWalls(route.walls)
	local blocked = blockedLinks(map, grid)
	local stops = {snap(map, grid, route.grid.pos)}
	for _, checkpoint in ipairs(route.checkpoints) do table.insert(stops, snap(map, grid, checkpoint.pos)) end
	local road = {nodes = {stops[1]}, points = {xyz(map.pos[stops[1]])}, legs = {}, length = 0, fallbacks = 0}
	for i = 2, #stops do
		local leg = legOf(map, blocked, stops[i - 1], stops[i])
		leg.from, leg.to = i - 2, i - 1
		road.legs[i - 1] = leg
		for j = 2, #leg.nodes do
			table.insert(road.nodes, leg.nodes[j])
			table.insert(road.points, leg.points[j])
		end
		road.length = road.length + leg.length
	end
	if (route.laps or 1) > 1 and #stops > 2 then
		road.closing = legOf(map, blocked, stops[#stops], stops[2])
		road.closing.from, road.closing.to = #stops - 1, 1
	end
	local legs = {}
	for _, leg in ipairs(road.legs) do table.insert(legs, leg) end
	if road.closing then table.insert(legs, road.closing) end
	for _, leg in ipairs(legs) do
		if leg.unreached then
			road.fallbacks = road.fallbacks + 1
			log("W", logTag, string.format("%s: no road reaches checkpoint %d; going straight to it", tostring(route.id),
				leg.to))
		elseif leg.fallback then
			road.fallbacks = road.fallbacks + 1
			log("W", logTag, string.format("%s: no road to checkpoint %d crosses no wall; using the walls-ignored road",
				tostring(route.id), leg.to))
		end
	end
	return road
end

--- The race road of a route (see the top of this file), worked out once; nil when the
--- game has no road map.
function M.road(route)
	if type(route) ~= "table" or type(route.id) ~= "string" or type(route.checkpoints) ~= "table" then return nil end
	local kept = cache[route.id]
	if kept == nil then
		local ok, road = pcall(work, route)
		if not ok then
			log("E", logTag, route.id .. ": the race road could not be worked out: " .. tostring(road))
			kept = false
		elseif road then
			kept = road
		else
			-- The game has no road map yet (the level is still loading): ask again next time.
			return nil
		end
		cache[route.id] = kept
	end
	return kept or nil
end

--== the check ===============================================================

-- How near the segment a-b comes to centre, from s0 along it on (0 at a, 1 at b), and where
-- (so the next checkpoint on the same segment is only looked for beyond it, as the server
-- counts checkpoints in order).
local function nearest(a, b, centre, s0)
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local length2 = dx * dx + dy * dy + dz * dz
	local s = s0 or 0
	if length2 > 0 then
		s = ((centre.x - a.x) * dx + (centre.y - a.y) * dy + (centre.z - a.z) * dz) / length2
		s = math.max(s0 or 0, math.min(1, s))
	end
	return distance({x = a.x + dx * s, y = a.y + dy * s, z = a.z + dz * s}, centre), s
end

-- The whole race as points: the grid to the finish, then the closing leg and a lap again
-- for every further lap.
local function racePoints(road, laps)
	local points = {}
	for _, p in ipairs(road.points) do table.insert(points, p) end
	for _ = 2, laps do
		if road.closing then
			for j = 2, #road.closing.points do table.insert(points, road.closing.points[j]) end
		end
		for i = 2, #road.legs do
			for j = 2, #road.legs[i].points do table.insert(points, road.legs[i].points[j]) end
		end
	end
	return points
end

local function checkRoute(route)
	local road = M.road(route)
	if not road then
		return {id = route.id, ok = false, noMap = true, problems = {"the game has no road map here"}}
	end
	local problems = {}
	for i, leg in ipairs(road.legs) do
		if leg.unreached then
			table.insert(problems, string.format("no road reaches checkpoint %d", i))
		elseif leg.fallback then
			table.insert(problems, string.format("the road to checkpoint %d crosses a wall", i))
		end
	end
	if road.closing and road.closing.unreached then
		table.insert(problems, "no road leads from the finish back to checkpoint 1")
	elseif road.closing and road.closing.fallback then
		table.insert(problems, "the road from the finish back to checkpoint 1 crosses a wall")
	end
	local laps = math.max(1, route.laps or 1)
	local points = racePoints(road, laps)
	local at, passed, along = 2, 0, 0
	for lap = 1, laps do
		for i, checkpoint in ipairs(route.checkpoints) do
			local reach = (checkpoint.r or 0) + CHECKPOINT_SLACK
			local found, closest = false, nil
			while at <= #points do
				local d, s = nearest(points[at - 1], points[at], checkpoint.pos, along)
				closest = math.min(closest or d, d)
				if d <= reach then
					found, along = true, s
					break
				end
				at, along = at + 1, 0
			end
			if not found then
				table.insert(problems, string.format("lap %d misses checkpoint %d%s", lap, i,
					closest and string.format(" (nearest %d m)", math.floor(closest)) or ""))
				break
			end
			passed = passed + 1
		end
		if passed < lap * #route.checkpoints then break end
	end
	local total = 0
	for i = 2, #points do total = total + distance(points[i - 1], points[i]) end
	local ratio = (tonumber(route.length) or 0) > 0 and total / route.length or nil
	if not ratio or ratio < LENGTH_LOW or ratio > LENGTH_HIGH then
		table.insert(problems, string.format("its %.1f km is %s the route's %.1f km", total / 1000,
			ratio and string.format("%.2f x", ratio) or "not comparable to", (tonumber(route.length) or 0) / 1000))
	end
	return {id = route.id, ok = #problems == 0, problems = problems, legs = #road.legs + (road.closing and 1 or 0),
		checkpoints = passed, metres = total, ratio = ratio}
end

-- Whether each route's road passed the check, by route id.
local usable = {}

--- The race road of a route, but only where this game's own check passes for that route
--- (every leg on a road that crosses no wall, every checkpoint in order every lap, a length
--- in reason); nil otherwise, and the race keeps the game's own navigation for it.
function M.usable(route)
	if type(route) ~= "table" or type(route.id) ~= "string" then return nil end
	if usable[route.id] == nil then
		local ok, result = pcall(checkRoute, route)
		if ok and result.noMap then return nil end
		usable[route.id] = ok and result.ok == true
	end
	if not usable[route.id] then return nil end
	return M.road(route)
end

--- The leg of a road that leads to the next checkpoint after this many have been passed
--- over the whole race: the road from the grid to checkpoint 1 first, then from each
--- checkpoint to the next, and from the finish back to checkpoint 1 on a later lap.
function M.legAfter(road, passed, checkpoints)
	local n = checkpoints
	local k = passed % n + 1
	if passed > 0 and k == 1 then return road.closing end
	return road.legs[k]
end

--- Works out and checks the race road of every route, logging one line each and a
--- summary. Returns {passed, total, routes = {{id, ok, problems}, ...}}.
function M.check()
	local results, passed = {}, 0
	for _, route in ipairs(routes()) do
		local result = checkRoute(route)
		if not result.noMap then usable[route.id] = result.ok == true end
		table.insert(results, result)
		if result.ok then
			passed = passed + 1
			log("I", logTag, string.format("race road %s: passes: %d legs on roads that cross no wall, %d checkpoints in " ..
				"order, %.1f km (%.2f x the route)", route.id, result.legs, result.checkpoints, result.metres / 1000,
				result.ratio))
		else
			log("W", logTag, string.format("race road %s: FAILS: %s", route.id, table.concat(result.problems, "; ")))
		end
	end
	log(passed == #results and "I" or "W", logTag, string.format("race road check: %d of %d routes pass", passed,
		#results))
	return {passed = passed, total = #results, routes = results}
end

function M.onCareerActive(active)
	if not active then return end
	local c = compat()
	if c and c.isMPSession() then M.check() end
end

function M.onBeamMPServerLeave()
	cache, roadMap, usable = {}, nil, {}
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
