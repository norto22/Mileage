// Mileage-Offers/app.js, the Mileage prompts app: offers and requests with their
// answers, the race countdown, panel and result, race events and the leaderboard. Runs
// the real app script against small stand-ins for the game's UI (Angular scope, bngApi),
// with Node's standard library only.
//
//   node tests/prompts_app_test.js          (from the repository root)

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const SOURCE = "Resources/Client/Mileage/ui/modules/apps/Mileage-Offers/app.js";
const TEMPLATE = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Offers/app.html", "utf8");

// A fresh controller; returns its scope and the Lua the app sent to the game.
function load(now) {
	const lua = [];
	let controller = null;
	const handlers = {};
	const scope = {
		$on(name, fn) { handlers[name] = fn; },
		$evalAsync(fn) { fn(); },
		emit(name, data) { handlers[name]({}, data); },
	};
	const clock = {now: now || 1000000};
	const context = {
		angular: {module: () => ({directive() {}, controller(name, deps) { controller = deps[deps.length - 1]; }})},
		bngApi: {engineLua(cmd) { lua.push(cmd); }},
		setInterval() { return 1; }, clearInterval() {},
		Date: {now: () => clock.now},
		console, JSON, TextEncoder, btoa, Math, Number, String, isFinite,
	};
	vm.createContext(context);
	vm.runInContext(fs.readFileSync(SOURCE, "utf8"), context, {filename: SOURCE});
	controller(scope);
	return {scope, lua, clock, context};
}

const b64 = (text) => "require('mime').unb64('" + Buffer.from(text, "utf8").toString("base64") + "')";

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

//== offers =====================================================================

const REQUEST = {id: "o7", kind: "request", from: "Sam_Okafor_the_Long_Name", amount: 3500, secondsLeft: 60};
const RACE = {id: "o8", kind: "race", from: "norto22", amount: 1000, distance: 2400, prize: 500, secondsLeft: 60};

test("a request shows who asks and how much, with Pay and Decline", () => {
	const {scope} = load();
	scope.emit("MileageOffer", REQUEST);
	assert.strictEqual(scope.offers.length, 1);
	const v = scope.offers[0].view;
	assert.strictEqual(v.title, "Sam_Okafor_the_Long_Name asks you for $3,500");
	assert.strictEqual(v.accept, "Pay $3,500");
	assert.strictEqual(v.note, "Counts towards your sending limits on this server.");
});

test("a race challenge shows the finish, the stake and what the winner gets", () => {
	const {scope} = load();
	scope.emit("MileageOffer", RACE);
	const v = scope.offers[0].view;
	assert.strictEqual(v.title, "norto22 challenges you to a race");
	assert.deepStrictEqual([...v.rows].map((r) => r.label + ": " + r.value), [
		"Finish: 2.4 km from them", "Stake: $1,000 each", "Winner gets: $2,000 + $500 server prize"]);
	assert.ok(v.note.includes("Leaving mid-race loses your stake."));
	assert.strictEqual(v.accept, "Accept");
});

test("a race without a stake or prize says so", () => {
	const {scope} = load();
	scope.emit("MileageOffer", Object.assign({}, RACE, {amount: 0, prize: 0}));
	const v = scope.offers[0].view;
	assert.deepStrictEqual([...v.rows].map((r) => r.value), ["2.4 km from them", "No stake"]);
	assert.ok(!v.note.includes("stake"));
});

test("an answer goes to the game once, with the id encoded, and the card goes", () => {
	const {scope, lua} = load();
	scope.emit("MileageOffer", REQUEST);
	const offer = scope.offers[0];
	scope.answer(offer, true);
	scope.answer(offer, true);
	const sent = lua.filter((cmd) => cmd.includes("mileage_offers.answer"));
	assert.deepStrictEqual(sent, ["if mileage_offers then mileage_offers.answer(" + b64("o7") + ", true) end"]);
	assert.strictEqual(scope.offers.length, 0, "card removed");
	scope.emit("MileageOffer", RACE);
	scope.answer(scope.offers[0], false);
	assert.ok(lua.includes("if mileage_offers then mileage_offers.answer(" + b64("o8") + ", false) end"), "decline");
});

