#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

// Chỉ sửa cấu hình trong khối này. Script không nhận command-line arguments.
const CONFIG = {
  profile: "huynew",
  urlFile: "scripts/urls-100.txt",
  outputDirectory: "exports/urls-retry",
  logDirectory: "export-logs",
  keepScripts: false,
  waitUntil: "domstable",
  waitMs: 2_000,
  terminateMs: 30_000,
  terminateGraceMs: 2_000,
  killGraceMs: 2_000,
  maxSites: 100,
};

function stripScriptElements(html) {
  let removed = 0;
  const stripped = html.replace(
    /<script\b[^>]*>[\s\S]*?<\/script\s*>/gi,
    () => {
      removed += 1;
      return "";
    },
  );
  return { html: stripped, removed };
}

function outputNameForUrl(url, index) {
  const urlPart = `${url.hostname}${url.pathname === "/" ? "" : url.pathname}`
    .replace(/[^a-z0-9.-]+/gi, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120);
  const sequence = String(index + 1).padStart(3, "0");
  return `${sequence}-${urlPart || "site"}.html`;
}

function validateSite(entry, index) {
  if (!entry || entry.enabled === false) return null;

  let url;
  try {
    url = new URL(entry.url);
  } catch (error) {
    throw new Error(
      `${CONFIG.urlFile}:${index + 1} contains an invalid URL: ${error.message}`,
    );
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(
      `${CONFIG.urlFile}:${index + 1} must use http:// or https://`,
    );
  }

  return {
    ...CONFIG,
    ...entry,
    url,
    output: entry.output || outputNameForUrl(url, index),
  };
}

const projectRoot = path.resolve(__dirname, "..");
const koko = path.join(projectRoot, "zig-out", "bin", "koko");

