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
	assert.strictEqual(v.note, "Your car moves beside theirs · leaving loses your stake");
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

//== a drag race for money ========================================================

const DRAG = {id: "o9", kind: "drag", from: "Turbo_Tom", amount: 2000, prize: 500, minutes: 15, secondsLeft: 60};

test("a drag challenge shows where, the stake, what the winner gets and how the stakes are lost", () => {
	const {scope} = load();
	scope.emit("MileageOffer", DRAG);
	const v = scope.offers[0].view;
	assert.strictEqual(v.title, "Turbo_Tom challenges you to a drag race");
	assert.deepStrictEqual(rows(v), ["Where: The drag strip, within 15 min", "Stake: $2,000 each",
		"Winner gets: $4,000 + $500 server prize"]);
	assert.strictEqual(v.note, "Your next run together decides it · after the green, leaving or jumping the start loses your stake");
	assert.strictEqual(v.accept, "Accept");
	scope.emit("MileageOffer", Object.assign({}, DRAG, {id: "o10", amount: 0}));
	const free = scope.offers[1].view;
	assert.deepStrictEqual(rows(free), ["Where: The drag strip, within 15 min", "Stake: No stake",
		"Winner gets: $500 server prize"]);
	assert.strictEqual(free.note, "Your next run together decides it");
});

const HELD = {race: "r3", phase: "toStrip", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000, prize: 500, minutesLeft: 13};

test("held stakes: the card says what the winner gets, the time left, and Call off sends it to the game", () => {
	const {scope, lua} = load();
	scope.emit("MileageDragRace", {race: "r3", phase: "staking", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000});
	assert.strictEqual(scope.drag.view.note, "Taking both stakes...");
	scope.emit("MileageDragRace", HELD);
	const v = scope.drag.view;
	assert.strictEqual(v.title, "Drag race vs DriftQueen_77");
	assert.deepStrictEqual(rows(v), ["Stakes held: $2,000 each", "Winner gets: $4,000 + $500 prize"]);
	assert.strictEqual(v.note, "Meet at the drag strip and line up together · 13 min left");
	assert.strictEqual(v.callOff, "Call off (stakes back)");
	scope.callOffDrag();
	assert.ok(lua.includes("if mileage_dragMoney then mileage_dragMoney.callOff() end"), "call off sent");
	scope.emit("MileageDragRace", Object.assign({}, HELD, {note: "lined", minutesLeft: 11}));
	assert.strictEqual(scope.drag.view.note, "This run decides the stakes · 11 min left");
	scope.emit("MileageDragRace", Object.assign({}, HELD, {note: "ended", minutesLeft: 9}));
	assert.strictEqual(scope.drag.view.note, "That run ended before the green · stakes still held, line up again · 9 min left");
	scope.emit("MileageDragRace", {race: "r3", phase: "racing", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000});
	assert.strictEqual(scope.drag.view.callOff, undefined, "no Call off once the run went green");
});

test("a called-off drag race says why and gives the stake back", () => {
	const {scope} = load();
	scope.emit("MileageDragRace", {race: "r3", phase: "calledOff", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000,
		why: "DriftQueen_77 called it off"});
	assert.strictEqual(scope.drag.view.title, "Drag race called off");
	assert.strictEqual(scope.drag.view.note, "DriftQueen_77 called it off.");
	assert.deepStrictEqual(rows(scope.drag.view), ["Stake: $2,000 back to you"]);
	scope.emit("MileageDragRace", {race: "r4", phase: "calledOff", you: "Turbo_Tom", other: "D", stake: 2000,
		why: "no run together in 15 min"});
	assert.strictEqual(scope.drag.view.note, "No run together in 15 min.");
	scope.closeDrag();
	assert.strictEqual(scope.drag, null, "closed");
});

test("the winner of a staked run sees one total, both times with the gap, and the stakes and prize split", () => {
	const {scope} = load();
	scope.emit("MileageDragRace", {race: "r3", phase: "result", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000,
		pot: 4000, prize: 500, winner: "Turbo_Tom", why: "finished",
		times: {Turbo_Tom: 12.418, DriftQueen_77: 12.901}, outcomes: {Turbo_Tom: "finished", DriftQueen_77: "finished"}});
	const v = scope.drag.view;
	assert.strictEqual(v.title, "You won $4,500");
	assert.deepStrictEqual(rows(v), ["Your time: 12.418 s", "DriftQueen_77: 12.901 s (+0.483 s)",
		"You get: $4,000 stakes + $500 prize"]);
	assert.strictEqual(v.close, true);
});

test("the loser of a staked run sees who won, that they jumped or left, and the stake lost", () => {
	const {scope} = load();
	scope.emit("MileageDragRace", {race: "r3", phase: "result", you: "DriftQueen_77", other: "Turbo_Tom", stake: 2000,
		pot: 4000, prize: 500, winner: "Turbo_Tom", why: "jumped",
		times: {Turbo_Tom: 12.418}, outcomes: {Turbo_Tom: "finished", DriftQueen_77: "jumped"}});
	assert.strictEqual(scope.drag.view.title, "Turbo_Tom won the drag race");
	assert.deepStrictEqual(rows(scope.drag.view), ["Your time: jumped the start", "Turbo_Tom: 12.418 s",
		"You lost: your $2,000 stake"]);
	scope.emit("MileageDragRace", {race: "r3", phase: "result", you: "DriftQueen_77", other: "Turbo_Tom", stake: 2000,
		pot: 4000, prize: 0, winner: "Turbo_Tom", why: "left",
		times: {Turbo_Tom: 12.418}, outcomes: {Turbo_Tom: "finished", DriftQueen_77: "none"}});
	assert.strictEqual(rows(scope.drag.view)[0], "Your time: did not finish: you left the race");
	scope.emit("MileageDragRace", {race: "r3", phase: "result", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000,
		pot: 4000, prize: 0, winner: "Turbo_Tom", why: "left",
		times: {Turbo_Tom: 12.418}, outcomes: {Turbo_Tom: "finished", DriftQueen_77: "none"}});
	assert.strictEqual(rows(scope.drag.view)[1], "DriftQueen_77: left the race");
	assert.strictEqual(scope.drag.view.title, "You won $4,000");
});

test("a plain run that paid the prize: the prize to the winner, who won to the loser, no money line", () => {
	const {scope} = load();
	scope.emit("MileageDragRace", {run: "alderStrip-5", phase: "result", you: "Turbo_Tom", other: "DriftQueen_77",
		stake: 0, pot: 0, prize: 500, winner: "Turbo_Tom", times: {Turbo_Tom: 12.4}});
	assert.strictEqual(scope.drag.view.title, "You won $500");
	assert.deepStrictEqual(rows(scope.drag.view), ["vs: DriftQueen_77", "You get: $500 prize"]);
	scope.emit("MileageDragRace", {run: "alderStrip-5", phase: "result", you: "DriftQueen_77", other: "Turbo_Tom",
		stake: 0, pot: 0, prize: 500, winner: "Turbo_Tom"});
	assert.strictEqual(scope.drag.view.title, "Turbo_Tom won the drag race");
	assert.deepStrictEqual(rows(scope.drag.view), ["vs: Turbo_Tom"]);
});

