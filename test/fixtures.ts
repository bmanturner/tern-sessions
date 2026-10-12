// Builds stand-in omp databases with the real schemas: <dir>/agent/history.db and <dir>/stats.db.
// build(dir, false) writes the small fixed set test/sql.ts checks; build(dir, true) writes believable
// demo sessions for screenshots. CLI: bun test/fixtures.ts --demo <dir>
import { mkdirSync, rmSync } from "fs";
import { join } from "path";

const SQLITE = "/usr/bin/sqlite3";

const HISTORY_DDL = `
CREATE TABLE history (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	prompt TEXT NOT NULL UNIQUE,
	created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
	cwd TEXT,
	session_id TEXT,
	use_count INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_history_created_at ON history(created_at DESC);
CREATE VIRTUAL TABLE history_fts USING fts5(prompt, content='history', content_rowid='id');
CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
	INSERT INTO history_fts(rowid, prompt) VALUES (new.id, new.prompt);
END;
CREATE TABLE session_titles (
	session_id TEXT PRIMARY KEY,
	title TEXT NOT NULL,
	updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
);
CREATE TABLE session_recaps (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	session_id TEXT NOT NULL,
	cwd TEXT NOT NULL,
	recap TEXT NOT NULL,
	created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
);
CREATE INDEX idx_session_recaps_session ON session_recaps(session_id, created_at);
`;

const STATS_DDL = `
CREATE TABLE session_rollup (
	session_file TEXT PRIMARY KEY,
	requests INTEGER NOT NULL,
	started_at INTEGER NOT NULL,
	ended_at INTEGER NOT NULL,
	total_tokens INTEGER NOT NULL,
	cost_total REAL NOT NULL,
	unpriced INTEGER NOT NULL,
	models TEXT,
	tool_calls INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TABLE message_rollup (
	bucket INTEGER NOT NULL, model TEXT NOT NULL, provider TEXT NOT NULL, folder TEXT NOT NULL, agent_type TEXT NOT NULL,
	requests INTEGER NOT NULL, failed INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
	cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL, total_tokens INTEGER NOT NULL,
	premium_requests REAL NOT NULL, cost_total REAL NOT NULL, cost_input REAL NOT NULL, cost_output REAL NOT NULL,
	cost_cache_read REAL NOT NULL, cost_cache_write REAL NOT NULL, unpriced INTEGER NOT NULL,
	cached_prompt_cost REAL NOT NULL, no_cache_input_cost REAL NOT NULL, duration_sum REAL NOT NULL,
	duration_n INTEGER NOT NULL, ttft_sum REAL NOT NULL, ttft_n INTEGER NOT NULL, tps_sum REAL NOT NULL,
	tps_n INTEGER NOT NULL, first_ts INTEGER NOT NULL, last_ts INTEGER NOT NULL
);
CREATE INDEX idx_message_rollup_bucket ON message_rollup(bucket);
`;

export const IDS = {
	A: "aaaaaaaa-0000-4000-8000-00000000000a",
	B: "bbbbbbbb-0000-4000-8000-00000000000b",
	C: "cccccccc-0000-4000-8000-00000000000c",
	D: "dddddddd-0000-4000-8000-00000000000d",
};

const q = (s: string | number | null) => (s === null ? "null" : typeof s === "number" ? String(s) : `'${s.replace(/'/g, "''")}'`);
const DAY = 86400;
const HOUR_MS = 3600000;

function exec(db: string, sql: string) {
	const p = Bun.spawnSync([SQLITE, db], { stdin: new TextEncoder().encode(sql) });
	if (p.exitCode !== 0) throw new Error(`sqlite3 ${db}: ${p.stderr.toString()}`);
}

class Writer {
	h: string[] = [];
	s: string[] = [];
	prompt(sid: string | null, cwd: string, at: number, text: string) {
		this.h.push(`insert into history(prompt, created_at, cwd, session_id) values (${q(text)}, ${at}, ${q(cwd)}, ${q(sid)});`);
	}
	title(sid: string, title: string, at: number) {
		this.h.push(`insert into session_titles values (${q(sid)}, ${q(title)}, ${at});`);
	}
	recap(sid: string, cwd: string, at: number, text: string) {
		this.h.push(`insert into session_recaps(session_id, cwd, recap, created_at) values (${q(sid)}, ${q(cwd)}, ${q(text)}, ${at});`);
	}
	session(file: string, started: number, ended: number, cost: number, models: string, requests = 10, tools = 20) {
		this.s.push(
			`insert into session_rollup values (${q(file)}, ${requests}, ${started * 1000}, ${ended * 1000}, ${requests * 30000}, ${cost}, 0, ${q(models)}, ${tools});`,
		);
	}
	spend(bucketMs: number, folder: string, model: string, cost: number) {
		const bucket = Math.floor(bucketMs / HOUR_MS) * HOUR_MS;
		this.s.push(
			`insert into message_rollup values (${bucket}, ${q(model)}, 'anthropic', ${q(folder)}, 'main', 3, 0, 1000, 500, 0, 0, 1500, 0, ${cost}, ${cost}, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, ${bucket}, ${bucket + 60000});`,
		);
	}
}

