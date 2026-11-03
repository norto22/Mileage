-- Runs every Mileage test file against the real sources, with the game and the
-- BeamMP server replaced by small stand-ins. LuaJIT (the game's Lua) or Lua 5.3 and
-- later, no libraries.
--
--   luajit tests/run.lua       (from the repository root)
--   lua5.4 tests/run.lua
--
-- Each test file calls test(name, fn); fn fails by raising an error (expect, same).

local files = {
	"tests/traffic_meter_test.lua",
	"tests/server_config_test.lua",
	"tests/announcements_test.lua",
	"tests/insurance_restore_test.lua",
	"tests/join_insurance_check_test.lua",
	"tests/connection_watch_test.lua",
	"tests/vehicle_sync_test.lua",
	"tests/parking_challenge_test.lua",
	"tests/far_traffic_test.lua",
	"tests/remote_vehicle_test.lua",
	"tests/damage_sync_test.lua",
	"tests/purchase_insurance_test.lua",
	"tests/purchase_insurance_guard_test.lua",
	"tests/career_active_guard_test.lua",
	"tests/garage_rebuild_test.lua",
	"tests/pause_menu_test.lua",
	"tests/drag_guard_test.lua",
	"tests/server_stats_test.lua",
	"tests/traffic_share_test.lua",
	"tests/position_rate_test.lua",
	"tests/load_session_test.lua",
	"tests/ui_apps_layout_test.lua",
	"tests/transfers_test.lua",
	"tests/offers_test.lua",
	"tests/street_race_test.lua",
	"tests/leaderboard_test.lua",
	"tests/race_events_test.lua",
	"tests/ai_race_test.lua",
	"tests/race_spots_test.lua",
	"tests/spot_race_test.lua",
	"tests/money_oracle_test.lua",
	"tests/money_edges_test.lua",
	"tests/runtime_guard_test.lua",
	"tests/career_start_test.lua",
	"tests/drag_routing_test.lua",
	"tests/paint_hold_test.lua",
	"tests/lua_syntax_test.lua",
}

local passed, failed = 0, 0
local current = nil

function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("ok   " .. current .. ": " .. name)
	else
		failed = failed + 1
		print("FAIL " .. current .. ": " .. name .. "\n     " .. tostring(err))
	end
end

function expect(cond, what)
	if not cond then error(what or "expectation failed", 2) end
end

function same(actual, wanted, what)
	if actual ~= wanted then
		error(string.format("%s: got %s, wanted %s", what or "value", tostring(actual), tostring(wanted)), 2)
	end
end

-- Lines in a captured log that contain text (plain match).
function countLines(lines, text)
	local n = 0
	for _, line in ipairs(lines) do
		if string.find(line, text, 1, true) then n = n + 1 end
	end
	return n
end

for _, file in ipairs(files) do
	current = file
	local chunk, err = loadfile(file)
	if not chunk then
		failed = failed + 1
		print("FAIL " .. file .. ": does not load\n     " .. tostring(err))
	else
		local ok, runErr = pcall(chunk)
		if not ok then
			failed = failed + 1
			print("FAIL " .. file .. ": stopped\n     " .. tostring(runErr))
		end
	end
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then error("tests failed", 0) end