test("a staked run with no winner gives the stake back and says why", () => {
	const {scope} = load();
	scope.emit("MileageDragRace", {race: "r3", phase: "result", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000,
		pot: 0, prize: 0, why: "noFinish", times: {}, outcomes: {}});
	assert.strictEqual(scope.drag.view.title, "No winner");
	assert.deepStrictEqual(rows(scope.drag.view), ["Stake: $2,000 back to you"]);
	assert.strictEqual(scope.drag.view.note, "Neither car crossed the finish line · both stakes go back.");
	scope.emit("MileageDragRace", {race: "r3", phase: "result", you: "Turbo_Tom", other: "DriftQueen_77", stake: 2000,
		pot: 0, prize: 0, why: "tie", times: {Turbo_Tom: 12, DriftQueen_77: 12}, outcomes: {}});
	assert.strictEqual(scope.drag.view.note, "A dead heat · both stakes go back.");
});

test("the drag card binds every text as text, and the app asks for the drag race under way when it loads", () => {
	const {lua} = load();
	assert.ok(lua.includes("if mileage_dragMoney then mileage_dragMoney.sendState() end"));
	const card = TEMPLATE.slice(TEMPLATE.indexOf('ng-if="drag"'), TEMPLATE.indexOf('ng-if="traffic"'));
	assert.ok(card.includes('ng-bind="drag.view.title"'), "title bound");
	assert.ok(!/\{\{/.test(card) && !/ng-bind-html/.test(card), "no interpolated markup");
});

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
	assert.strictEqual(scope.race.view.note, "Nobody reached the finish in time.");
	assert.deepStrictEqual(rows(scope.race.view), ["Stake: $1,000 back to you"]);
	scope.emit("MileageRace", {phase: "calledOff", race: "r2", why: "b did not have the stake", stake: 500});
	assert.strictEqual(scope.race.view.title, "Race called off");
	assert.strictEqual(scope.race.view.note, "b did not have the stake.");
	assert.deepStrictEqual(rows(scope.race.view), ["Stake: $500 back to you"]);
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
	assert.strictEqual(v.line, "Ibishu Pessima · 1.5–4 km · $2,000", "car, finish range and reward on one line");
	assert.deepStrictEqual(rows(v), [], "no rows");
	assert.strictEqual(v.note, "+50% per player who joins · 300 m invite");
	assert.strictEqual(v.key, undefined, "no key bound");
	assert.strictEqual(v.keyHint, "Key: Options › Controls", "where to set one, beside the title");
	assert.strictEqual(v.raceOff, false, "the button is on");
	scope.raceTraffic();
	assert.ok(lua.includes("if mileage_aiRace then mileage_aiRace.press() end"));
	scope.emit("MileageAiRace", Object.assign({}, OWN, {key: "J"}));
	assert.strictEqual(scope.traffic.view.key, "J", "the bound key");
	assert.strictEqual(scope.traffic.view.keyHint, undefined, "no hint with a key bound");
	assert.ok(/mo-head[\s\S]*ng-bind="traffic\.view\.key"[\s\S]*ng-bind="traffic\.view\.line"/.test(TEMPLATE),
		"the key sits in the title row, above the line");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {prizeAgainIn: 330}));
	assert.strictEqual(scope.traffic.view.line, "Ibishu Pessima · 1.5–4 km · reward in 6 min");
	assert.strictEqual(scope.traffic.view.note, "A win still counts on the leaderboard · 300 m invite");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {prize: 0}));
	assert.strictEqual(scope.traffic.view.line, "Ibishu Pessima · 1.5–4 km · no reward");
	assert.strictEqual(scope.traffic.view.note, "A win counts on the leaderboard · 300 m invite");
	scope.emit("MileageAiRace", Object.assign({}, OWN, {note: "No reachable finish from here, try another road."}));
	assert.strictEqual(scope.traffic.view.line, "Ibishu Pessima", "only the car with a refusal");
	assert.strictEqual(scope.traffic.view.note, "No reachable finish from here, try another road.");
	scope.emit("MileageAiRace", {phase: "none"});
	assert.strictEqual(scope.traffic, null, "no car beside you");
});

test("next to another player's traffic, or with racing traffic off, the button is off and says why", () => {
	const {scope} = load();
	scope.emit("MileageAiRace", {phase: "available", own: false, car: "Gavril Grand Marshal", owner: "Alex", allowed: true});
	assert.strictEqual(scope.traffic.view.raceOff, true);
	assert.strictEqual(scope.traffic.view.line, "Gavril Grand Marshal");
	assert.strictEqual(scope.traffic.view.note, "Only Alex's game can race it; find your own traffic");
	assert.strictEqual(scope.traffic.view.keyHint, undefined, "no key hint with the button off");
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
	assert.strictEqual(v.line, "vs Ibishu Pessima · 2.9 km · $3,000", "the car, the finish from you and the reward");
	assert.strictEqual(v.note, "First player to beat it wins · rolling start", "who earns the reward");
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
	assert.strictEqual(scope.traffic.view.line, "vs C · 0.0 km", "no reward to show");
	assert.strictEqual(scope.traffic.view.note, "Rolling start from where you are");
	scope.declineTraffic();
	assert.strictEqual(scope.traffic, null, "declined");
	assert.ok(lua.includes("if mileage_aiRace then mileage_aiRace.decline() end"));
});

test("once a race counts down, an invite or a car card goes but a result stays", () => {
	const {scope} = load();
	const INVITE = {phase: "invite", race: "ai3-9", host: "Taylor", car: "Ibishu Pessima", distance: 2900, prize: 3000,
		seconds: 5};
	scope.emit("MileageAiRace", INVITE);
	scope.emit("MileageAiRace", {phase: "none"});
	assert.strictEqual(scope.traffic.kind, "invite", "no car beside you leaves the invite");
	scope.emit("MileageAiRace", {phase: "racing", race: "ai3-9"});
	assert.strictEqual(scope.traffic, null, "a joined invite goes once its race counts down");
	scope.emit("MileageAiRace", OWN);
	scope.emit("MileageAiRace", {phase: "racing", race: "ai5"});
	assert.strictEqual(scope.traffic, null, "the car card goes too");
	scope.emit("MileageAiRace", {phase: "result", race: "ai1", host: "x", car: "C", winner: null, places: [], you: "y"});
	scope.emit("MileageAiRace", {phase: "racing", race: "ai6"});
	scope.emit("MileageAiRace", {phase: "none"});
	assert.strictEqual(scope.traffic.kind, "result", "a result stays until closed");
});