function loadSitesFromFile(urlFile = CONFIG.urlFile) {
  const inputPath = path.resolve(projectRoot, urlFile);
  if (!fs.existsSync(inputPath)) {
    throw new Error(`URL file not found: ${inputPath}`);
  }

  const entries = fs
    .readFileSync(inputPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"))
    .map((line) => {
      const tab = line.indexOf("\t");
      if (tab === -1) return { enabled: true, url: line };
      return {
        enabled: true,
        output: line.slice(0, tab).trim(),
        url: line.slice(tab + 1).trim(),
      };
    });

  if (entries.length === 0) {
    throw new Error(`No URLs found in ${inputPath}`);
  }
  return entries;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function writeIndex(sites, states = new Map()) {
  const outputDirectory = path.resolve(projectRoot, CONFIG.outputDirectory);
  fs.mkdirSync(outputDirectory, { recursive: true });

  const rows = sites
    .map((site, index) => {
      const outputPath = path.join(outputDirectory, site.output);
      const hasArtifact = fs.existsSync(outputPath);
      const state = states.get(site.output);
      const status =
        state === "failed"
          ? "Lần chạy mới lỗi"
          : state === "exported"
            ? "Đã export"
            : hasArtifact
              ? "Có file"
              : "Đang chờ";
      const statusClass =
        state === "failed"
          ? "failed"
          : hasArtifact || state === "exported"
            ? "ready"
            : "pending";
      const pageLink = hasArtifact
        ? `<a class="page-link" href="./${encodeURI(site.output)}">${escapeHtml(site.output)}</a>`
        : `<span class="missing">${escapeHtml(site.output)}</span>`;

      return `<tr>
        <td>${index + 1}</td>
        <td><a href="${escapeHtml(site.url.href)}" target="_blank" rel="noreferrer">${escapeHtml(site.url.href)}</a></td>
        <td>${pageLink}</td>
        <td><span class="status ${statusClass}">${status}</span></td>
      </tr>`;
    })
    .join("\n");

  const readyCount = sites.filter((site) =>
    fs.existsSync(path.join(outputDirectory, site.output)),
  ).length;
  const summary = `${readyCount}/${sites.length} file đã sẵn sàng. Cập nhật: ${new Date().toLocaleString("vi-VN")}`;
  const indexScript = `// Generated automatically by scripts/export-site.js.
document.querySelector("#export-summary").textContent = ${JSON.stringify(summary)};
document.querySelector("#export-rows").innerHTML = ${JSON.stringify(rows)};
`;
  const html = `<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Koko HTML exports</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    body { max-width: 1400px; margin: 0 auto; padding: 24px; }
    h1 { margin-bottom: 6px; }
    .summary { margin: 0 0 22px; color: #777; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 10px 12px; border-bottom: 1px solid #8885; text-align: left; vertical-align: top; }
    th { position: sticky; top: 0; background: Canvas; }
    td:first-child { width: 48px; text-align: right; color: #777; }
    a { color: LinkText; overflow-wrap: anywhere; }
    .page-link { font-weight: 650; }
    .missing { color: #888; }
    .status { display: inline-block; white-space: nowrap; padding: 3px 8px; border-radius: 999px; font-size: 12px; }
    .ready { color: #08783e; background: #28c76f22; }
    .pending { color: #806400; background: #ffc10722; }
    .failed { color: #b42318; background: #f0443822; }
    @media (max-width: 760px) {
      body { padding: 12px; }
      th:nth-child(2), td:nth-child(2) { display: none; }
    }
  </style>
</head>
<body>
  <h1>Koko HTML exports</h1>
  <p class="summary" id="export-summary">Đang tải danh sách…</p>
  <table>
    <thead><tr><th>#</th><th>URL gốc</th><th>HTML export</th><th>Trạng thái</th></tr></thead>
    <tbody id="export-rows"></tbody>
  </table>
  <script src="./index.js"></script>
</body>
</html>
`;
  fs.writeFileSync(path.join(outputDirectory, "index.html"), html, "utf8");
  fs.writeFileSync(path.join(outputDirectory, "index.js"), indexScript, "utf8");
}

function exportSite(site, number, total) {
  return new Promise((resolve) => {
    const outputDirectory = path.resolve(projectRoot, site.outputDirectory);
    const output = path.resolve(outputDirectory, site.output);
    const temporary = `${output}.partial-${process.pid}`;
    const runId = new Date().toISOString().replace(/[:.]/g, "-");
    const logDirectory = path.resolve(projectRoot, site.logDirectory);
    const logName = `${site.url.hostname}-${runId}.log`;
    const logPath = path.join(logDirectory, logName);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.mkdirSync(logDirectory, { recursive: true });
    const outputFd = fs.openSync(temporary, "w");
    const logFd = fs.openSync(logPath, "w");

    const args = [
      "fetch",
      "--dump",
      "html",
      "--with-base",
      "--browser-profile",
      site.profile,
      "--wait-until",
      site.waitUntil,
      "--wait-ms",
      String(site.waitMs),
      "--terminate-ms",
      String(site.terminateMs),
    ];
    args.push(site.url.href);

    console.log(`\n[${number}/${total}] Exporting ${site.url.href}`);
    console.log(`Profile: ${site.profile}`);
    console.log(`Scripts: ${site.keepScripts ? "preserved" : "removed"}`);
    console.log(`Output: ${output}`);
    console.log(`Log: ${logPath}`);

    const child = spawn(koko, args, {
      cwd: projectRoot,
      stdio: ["ignore", outputFd, "pipe"],
    });

    // --terminate-ms asks the browser core to stop and serialize gracefully.
    // A native/V8 call that does not unwind can prevent the child from ever
    // reaching process teardown, so contain every site with a parent-owned
    // deadline as well. This is process lifecycle protection, independent of
    // the URL being exported.
    let forcedTermination = false;
    let forceKillTimer = null;
    const containmentTimer = setTimeout(() => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      forcedTermination = true;
      console.error(
        `Koko did not exit ${site.terminateGraceMs}ms after its ${site.terminateMs}ms deadline; sending SIGTERM.`,
      );
      child.kill("SIGTERM");
      forceKillTimer = setTimeout(() => {
        if (child.exitCode !== null || child.signalCode !== null) return;
        console.error(
          `Koko still did not exit after ${site.killGraceMs}ms; sending SIGKILL.`,
        );
        child.kill("SIGKILL");
      }, site.killGraceMs);
      forceKillTimer.unref();
    }, site.terminateMs + site.terminateGraceMs);
    containmentTimer.unref();
    child.stderr.on("data", (chunk) => {
      fs.writeSync(logFd, chunk);
      process.stderr.write(chunk);
    });

    let spawnError = null;
    child.once("error", (error) => {
      spawnError = error;
    });

    child.once("close", (code, signal) => {
      clearTimeout(containmentTimer);
      if (forceKillTimer !== null) clearTimeout(forceKillTimer);
      fs.closeSync(outputFd);
      fs.closeSync(logFd);

      if (spawnError) {
        fs.rmSync(temporary, { force: true });
        console.error(`Could not start Koko: ${spawnError.message}`);
        resolve({ artifact: false, clean: false, forcedTermination });
        return;
      }

      let html = "";
      try {
        html = fs.readFileSync(temporary, "utf8");
      } catch {
        // The complete-document check below reports the failure.
      }

      const completeHtml =
        /^\s*(?:<!doctype\s+html[^>]*>)?(?:\s|<!--[\s\S]*?-->)*<html[\s>]/i.test(
          html,
        ) &&
        /<\/html>(?:\s|<!--[\s\S]*?-->)*$/i.test(html);

      if (!completeHtml) {
        fs.rmSync(temporary, { force: true });
        console.error(
          `Export failed${signal ? ` (${signal})` : ` (exit ${code})`}: no complete HTML was produced.`,
        );
        resolve({ artifact: false, clean: false, forcedTermination });
        return;
      }

      if (!site.keepScripts) {
        const result = stripScriptElements(html);
        html = result.html;
        fs.writeFileSync(temporary, html, "utf8");
        console.log(`Removed ${result.removed} <script> element(s).`);
      }

      fs.renameSync(temporary, output);
      console.log(`Done: ${output} (${Buffer.byteLength(html)} bytes)`);

      if (code !== 0 || signal) {
        console.warn(
          `Warning: HTML is valid, but Koko exited with ${signal || code} during teardown.`,
        );
      }
      resolve({
        artifact: true,
        clean: code === 0 && signal === null,
        forcedTermination,
      });
    });
  });
}

async function main() {
  if (process.argv.length > 2) {
    throw new Error(
      "This script no longer accepts arguments; edit CONFIG in export-site.js.",
    );
  }
  if (!fs.existsSync(koko)) {
    throw new Error(`Koko binary not found: ${koko}\nBuild it with: zig build`);
  }

  const indexSites = loadSitesFromFile(CONFIG.urlFile)
    .map(validateSite)
    .filter((site) => site !== null);
  if (indexSites.length === 0) {
    throw new Error(`No valid URLs found in ${CONFIG.urlFile}.`);
  }

  const batchUrlFile =
    process.env.KOKO_EXPORT_URL_FILE || CONFIG.urlFile;
  const batchSites =
    batchUrlFile === CONFIG.urlFile
      ? indexSites
      : loadSitesFromFile(batchUrlFile)
        .map(validateSite)
        .filter((site) => site !== null);
  if (!Number.isSafeInteger(CONFIG.maxSites) || CONFIG.maxSites <= 0) {
    throw new Error("CONFIG.maxSites must be a positive integer.");
  }
  const sites = batchSites.slice(0, CONFIG.maxSites);

  const states = new Map();
  writeIndex(indexSites, states);
  if (process.env.KOKO_EXPORT_INDEX_ONLY === "1") {
    console.log(
      `Index: ${path.resolve(projectRoot, CONFIG.outputDirectory, "index.html")}`,
    );
    return;
  }

  let artifactFailures = 0;
  let coreFailures = 0;
  for (const [index, site] of sites.entries()) {
    const result = await exportSite(site, index + 1, sites.length);
    states.set(site.output, result.artifact ? "exported" : "failed");
    writeIndex(indexSites, states);
    if (!result.artifact) artifactFailures += 1;
    if (!result.clean) coreFailures += 1;
  }

  console.log(
    `\nFinished: ${sites.length - artifactFailures} artifact(s), ${artifactFailures} export failure(s), ${coreFailures} core failure(s).`,
  );
  if (artifactFailures > 0 || coreFailures > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
