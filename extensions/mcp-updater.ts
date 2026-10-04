/**
 * mcp-updater.ts — MCP server maintenance from inside pi.
 *
 * 1. On every session_start it launches
 *      ~/.pi/agent\extensions\mcp-update-plus\scripts\update-mcp.ps1
 *    detached (fire and forget, never blocks pi). The script itself decides
 *    whether to do anything: each server has its own 7-day stamp in
 *    mcp-servers\state\stamps\, so a normal launch checks the stamps, updates
 *    only servers that are both older than 7 days AND have a newer upstream
 *    version, and exits in ~2 seconds when there is nothing to do.
 *
 * 2. /mcp-update-plus — forced update check from inside pi, whenever you want:
 *      /mcp-update-plus              force check + update ALL servers (ignores the 7-day stamps)
 *      /mcp-update-plus check        check only: installed vs latest table, changes nothing
 *      /mcp-update-plus <name> ...   force check + update only the named servers
 *    It runs the same PowerShell script in the foreground, waits for it, and
 *    reports the result as a notification. A forced run refreshes the stamps,
 *    so the next startup sweep will not redo the same work.
 *
 * Why "-plus" in the name: pi's own built-in MCP support (built-in extension
 * `builtin:mcp`, command /mcp) also owns /mcp, so a plain /mcp-update could
 * collide. 2026-10-04 migration: pi-mcp-adapter was removed and pi's built-in
 * MCP client is the only implementation again (config: mcp.json; the adapter's
 * mcp-adapter.json is retired as mcp-servers/state/backups/...bak). This
 * updater is independent of all of that: it only reads mcp.json for the server
 * list and enabled flags, then updates the installs.
 *
 * Turn the startup sweep off without uninstalling: create an empty file
 *   ~/.pi/agent\mcp-servers\state\updates-disabled
 * Force a run by hand:
 *   powershell -NoProfile -ExecutionPolicy Bypass -File ~/.pi/agent\extensions\mcp-update-plus\scripts\update-mcp.ps1 -Force
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
const HERE = dirname(fileURLToPath(import.meta.url));
const SWEEP = path.join(HERE, "..", "scripts", "update-mcp.ps1");
const OFF_SWITCH = path.join(homedir(), ".pi", "agent", "mcp-servers", "state", "updates-disabled");
const POWERHELL = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

/** Run the sweep in the foreground and resolve with a one-line summary. */
function runSweep(args: string[], timeoutMs = 30 * 60 * 1000): Promise<string> {
	return new Promise((resolve) => {
		let stdout = "";
		let stderr = "";
		let done = false;
		const child = spawn(
			POWERHELL,
			["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SWEEP, ...args],
			{ windowsHide: true },
		);
		const timer = setTimeout(() => {
			if (done) return;
			done = true;
			child.kill();
			resolve("timed out after 30 min (partial log: mcp-servers\\state\\update.log)");
		}, timeoutMs);
		child.stdout?.on("data", (chunk: unknown) => {
			stdout += String(chunk);
		});
		child.stderr?.on("data", (chunk: unknown) => {
			stderr += String(chunk);
		});
		child.on("error", (error: unknown) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			resolve(`failed to start: ${(error as Error).message}`);
		});
		child.on("exit", (code: number | null) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			const output = `${stdout}\n${stderr}`.trim();
			const lastLine = output.split(/\r?\n/).filter(Boolean).pop() ?? "";
			const summary = code === 0 ? "finished OK" : `exit code ${code}`;
			resolve(lastLine ? `${summary} — ${lastLine}` : `${summary} (log: mcp-servers\\state\\update.log)`);
		});
	});
}

export default function (pi: any) {
	pi.registerCommand("mcp-update-plus", {
		description: "MCP server updates: forced update now (no args), check-only (check), or named servers",
		handler: async (args: string, ctx: any) => {
			if (!existsSync(SWEEP)) {
				ctx.ui.notify(`update script not found: ${SWEEP}`, "error");
				return;
			}
			const words = args.trim().split(/\s+/).filter(Boolean);
			if (words.length === 0) {
				// Forced full check + update (ignores the 7-day stamps).
				ctx.ui.notify("MCP update: checking all servers for newer versions (forced)...", "info");
				const result = await runSweep(["-Force", "-Restart"]);
				ctx.ui.notify(`MCP update ${result}`, "info");
				return;
			}
			if (words[0] === "check") {
				ctx.ui.notify("MCP update: check-only (installed vs latest, nothing is changed)...", "info");
				const result = await runSweep(["-CheckOnly"]);
				ctx.ui.notify(`MCP check ${result}`, "info");
				return;
			}
			// Otherwise: treat every word as a server name, forced update.
			const names = words.map((word) => word.replace(/,$/, ""));
			ctx.ui.notify(`MCP update: forcing check for ${names.join(", ")}...`, "info");
			const result = await runSweep(["-Force", "-Restart", "-Name", names.join(",")]);
			ctx.ui.notify(`MCP update ${result}`, "info");
		},
	});

	pi.on("session_start", async (_event: any, ctx: any) => {
		try {
			if (!existsSync(SWEEP)) return;
			if (existsSync(OFF_SWITCH)) return;

			// delay 90 s so the session's servers have settled before the sweep
			// checks them (a server mid-connect would lock its own files)
			const timer = setTimeout(() => {
				const child = spawn(
					POWERHELL,
					["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", SWEEP, "-Restart"],
					{ detached: true, stdio: "ignore", windowsHide: true },
				);
				child.on("error", () => {
					/* never let a failed sweep disturb the session */
				});
				child.unref();
			}, 90 * 1000) as unknown as { unref(): void };
			timer.unref();

			ctx.ui?.notify?.("MCP update check started in background (log: .pi\\agent\\mcp-servers\\state\\update.log)", "info");
		} catch {
			/* ignore */
		}
	});
}
