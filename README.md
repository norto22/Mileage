<p align="center">
  <img src=".github/banner.jpg" alt="Mileage, a multiplayer career: Co-op career. Cruise together. Race your friends.">
</p>

# Mileage
**Co-op career. Cruise together. Race your friends.**

Mileage is a multiplayer career for [BeamNG.drive](https://beamng.com/game/) on [BeamMP](https://beammp.com/). You and your friends play the career in one shared world: the same roads, traffic and signals. Race each other, pay each other, and keep your progress in your own save.

Mileage was called CareerMP until v0.3.0. A server still running CareerMP needs Mileage installed by hand, as below; copy `Resources/Server/CareerMP/config/config.json` to `Resources/Server/Mileage/config/config.json` to keep its settings, then delete `Resources/Server/CareerMP/` and `Resources/Client/CareerMP.zip`.

## What works
- Joining a server and starting a career (BeamNG.drive 0.40.4.0)
- Buying a car, customising parts and parcel deliveries
- Drag racing another player on one tree, or a solo run when nobody joins within 10 seconds
- Tuning, painting, insurance and repairs
- Seeing damage on other players' cars
- Paint sync
- Shared road traffic, police and parked cars
- Synced traffic lights, red-light cameras and speed traps
- Other players' cars shown correctly, with nametags hidden for traffic
- Chat
- Local saves: continue on any Mileage server, or offline
- Paying and asking other players for money
- Street races for money
- Race events run by the server owner
- A server leaderboard
- Race spots: ten of the game's West Coast routes on the big map, raced alone or with friends, with best times on the leaderboard

## Planned
- Mission and challenge props everyone sees (in progress, [#30](https://github.com/norto22/Mileage/issues/30))
- Racing your traffic cars on the road (in progress, [#113](https://github.com/norto22/Mileage/issues/113))
- Getting paid for beating a player in a drag race: the owner's drag prize on every win, and a stake you both agree with Drag race… in the player list (in progress, [#145](https://github.com/norto22/Mileage/issues/145))
- Three or more players at once (in progress, [#32](https://github.com/norto22/Mileage/issues/32))
- Smoother play with five to eight players together and traffic on: traffic and parked cars send fewer updates, a joining player's cars are built one at a time instead of in one freeze, and other players' traffic more than 1 km away is hidden on your game (in progress, [#118](https://github.com/norto22/Mileage/issues/118), [#86](https://github.com/norto22/Mileage/issues/86))
- Mod vehicles and longer render distance (in progress, [#100](https://github.com/norto22/Mileage/issues/100))
- Co-op jobs with split pay ([#89](https://github.com/norto22/Mileage/issues/89))
- Paying a player to tow or repair your car ([#91](https://github.com/norto22/Mileage/issues/91))
- Loans between players ([#88](https://github.com/norto22/Mileage/issues/88))
- Trading vehicles between players ([#39](https://github.com/norto22/Mileage/issues/39))
- Career races together ([#36](https://github.com/norto22/Mileage/issues/36))
- Daily and weekly challenges ([#127](https://github.com/norto22/Mileage/issues/127))
- Cops and racers ([#128](https://github.com/norto22/Mileage/issues/128))
- A racing rank that opens harder races ([#129](https://github.com/norto22/Mileage/issues/129))
- Bigger drag races ([#37](https://github.com/norto22/Mileage/issues/37))
- Watching other players' races ([#93](https://github.com/norto22/Mileage/issues/93))
- Bounties on players ([#92](https://github.com/norto22/Mileage/issues/92))
- Crews with a shared bank account ([#90](https://github.com/norto22/Mileage/issues/90))

Known problems are on the [issue tracker](https://github.com/norto22/Mileage/issues?q=is%3Aissue%20state%3Aopen%20label%3Abug).

## Install
You need BeamNG.drive 0.40.4.0, the current BeamMP server and the West Coast, USA map.

1. Download `Mileage-<version>.zip` from the latest [release](https://github.com/norto22/Mileage/releases/latest) and unpack it into your BeamMP server folder.
2. In `ServerConfig.toml`, set `MaxCars = 100` and `Map = "/levels/west_coast_usa/info.json"`.
3. Start the server. Type `Mileage Help` in the server console for its commands.

Race prizes are paid by the server and are off until you set them, each in whole dollars from 0 to 1,000,000, with `Mileage SetConfig server <setting> <dollars>`: `racePrize` for a street race between players, `aiRacePrize` for beating a traffic car, `spotRacePrize` for first place at a race spot, and `dragRacePrize` for beating another player on the drag strip (paid on every win, with no wait between prizes). `raceStakeMax` caps the stake players agree for a street race or a drag race (10,000 by default; 0 means no stakes).

`Mileage Stats` shows what the server sent and received for each part of Mileage, and what playing together costs each player's game: its frame time, frames over 100 ms, the updates it sent and received, and its cars split into driving traffic, parked cars and players' own. Each game reports every 30 seconds and writes the same numbers to its own log under `mileage.perf`, so a session can be compared before and after a change.

## Credits
Mileage began as [CareerMP](https://github.com/StanleyDudek/CareerMP) by **Dudekahedron** ([Dudek's Sandbox](https://discord.gg/caU5adg)). The port to BeamNG.drive 0.39, including multiplayer drag racing, is by Vlad Maksimenko ([CareerMP-0.39](https://github.com/vladmaksimenko-0/CareerMP-0.39)). Thanks to Bouboule, and to Lion and Luuk from BeamPaint, for the HTTP request examples the server plugin is built on.
