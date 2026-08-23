#!/usr/bin/env node

/**
 * Bounded supervisor for one-shot Koko fetch workers.
 *
 * Koko owns a V8 isolate per process and is intentionally one-shot. This
 * supervisor provides a safe first phase of a worker-pool architecture:
 * each slot runs at most one fetch at a time, every job gets an isolated
 * profile/storage directory, and a stuck child is terminated without
 * blocking the other slots.
 */

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, "..");

export class PoolError extends Error {}

export function positiveInt(value, name) {
  const number = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(number) || number <= 0) throw new PoolError(`${name} must be a positive integer`);
  return number;
}

export function nonNegativeInt(value, name) {
  const number = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(number) || number < 0) throw new PoolError(`${name} must be a non-negative integer`);
  return number;
}

export function parseArgs(argv) {
  const options = {
    binary: path.join(PROJECT_ROOT, "zig-out", "bin", "koko"),
    urls: null,
    concurrency: 1,
    queueLimit: null,
    timeoutMs: 60_000,
    terminateGraceMs: 2_000,
    killGraceMs: 2_000,
    profileRoot: null,
    outputDir: null,
    waitUntil: "done",
    waitMs: 5_000,
    dump: "html",
    keepProfiles: false,
    binaryArgs: [],
    extraArgs: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help") return { help: true };
    if (arg === "--keep-profiles") { options.keepProfiles = true; continue; }
    if (arg === "--") { options.extraArgs.push(...argv.slice(index + 1)); break; }
    const value = argv[++index];
    if (value === undefined || value.startsWith("--")) throw new PoolError(`${arg} requires a value`);
    switch (arg) {
      case "--binary": options.binary = value; break;
      case "--urls": options.urls = value; break;
      case "--concurrency": options.concurrency = positiveInt(value, arg); break;
      case "--queue-limit": options.queueLimit = positiveInt(value, arg); break;
      case "--timeout-ms": options.timeoutMs = positiveInt(value, arg); break;
      case "--terminate-grace-ms": options.terminateGraceMs = nonNegativeInt(value, arg); break;
      case "--kill-grace-ms": options.killGraceMs = nonNegativeInt(value, arg); break;
      case "--profile-root": options.profileRoot = value; break;
      case "--output-dir": options.outputDir = value; break;
      case "--wait-until": options.waitUntil = value; break;
      case "--wait-ms": options.waitMs = positiveInt(value, arg); break;
      case "--dump": options.dump = value; break;
      default: throw new PoolError(`Unknown option: ${arg}`);
    }
  }
  if (!options.urls) throw new PoolError("--urls is required");
  if (options.queueLimit === null) options.queueLimit = options.concurrency * 2;
  return options;
}

export async function loadUrls(file) {
  const contents = await fs.readFile(path.resolve(PROJECT_ROOT, file), "utf8");
  const urls = contents.split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
  for (const value of urls) {
    let parsed;
    try { parsed = new URL(value); } catch (error) { throw new PoolError(`Invalid URL ${JSON.stringify(value)}: ${error.message}`); }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") throw new PoolError(`URL must use http:// or https://: ${value}`);
  }
  return urls;
}

function outputName(url, index) {
  const parsed = new URL(url);
  const safe = `${parsed.hostname}${parsed.pathname === "/" ? "" : parsed.pathname}`.replace(/[^a-z0-9.-]+/gi, "-").replace(/^-+|-+$/g, "").slice(0, 120) || "site";
  return `${String(index + 1).padStart(4, "0")}-${safe}.html`;
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function terminateChild(child, options) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  const termDeadline = Date.now() + options.terminateGraceMs;
  while (child.exitCode === null && child.signalCode === null && Date.now() < termDeadline) await sleep(10);
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  const killDeadline = Date.now() + options.killGraceMs;
  while (child.exitCode === null && child.signalCode === null && Date.now() < killDeadline) await sleep(10);
}

