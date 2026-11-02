--Mileage :: mod entry point
--
-- Load order matters:
--   1. compat        - everything else reads renamed 0.39 game APIs through it
--   2. patches       - installs the runtime wrappers that publish the enriched
--                      *MP hooks the feature extensions listen for
--   3. careerPatches - neutralises career activation's vehicle cleanup before
--                      any career can start, and keeps one failing career-start
--                      handler from skipping the rest
--   4. traffic       - hands the server's traffic amounts to the game's career
--                      traffic setup
--   5. parkingChallenge - holds other players' traffic and parked cars hidden here
--                      while a parking challenge runs (mileageEnabler reads it)
--   6. farTraffic    - holds other players' traffic more than 1 km away hidden here
--                      (mileageEnabler reads it)
--   7. insuranceRestore - loads the game's insurance records when a join's career
--                      start leaves them empty
--   8. purchaseInsurance - gives the purchase screen a safe insurance choice when the
--                      insurance records are missing (patches wraps the game's purchase
--                      menu and looks this extension up when it is used)
--   9. features
--
-- 'manual' unload mode keeps these alive across level switches, which career
-- does constantly.

local function loadPersistent(path)
	load(path)
	setExtensionUnloadMode(path, 'manual')
end

-- Foundation
loadPersistent('mileage/compat')
loadPersistent('mileage/patches')
loadPersistent('mileage/careerPatches')
loadPersistent('mileage/traffic')
loadPersistent('mileage/parkingChallenge')
loadPersistent('mileage/farTraffic')
loadPersistent('mileage/insuranceRestore')
loadPersistent('mileage/purchaseInsurance')

-- Core
loadPersistent('mileageEnabler')

-- Features
loadPersistent('mileage/connectionWatch')
loadPersistent('mileage/damageSync')
loadPersistent('mileage/positionRate')
loadPersistent('mileageUIApps')
loadPersistent('mileage/transfers')
loadPersistent('mileagePlayerPayments')
loadPersistent('mileage/offers')
loadPersistent('mileage/streetRace')
loadPersistent('mileage/leaderboard')
loadPersistent('mileage/raceEvents')
-- Racing your own traffic cars: uses the street race's rolling start and the race
-- events' road-point picker, so it loads after both.
loadPersistent('mileage/aiRace')
loadPersistent('mileagePrefabSync')
loadPersistent('mileagePerPartPaint')

-- Drag racing: drives BeamNG 0.39's own multiplayer drag implementation.
--
-- Order matters here. sessionManager and the gamemode both reach into the transport,
-- and the transport is what loads gameplay_drag_mpDragHandlers -- which the base game
-- never loads by itself.
loadPersistent('mileage/dragTransport')
loadPersistent('multiplayer/sessionManager')
loadPersistent('multiplayer/synclib')
loadPersistent('mileage/dragLobby')
loadPersistent('multiplayer/gamemodes/drag/drag')
loadPersistent('mileage/dragSync')
