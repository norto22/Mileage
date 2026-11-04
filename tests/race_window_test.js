// Mileage-Race/app.js, the race window: the live race (countdown, GO, racing, finished) of
// race spots, street races and races against traffic cars, in a small strip at the top
// right. Runs the real app script against small stand-ins for the game's UI (Angular
// scope, bngApi), with Node's standard library only.
//
//   node tests/race_window_test.js          (from the repository root)

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const SOURCE = "Resources/Client/Mileage/ui/modules/apps/Mileage-Race/app.js";
const PROMPTS = "Resources/Client/Mileage/ui/modules/apps/Mileage-Offers/app.js";
const TEMPLATE = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Race/app.html", "utf8");

// A fresh controller of each source, in one shared page; returns their scopes and the Lua
// they sent to the game.
function load(sources) {
	const lua = [];
	const controllers = [];
	const context = {
		angular: {module: () => ({directive() {}, controller(name, deps) { controllers.push(deps[deps.length - 1]); }})},
		bngApi: {engineLua(cmd) { lua.push(cmd); }},
		setInterval() { return 1; }, clearInterval() {},
		Date: {now: () => 1000000},
		console, JSON, TextEncoder, btoa, Math, Number, String, isFinite,
	};
	vm.createContext(context);
	const scopes = (sources || [SOURCE]).map((source) => {
		vm.runInContext(fs.readFileSync(source, "utf8"), context, {filename: source});
		const handlers = {};
		const scope = {
			$on(name, fn) { (handlers[name] = handlers[name] || []).push(fn); },
			$evalAsync(fn) { fn(); },
			emit(name, data) { (handlers[name] || []).forEach((fn) => fn({}, data)); },
		};
		controllers[controllers.length - 1](scope);
		return scope;
	});
	// A message reaches every app on the page.
	const emit = (name, data) => scopes.forEach((s) => s.emit(name, data));
	return {scope: scopes[0], scopes, emit, lua, context};
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

const lineOf = (view) => [...view.line].join(" · ");

//== race spots =================================================================

test("a race spot's countdown, GO, race and finish show in the window", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "countdown", id: "s1", routeName: "City Race 1", count: 3, you: "Taylor",
		racers: [{name: "Taylor"}, {name: "Ann"}, {name: "ETK 800", car: true}, {name: "Pessima", car: true}]});
	assert.strictEqual(scope.live.view.big, "3");
	assert.strictEqual(scope.live.view.label, "City Race 1");
	assert.strictEqual(lineOf(scope.live.view), "You, Ann, 2 cars");
	scope.emit("MileageSpotRace", {phase: "go", id: "s1", routeName: "City Race 1"});
	assert.strictEqual(scope.live.view.big, "GO");
	assert.strictEqual(scope.live.view.giveUp, "Give up");
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "City Race 1", place: 2, of: 6, ahead: "Pessima",
		gap: 1.24, lap: 1, laps: 2, checkpoint: 4, checkpoints: 13, elapsed: 83.45});
	const v = scope.live.view;
	assert.strictEqual(v.big, "P2/6");
	assert.strictEqual(v.time, "1:23.5");
	assert.strictEqual(lineOf(v), "Lap 1/2 · CP 4/13 · Ahead: Pessima +1.2 s");
	assert.strictEqual(v.warn, null);
	scope.emit("MileageSpotRace", {phase: "finished", id: "s1", routeName: "City Race 1", elapsed: 192.4});
	assert.strictEqual(scope.live.view.big, "Finished");
	assert.strictEqual(scope.live.view.time, "3:12.4");
	assert.strictEqual(lineOf(scope.live.view), "Waiting for the other racers…");
	assert.strictEqual(scope.live.view.giveUp, null, "nothing to give up once finished");
	scope.emit("MileageSpotRace", {phase: "result", id: "s1", routeName: "City Race 1"});
	assert.strictEqual(scope.live, null, "the result opens in the prompts window instead");
});