export async function runWorkerJob({ binary, url, index, slot, options, profileRoot, outputDir }) {
  const profileDir = path.join(profileRoot, `worker-${slot + 1}`, `job-${index + 1}`);
  await fs.mkdir(profileDir, { recursive: true });
  return new Promise((resolve) => {
    const output = path.join(outputDir, outputName(url, index));
    const storagePath = path.join(profileDir, "storage.sqlite");
    const args = [...options.extraArgs, "fetch", "--dump", options.dump, "--dump-html-file", output, "--wait-until", options.waitUntil, "--wait-ms", String(options.waitMs), "--user-data-dir", profileDir, "--storage-sqlite-path", storagePath, url];
    const startedAt = Date.now();
    const child = spawn(binary, [...(options.binaryArgs || []), ...args], { cwd: PROJECT_ROOT, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    let timedOut = false;
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-8_192); });
    const timeout = setTimeout(async () => { timedOut = true; await terminateChild(child, options); }, options.timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timeout);
      resolve({ index, slot, url, output, ok: false, reason: "spawn-error", error: error.message, stderr, elapsedMs: Date.now() - startedAt });
    });
    child.once("close", (code, signal) => {
      clearTimeout(timeout);
      resolve({ index, slot, url, output, ok: !timedOut && code === 0, reason: timedOut ? "timeout" : code === 0 ? "ok" : "exit", code, signal, stderr, elapsedMs: Date.now() - startedAt });
    });
  });
}

export async function runPool(urls, input = {}) {
  const options = { concurrency: 1, queueLimit: 2, timeoutMs: 60_000, terminateGraceMs: 2_000, killGraceMs: 2_000, binary: path.join(PROJECT_ROOT, "zig-out", "bin", "koko"), binaryArgs: [], profileRoot: null, outputDir: null, waitUntil: "done", waitMs: 5_000, dump: "html", keepProfiles: false, extraArgs: [], ...input };
  if (!Number.isSafeInteger(options.concurrency) || options.concurrency <= 0) throw new PoolError("concurrency must be positive");
  if (!Number.isSafeInteger(options.queueLimit) || options.queueLimit <= 0) throw new PoolError("queueLimit must be positive");
  // Workers pull directly from the input cursor. This is a bounded queue in
  // practice: at most `concurrency` children are live and no unbounded list
  // of child processes is created. `queueLimit` remains a public admission
  // knob for callers that stream jobs into a future producer API.
  const ownsRoot = !options.profileRoot;
  const root = options.profileRoot || await fs.mkdtemp(path.join(os.tmpdir(), "koko-pool-"));
  const outputDir = options.outputDir || path.join(root, "output");
  await fs.mkdir(outputDir, { recursive: true });
  for (let slot = 0; slot < options.concurrency; slot += 1) await fs.mkdir(path.join(root, `worker-${slot + 1}`), { recursive: true });
  const results = new Array(urls.length);
  let next = 0;
  async function worker(slot) {
    while (true) {
      const index = next++;
      if (index >= urls.length) return;
      results[index] = await runWorkerJob({ binary: options.binary, url: urls[index], index, slot, options, profileRoot: root, outputDir });
    }
  }
  const startedAt = Date.now();
  await Promise.all(Array.from({ length: Math.min(options.concurrency, urls.length) }, (_, slot) => worker(slot)));
  if (ownsRoot && !options.keepProfiles) await fs.rm(root, { recursive: true, force: true });
  return { results, elapsedMs: Date.now() - startedAt, profileRoot: options.keepProfiles ? root : null, outputDir };
}

export function usage() {
  return `Usage: node scripts/koko-pool.mjs --urls FILE [options]\n\n` +
    `  --binary PATH             Koko binary (default: zig-out/bin/koko)\n` +
    `  --concurrency N           Worker slots (default: 1)\n` +
    `  --queue-limit N           Maximum queued jobs (default: 2x concurrency)\n` +
    `  --timeout-ms N            Per-job hard timeout (default: 60000)\n` +
    `  --terminate-grace-ms N   SIGTERM grace period\n` +
    `  --kill-grace-ms N        SIGKILL grace period\n` +
    `  --profile-root DIR       Root for isolated worker profiles\n` +
    `  --output-dir DIR         Output directory\n` +
    `  --wait-until EVENT       Koko wait target (default: done)\n` +
    `  --wait-ms N              Koko wait budget (default: 5000)\n` +
    `  --dump FORMAT            Koko dump format (default: html)\n` +
    `  --keep-profiles          Keep temporary worker directories\n` +
    `  -- [Koko fetch args]     Extra fetch args\n`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const parsed = parseArgs(process.argv.slice(2));
    if (parsed.help) { process.stdout.write(usage()); process.exit(0); }
    const urls = await loadUrls(parsed.urls);
    const result = await runPool(urls, parsed);
    const failed = result.results.filter((item) => !item.ok);
    process.stdout.write(`${JSON.stringify({ jobs: result.results.length, succeeded: result.results.length - failed.length, failed: failed.length, elapsedMs: result.elapsedMs, results: result.results }, null, 2)}\n`);
    process.exitCode = failed.length === 0 ? 0 : 1;
  } catch (error) {
    process.stderr.write(`koko-pool: ${error.message}\n${usage()}`);
    process.exitCode = 2;
  }
}