test("a closed offer leaves the app; the same offer shown twice is one card", () => {
	const {scope} = load();
	scope.emit("MileageOffer", REQUEST);
	scope.emit("MileageOffer", REQUEST);
	scope.emit("MileageOffer", RACE);
	assert.strictEqual(scope.offers.length, 2);
	scope.emit("MileageOfferClosed", {id: "o7", why: "expired"});
	assert.deepStrictEqual([...scope.offers].map((o) => o.id), ["o8"]);
});

test("the time bar runs down over the offer's seconds", () => {
	const {scope, clock} = load();
	scope.emit("MileageOffer", REQUEST);
	const offer = scope.offers[0];
	assert.strictEqual(scope.barWidth(offer), "100%");
	clock.now += 30000;
	assert.strictEqual(scope.barWidth(offer), "50%");
	clock.now += 60000;
	assert.strictEqual(scope.barWidth(offer), "0%");
});

test("the app asks the game for open offers when it loads", () => {
	const {lua} = load();
	assert.ok(lua.includes("if mileage_offers then mileage_offers.sendState() end"));
});

//== a street race ================================================================

const rows = (view) => [...(view.rows || [])].map((r) => r.label + ": " + r.value);

test("the countdown shows big, then GO, then the race panel with Give up", () => {
	const {scope, lua} = load();
	scope.emit("MileageRace", {phase: "countdown", race: "r1", other: "Alex_Rivera", stake: 1000, count: 2});
	assert.strictEqual(scope.race.view.big, "2");
	assert.strictEqual(scope.race.view.note, "vs Alex_Rivera · $1,000 stake");
	scope.emit("MileageRace", {phase: "go", race: "r1", other: "Alex_Rivera", stake: 1000});
	assert.strictEqual(scope.race.view.big, "GO");
	scope.emit("MileageRace", {phase: "racing", race: "r1", other: "Alex_Rivera", stake: 1000, elapsed: 72.43,
		distance: 900});
	assert.strictEqual(scope.race.view.title, "Racing Alex_Rivera");
	assert.strictEqual(scope.race.view.big, "1:12.4");
	assert.strictEqual(scope.race.view.note, "Finish 0.9 km · follow your map route");
	assert.strictEqual(scope.race.view.giveUp, "Give up (lose $1,000)");
	scope.giveUp();
	assert.ok(lua.includes("if mileage_streetRace then mileage_streetRace.giveUp() end"));
});

test("the winner sees both times, the gap and the money", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "result", race: "r1", you: "norto22", other: "Alex_Rivera", winner: "norto22",
		why: "finished", times: {norto22: 123.8, Alex_Rivera: 126.1}, stake: 1000, pot: 2000, prize: 500});
	assert.strictEqual(scope.race.view.title, "You won");
	assert.deepStrictEqual(rows(scope.race.view), ["Your time: 2:03.8", "Alex_Rivera: 2:06.1 (+2.3 s)",
		"You get: $2,000 stakes + $500 prize"]);
	scope.closeRace();
	assert.strictEqual(scope.race, null, "closed");
});

test("the loser sees who won and the stake lost; a leaver is told they did not finish", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "result", race: "r1", you: "norto22", other: "Alex_Rivera",
		winner: "Alex_Rivera", why: "left", gaveUp: "norto22", times: {}, stake: 1000, pot: 2000, prize: 0});
	assert.strictEqual(scope.race.view.title, "Alex_Rivera won");
	assert.deepStrictEqual(rows(scope.race.view), ["Your time: did not finish: you left the race",
		"You lost: your $1,000 stake"]);
});

test("nobody finishing in time says the stake is back; a called-off race says why", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "result", race: "r1", you: "a", other: "b", why: "timeout", times: {}, stake: 1000});
	assert.strictEqual(scope.race.view.title, "No winner");
	assert.strictEqual(scope.race.view.note, "Nobody reached the finish in time. Your $1,000 stake is back.");
	scope.emit("MileageRace", {phase: "calledOff", race: "r2", why: "b did not have the stake", stake: 500});
	assert.strictEqual(scope.race.view.title, "Race called off");
	assert.strictEqual(scope.race.view.note, "b did not have the stake. Your $500 stake is back.");
	assert.strictEqual(scope.race.view.close, true, "can be closed");
});

//== the leaderboard ===============================================================