test("off the route the window warns in one line and says how far the checkpoint is", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "City Race 1", place: 4, of: 6, lap: 2, laps: 2,
		checkpoint: 9, checkpoints: 13, elapsed: 122.1, offRoute: 12, nextMetres: 412});
	assert.strictEqual(scope.live.view.warn, "Back to checkpoint 9 within 12 s");
	assert.strictEqual(lineOf(scope.live.view), "Lap 2/2 · CP 9/13 · 0.4 km away");
});

test("Give up in the window gives up the race it shows", () => {
	const {scope, lua} = load();
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "R", lap: 1, laps: 1, checkpoint: 1, checkpoints: 3,
		elapsed: 1});
	scope.giveUp();
	assert.strictEqual(lua[lua.length - 1], "if mileage_spotRace then mileage_spotRace.giveUp() end");
	scope.emit("MileageRace", {phase: "racing", race: "r1", other: "Ann", stake: 500, elapsed: 2, distance: 1200});
	scope.giveUp();
	assert.strictEqual(lua[lua.length - 1], "if mileage_streetRace then mileage_streetRace.giveUp() end");
});

test("set-up, invites, the grid, results and call-offs never show in the window", () => {
	const {scope} = load();
	["setup", "inviting", "invite", "grid", "out", "result", "closed", "clear"].forEach((phase) => {
		scope.emit("MileageSpotRace", {phase, id: "s1", routeName: "R"});
		assert.strictEqual(scope.live, null, phase);
	});
});

//== street races and traffic races =============================================

test("a street race shows the opponent, the time, the finish and the stake", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "countdown", race: "r1", other: "Ann", stake: 500, count: 2});
	assert.strictEqual(scope.live.view.big, "2");
	assert.strictEqual(lineOf(scope.live.view), "vs Ann · $500 stake");
	scope.emit("MileageRace", {phase: "racing", race: "r1", other: "Ann", stake: 500, elapsed: 62.1, distance: 1200});
	assert.strictEqual(scope.live.view.big, "vs Ann");
	assert.strictEqual(scope.live.view.time, "1:02.1");
	assert.strictEqual(lineOf(scope.live.view), "Finish 1.2 km · follow your map route · $500 stake");
	assert.strictEqual(scope.live.view.giveUp, "Give up (lose $500)");
	scope.emit("MileageRace", {phase: "finished", race: "r1", other: "Ann", elapsed: 70});
	assert.strictEqual(lineOf(scope.live.view), "Waiting for Ann…");
	scope.emit("MileageRace", {phase: "result", race: "r1", other: "Ann"});
	assert.strictEqual(scope.live, null);
});

test("a race spot's countdown shows the prize for first place with everyone on the grid", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "countdown", id: "s1", routeName: "City Race 1", count: 3, you: "Taylor",
		prize: 4000, racers: [{name: "Taylor"}, {name: "Sam"}, {name: "Ibishu Pessima", car: true}, {name: "ETK 800", car: true}]});
	assert.strictEqual(lineOf(scope.live.view), "You, Sam, 2 cars · prize $4,000 for 4 racers");
	scope.emit("MileageSpotRace", {phase: "countdown", id: "s1", routeName: "City Race 1", count: 2, you: "Taylor",
		prize: 0, racers: [{name: "Taylor"}, {name: "Sam"}]});
	assert.strictEqual(lineOf(scope.live.view), "You, Sam", "no prize line when the server prize is off");
});

test("a race event's countdown and GO show the prize for the racers who started", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "countdown", race: "e1", other: "the race event", stake: 0, event: true,
		prize: 50000, racers: 4, count: 3});
	assert.strictEqual(lineOf(scope.live.view), "vs the race event · prize $50,000 for 4 racers");
	scope.emit("MileageRace", {phase: "go", race: "e1", other: "the race event", stake: 0, event: true,
		prize: 50000, racers: 4});
	assert.strictEqual(lineOf(scope.live.view), "vs the race event · prize $50,000 for 4 racers");
	scope.emit("MileageRace", {phase: "countdown", race: "e2", other: "the race event", stake: 0, event: true,
		prize: 0, racers: 2, count: 3});
	assert.strictEqual(lineOf(scope.live.view), "vs the race event · no stake", "no prize line for a $0 event");
});