test("the rolling countdown and race panel say keep driving and show the reward", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "countdown", race: "ai1", other: "the Ibishu Pessima and Sam", stake: 0, count: 4,
		rolling: true, reward: 3000});
	assert.strictEqual(scope.race.view.big, "4");
	assert.strictEqual(scope.race.view.title, "vs the Ibishu Pessima and Sam", "who you race moves to the title");
	assert.strictEqual(scope.race.view.note, "Rolling start · keep driving · reward $3,000");
	scope.emit("MileageRace", {phase: "go", race: "ai1", other: "the Ibishu Pessima", stake: 0, rolling: true, reward: 3000});
	assert.strictEqual(scope.race.view.title, "vs the Ibishu Pessima");
	assert.strictEqual(scope.race.view.note, "Race reward $3,000");
	scope.emit("MileageRace", {phase: "racing", race: "ai1", other: "the Ibishu Pessima", stake: 0, elapsed: 72.4,
		distance: 1300, rolling: true, reward: 3000});
	assert.strictEqual(scope.race.view.title, "Racing the Ibishu Pessima");
	assert.strictEqual(scope.race.view.note, "Finish 1.3 km · follow your map route · reward $3,000");
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
	assert.strictEqual(v.title, "You won · $3,000", "the reward in the title");
	assert.deepStrictEqual([...v.places].map((r) => r.place + " " + r.name + " " + r.value),
		["1 You 2:31.4", "2 Ibishu Pessima 2:33.0", "3 Sam 2:40.2"]);
	assert.deepStrictEqual(rows(v), []);
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
	assert.strictEqual(v.note, "Nobody beat it, so no reward this time.");
	scope.emit("MileageAiRace", {phase: "result", race: "ai3", host: "norto22", car: "Ibishu Pessima", places: [],
		prize: 0, reward: 2000, why: "aiOut", you: "Sam"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Ibishu Pessima: out: crashed or stuck for 15 s"]);
	assert.strictEqual(scope.traffic.view.note, "No winner, no reward · the car is back in traffic");
	scope.emit("MileageAiRace", {phase: "result", race: "ai4", host: "norto22", car: "Ibishu Pessima", places: [],
		prize: 0, reward: 2000, why: "hostGaveUp", you: "norto22"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Your time: did not finish: you gave up"]);
	assert.strictEqual(scope.traffic.view.note, "No winner, no reward · the car is back in traffic");
	scope.emit("MileageAiRace", {phase: "result", race: "ai4b", host: "Taylor", car: "Ibishu Pessima", places: [],
		prize: 0, reward: 2000, why: "hostLeft", you: "norto22"});
	assert.strictEqual(scope.traffic.view.note, "Taylor left: no winner, no reward");
	scope.emit("MileageAiRace", {phase: "result", race: "ai5", host: "norto22", car: "Ibishu Pessima", out: true,
		places: [], prize: 0, why: "gaveUp", you: "Sam"});
	assert.strictEqual(scope.traffic.view.title, "You left the race");
	assert.strictEqual(scope.traffic.view.note, "The others race on; no reward for you this time.");
	scope.emit("MileageAiRace", {phase: "result", race: "ai6", host: "norto22", car: "Ibishu Pessima", winner: "norto22",
		places: PLACES, prize: 0, reward: 2000, prizeAgainIn: 240, why: "finished", you: "norto22"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Race reward: Again in 4 min"]);
	assert.strictEqual(scope.traffic.view.note, "The win counts on the leaderboard.");
	scope.emit("MileageAiRace", {phase: "result", race: "ai7", host: "norto22", car: "Ibishu Pessima", winner: "norto22",
		places: PLACES, prize: 0, reward: 2000, prizeAgainIn: 0, why: "finished", you: "norto22"});
	assert.deepStrictEqual(rows(scope.traffic.view), ["Race reward: Not paid for this race"],
		"a win the server could not pay never says again in 0 min");
});

test("an unpaid win's reward row: a wait under a minute reads 1 min, a bad wait reads not paid, no row with the reward off", () => {
	const {scope} = load();
	const won = (extra) => {
		scope.emit("MileageAiRace", Object.assign({phase: "result", race: "ai8", host: "norto22", car: "Ibishu Pessima",
			winner: "norto22", places: PLACES, prize: 0, reward: 2000, why: "finished", you: "norto22"}, extra));
		return rows(scope.traffic.view);
	};
	assert.deepStrictEqual(won({prizeAgainIn: 30}), ["Race reward: Again in 1 min"],
		"30 s left is rounded up, never shown as 0 min");
	assert.deepStrictEqual(won({prizeAgainIn: 61}), ["Race reward: Again in 2 min"]);
	assert.deepStrictEqual(won({prizeAgainIn: -5}), ["Race reward: Not paid for this race"],
		"a negative wait is no wait");
	assert.deepStrictEqual(won({prizeAgainIn: "soon"}), ["Race reward: Not paid for this race"],
		"a wait that is not a number is no wait");
	assert.deepStrictEqual(won({prizeAgainIn: undefined}),
		["Race reward: Not paid for this race"], "no wait sent");
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
	assert.strictEqual(v.title, "You won · $3,000");
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2", "- Sam did not finish", "- Ibishu Pessima still on its way"]);
	v = shown({notFinished: [{name: "Ibishu Pessima", car: true, out: "gone"}]});
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2", "- Ibishu Pessima out: crashed or stuck"]);
	v = shown({notFinished: [{name: "norto22"}], winner: "Sam", places: [{name: "Sam", seconds: 39}], you: "norto22"});
	assert.deepStrictEqual(placeRows(v), ["1 Sam 0:39.0", "- You did not finish"]);
	v = shown({notFinished: "broken"});
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2"], "a list that is not one adds nothing");
	v = shown({prize: 0, prizeAgainIn: 0, rewardWithheld: "slow"});
	assert.deepStrictEqual(rows(v),
		["Race reward: Not paid: the car was too slow to count"]);
	v = shown({prize: 0, prizeAgainIn: 0, rewardWithheld: "jumped"});
	assert.deepStrictEqual(rows(v),
		["Race reward: Not paid: the car jumped too far"]);
	scope.emit("MileageAiRace", {phase: "result", race: "ai10", host: "norto22", car: "Ibishu Pessima", places: [],
		notFinished: [{name: "norto22"}, {name: "Ibishu Pessima", car: true, out: "stuck"}], prize: 0, reward: 2000,
		why: "aiOut", you: "norto22"});
	assert.strictEqual(scope.traffic.view.note, "No winner, no reward · the car is back in traffic");
});

test("a traffic race result skips broken not-finished entries and never reads a withheld reason off the prototype", () => {
	const {scope} = load();
	const shown = (extra) => {
		scope.emit("MileageAiRace", Object.assign({phase: "result", race: "ai11", host: "norto22", car: "Ibishu Pessima",
			winner: "norto22", aiWon: false, places: [{name: "norto22", seconds: 40.2}], prize: 0, reward: 3000,
			prizeAgainIn: 0, why: "finished", you: "norto22"}, extra));
		return scope.traffic.view;
	};
	const placeRows = (v) => [...(v.places || [])].map((r) => r.place + " " + r.name + " " + r.value);
	let v = shown({notFinished: [null, "Sam", 5, {name: "Bob"}]});
	assert.deepStrictEqual(placeRows(v), ["1 You 0:40.2", "- Bob did not finish"], "only the entry that is one");
	for (const why of ["toString", "constructor", "__proto__", "made up"]) {
		v = shown({rewardWithheld: why});
		assert.deepStrictEqual(rows(v), ["Race reward: Not paid for this race"], why);
	}
	v = shown({prize: 3000, rewardWithheld: "slow"});
	assert.deepStrictEqual(rows(v), [], "a paid reward wins over a stray reason");
	assert.strictEqual(v.title, "You won · $3,000");
	v = shown({reward: 0, rewardWithheld: "slow"});
	assert.deepStrictEqual(rows(v), [], "no reward row with the reward off");
	v = shown({winner: null, aiWon: true, places: [{name: "Ibishu Pessima", seconds: 38, car: true}],
		notFinished: [{name: "norto22"}]});
	assert.deepStrictEqual(placeRows(v), ["1 Ibishu Pessima 0:38.0", "- You did not finish"], "the car's win lists her too");
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

//== races at race spots ===========================================================

const SETUP = {phase: "setup", spot: "city_race_1", spotName: "City Race 1", allowed: true, prize: 2000, againIn: 0,
	opponentsMax: 5, you: "Taylor", note: null, routes: [{id: "city_race_1", name: "City Race 1", laps: 2, length: 4100,
		closed: true, best: 221.27, bestBy: "Sam", mine: 232.8}],
	players: [{name: "Sam", busy: false}, {name: "Jordan", busy: false}, {name: "Alex", busy: true}]};

const rowsOf = (view) => [...(view.rows || [])].map((r) => r.label + ": " + r.value);

test("the set-up card shows the route, the bests, the prize, the opponents and who to invite", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", SETUP);
	const v = scope.spot.view;
	assert.strictEqual(v.title, "Race spot: City Race 1");
	assert.deepStrictEqual(rowsOf(v), ["Route: Circuit, 2 laps, 4.1 km", "Best time here: 3:41.27 by Sam",
		"Your best: 3:52.80", "Prize for first place: $4,000 for 4 racers"]);
	assert.strictEqual(v.stepper.value, 3, "three opponents to start with");
	assert.strictEqual(v.stepper.max, 5);
	assert.strictEqual(v.layouts, null, "one route, no layout choice");
	assert.deepStrictEqual(v.players.map((p) => p.name + (p.busy ? " busy" : "")), ["Sam", "Jordan", "Alex busy"]);
	assert.strictEqual(v.start, "Start race");
});

test("Start sends the route, the opponents and the invited players, encoded", () => {
	const {scope, lua} = load();
	scope.emit("MileageSpotRace", SETUP);
	scope.spotOpponents(1);
	scope.spotPick(scope.spot.view.players[0]);
	scope.spotPick(scope.spot.view.players[2]);
	scope.spotStart();
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.request(" + b64("city_race_1") +
		", 4, " + b64('["Sam"]') + ") end", "a busy player cannot be picked");
	assert.strictEqual(scope.spot.view.startOff, true, "pressed once");
	const sent = lua.length;
	scope.spotStart();
	assert.strictEqual(lua.length, sent, "not sent twice");
});

test("the opponents stay within 0 and the server's maximum; none and nobody invited is a timed run", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {opponentsMax: 2, prize: 0}));
	assert.strictEqual(scope.spot.view.stepper.value, 2, "the maximum when it is below three");
	scope.spotOpponents(1);
	assert.strictEqual(scope.spot.view.stepper.value, 2);
	for (let i = 0; i < 4; i++) scope.spotOpponents(-1);
	assert.strictEqual(scope.spot.view.stepper.value, 0);
	assert.strictEqual(scope.spot.view.start, "Start run");
	assert.strictEqual(scope.spot.view.note, "Solo run: a leaderboard time, no prize");
	assert.ok(rowsOf(scope.spot.view).includes("Prize: None on this server"));
});

test("the set-up card's prize grows with the opponents and the friends picked", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {prize: 1000}));
	const prize = () => rowsOf(scope.spot.view).filter((r) => r.startsWith("Prize"))[0];
	assert.strictEqual(prize(), "Prize for first place: $2,000 for 4 racers", "three opponents to start with");
	scope.spotOpponents(-2);
	assert.strictEqual(prize(), "Prize for first place: $1,000 for 2 racers", "one opponent: the owner's prize");
	scope.spotOpponents(4);
	assert.strictEqual(prize(), "Prize for first place: $3,000 for 6 racers", "five opponents: three times");
	scope.spotOpponents(-5);
	scope.spotPick(scope.spot.view.players[0]);
	assert.strictEqual(prize(), "Prize for first place: $1,000 for 2 racers", "a friend counts as a racer");
	scope.spotPick(scope.spot.view.players[1]);
	assert.strictEqual(prize(), "Prize for first place: $1,500 for 3 racers", "and grows it by half");
	scope.spotPick(scope.spot.view.players[0]);
	scope.spotPick(scope.spot.view.players[1]);
	assert.strictEqual(prize(), "Prize for first place: $1,000 with a rival", "a run alone shows the prize a race pays");
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {prize: 1000, againIn: 300}));
	assert.strictEqual(prize(), "Prize for first place: Again in 5 min", "the wait as before");
});