test("the leaderboard lists race wins and each strip's best drag times, names as text", () => {
	const {scope} = load();
	scope.emit("MileageLeaderboard", {
		wins: [{name: "norto22", wins: 31}, {name: "<b>Sam</b>", wins: 27}],
		drag: {alder_dragway: [{name: "Alex_Rivera", et: 10.84, trap: 56.4}, {name: "norto22", et: 11.37, trap: 52.5}]},
	});
	const board = scope.leaderboard;
	assert.strictEqual(board.tab, "wins", "opens on race wins");
	assert.deepStrictEqual([...board.wins].map((r) => r.place + " " + r.name + " " + r.value),
		["1 norto22 31", "2 <b>Sam</b> 27"]);
	assert.strictEqual(board.strips[0].name, "alder_dragway");
	assert.deepStrictEqual([...board.strips[0].rows].map((r) => r.name + " " + r.value + " " + r.extra),
		["Alex_Rivera 10.84 s 203 km/h", "norto22 11.37 s 189 km/h"]);
	scope.showTab("drag");
	assert.strictEqual(scope.leaderboard.tab, "drag");
	scope.emit("MileageLeaderboard", {wins: [], drag: {}});
	assert.strictEqual(scope.leaderboard.tab, "drag", "an update keeps the tab");
	scope.closeLeaderboard();
	assert.strictEqual(scope.leaderboard, null);
});

//== race events ===================================================================

test("an event invitation shows the route, prize and players, and Join sends once with the id encoded", () => {
	const {scope, lua} = load();
	scope.emit("MileageEvent", {id: "e1-5", phase: "announce", route: "Service station garage to Alder Dragway",
		prize: 25000, seconds: 300, joined: 4, youJoined: false});
	const v = scope.event.view;
	assert.strictEqual(v.title, "Race event in 5 minutes");
	assert.deepStrictEqual(rows(v), ["Route: Service station garage to Alder Dragway", "Prize: $25,000 to the winner",
		"Joined: 4 players"]);
	assert.strictEqual(v.joined, false);
	scope.joinEvent();
	assert.ok(lua.includes("if mileage_raceEvents then mileage_raceEvents.join(" + b64("e1-5") + ") end"));
	scope.emit("MileageEvent", {id: "e1-5", phase: "joined", route: "random finish", random: true, prize: 25000,
		seconds: 60, joined: 1, youJoined: true});
	assert.strictEqual(scope.event.view.title, "Race event in 1 minute");
	assert.strictEqual(scope.event.view.note, "The finish is picked when it starts.");
	assert.strictEqual(scope.event.view.joined, true, "Leave event shown");
	scope.leaveEvent();
	assert.ok(lua.includes("if mileage_raceEvents then mileage_raceEvents.leave(" + b64("e1-5") + ") end"));
});

test("the event result names the winner and this player's place", () => {
	const {scope} = load();
	const places = [{name: "Alex_Rivera", seconds: 192.6}, {name: "Sam", seconds: 195}, {name: "norto22", seconds: 200.4}];
	scope.emit("MileageEvent", {id: "e1", phase: "result", route: "R", winner: "Alex_Rivera", places, prize: 25000,
		racers: 4, you: "norto22"});
	assert.strictEqual(scope.event.view.title, "Race event over");
	assert.deepStrictEqual(rows(scope.event.view), ["Winner: Alex_Rivera, 3:12.6", "You: 3rd of 4, 3:20.4"]);
	scope.emit("MileageEvent", {id: "e1", phase: "result", route: "R", winner: "Alex_Rivera", places, prize: 25000,
		racers: 4, you: "Alex_Rivera"});
	assert.strictEqual(scope.event.view.title, "You won the race event");
	assert.deepStrictEqual(rows(scope.event.view), ["Route: R", "Your time: 3:12.6, 1st of 4",
		"Prize: $25,000 paid to you"]);
	scope.emit("MileageEvent", {id: "e2", phase: "cancelled"});
	assert.strictEqual(scope.event.view.title, "Race event cancelled");
	scope.closeEvent();
	assert.strictEqual(scope.event, null);
});

test("a refused join says why, an invitation that began without the player goes, and a stopped race clears", () => {
	const {scope} = load();
	scope.emit("MileageEvent", {id: "e1", phase: "refused", why: "Finish your race first, then join."});
	assert.strictEqual(scope.event.view.title, "Could not join the race event");
	assert.strictEqual(scope.event.view.note, "Finish your race first, then join.");
	scope.emit("MileageEvent", {id: "e1", phase: "announce", route: "R", prize: 5, seconds: 60, joined: 0});
	assert.ok(scope.event, "invitation shown");
	scope.emit("MileageEvent", {id: "e1", phase: "begun"});
	assert.strictEqual(scope.event, null, "invitation closed at the start");
	scope.emit("MileageRace", {phase: "racing", race: "e1", other: "the race event", elapsed: 5});
	assert.ok(scope.race, "race panel shown");
	scope.emit("MileageRace", {phase: "clear", race: "e1"});
	assert.strictEqual(scope.race, null, "race panel cleared");
});