function fixed(w: Writer, sessions: string) {
	const now = Math.floor(Date.now() / 1000);
	const file = (bucket: string, id: string) => `${sessions}/${bucket}/2026-10-01T10-00-00-000Z_${id}.jsonl`;

	const a = now - 2 * DAY;
	w.session(file("-w-alpha", IDS.A), a, a + 3600, 3, "claude-opus-5-5", 12, 40);
	w.session(file("-w-alpha", IDS.A).replace(/\.jsonl$/, "/Explore.jsonl"), a + 60, a + 600, 4, "claude-opus-5-5", 5, 9);
	w.title(IDS.A, "Fix deploy script", a);
	w.prompt(IDS.A, "/w/alpha", a, "the release script fails on the last step");
	w.prompt(IDS.A, "/w/alpha", a + 120, "also check the changelog step");
	w.recap(IDS.A, "/w/alpha", a + 3000, "Rewrote the release step and fixed the tag push.");

	const b = now - 5 * DAY;
	w.session(file("-w-beta", IDS.B), b, b + 1800, 1, "gpt-6", 8, 10);
	w.title(IDS.B, "Refactor auth", b);
	w.prompt(IDS.B, "/w/beta", b, "move the token check before the deploy pipeline runs");

	const c = now - 10 * DAY;
	w.session(file("-w-beta", IDS.C), c, c + 600, 0.5, "gpt-6", 3, 2);
	w.title(IDS.C, "Tidy imports", c);
	w.prompt(IDS.C, "/w/beta", c, "sort the imports in src");
	w.recap(IDS.C, "/w/beta", c + 500, "Sorted imports; noted that deploy docs are stale.");

	const d = now - 40 * DAY;
	w.prompt(IDS.D, "/w/gamma", d, "write a haiku about rain");
	w.prompt(IDS.D, "/w/gamma", d + 60, "now one about snow");

	const nowMs = Date.now();
	w.spend(nowMs, "-w-alpha", "claude-opus-5-5", 5);
	w.spend(nowMs, "-w-beta", "gpt-6", 1);
	w.spend(nowMs - 24 * HOUR_MS, "-w-alpha", "claude-opus-5-5", 2);
	w.spend(nowMs - 20 * 24 * HOUR_MS, "-w-beta", "gpt-6", 3);
}

// Deterministic pseudo-random numbers, so demo screenshots are stable.
function rng(seed: number) {
	let x = seed;
	return () => {
		x = (x * 1103515245 + 12345) % 2147483648;
		return x / 2147483648;
	};
}

const DEMO = [
	["web", "Fix the deploy script's tag step", ["the deploy script fails when the tag already exists", "make it skip existing tags and continue"], "Made the deploy script skip existing tags; added a dry-run flag."],
	["web", "Dark mode for the settings page", ["add dark mode to the settings page", "the toggle should remember the choice"], "Added a theme toggle stored in local storage; settings page now follows it."],
	["api", "Rate limiter for public endpoints", ["add a rate limiter to the public endpoints", "use a sliding window, 100 requests a minute"], "Added a sliding-window rate limiter with per-key buckets and tests."],
	["api", "Slow orders query", ["the orders list endpoint takes 4 seconds", "explain the query plan"], "Added a composite index on (customer_id, created_at); p95 down to 120 ms."],
	["support", "Triage this week's tickets", ["summarize the open tickets by theme", "draft replies for the top three"], "Grouped 42 tickets into 6 themes and drafted three replies."],
	["web", "Flaky checkout e2e test", ["the checkout e2e test fails one run in five before every deploy", "find out why"], "The test raced the payment iframe; now waits for its ready event."],
	["api", "Upgrade to Postgres 17", ["plan the upgrade to postgres 17", "what breaks in our migrations when we deploy"], "Two migrations used removed syntax; rewrote them and documented the upgrade."],
	["web", "Image upload resizing", ["resize uploaded images on the client before upload", "keep EXIF orientation"], "Client-side resize to 2048 px with orientation preserved."],
	["support", "Refund policy macro", ["write a support macro for refund requests"], "Added a refund macro with three variants."],
	["api", "Webhook retries", ["webhooks are dropped when the receiver times out during a deploy", "add retries with backoff"], "Added exponential backoff with jitter and a dead-letter table."],
	["web", "Search page empty state", ["the search page shows nothing when there are no results", "add a friendly empty state"], "Added an empty state with suggestions."],
	["api", "Auth token rotation", ["rotate the signing keys without logging everyone out"], "Added key ids and a two-key overlap window."],
	["web", "Bundle size regression", ["the bundle grew 300 KB last week", "find what did it"], "A date library was imported whole; switched to per-function imports, so the next deploy ships 300 KB less."],
	["support", "Weekly support report", ["make the weekly support report"], "Report drafted: response times steady, two new themes."],
	["api", "Deploy pipeline caching", ["the deploy pipeline rebuilds everything every time", "cache the dependency layer"], "Split the Dockerfile so dependencies cache; deploys 6 min faster."],
	["web", "Accessibility pass on forms", ["check the signup form for accessibility issues"], "Fixed labels, focus order and error announcements."],
	["api", "Pagination for exports", ["the csv export times out for big accounts", "stream it in pages"], "Exports now stream in 5k-row pages."],
	["web", "Onboarding checklist", ["add an onboarding checklist to the dashboard"], "Added a dismissible checklist with progress."],
	["support", "Escalation runbook", ["write a runbook for escalating outages to on-call"], "Runbook written with contact tree and templates."],
	["api", "Audit log", ["add an audit log for admin actions"], "Audit log table, writer and an admin page."],
	["web", "Fix login redirect loop", ["login loops back to itself on safari"], "SameSite cookie fix; the redirect loop is gone."],
	["api", "Background job dashboard", ["show failed background jobs somewhere"], "Added a jobs page with retry buttons."],
	["web", "Translate the pricing page", ["prepare the pricing page for translation"], "Strings extracted; German and French added."],
	["api", "Deploy preview environments", ["spin up a preview environment for every pull request"], "Preview deploys per PR with automatic teardown."],
	["support", "FAQ refresh", ["update the FAQ with the new billing changes"], "FAQ updated for the new billing."],
] as const;