test("the set-up card's grown prize is rounded down to whole dollars, as the server pays it", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {prize: 1001}));
	const prize = () => rowsOf(scope.spot.view).filter((r) => r.startsWith("Prize"))[0];
	scope.spotOpponents(-1);
	assert.strictEqual(prize(), "Prize for first place: $1,501 for 3 racers", "1001 x 1.5 = 1501.5, rounded down");
});

test("a car changed since its last performance test is told its rivals may not match; a tested one is not", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {untested: true}));
	assert.strictEqual(scope.spot.view.warn, "Untested car: rivals may not match it until it is tested");
	assert.strictEqual(scope.spot.view.note, "Friends who join are moved onto the grid beside you.", "the usual note stays");
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {untested: false}));
	assert.strictEqual(scope.spot.view.warn, undefined, "a tested car: no warning");
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {untested: true, note: "Drive into the start marker first."}));
	assert.strictEqual(scope.spot.view.warn, undefined, "a reason it cannot start comes alone");
	assert.strictEqual(scope.spot.view.note, "Drive into the start marker first.", "a reason it cannot start comes alone");
});

test("the race track's card offers its layouts and keeps the choice when the card is sent again", () => {
	const {scope, lua} = load();
	const track = Object.assign({}, SETUP, {spot: "race_track", spotName: "Race Track", routes: [
		{id: "race_track", name: "Race Track", laps: 2, length: 8065, closed: true},
		{id: "race_track_chicane", name: "Race Track Chicane", laps: 2, length: 8069, closed: true},
		{id: "race_track_short", name: "Race Track Short", laps: 2, length: 4885, closed: true}]});
	scope.emit("MileageSpotRace", track);
	assert.deepStrictEqual(scope.spot.view.layouts.map((l) => l.name), ["Race Track", "Race Track Chicane", "Race Track Short"]);
	scope.spotLayout(2);
	assert.ok(rowsOf(scope.spot.view).includes("Route: Circuit, 2 laps, 4.9 km"));
	assert.ok(rowsOf(scope.spot.view).includes("Best time here: No times yet"));
	scope.emit("MileageSpotRace", Object.assign({}, track, {note: "Drive into the start marker first."}));
	assert.strictEqual(scope.spot.view.layouts[2].on, true, "still the short layout");
	assert.strictEqual(scope.spot.view.note, "Drive into the start marker first.", "the server's reason shows");
	scope.spotStart();
	assert.ok(lua[lua.length - 1].includes(b64("race_track_short")));
});