//== racing the traffic car beside you ============================================

const OWN = {phase: "available", own: true, car: "Ibishu Pessima", allowed: true, prize: 2000, prizeAgainIn: 0};

test("the race card offers Race this car beside your own traffic, with the reward", () => {
	const {scope, lua} = load();
	scope.emit("MileageAiRace", OWN);
	const v = scope.traffic.view;
	assert.strictEqual(v.title, "Race this car");
	assert.deepStrictEqual(rows(v), ["Car: Ibishu Pessima", "Finish: Random, 1.5 to 4 km",
		"Race reward: $2,000, +50% for each player who joins"]);
	assert.strictEqual(v.note, "Players within 300 m are invited. You can also set a key for this in Options › Controls.");
	assert.strictEqual(v.raceOff, false, "the button is on");
	scope.raceTraffic();
	assert.ok(lua.includes("if mileage_aiRace then mileage_aiRace.press() end"));
	scope.emit("MileageAiRace", Object.assign({}, OWN, {key: "J"}));
	assert.strictEqual(scope.traffic.view.key, "J", "the bound key");
	assert.strictEqual(scope.traffic.view.note, "Players within 300 m are invited.");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {prizeAgainIn: 330}));
	assert.deepStrictEqual(rows(scope.traffic.view)[2], "Race reward: Again in 6 min; a win still counts on the leaderboard");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {prize: 0}));
	assert.deepStrictEqual(rows(scope.traffic.view)[2], "Race reward: None on this server; a win counts on the leaderboard");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {note: "No reachable finish from here, try another road."}));
	assert.deepStrictEqual(rows(scope.traffic.view), ["Car: Ibishu Pessima"]);
	assert.strictEqual(scope.traffic.view.note, "No reachable finish from here, try another road.");
	scope.emit("MileageAiRace", {phase: "none"});
	assert.strictEqual(scope.traffic, null, "no car beside you");
});

test("next to another player's traffic, or with racing traffic off, the button is off and says why", () => {
	const {scope} = load();
	scope.emit("MileageAiRace", {phase: "available", own: false, car: "Gavril Grand Marshal", owner: "Alex", allowed: true});
	assert.strictEqual(scope.traffic.view.raceOff, true);
	assert.strictEqual(scope.traffic.view.note,
		"This is Alex's traffic, so only Alex's game can race it. Pull alongside one of your own traffic cars.");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {allowed: false}));
	assert.strictEqual(scope.traffic.view.raceOff, true);
	assert.strictEqual(scope.traffic.view.note, "Racing traffic is off on this server.");
	assert.ok(/ng-disabled="traffic\.view\.raceOff"/.test(TEMPLATE), "the button is disabled in the page");
});

test("the invite shows the host, the car, the reward and Join or Decline, and stays over the card", () => {
	const {scope, lua, clock} = load();
	scope.emit("MileageAiRace", {phase: "invite", race: "ai3-9", host: "Taylor", car: "Ibishu Pessima",
		distance: 2900, prize: 3000, seconds: 5});
	const v = scope.traffic.view;
	assert.strictEqual(v.title, "Taylor started a race near you");
	assert.deepStrictEqual(rows(v), ["Against: Ibishu Pessima", "Finish: 2.9 km from you",
		"Race reward: $3,000 if you join, to the first player to beat the Ibishu Pessima"]);
	assert.strictEqual(v.join, true);
	clock.now += 2500;
	assert.strictEqual(scope.barWidth(scope.traffic), "50%", "the time to join runs down");
	scope.emit("MileageAiRace", OWN);
	assert.strictEqual(scope.traffic.kind, "invite", "a car beside you does not hide the invite");
	scope.joinTraffic();
	assert.ok(lua.includes("if mileage_aiRace then mileage_aiRace.join(" + b64("ai3-9") + ") end"));
	scope.emit("MileageAiRace", {phase: "inviteClosed", race: "other"});
	assert.ok(scope.traffic, "another race's close changes nothing");
	scope.emit("MileageAiRace", {phase: "inviteClosed", race: "ai3-9"});
	assert.strictEqual(scope.traffic, null, "closed");
	scope.emit("MileageAiRace", {phase: "invite", race: "ai4", host: "T", car: "C", distance: 1, prize: 0, seconds: 5});
	scope.declineTraffic();
	assert.strictEqual(scope.traffic, null, "declined");
	assert.ok(lua.includes("if mileage_aiRace then mileage_aiRace.decline() end"));
});

