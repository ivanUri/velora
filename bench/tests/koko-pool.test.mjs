import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadUrls, parseArgs, PoolError, runPool } from "../../scripts/koko-pool.mjs";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(ROOT, "koko-pool-fixture.mjs");

async function writeUrls(values) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "koko-pool-test-"));
  const file = path.join(dir, "urls.txt");
  await fs.writeFile(file, `${values.join("\n")}\n`);
  return { dir, file };
}

test("parseArgs supplies bounded-pool defaults and accepts extra fetch args", () => {
  const parsed = parseArgs(["--urls", "urls.txt", "--concurrency", "3", "--", "--expand-lazy"]);
  assert.equal(parsed.concurrency, 3);
  assert.equal(parsed.queueLimit, 6);
  assert.deepEqual(parsed.extraArgs, ["--expand-lazy"]);
});

test("loadUrls rejects non-http schemes", async () => {
  const { dir, file } = await writeUrls(["file:///etc/passwd"]);
  await assert.rejects(loadUrls(file), (error) => error instanceof PoolError && /http/.test(error.message));
  await fs.rm(dir, { recursive: true, force: true });
});

test("pool isolates slots, preserves result order, and enforces timeout", async () => {
  const urls = ["https://fixture.test/slow", "https://fixture.test/ok", "https://fixture.test/fail"];
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "koko-pool-test-root-"));
  const result = await runPool(urls, { binary: process.execPath, binaryArgs: [FIXTURE], concurrency: 2, queueLimit: 4, timeoutMs: 40, terminateGraceMs: 20, killGraceMs: 100, profileRoot: root, outputDir: path.join(root, "output") });
  assert.deepEqual(result.results.map((item) => item.url), urls);
  assert.equal(result.results[0].reason, "timeout");
  assert.equal(result.results[1].ok, true);
  assert.equal(result.results[2].reason, "exit");
  assert.notEqual(result.results[0].slot, result.results[1].slot);
  await fs.rm(root, { recursive: true, force: true });
});