test("the countdown, the race panel and the off-route warning", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "countdown", id: "s1", routeName: "City Race 1", count: 3, you: "Taylor",
		racers: [{name: "Taylor"}, {name: "Sam"}, {name: "Ibishu Pessima", car: true}, {name: "ETK 800", car: true}]});
	assert.strictEqual(scope.spot.view.big, "3");
	assert.deepStrictEqual(rowsOf(scope.spot.view), ["Grid: You, Sam, 2 cars"]);
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "City Race 1", place: 2, of: 5, lap: 1, laps: 2,
		checkpoint: 7, checkpoints: 13, elapsed: 72.4, ahead: "Ibishu Pessima", gap: 1.8, you: "Taylor"});
	assert.deepStrictEqual(rowsOf(scope.spot.view), ["Place: 2 / 5", "Lap: 1 / 2", "Checkpoint: 7 / 13", "Time: 1:12.4",
		"Ahead: Ibishu Pessima, 1.8 s"]);
	assert.strictEqual(scope.spot.view.giveUp, true);
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "City Race 1", lap: 1, laps: 2, checkpoint: 7,
		checkpoints: 13, elapsed: 80, offRoute: 6, nextMetres: 1200, you: "Taylor"});
	assert.strictEqual(scope.spot.view.warn, "Off the route: back to checkpoint 7 within 6 s");
	assert.ok(rowsOf(scope.spot.view).includes("Next checkpoint: 1.2 km away"));
});

test("Give up and Cancel reach the game", () => {
	const {scope, lua} = load();
	scope.emit("MileageSpotRace", {phase: "go", id: "s1", routeName: "City Race 1"});
	scope.spotGiveUp();
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.giveUp() end");
	scope.emit("MileageSpotRace", SETUP);
	scope.spotCancel();
	assert.strictEqual(scope.spot, null);
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.closeSetup() end");
});

test("the result lists every racer with a time or why not, opponents by their model", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "result", id: "s1", routeName: "City Race 1", you: "Taylor", winner: "Taylor",
		prize: 0, prizeOffered: 0, places: [
			{name: "Taylor", seconds: 229.02}, {name: "Ibishu Pessima", car: true, seconds: 230.77},
			{name: "Sam", seconds: 235.1}, {name: "ETK 800", car: true, out: "stuck"}, {name: "Jordan", out: "left"},
			{name: "Alex", out: "quit"}, {name: "Gavril Grand Marshal", car: true}]});
	const v = scope.spot.view;
	assert.strictEqual(v.title, "You won City Race 1");
	assert.deepStrictEqual(v.places.map((p) => p.place + " " + p.name + " " + p.value), [
		"1 You 3:49.02", "2 Ibishu Pessima 3:50.77", "3 Sam 3:55.10", "- ETK 800 Stuck", "- Jordan Left the route",
		"- Alex Left the server", "- Gavril Grand Marshal Did not finish"]);
	assert.strictEqual(v.places[0].me, true);
	assert.strictEqual(v.close, true);
	scope.emit("MileageSpotRace", {phase: "result", id: "s2", routeName: "City Race 1", you: "Taylor", carWon: true,
		places: [{name: "Ibishu Pessima", car: true, seconds: 230}, {name: "Taylor", seconds: 231.4}]});
	assert.strictEqual(scope.spot.view.title, "Ibishu Pessima won City Race 1");
	scope.emit("MileageSpotRace", {phase: "result", id: "s3", routeName: "City Race 1", you: "Taylor", why: "starterLeft",
		places: [{name: "Taylor"}]});
	assert.strictEqual(scope.spot.view.title, "City Race 1: no winner");
	assert.deepStrictEqual([...scope.spot.view.notes], ["The starter left, so the race ended with no winner."]);
});

const INVITE = {phase: "invite", id: "s7-1793", from: "Taylor", opponents: 3, prize: 2000, seconds: 30,
	route: {id: "city_race_1", name: "City Race 1", laps: 2, length: 4100, closed: true}};

test("an invite shows who asks, the spot, the route, the opponents and the prize, with Join, Decline and a bar", () => {
	const {scope, lua, clock} = load();
	scope.emit("MileageSpotRace", INVITE);
	const v = scope.spot.view;
	assert.strictEqual(v.title, "Taylor invites you to a race");
	assert.deepStrictEqual(rowsOf(v), ["Race spot: City Race 1", "Route: Circuit, 2 laps, 4.1 km",
		"Opponents: 3 cars, plus Taylor", "Prize for first place: $2,000"]);
	assert.strictEqual(v.join, true);
	assert.strictEqual(v.note, "Joining moves your car to the start grid.");
	assert.ok(/ng-style="\{width: barWidth\(spot\)\}"/.test(TEMPLATE), "the time bar is on the card");
	clock.now += 15000;
	assert.strictEqual(scope.barWidth(scope.spot), "50%", "half the time left");
	scope.spotJoin();
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.join(" + b64("s7-1793") + ") end");
	scope.emit("MileageSpotRace", Object.assign({}, INVITE, {seconds: 15, note: "Joined: your car moves to the grid when it starts."}));
	assert.strictEqual(scope.barWidth(scope.spot), "50%", "the bar keeps running after Join");
	assert.strictEqual(scope.spot.view.note, "Joined: your car moves to the grid when it starts.");
	scope.spotDecline();
	assert.strictEqual(scope.spot, null, "Decline takes the card away");
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.decline(" + b64("s7-1793") + ") end");
});