test("the rolling countdown and race panel say keep driving and show the reward", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "countdown", race: "ai1", other: "the Ibishu Pessima and Sam", stake: 0, count: 4,
		rolling: true, reward: 3000});
	assert.strictEqual(scope.race.view.big, "4");
	assert.strictEqual(scope.race.view.note, "Rolling start · keep driving · vs the Ibishu Pessima and Sam · race reward $3,000");
	scope.emit("MileageRace", {phase: "racing", race: "ai1", other: "the Ibishu Pessima", stake: 0, elapsed: 72.4,
		distance: 1300, rolling: true, reward: 3000});
	assert.strictEqual(scope.race.view.title, "Racing the Ibishu Pessima");
	assert.strictEqual(scope.race.view.note, "Finish 1.3 km · follow your map route · race reward $3,000");
	assert.strictEqual(scope.race.view.giveUp, "Give up");
	scope.emit("MileageRace", {phase: "finished", race: "ai1", other: "x", elapsed: 151.4, rolling: true});
	assert.strictEqual(scope.race.view.note, "Waiting for the other racers...");
});

const PLACES = [{name: "norto22", seconds: 151.4}, {name: "Ibishu Pessima", seconds: 153, car: true},
	{name: "Sam", seconds: 160.2}];

test("the traffic race result lists every racer and the car by its model, and the reward", () => {
	const {scope, lua} = load();
	scope.emit("MileageAiRace", {phase: "result", race: "ai1", host: "norto22", car: "Ibishu Pessima", winner: "norto22",
		aiWon: false, places: PLACES, prize: 3000, reward: 3000, prizeAgainIn: 600, why: "finished", you: "norto22"});
	let v = scope.traffic.view;
	assert.strictEqual(v.title, "You won");
	assert.deepStrictEqual([...v.places].map((r) => r.place + " " + r.name + " " + r.value),
		["1 You 2:31.4", "2 Ibishu Pessima 2:33.0", "3 Sam 2:40.2"]);
	assert.deepStrictEqual(rows(v), ["You get: $3,000 race reward"]);
	scope.emit("MileageAiRace", OWN);
	assert.strictEqual(scope.traffic.kind, "result", "the result stays until closed");
	scope.closeTraffic();
	assert.strictEqual(scope.traffic, null);
	assert.ok(lua.filter((c) => c === "if mileage_aiRace then mileage_aiRace.sendState() end").length >= 2,
		"the card is asked for again");
	scope.emit("MileageAiRace", {phase: "result", race: "ai2", host: "norto22", car: "Ibishu Pessima", aiWon: true,
		places: [PLACES[1], PLACES[0]], prize: 0, reward: 2000, why: "finished", you: "norto22"});
	v = scope.traffic.view;
	assert.strictEqual(v.title, "The Ibishu Pessima won");
	assert.strictEqual(v.note, "Nobody beat the Ibishu Pessima, so no race reward this time.");
	scope.emit("MileageAiRace", {phase: "result", race: "ai3", host: "norto22", car: "Ibishu Pessima", places: [],
		prize: 0, reward: 2000, why: "aiOut", you: "Sam"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Ibishu Pessima: out: crashed or stuck for 15 s"]);
	scope.emit("MileageAiRace", {phase: "result", race: "ai4", host: "norto22", car: "Ibishu Pessima", places: [],
		prize: 0, reward: 2000, why: "hostGaveUp", you: "norto22"});
	assert.strictEqual(scope.traffic.view.note,
		"Your race ended for everyone, with no winner and no race reward. The Ibishu Pessima is back in traffic.");
	scope.emit("MileageAiRace", {phase: "result", race: "ai5", host: "norto22", car: "Ibishu Pessima", out: true,
		places: [], prize: 0, why: "gaveUp", you: "Sam"});
	assert.strictEqual(scope.traffic.view.title, "You left the race");
	scope.emit("MileageAiRace", {phase: "result", race: "ai6", host: "norto22", car: "Ibishu Pessima", winner: "norto22",
		places: PLACES, prize: 0, reward: 2000, prizeAgainIn: 240, why: "finished", you: "norto22"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Race reward: Again in 4 min; the win counts on the leaderboard"]);
	scope.emit("MileageAiRace", {phase: "result", race: "ai7", host: "norto22", car: "Ibishu Pessima", winner: "norto22",
		places: PLACES, prize: 0, reward: 2000, prizeAgainIn: 0, why: "finished", you: "norto22"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Race reward: Not paid for this race; the win counts on the leaderboard"],
		"a win the server could not pay never says again in 0 min");
});

test("an unpaid win's reward row: a wait under a minute reads 1 min, a bad wait reads not paid, no row with the reward off", () => {
	const {scope} = load();
	const won = (extra) => {
		scope.emit("MileageAiRace", Object.assign({phase: "result", race: "ai8", host: "norto22", car: "Ibishu Pessima",
			winner: "norto22", places: PLACES, prize: 0, reward: 2000, why: "finished", you: "norto22"}, extra));
		return rows(scope.traffic.view);
	};
	assert.deepStrictEqual(won({prizeAgainIn: 30}), ["Race reward: Again in 1 min; the win counts on the leaderboard"],
		"30 s left is rounded up, never shown as 0 min");
	assert.deepStrictEqual(won({prizeAgainIn: 61}), ["Race reward: Again in 2 min; the win counts on the leaderboard"]);
	assert.deepStrictEqual(won({prizeAgainIn: -5}), ["Race reward: Not paid for this race; the win counts on the leaderboard"],
		"a negative wait is no wait");
	assert.deepStrictEqual(won({prizeAgainIn: "soon"}), ["Race reward: Not paid for this race; the win counts on the leaderboard"],
		"a wait that is not a number is no wait");
	assert.deepStrictEqual(won({prizeAgainIn: undefined}),
		["Race reward: Not paid for this race; the win counts on the leaderboard"], "no wait sent");
	assert.deepStrictEqual(won({reward: 0, prizeAgainIn: 0}), [], "the reward is off: nothing to say about it");
	assert.deepStrictEqual(won({reward: 0, prizeAgainIn: 300}), [], "off, even while a wait runs");
});

test("a traffic race result lists racers and the car without a time, and says why a reward was withheld", () => {
	const {scope} = load();
	const shown = (extra) => {
		scope.emit("MileageAiRace", Object.assign({phase: "result", race: "ai9", host: "norto22", car: "Ibishu Pessima",
			winner: "norto22", aiWon: false, places: [{name: "norto22", seconds: 40.2}], prize: 3000, reward: 3000,
			prizeAgainIn: 600, why: "finished", you: "norto22"}, extra));
		return scope.traffic.view;
	};
	const placeRows = (v) => [...v.places].map((r) => r.place + " " + r.name + " " + r.value);
	let v = shown({notFinished: [{name: "Sam"}, {name: "Ibishu Pessima", car: true}]});
	assert.strictEqual(v.title, "You won");
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2", "- Sam did not finish", "- Ibishu Pessima still on its way"]);
	v = shown({notFinished: [{name: "Ibishu Pessima", car: true, out: "gone"}]});
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2", "- Ibishu Pessima out: crashed or stuck"]);
	v = shown({notFinished: [{name: "norto22"}], winner: "Sam", places: [{name: "Sam", seconds: 39}], you: "norto22"});
	assert.deepStrictEqual(placeRows(v), ["1 Sam 0:39.0", "- You did not finish"]);
	v = shown({notFinished: "broken"});
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2"], "a list that is not one adds nothing");
	v = shown({prize: 0, prizeAgainIn: 0, rewardWithheld: "slow"});
	assert.deepStrictEqual(rows(v),
		["Race reward: Not paid: the Ibishu Pessima was too slow to count as racing; the win counts on the leaderboard"]);
	v = shown({prize: 0, prizeAgainIn: 0, rewardWithheld: "jumped"});
	assert.deepStrictEqual(rows(v),
		["Race reward: Not paid: the Ibishu Pessima jumped farther than a car can drive; the win counts on the leaderboard"]);
	scope.emit("MileageAiRace", {phase: "result", race: "ai10", host: "norto22", car: "Ibishu Pessima", places: [],
		notFinished: [{name: "norto22"}, {name: "Ibishu Pessima", car: true, out: "stuck"}], prize: 0, reward: 2000,
		why: "aiOut", you: "norto22"});
	assert.strictEqual(scope.traffic.view.note,
		"The Ibishu Pessima dropped out before anyone finished, so the race ended with no winner and no race reward. " +
		"The car is back in traffic.");
});

// Every text a view holds, for the check below.
function texts(value) {
	if (typeof value === "string") return [value];
	if (!value || typeof value !== "object") return [];
	return Object.keys(value).reduce((all, key) => all.concat(texts(value[key])), []);
}

test("no text the app shows for a traffic race says AI", () => {
	const {scope} = load();
	const shown = [];
	const take = () => { if (scope.traffic) shown.push(...texts(scope.traffic.view)); };
	const base = {race: "ai1", host: "Taylor", car: "Ibishu Pessima", places: PLACES, prize: 3000, reward: 3000,
		prizeAgainIn: 300, you: "norto22"};
	[OWN, Object.assign({}, OWN, {allowed: false}), Object.assign({}, OWN, {prize: 0}),
		Object.assign({}, OWN, {prizeAgainIn: 90}), Object.assign({}, OWN, {key: "J"}),
		{phase: "available", own: false, car: "Gavril", owner: "Alex", allowed: true}].forEach((m) => {
		scope.traffic = null;
		scope.emit("MileageAiRace", m);
		take();
	});
	scope.emit("MileageAiRace", {phase: "invite", race: "ai1", host: "Taylor", car: "Ibishu Pessima", distance: 2900,
		prize: 3000, seconds: 5});
	take();
	[{winner: "norto22"}, {winner: "Sam"}, {winner: "norto22", prize: 0}, {aiWon: true}, {why: "timeout", places: []},
		{why: "aiOut"}, {why: "hostGaveUp", host: "norto22"}, {why: "hostLeft"}, {why: "failed"}, {out: true},
		{winner: "norto22", notFinished: [{name: "Sam"}, {name: "Ibishu Pessima", car: true}]},
		{winner: "norto22", notFinished: [{name: "Ibishu Pessima", car: true, out: "stuck"}]},
		{winner: "norto22", prize: 0, prizeAgainIn: 0, rewardWithheld: "slow"},
		{winner: "norto22", prize: 0, prizeAgainIn: 0, rewardWithheld: "jumped"}]
		.forEach((extra) => {
			scope.emit("MileageAiRace", Object.assign({phase: "result", why: "finished"}, base, extra));
			take();
		});
	["countdown", "go", "racing", "finished"].forEach((phase) => {
		scope.emit("MileageRace", {phase, race: "ai1", other: "the Ibishu Pessima", count: 3, elapsed: 5, rolling: true,
			reward: 3000});
		shown.push(...texts(scope.race.view));
	});
	assert.ok(shown.length > 40, "views checked: " + shown.length);
	const said = shown.filter((t) => /\bAI\b/.test(t));
	assert.deepStrictEqual(said, []);
	assert.ok(!/\bAI\b/.test(TEMPLATE.replace(/mileage_aiRace|aiRace/g, "")), "nor the page");
});

//== the template ================================================================

test("the template binds every text as text, never as markup", () => {
	assert.ok(!/ng-bind-html|innerHTML/.test(TEMPLATE), "no markup binding");
	assert.ok(!/\{\{/.test(TEMPLATE), "no interpolation either: ng-bind only");
	assert.ok(/ng-bind="offer\.view\.title"/.test(TEMPLATE), "title bound as text");
});

test("every top-level declaration can be evaluated twice", () => {
	const source = fs.readFileSync(SOURCE, "utf8");
	assert.ok(!/^(let|const) /m.test(source), "no top-level let or const");
	const context = {
		angular: {module: () => ({directive() {}, controller() {}})},
		bngApi: {engineLua() {}}, TextEncoder, btoa,
	};
	vm.createContext(context);
	vm.runInContext(source, context);
	vm.runInContext(source, context);
});

let failed = 0;
for (const [name, fn] of tests) {
	try {
		fn();
		console.log("ok   " + name);
	} catch (err) {
		failed++;
		console.log("FAIL " + name + "\n     " + err.message);
	}
}
console.log(`${tests.length - failed} passed, ${failed} failed`);
process.exitCode = failed > 0 ? 1 : 0;
