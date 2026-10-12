// Runs the SQL lib/query.luau builds (printed by test/emit_sql.luau) against fixture databases with
// the real sqlite3 and checks the results. Exit 1 on any failure.
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { build, IDS } from "./fixtures";

const dir = mkdtempSync(join(tmpdir(), "tern-sessions-"));
const { history, stats } = build(dir, false);

const emitted = Bun.spawnSync(["bun", join(import.meta.dir, "run.ts"), join(import.meta.dir, "emit_sql.luau")]);
const text = emitted.stdout.toString();
if (emitted.exitCode !== 0 || /^(ERR|COMPILE)/m.test(text)) {
	console.log(`FAIL emit_sql\n${text}${emitted.stderr.toString()}`);
	process.exit(1);
}

type Run = { ok: boolean; value: any; stderr: string };
const blocks = new Map<string, Run>();
const skipped = new Set<string>();
for (const m of text.matchAll(/^@@skip\|(\w+)$/gm)) skipped.add(m[1]);
for (const m of text.matchAll(/^@@(\w+)\|([01])\n([\s\S]*?)\n@@end$/gm)) {
	const [, name, hasStats, sql] = m;
	// The same argv as lib/db.luau.
	const argv = ["/usr/bin/sqlite3", "-readonly", "-noheader", "-list"];
	if (hasStats === "1") argv.push("-cmd", `attach '${stats.replace(/'/g, "''")}' as s`);
	argv.push(history, sql);
	const p = Bun.spawnSync(argv);
	const lines = p.stdout.toString().split("\n").filter((l) => l.trim() !== "");
	let value: any = undefined;
	if (lines.length > 0) {
		try {
			value = JSON.parse(lines[lines.length - 1]);
		} catch {
			value = "<bad json>";
		}
	}
	blocks.set(name, { ok: p.exitCode === 0, value, stderr: p.stderr.toString() });
}

let failed = 0;
function check(name: string, fn: (v: any) => string | null) {
	const r = blocks.get(name);
	let problem: string | null;
	if (r === undefined) problem = "not emitted";
	else if (!r.ok) problem = `sqlite3 failed: ${r.stderr.trim()}`;
	else {
		try {
			problem = fn(r.value);
		} catch (e) {
			problem = String(e);
		}
	}
	if (problem) {
		failed++;
		console.log(`FAIL ${name}: ${problem}`);
	} else {
		console.log(`ok ${name}`);
	}
}

const ids = (v: any[]) => v.map((r) => r.id);
const same = (a: string[], b: string[]) => JSON.stringify(a) === JSON.stringify(b);
const localDate = (d: Date) =>
	`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

check("empty", (v) => {
	if (v.length !== 4) return `want 4 sessions, got ${v.length}`;
	if (!same(ids(v), [IDS.A, IDS.B, IDS.C, IDS.D])) return `want newest first, got ${ids(v)}`;
	const d = v.find((r: any) => r.id === IDS.D);
	if (d.file !== null || d.cost !== null) return "D should have no file and no cost";
	if (d.title !== "write a haiku about rain") return `D's title should be its first prompt, got ${d.title}`;
	if (d.cwd !== "/w/gamma") return `D's cwd: ${d.cwd}`;
	const a = v[0];
	if (a.cost !== 7) return `A's cost should include its subagent (7), got ${a.cost}`;
	return null;
});
check("deploy", (v) => {
	if (!same(ids(v), [IDS.A, IDS.C, IDS.B])) return `want A (title), C (recap), B (prompt); got ${ids(v)}`;
	if (v[0].hit !== "title" || v[1].hit !== "recap" || v[2].hit !== "prompt") return `hits: ${v.map((r: any) => r.hit)}`;
	if (!String(v[2].snip).includes("«deploy")) return `B's snippet should mark deploy: ${v[2].snip}`;
	if (!String(v[1].snip).includes("deploy docs")) return `C's snippet should be its recap: ${v[1].snip}`;
	return null;
});
check("repo", (v) => (same(ids(v), [IDS.B, IDS.C]) ? null : `want B, C; got ${ids(v)}`));
check("model", (v) => (same(ids(v), [IDS.A]) ? null : `want A; got ${ids(v)}`));
check("cost", (v) => (same(ids(v), [IDS.A]) && v[0].cost === 7 ? null : `want A at 7; got ${JSON.stringify(v)}`));
check("after", (v) => (same(ids(v), [IDS.A]) ? null : `want A; got ${ids(v)}`));
check("before", (v) => (same(ids(v), [IDS.B, IDS.C, IDS.D]) ? null : `want B, C, D; got ${ids(v)}`));
check("syntax", (v) => (Array.isArray(v) ? null : "want an array"));
check("nostats", (v) => {
	if (v.length !== 4) return `want 4 sessions, got ${v.length}`;
	if (v.some((r: any) => r.cost !== null || r.file !== null)) return "without stats.db no session has a cost or file";
	return null;
});
check("nostats_deploy", (v) => (same(ids(v), [IDS.A, IDS.C, IDS.B]) ? null : `want A, C, B; got ${ids(v)}`));
check("detail", (v) => {
	if (v.id !== IDS.A) return `id ${v.id}`;
	if (v.subagents !== 1 || v.cost_sub !== 4 || v.cost !== 7) return `subagents ${v.subagents}, cost_sub ${v.cost_sub}, cost ${v.cost}`;
	if (v.prompts.length !== 2 || v.prompts[0].t > v.prompts[1].t) return "prompts should be oldest first";
	if (v.prompt_count !== 2) return `prompt_count ${v.prompt_count}`;
	if (v.recaps.length !== 1) return `recaps ${v.recaps.length}`;
	return null;
});
check("detail_nostats", (v) => (v.id === IDS.A && (v.cost === undefined || v.cost === null) ? null : `cost should be null: ${v.cost}`));
if (!skipped.has("detail_bad")) {
	failed++;
	console.log("FAIL detail_bad: detail_sql should return nil for a bad id");
} else {
	console.log("ok detail_bad");
}
check("spend", (v) => {
	if (Math.abs(v.today - 6) > 1e-9) return `today ${v.today}, want 6`;
	if (v.days.length !== 14) return `days ${v.days.length}`;
	if (v.days[13].d !== localDate(new Date())) return `last day ${v.days[13].d}`;
	if (v.days[13].c !== 6 || v.days[12].c !== 2) return `daily totals ${JSON.stringify(v.days.slice(12))}`;
	if (v.folders[0].f !== "-w-alpha" || v.folders[0].c !== 7 || v.folders[0].cwd !== "/w/alpha") return `folders ${JSON.stringify(v.folders)}`;
	if (v.models.length !== 2) return `models ${JSON.stringify(v.models)}`;
	if (v.top[0].id !== IDS.A || v.top[0].cost !== 7) return `top ${JSON.stringify(v.top[0])}`;
	if (Math.abs(v.total30 - 11) > 1e-9) return `total30 ${v.total30}`;
	if (v.month < v.today || v.week < v.today) return "week and month include today";
	return null;
});
check("today", (v) => (v.day === localDate(new Date()) && v.today === 6 ? null : `got ${JSON.stringify(v)}`));

rmSync(dir, { recursive: true, force: true });
process.exit(failed > 0 ? 1 : 0);