test("an invite without a prize leaves the prize out, and a closed invite goes", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", Object.assign({}, INVITE, {prize: 0, opponents: 1}));
	assert.deepStrictEqual(rowsOf(scope.spot.view).slice(2), ["Opponents: 1 car, plus Taylor"]);
	scope.emit("MileageSpotRace", {phase: "inviteClosed", id: "other"});
	assert.ok(scope.spot, "another invite's closing changes nothing");
	scope.emit("MileageSpotRace", {phase: "inviteClosed", id: "s7-1793"});
	assert.strictEqual(scope.spot, null);
	scope.emit("MileageSpotRace", INVITE);
	scope.emit("MileageSpotRace", {phase: "closed", id: "s7-1793", why: "The race started without you."});
	assert.strictEqual(scope.spot.view.title, "Invite over");
	assert.strictEqual(scope.spot.view.note, "The race started without you.");
});

test("the starter's card shows who joined, with Start now and Call off", () => {
	const {scope, lua} = load();
	scope.emit("MileageSpotRace", {phase: "inviting", id: "s7", routeName: "City Race 1", opponents: 3, seconds: 19,
		answers: [{name: "Jordan", answer: "waiting"}, {name: "Kim", answer: "declined"}, {name: "Sam", answer: "joined"}]});
	const v = scope.spot.view;
	assert.strictEqual(v.title, "Race spot: City Race 1");
	assert.deepStrictEqual(rowsOf(v), ["Jordan: Waiting…", "Kim: Declined", "Sam: Joined", "Opponents: 3 cars on the grid"]);
	assert.strictEqual(v.note, "Starts when everyone has answered, or in 19 s.");
	scope.spotStartNow();
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.startNow() end");
	scope.spotCallOff();
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.callOff() end");
	scope.emit("MileageSpotRace", {phase: "closed", id: "s7", why: "The starter called it off."});
	assert.strictEqual(scope.spot.view.title, "Race called off");
});

test("a won race spot shows the prize paid, or why not, and a new best", () => {
	const {scope} = load();
	const won = {phase: "result", id: "s1", routeName: "City Race 1", you: "Taylor", winner: "Taylor", prizeOffered: 2000,
		places: [{name: "Taylor", seconds: 229.02}, {name: "Ibishu Pessima", car: true, seconds: 230.77}]};
	scope.emit("MileageSpotRace", Object.assign({}, won, {prize: 2000, best: {improved: true, old: 232.8}}));
	assert.deepStrictEqual(rowsOf(scope.spot.view), ["Prize: $2,000"]);
	assert.deepStrictEqual([...scope.spot.view.notes], ["New personal best; your best here was 3:52.80."]);
	scope.emit("MileageSpotRace", Object.assign({}, won, {prize: 0, best: {improved: true}}));
	assert.deepStrictEqual([...scope.spot.view.notes], ["Your first time here is on the leaderboard."]);
	const notes = {};
	["alone", "wait", "unseen", "slow"].forEach((withheld) => {
		scope.emit("MileageSpotRace", Object.assign({}, won, {prize: 0, withheld, againIn: 360, best: {improved: false}}));
		notes[withheld] = [...scope.spot.view.notes].join(" | ");
		assert.deepStrictEqual(rowsOf(scope.spot.view), [], withheld + ": no prize row");
	});
	assert.deepStrictEqual(notes, {
		alone: "No prize: nobody else raced; your time still counts",
		// Slow rivals no longer withhold the prize; a reason the app does not know reads plainly.
		slow: "No prize this time.",
		wait: "No prize: you can win it again in 6 min.",
		unseen: "Unranked: not every car was seen; no prize, win or time",
	});
	scope.emit("MileageSpotRace", Object.assign({}, won, {prize: 0, withheld: "alone", why: "timeout",
		best: {improved: true, old: 232.8}}));
	assert.deepStrictEqual([...scope.spot.view.notes], ["No prize: nobody else raced; your time still counts",
		"New personal best; your best here was 3:52.80.", "The time ran out."], "each on its own line");
	scope.emit("MileageSpotRace", Object.assign({}, won, {prize: 0, prizeOffered: 0, withheld: "alone"}));
	assert.deepStrictEqual([...scope.spot.view.notes], [], "no prize on this server: nothing to explain");
	scope.emit("MileageSpotRace", {phase: "result", id: "s2", routeName: "City Race 1", you: "Taylor", carWon: true,
		prizeOffered: 2000, withheld: "car won", places: [{name: "ETK 800", car: true, seconds: 230}, {name: "Taylor", seconds: 231}]});
	assert.deepStrictEqual([...scope.spot.view.notes], ["No prize: only a player who finishes first is paid."]);
});

test("the leaderboard has a Race spots tab with each route's fastest players", () => {
	const {scope} = load();
	scope.emit("MileageLeaderboard", {wins: [], drag: {}, spots: {
		mountain_race: {name: "Mountain Race", rows: [{name: "Jordan", time: 372.9}]},
		city_race_1: {name: "City Race 1", rows: [{name: "Sam", time: 221.27}, {name: "Taylor", time: 229.02}]}}});
	scope.showTab("spots");
	const spots = scope.leaderboard.spots;
	assert.deepStrictEqual([...spots].map((s) => s.name), ["City Race 1", "Mountain Race"], "by name");
	assert.deepStrictEqual([...spots[0].rows].map((r) => r.place + " " + r.name + " " + r.value), ["1 Sam 3:41.27",
		"2 Taylor 3:49.02"]);
	assert.ok(/showTab\('spots'\)">Race spots</.test(TEMPLATE), "the tab is on the page");
	assert.ok(TEMPLATE.includes("No race spot times yet; drive to one on the map."), "with a line for an empty board");
	scope.emit("MileageLeaderboard", {wins: [], drag: {}});
	assert.strictEqual(scope.leaderboard.spots.length, 0, "an older server sends none");
	assert.strictEqual(scope.leaderboard.tab, "spots", "the tab is kept");
});

test("a server that allows no opponents keeps the stepper at 0 and offers a timed run", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", Object.assign({}, SETUP, {opponentsMax: 0}));
	assert.strictEqual(scope.spot.view.stepper.value, 0, "none to start with");
	assert.strictEqual(scope.spot.view.stepper.max, 0, "the server's maximum");
	scope.spotOpponents(1);
	assert.strictEqual(scope.spot.view.stepper.value, 0, "+ cannot pass the server's maximum");
	assert.strictEqual(scope.spot.view.start, "Start run");
});