test("a race against a traffic car shows its model, keep driving and the race reward", () => {
	const {scope} = load();
	scope.emit("MileageRace", {phase: "countdown", race: "a1", rolling: true, other: "Ibishu Pessima", reward: 750, count: 3});
	assert.strictEqual(lineOf(scope.live.view), "Rolling start · keep driving · vs Ibishu Pessima · race reward $750");
	scope.emit("MileageRace", {phase: "racing", race: "a1", rolling: true, other: "Ibishu Pessima", reward: 750,
		elapsed: 10, distance: 2400});
	assert.strictEqual(scope.live.view.big, "vs Ibishu Pessima");
	assert.strictEqual(lineOf(scope.live.view), "Finish 2.4 km · follow your map route · race reward $750");
	assert.strictEqual(scope.live.view.giveUp, "Give up");
	const shown = [scope.live.view.big, scope.live.view.label].concat([...scope.live.view.line]);
	assert.deepStrictEqual(shown.filter((t) => /\bAI\b/.test(String(t))), [], "no text says AI");
});

test("a message for the other kind of race does not clear the one shown", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "R", lap: 1, laps: 1, checkpoint: 1, checkpoints: 3,
		elapsed: 1});
	scope.emit("MileageRace", {phase: "result", race: "r0", other: "Ann"});
	assert.ok(scope.live, "an old street race result leaves the race spot race");
});

//== beside the prompts app =====================================================

test("while the window is on the page the prompts app leaves it the live race; set-up and results stay there", () => {
	const {scopes, emit} = load([SOURCE, PROMPTS]);
	const [windowScope, prompts] = scopes;
	emit("MileageSpotRace", {phase: "grid", id: "s1", routeName: "City Race 1"});
	assert.strictEqual(prompts.spot.view.note, "Lining up on the grid...", "the grid shows in the prompts window");
	emit("MileageSpotRace", {phase: "countdown", id: "s1", routeName: "City Race 1", count: 3, racers: []});
	assert.strictEqual(prompts.spot, null, "the countdown leaves the prompts window");
	assert.strictEqual(windowScope.live.view.big, "3", "and shows in the race window");
	emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "R", lap: 1, laps: 1, checkpoint: 1, checkpoints: 3,
		elapsed: 1});
	assert.strictEqual(prompts.spot, null);
	emit("MileageRace", {phase: "racing", race: "r1", other: "Ann", stake: 0, elapsed: 2});
	assert.strictEqual(prompts.race, null, "a street race too");
	emit("MileageSpotRace", {phase: "result", id: "s1", routeName: "City Race 1", you: "T", places: []});
	assert.strictEqual(prompts.spot.view.title, "City Race 1: no winner", "the result in the prompts window");
	windowScope.emit("$destroy");
	emit("MileageSpotRace", {phase: "racing", id: "s2", routeName: "R", lap: 1, laps: 1, checkpoint: 1, checkpoints: 3,
		elapsed: 1});
	assert.strictEqual(prompts.spot.view.title, "R", "with the window gone, the prompts window shows the race again");
});

test("a street race's stake and lining up stay in the prompts window while the window is on the page", () => {
	const {scopes, emit} = load([SOURCE, PROMPTS]);
	const [windowScope, prompts] = scopes;
	emit("MileageRace", {phase: "staking", race: "r1", other: "Ann", stake: 500});
	assert.strictEqual(windowScope.live, null, "the stake is not a live race");
	assert.ok(prompts.race, "the stake shows in the prompts window");
	emit("MileageRace", {phase: "lining up", race: "r1", other: "Ann"});
	assert.strictEqual(windowScope.live, null, "lining up is not a live race");
	assert.ok(prompts.race, "lining up shows in the prompts window");
});