const MODELS = ["claude-opus-5-5", "claude-sonnet-5", "gpt-6", "gemini-3-pro"];

function demo(w: Writer, sessions: string) {
	const home = process.env.HOME ?? "/home/you";
	const now = Math.floor(Date.now() / 1000);
	const r = rng(7);
	DEMO.forEach(([repo, title, prompts, recap], i) => {
		const id = `${(0x10000000 + i * 7919).toString(16)}-1111-4000-8000-${(0x100000000000 + i).toString(16)}`;
		const cwd = `${home}/Dev/acme/${repo}`;
		const folder = `-Dev-acme-${repo}`;
		// Newest first, two today, during working hours.
		const day = new Date((now - Math.floor((i / DEMO.length) * 28 * DAY)) * 1000);
		day.setHours(9 + Math.floor(r() * 9), Math.floor(r() * 60), 0, 0);
		const started = Math.min(Math.floor(day.getTime() / 1000), now - 3 * 3600 + i * 600);
		const dur = 600 + Math.floor(r() * 7200);
		const model = MODELS[Math.floor(r() * MODELS.length)];
		const cost = Math.round((0.4 + r() * r() * 28) * 100) / 100;
		const iso = new Date(started * 1000).toISOString().replace(/[:.]/g, "-");
		const file = `${sessions}/${folder}/${iso}_${id}.jsonl`;
		const sub = r() < 0.4 ? Math.round(r() * cost * 60) / 100 : 0;
		w.session(file, started, started + dur, cost, model, 5 + Math.floor(r() * 60), 10 + Math.floor(r() * 120));
		if (sub > 0) w.session(file.replace(/\.jsonl$/, "/Explore.jsonl"), started + 60, started + 400, sub, model, 4, 12);
		w.title(id, title, started);
		prompts.forEach((p, j) => w.prompt(id, cwd, started + j * 240, p));
		w.recap(id, cwd, started + dur - 60, recap);
		// Spend in up to three hourly buckets of the session.
		const total = cost + sub;
		const parts = [0.5, 0.3, 0.2];
		parts.forEach((f, j) => {
			const at = (started + Math.min(dur, j * 3600)) * 1000;
			if (at <= Date.now()) w.spend(at, folder, model, Math.round(total * f * 100) / 100);
		});
	});
}

export function build(dir: string, isDemo: boolean): { history: string; stats: string } {
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(join(dir, "agent"), { recursive: true });
	const history = join(dir, "agent", "history.db");
	const stats = join(dir, "stats.db");
	const w = new Writer();
	const sessions = join(dir, "agent", "sessions");
	// Demo paths look like a real install's; nothing reads those files.
	if (isDemo) demo(w, join(process.env.HOME ?? "/home/you", ".omp", "agent", "sessions"));
	else fixed(w, sessions);
	exec(history, `PRAGMA journal_mode=WAL;\n${HISTORY_DDL}\nbegin;\n${w.h.join("\n")}\ncommit;`);
	exec(stats, `PRAGMA journal_mode=WAL;\n${STATS_DDL}\nbegin;\n${w.s.join("\n")}\ncommit;`);
	return { history, stats };
}

if (import.meta.main) {
	const i = process.argv.indexOf("--demo");
	const dir = i > 0 ? process.argv[i + 1] : undefined;
	if (!dir) {
		console.log("usage: bun test/fixtures.ts --demo <dir>");
		process.exit(2);
	}
	const out = build(dir, true);
	console.log(`wrote ${out.history} and ${out.stats}`);
}