test("a broken race spot result or leaderboard shows what it can and keeps the app working", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "result", id: "s9", routeName: "City Race 1", you: "Taylor", places: "none"});
	assert.strictEqual(scope.spot.view.title, "City Race 1: no winner");
	assert.deepStrictEqual([...scope.spot.view.places], [], "no places to list");
	scope.emit("MileageLeaderboard", {wins: [], drag: {}, spots: {
		city_race_1: {name: "City Race 1", rows: "x"}, highway_race: null}});
	scope.showTab("spots");
	assert.deepStrictEqual([...scope.leaderboard.spots].map((s) => s.name + ": " + s.rows.length),
		["City Race 1: 0", "highway_race: 0"], "each route listed, by its id when the name is missing");
});

test("times just under a whole minute or second round up into the next, never show 60 seconds", () => {
	const {scope, context} = load();
	scope.emit("MileageLeaderboard", {wins: [], drag: {}, spots: {r: {name: "R", rows: [
		{name: "A", time: 59.996}, {name: "B", time: 69.996}, {name: "C", time: 119.999}, {name: "D", time: 61.5}]}}});
	assert.deepStrictEqual([...scope.leaderboard.spots[0].rows].map((r) => r.value),
		["1:00.00", "1:10.00", "2:00.00", "1:01.50"]);
	assert.strictEqual(context.moTime(59.96), "1:00.0", "the race panel's clock too");
	assert.strictEqual(context.moTime(119.97), "2:00.0");
	assert.strictEqual(context.moTime(72.44), "1:12.4");
});

test("no text the app shows for a race spot says AI", () => {
	const {scope} = load();
	const texts = (v) => [v.title, v.note, v.warn, v.big, v.start].concat((v.rows || []).map((r) => r.label + " " + r.value),
		(v.places || []).map((p) => p.name + " " + p.value)).filter((t) => typeof t === "string");
	const shown = [];
	scope.emit("MileageSpotRace", SETUP);
	shown.push(...texts(scope.spot.view));
	scope.emit("MileageSpotRace", {phase: "countdown", id: "s1", routeName: "R", count: 2, racers: [{name: "ETK 800", car: true}]});
	shown.push(...texts(scope.spot.view));
	["alone", "slow", "car won", "wait", "unseen"].forEach((withheld) => {
		scope.emit("MileageSpotRace", {phase: "result", id: "s1", routeName: "R", you: "T", winner: "T", prizeOffered: 100,
			withheld, places: [{name: "T", seconds: 10}, {name: "ETK 800", car: true, out: "gone"}]});
		shown.push(...texts(scope.spot.view));
	});
	assert.ok(shown.length > 20, "views checked: " + shown.length);
	assert.deepStrictEqual(shown.filter((t) => /\bAI\b/.test(t)), []);
});

//== the compact look ============================================================

// The declarations of the first rule whose selector list is exactly `selector`.
function cssRule(css, selector) {
	const re = /([^{}]+)\{([^}]*)\}/g;
	let m;
	while ((m = re.exec(css)) !== null) {
		if (m[1].replace(/\/\*[\s\S]*?\*\//g, "").trim() === selector) {
			const props = {};
			m[2].split(";").forEach((d) => {
				const i = d.indexOf(":");
				if (i > 0) props[d.slice(0, i).trim()] = d.slice(i + 1).trim();
			});
			return props;
		}
	}
	throw new Error("no rule " + selector);
}

const CSS = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Offers/app.css", "utf8");

test("every prompts card uses the compact sizes: padding, gaps, text and buttons", () => {
	assert.strictEqual(cssRule(CSS, ".mo-card").padding, "6px 8px", "card padding");
	assert.strictEqual(cssRule(CSS, ".mo-card")["margin-bottom"], "4px", "gap between cards");
	assert.strictEqual(cssRule(CSS, ".mo-row")["font-size"], "0.85em", "rows");
	assert.strictEqual(cssRule(CSS, ".mo-note")["font-size"], "0.8em", "notes");
	assert.strictEqual(cssRule(CSS, ".mo-title")["font-size"], "0.95em", "title");
	const button = cssRule(CSS, ".mo-actions button, .mo-card button");
	assert.strictEqual(button.padding, "4px 8px", "button padding");
	assert.strictEqual(button["font-size"], "0.85em", "button text");
	assert.strictEqual(cssRule(CSS, ".mo-table")["font-size"], "0.85em", "tables as rows");
	assert.ok(!/text-overflow:\s*ellipsis/.test(CSS), "nothing cut off with an ellipsis");
});

// Every note line a view shows: its note, each of its notes, and a warning.
function noteLines(view) {
	if (!view) return [];
	return [view.note, view.warn].concat(view.notes || []).filter((t) => typeof t === "string" && t !== "");
}