test("a race spot's first panel before the standings arrive shows no made-up place", () => {
	const {scope} = load();
	scope.emit("MileageSpotRace", {phase: "racing", id: "s1", routeName: "City Race 1", lap: 1, laps: 2, checkpoint: 0,
		checkpoints: 13, elapsed: 0.4});
	const v = scope.live.view;
	const shown = [v.big, v.label, v.time].concat([...v.line]);
	assert.deepStrictEqual(shown.filter((t) => /undefined|NaN/.test(String(t))), [], "no undefined place or gap");
	assert.strictEqual(v.big, "", "no place yet");
	assert.strictEqual(lineOf(v), "Lap 1/2 · CP 0/13");
});

test("the window asks the game for the race under way when it loads", () => {
	const {lua} = load();
	assert.ok(lua.includes("if mileage_spotRace then mileage_spotRace.sendState() end"));
	assert.ok(lua.includes("if mileage_streetRace then mileage_streetRace.sendState() end"));
});

//== the template ===============================================================

test("the template binds every text as text, and the app is placed at the top right", () => {
	assert.ok(!/ng-bind-html|innerHTML|\{\{/.test(TEMPLATE), "ng-bind only");
	const app = JSON.parse(fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Race/app.json", "utf8"));
	assert.strictEqual(app.directive, "mileagerace");
	assert.deepStrictEqual(app.css, {right: "0px", top: "64px", width: "280px", height: "90px"});
});

test("a long opponent name is cut short with an ellipsis and the clock keeps its own room", () => {
	const css = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Race/app.css", "utf8");
	const rule = (selector) => {
		const match = css.match(new RegExp("\\n" + selector.replace(".", "\\.") + " \\{([^}]*)\\}"));
		assert.ok(match, selector + " has a rule");
		return match[1];
	};
	const big = rule(".mr-big");
	assert.ok(/min-width:\s*0/.test(big) && /overflow:\s*hidden/.test(big) && /text-overflow:\s*ellipsis/.test(big) &&
		/flex:\s*0 1 auto/.test(big), "the big text shrinks and ends in an ellipsis");
	assert.ok(/min-width:\s*0/.test(rule(".mr-label")) && /text-overflow:\s*ellipsis/.test(rule(".mr-label")),
		"so does the route name");
	assert.ok(/flex:\s*none/.test(rule(".mr-time")), "the clock never shrinks or leaves the strip");
	// The text a traffic race puts there is as long as a car's name.
	const {scope} = load();
	scope.emit("MileageRace", {phase: "racing", race: "a1", rolling: true, other: "Ibishu Pessima Custom Edition",
		reward: 750, elapsed: 5, distance: 1000});
	assert.strictEqual(scope.live.view.big, "vs Ibishu Pessima Custom Edition");
	assert.strictEqual(scope.live.view.time, "0:05.0");
});

test("the strip's card uses the compact padding every Mileage window shares, and keeps its size", () => {
	const css = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Race/app.css", "utf8");
	const card = css.match(/\.mr-card\s*\{([^}]*)\}/);
	assert.ok(card, "a .mr-card rule");
	assert.ok(/padding:\s*6px 8px;/.test(card[1]), "6px 8px padding: " + card[1].trim());
	const app = JSON.parse(fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Race/app.json", "utf8"));
	assert.strictEqual(app.css.width, "280px", "width");
	assert.strictEqual(app.css.height, "90px", "height");
});

test("every top-level declaration can be evaluated twice", () => {
	const source = fs.readFileSync(SOURCE, "utf8");
	assert.ok(!/^(let|const) /m.test(source), "no top-level let or const");
	const context = {angular: {module: () => ({directive() {}, controller() {}})}, bngApi: {engineLua() {}}};
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
