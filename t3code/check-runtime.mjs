// 镜像 CI：默认检查运行环境，--http [URL] 检查服务及前端资源。
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

async function checkProviderDiscovery(launcher, temporary) {
  const base = path.join(temporary, "provider-state");
  const bin = path.join(temporary, "provider-bin");
  await mkdir(path.join(base, "userdata"), { recursive: true });
  await mkdir(bin);
  // Discovery is a file check; it must not require a provider download or login.
  await writeFile(path.join(bin, "agy"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const providerInstances = {};
  for (const driver of ["codex", "claudeAgent", "pi", "opencode", "antigravity", "grok", "kiro", "fx", "cursor", "muse"]) {
    providerInstances[driver] = { driver, enabled: false };
  }
  providerInstances["agy-path"] = { driver: "antigravity", enabled: true };
  providerInstances["agy-override"] = {
    driver: "antigravity", enabled: true, config: { binaryPath: path.join(bin, "agy") },
  };
  providerInstances["agy-missing"] = {
    driver: "antigravity", enabled: true, config: { binaryPath: path.join(bin, "missing") },
  };
  await writeFile(path.join(base, "userdata/settings.json"), JSON.stringify({ providerInstances }));
  const listener = createServer();
  await new Promise((resolve, reject) => { listener.once("error", reject); listener.listen(0, "127.0.0.1", resolve); });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));
  const child = spawn(launcher, ["serve", "--host", "127.0.0.1", "--port", String(port)], {
    cwd: temporary,
    env: {
      ...process.env, HOME: temporary, T3CODE_HOME: base,
      PATH: `${bin}:/usr/local/bin:/usr/bin:/bin`,
      T3CODE_NO_BROWSER: "1", T3CODE_TELEMETRY_ENABLED: "false",
    },
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  let spawnError;
  child.stdout.on("data", (data) => { output = (output + data).slice(-8_000); });
  child.stderr.on("data", (data) => { output = (output + data).slice(-8_000); });
  child.on("error", (error) => { spawnError = error; });
  const closed = new Promise((resolve) => child.once("close", resolve));
  try {
    const deadline = Date.now() + 30_000;
    const ids = ["agy-path", "agy-override", "agy-missing"];
    while (Date.now() < deadline) {
      if (spawnError) throw spawnError;
      assert.equal(child.exitCode, null, `Provider check server exited: ${output}`);
      const snapshots = await Promise.all(ids.map(async (id) => {
        try { return JSON.parse(await readFile(path.join(base, `caches/${id}.json`), "utf8")); }
        catch (error) { if (error.code === "ENOENT" || error instanceof SyntaxError) return null; throw error; }
      }));
      if (snapshots.every((snapshot) => snapshot && !snapshot.message?.startsWith("Checking "))) {
        assert.equal(snapshots[0].installed, true, `agy on PATH was not discovered: ${snapshots[0].message}`);
        assert.equal(snapshots[1].installed, true, "Explicit agy path was not resolved");
        for (const snapshot of snapshots.slice(0, 2)) {
          assert.equal(snapshot.status, "warning", snapshot.message);
          assert.match(snapshot.message, /Google account access is not checked yet/);
        }
        assert.equal(snapshots[2].installed, false, "Missing explicit path must not fall back to PATH");
        assert.equal(snapshots[2].status, "error");
        console.log("Antigravity CLI discovery and explicit path precedence passed");
        return;
      }
      await delay(100);
    }
    assert.fail(`Provider discovery timed out: ${output}`);
  } finally {
    child.kill("SIGTERM");
    await Promise.race([closed, delay(5_000, undefined, { ref: false })]);
    if (child.exitCode === null && child.signalCode === null && child.pid) process.kill(-child.pid, "SIGKILL");
    await closed;
  }
}

async function checkRuntime() {
  const root = process.env.T3_ROOT || "/opt/t3";
  const launcher = path.join(root, "t3");
  const require = createRequire(path.join(root, "bin.mjs"));

  const temporary = await mkdtemp(path.join(tmpdir(), "t3-runtime-check-"));
  const env = { ...process.env, HOME: temporary, T3CODE_HOME: path.join(temporary, "state") };
  try {
    const version = execFileSync(launcher, ["--version"], { env, encoding: "utf8", timeout: 30_000 }).trim();
    const expected = process.env.T3_EXPECTED_VERSION?.replace(/^t3-/, "");
    if (expected) assert.equal(version, `t3 v${expected}`);
    const probe = path.join(temporary, "probe.cjs");
    await writeFile(probe, 'console.log(JSON.stringify({execPath:process.execPath,isSea:require("node:sea").isSea()}));process.exit(0);');
    const runtime = JSON.parse(execFileSync(launcher, ["--version"], {
      env: { ...env, NODE_OPTIONS: `--require=${probe}` }, encoding: "utf8", timeout: 10_000,
    }));
    assert.equal(runtime.isSea, false);
    assert.equal(await realpath(runtime.execPath), await realpath(process.execPath));
    assert.match(execFileSync(process.execPath, ["/usr/local/lib/node_modules/npm/bin/npm-cli.js", "--version"], {
      env, encoding: "utf8", timeout: 10_000,
    }), /^\d+\.\d+\.\d+/);
    assert.equal(require("zod").z.string().parse("ok"), "ok");
    assert(Object.keys(require("@cursor/sdk")).length > 0);
    assert(Object.keys(require("@cursor/sdk/sqlite")).length > 0);
    assert(require("playwright-core").chromium);
    const ffi = require("ffi-rs");
    ffi.open({ library: "t3_runtime_check", path: path.join(root, `node_modules/@ff-labs/fff-bin-linux-${process.arch}-gnu/libfff_c.so`) });
    ffi.close("t3_runtime_check");
    const speech = await import(pathToFileURL(path.join(root, "node_modules/transcribe-cpp/dist/index.js")));
    await speech.initialize();
    assert(speech.getAvailableBackends().some((backend) => backend.kind === "cpu"));
    const terminal = require("node-pty").spawn("/bin/sh", ["-c", "printf t3-pty-ok"], { cwd: temporary, env });
    let output = "";
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { terminal.kill(); reject(new Error("PTY timeout")); }, 10_000);
      terminal.onData((data) => { output += data; });
      terminal.onExit(({ exitCode }) => { clearTimeout(timer); exitCode === 0 ? resolve() : reject(new Error(`PTY exit ${exitCode}`)); });
    });
    assert(output.includes("t3-pty-ok"));
    const document = path.join(temporary, "check.docx");
    await writeFile(document, Buffer.from("UEsDBBQAAAAIAK4la13GEnoHrAAAAPEAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbF2Puw7CMAxFf6XKihoXBgaUlIEdGPgBK3HbiOahJBT4exKQOjBax/dcWxxfdm4Wisl4J9mWd+zYi9s7UGoKcUmyKedwAEhqIouJ+0CukMFHi7mMcYSA6o4jwa7r9qC8y+Rym6uD9eJS5NFoaq4Y8xktSQZPHzVorx62bPJiY83pF6vNkmEIs1GYy02wOP3X2fphMIrWfLWF6BWlZNxoZ74Si8Ztqh56Ad+n+g9QSwMEFAAAAAgAriVrXetODUmFAAAAuAAAABEAAAB3b3JkL2RvY3VtZW50LnhtbEWO0Q6CMAxFf4XsHTo18YHA+JbJJixh69IW0L+XYYwvp7n3pu3thldcqs0TB0y9ujRaDabbW4fjGn2S6ogTt3uvZpHcAvA4+2i5wezTkT2RopVD0gQ7ksuEo2cOaYoLXLW+Q7QhqXLyge5dZi6gAjFyq3+faru6IB0Uu5BO5pPfVfjXMh9QSwECFAMUAAAACACuJWtdxhJ6B6wAAADxAAAAEwAAAAAAAAAAAAAAgAEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAIAK4la13rTg1JhQAAALgAAAARAAAAAAAAAAAAAACAAd0AAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAAAgACAIAAAACRAQAAAAA=", "base64"));
    assert.equal(execFileSync(launcher, ["__document-text", document, ".docx"], {
      env, encoding: "utf8", timeout: 30_000,
    }).trim(), "t3-document-audit");
    await new Promise((resolve, reject) => {
      const child = spawn(launcher, ["__speech-worker", "discover"], { env, stdio: ["ignore", "ignore", "inherit", "ipc"] });
      let received = false;
      const timer = setTimeout(() => { child.kill(); reject(new Error("Speech worker timeout")); }, 30_000);
      child.on("message", (devices) => {
        received = Array.isArray(devices);
        if (child.connected) child.disconnect();
      });
      child.on("error", (error) => { clearTimeout(timer); reject(error); });
      child.on("exit", (code) => {
        clearTimeout(timer);
        code === 0 && received ? resolve() : reject(new Error(`Speech worker exit ${code}`));
      });
    });
    await access(path.join(root, "claude-history-worker.mjs"), constants.R_OK);
    await access(path.join(root, `resource-monitor/linux-${process.arch}/t3-resource-monitor`), constants.X_OK);
    await checkProviderDiscovery(launcher, temporary);
    console.log(`${version}: shared Node, npm, native modules, PTY and workers passed`);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function checkHttp(origin) {
  const response = await fetch(origin, { signal: AbortSignal.timeout(5_000) });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<html/i);
  const script = html.match(/src="([^" ]+\.js)"/);
  assert(script, "web client script missing");
  const asset = await fetch(new URL(script[1], origin), { signal: AbortSignal.timeout(5_000) });
  assert.equal(asset.status, 200);
  assert((await asset.text()).length > 0);
  console.log("T3 web startup passed");
}

if (process.argv[2] === "--http") {
  await checkHttp(process.argv[3] || "http://127.0.0.1:3773");
} else {
  await checkRuntime();
}