test("every note in the prompts window is one line of at most 60 characters", () => {
	const {scope} = load();
	const seen = [];
	const look = (where, view) => noteLines(view).forEach((text) => seen.push({where, text}));
	const emit = (name, data, slot) => {
		scope.emit(name, data);
		const value = scope[slot];
		look(name + " " + (data.phase || data.kind || ""), Array.isArray(value) ? value[value.length - 1].view
			: value && value.view);
	};
	// Challenges and money requests.
	emit("MileageOffer", REQUEST, "offers");
	emit("MileageOffer", RACE, "offers");
	emit("MileageOffer", Object.assign({}, RACE, {id: "o9", amount: 0}), "offers");
	// A race against a player, rolling and not.
	const OTHER = {race: "r1", other: "Sam", stake: 1000};
	["staking", "lining up"].forEach((phase) => emit("MileageRace", Object.assign({phase}, OTHER), "race"));
	emit("MileageRace", Object.assign({phase: "countdown", count: 3}, OTHER), "race");
	emit("MileageRace", Object.assign({phase: "go"}, OTHER), "race");
	emit("MileageRace", Object.assign({phase: "racing", elapsed: 72.4, distance: 1300}, OTHER), "race");
	emit("MileageRace", Object.assign({phase: "finished", elapsed: 151.4}, OTHER), "race");
	emit("MileageRace", Object.assign({phase: "calledOff", why: "Sam did not have the stake"}, OTHER), "race");
	emit("MileageRace", Object.assign({phase: "result", you: "norto22", why: "timeout", times: {}}, OTHER), "race");
	emit("MileageRace", Object.assign({phase: "result", you: "norto22", why: "gaveUp", times: {}}, OTHER, {stake: 0}), "race");
	const ROLL = {race: "ai1", other: "the Ibishu Pessima and Sam", stake: 0, rolling: true, reward: 3000};
	emit("MileageRace", Object.assign({phase: "countdown", count: 4}, ROLL), "race");
	emit("MileageRace", Object.assign({phase: "go"}, ROLL), "race");
	emit("MileageRace", Object.assign({phase: "racing", elapsed: 72.4, distance: 1300}, ROLL), "race");
	emit("MileageRace", Object.assign({phase: "finished", elapsed: 151.4}, ROLL), "race");
	// Racing the traffic car beside you, its invite and every result.
	emit("MileageAiRace", OWN, "traffic");
	emit("MileageAiRace", Object.assign({}, OWN, {prizeAgainIn: 330}), "traffic");
	emit("MileageAiRace", Object.assign({}, OWN, {prize: 0}), "traffic");
	emit("MileageAiRace", {phase: "available", own: false, car: "Gavril Grand Marshal", owner: "Alex", allowed: true}, "traffic");
	emit("MileageAiRace", Object.assign({}, OWN, {allowed: false}), "traffic");
	scope.traffic = null;
	emit("MileageAiRace", {phase: "invite", race: "ai3", host: "Taylor", car: "Ibishu Pessima", distance: 2900,
		prize: 3000, seconds: 5}, "traffic");
	scope.traffic = null;
	emit("MileageAiRace", {phase: "invite", race: "ai4", host: "Taylor", car: "Ibishu Pessima", distance: 2900,
		prize: 0, seconds: 5}, "traffic");
	const RESULT = {phase: "result", race: "ai1", host: "norto22", car: "Ibishu Pessima", places: PLACES, prize: 0,
		reward: 2000, why: "finished", you: "norto22"};
	[{out: true}, {why: "hostGaveUp"}, {why: "hostLeft", host: "Taylor"}, {why: "failed", host: "Taylor"},
		{why: "aiOut"}, {aiWon: true}, {winner: null}, {winner: "norto22", prize: 3000},
		{winner: "norto22", rewardWithheld: "slow"}, {winner: "norto22", rewardWithheld: "jumped"},
		{winner: "norto22", prizeAgainIn: 240}, {winner: "norto22"}, {winner: "Sam"}].forEach((extra) =>
		emit("MileageAiRace", Object.assign({}, RESULT, extra), "traffic"));
	// Race spots: the set-up, the starter's card, an invite and every phase to the result.
	emit("MileageSpotRace", SETUP, "spot");
	emit("MileageSpotRace", Object.assign({}, SETUP, {spot: "x", players: []}), "spot");
	scope.spotOpponents(-5);
	look("spot setup solo", scope.spot.view);
	emit("MileageSpotRace", Object.assign({}, SETUP, {untested: true}), "spot");
	emit("MileageSpotRace", Object.assign({}, SETUP, {allowed: false}), "spot");
	emit("MileageSpotRace", {phase: "inviting", id: "s7", routeName: "City Race 1", opponents: 3, seconds: 19,
		answers: [{name: "Jordan", answer: "waiting"}]}, "spot");
	emit("MileageSpotRace", INVITE, "spot");
	emit("MileageSpotRace", {phase: "grid", id: "s7", routeName: "City Race 1"}, "spot");
	emit("MileageSpotRace", {phase: "racing", id: "s7", routeName: "City Race 1", place: 2, of: 4, lap: 1, laps: 2,
		checkpoint: 7, checkpoints: 12, elapsed: 60, offRoute: 6, nextMetres: 1200}, "spot");
	emit("MileageSpotRace", {phase: "finished", id: "s7", routeName: "City Race 1", elapsed: 229}, "spot");
	emit("MileageSpotRace", {phase: "out", id: "s7", routeName: "City Race 1", why: "left"}, "spot");
	emit("MileageSpotRace", {phase: "out", id: "s7", routeName: "City Race 1", why: "gaveUp"}, "spot");
	const WON = {phase: "result", id: "s1", routeName: "City Race 1", you: "Taylor", winner: "Taylor", prizeOffered: 2000,
		places: [{name: "Taylor", seconds: 229.02}], againIn: 360};
	[{prize: 2000, best: {improved: true, old: 232.8}}, {best: {improved: true}}, {withheld: "alone"},
		{withheld: "wait"}, {withheld: "unseen"}, {withheld: "car won", winner: null, carWon: true},
		{withheld: "alone", why: "timeout", best: {improved: true, old: 232.8}},
		{winner: null, why: "starterLeft", withheld: "unseen"}].forEach((extra) =>
		emit("MileageSpotRace", Object.assign({}, WON, extra), "spot"));
	// Race events.
	const EVENT = {id: "e1", route: "Service station garage to Alder Dragway", prize: 25000, seconds: 300, joined: 3};
	["announce", "joined", "left"].forEach((phase) =>
		emit("MileageEvent", Object.assign({phase, random: true}, EVENT), "event"));
	emit("MileageEvent", Object.assign({phase: "result", winner: null, places: [], you: "norto22"}, EVENT), "event");
	emit("MileageEvent", Object.assign({phase: "cancelled"}, EVENT), "event");

	assert.ok(seen.length >= 40, "notes checked: " + seen.length);
	const long = seen.filter((s) => s.text.length > 60 || /\n/.test(s.text));
	assert.deepStrictEqual(long.map((s) => s.where + ": " + s.text + " (" + s.text.length + ")"), []);
	const staticNotes = [...TEMPLATE.matchAll(/class="mo-(?:note|warn|sub)"[^>]*>([^<]+)</g)].map((m) => m[1].trim());
	assert.ok(staticNotes.length >= 4, "static notes found: " + staticNotes.length);
	assert.deepStrictEqual(staticNotes.filter((t) => t.length > 60), [], "static notes in the template");
});

test("an invite the game could not join keeps its car, distance and reward line under the reason", () => {
	const {scope} = load();
	scope.emit("MileageAiRace", {phase: "invite", race: "ai3", host: "Taylor", car: "Ibishu Pessima", distance: 2900,
		prize: 3000, seconds: 4, note: "You are already in a race."});
	const v = scope.traffic.view;
	assert.strictEqual(v.note, "You are already in a race.", "the reason replaces the note");
	assert.strictEqual(v.line, "vs Ibishu Pessima · 2.9 km · $3,000", "the line stays");
	assert.strictEqual(v.join, true, "Join and Decline stay");
});

test("a close for an invite that is no longer on screen leaves a result alone", () => {
	const {scope} = load();
	scope.emit("MileageAiRace", {phase: "result", race: "ai1", host: "x", car: "C", winner: null, places: [], you: "y"});
	scope.emit("MileageAiRace", {phase: "inviteClosed", race: "ai1"});
	assert.strictEqual(scope.traffic.kind, "result", "the result stays until closed");
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
