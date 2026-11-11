import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const script = fileURLToPath(import.meta.url);
const execute = promisify(execFile);
const pending = new Map();

export const hooks = {
  readPackage(manifest) {
    for (const name of Object.keys(manifest.optionalDependencies || {})) {
      if (/^(?:@openai\/codex-|@anthropic-ai\/claude-agent-sdk-|opencode-(?:linux|darwin|windows)-|@github\/copilot-(?:linux|darwin|win32)-)/.test(name)) delete manifest.optionalDependencies[name];
    }
    return manifest;
  },
};

function providerConfiguration() {
  const runtimeRoot = process.env.PAPERCLIP_RUNTIME_ROOT || "/app";
  const metadata = path.join(runtimeRoot, ".build/runtime.json");
  if (!fs.existsSync(metadata)) return undefined;
  const bound = process.env.PAPERCLIP_ACPX_PROVIDER_PACKAGE_ROOT;
  if (bound && (path.resolve(bound) !== bound || (bound !== runtimeRoot && !bound.startsWith(`${runtimeRoot}/`)))) return undefined;
  return { runtimeRoot, nativeProviders: JSON.parse(fs.readFileSync(metadata, "utf8")).nativeProviders };
}

export function hasImageProviderRuntime() {
  return Boolean(providerConfiguration()?.nativeProviders);
}

function providerState(provider) {
  const configuration = providerConfiguration();
  const recipe = configuration?.nativeProviders?.[provider];
  if (!recipe) return undefined;
  const { runtimeRoot } = configuration;
  const key = createHash("sha256").update(JSON.stringify(recipe)).digest("hex");
  const cache = path.resolve(process.env.PAPERCLIP_PROVIDER_CACHE || path.join(process.env.AGENT_CLI_ROOT || path.join(process.env.HOME, "agent-cli"), "paperclip-native"));
  fs.mkdirSync(cache, { recursive: true, mode: 0o700 });
  const root = path.join(fs.realpathSync(cache), `${provider}-${key}`);
  return { provider, runtimeRoot, recipe, key, root };
}

function installedProvider(state) {
  const receipt = path.join(state.root, ".complete.json");
  if (!fs.existsSync(receipt)) return undefined;
  assert.equal(fs.realpathSync(state.root), state.root, "Provider cache must not redirect through links");
  const metadata = fs.lstatSync(receipt);
  assert(metadata.isFile() && metadata.nlink === 1 && metadata.uid === process.getuid(), "Unsafe provider cache receipt");
  assert.equal(JSON.parse(fs.readFileSync(receipt, "utf8")).key, state.key, "Provider cache identity mismatch");
  const packageRoot = path.join(state.root, "node_modules", state.recipe.packageName);
  const root = state.provider === "copilot" ? path.join(state.root, "runtime") : packageRoot;
  const manifest = path.join(root, state.provider === "copilot" ? ".paperclip-copilot-closure.json" : "package.json");
  const executable = path.join(root, state.provider === "copilot" ? "copilot" : state.recipe.executable);
  for (const filename of [manifest, executable]) {
    assert.equal(fs.realpathSync(filename), filename, "Provider cache entry must remain canonical");
    assert(fs.lstatSync(filename).isFile(), "Provider cache entry must be a regular file");
  }
  fs.accessSync(executable, fs.constants.X_OK);
  return { packageName: state.recipe.packageName, manifest, root, executable, applicationRoot: fs.realpathSync(state.runtimeRoot), command: state.provider === "codex" ? path.join(state.root, "bin/codex.js") : executable };
}

function installInvocation(state) {
  return ["--exclusive", "--wait", "600", `${state.root}.lock`, process.execPath, script, "--hydrate", state.provider];
}

export async function ensureProviderRuntime(provider) {
  const state = providerState(provider);
  if (!state) return undefined;
  const installed = installedProvider(state);
  if (installed) return installed;
  if (!pending.has(state.root)) {
    const child = execute("flock", installInvocation(state), { timeout: 660000, maxBuffer: 1024 * 1024 });
    child.child.stderr.pipe(process.stderr, { end: false });
    const installation = child.then(() => installedProvider(state)).finally(() => pending.delete(state.root));
    pending.set(state.root, installation);
  }
  return pending.get(state.root);
}

export function ensureProviderRuntimeSync(provider) {
  const state = providerState(provider);
  if (!state) return undefined;
  const installed = installedProvider(state);
  if (installed) return installed;
  execFileSync("flock", installInvocation(state), { timeout: 660000, stdio: ["ignore", "ignore", "inherit"] });
  return installedProvider(state);
}

async function hydrateProvider(provider) {
  const state = providerState(provider);
  assert(state, `No qualified native runtime for ${provider} on ${process.platform}-${process.arch}`);
  if (installedProvider(state)) return;
  assert(!fs.existsSync(state.root), `Incomplete provider cache: ${state.root}; inspect it before removing it and retrying`);
  const staging = fs.mkdtempSync(`${state.root}.stage-`);
  try {
    console.error(`[paperclip-native] Installing ${provider}: ${state.recipe.artifact}@${state.recipe.version}`);
    const environment = { ...process.env };
    delete environment.NODE_OPTIONS;
    const result = await execute(process.execPath, ["/usr/local/lib/node_modules/npm/bin/npm-cli.js", "pack", `${state.recipe.artifact}@${state.recipe.version}`, "--ignore-scripts", "--json", "--cache", path.join(staging, ".npm"), "--pack-destination", staging], {
      cwd: staging, env: environment, timeout: 300000, maxBuffer: 1024 * 1024,
    });
    const [packed] = JSON.parse(result.stdout);
    assert(packed && path.basename(packed.filename) === packed.filename, "Invalid native package archive path");
    const archive = path.join(staging, packed.filename);
    const [algorithm, digest] = state.recipe.integrity.split("-");
    assert.equal(algorithm, "sha512", "Native packages require a lockfile SHA-512 integrity pin");
    const hash = createHash(algorithm);
    for await (const chunk of fs.createReadStream(archive)) hash.update(chunk);
    assert.equal(hash.digest("base64"), digest, "Native package archive differs from the image lockfile");
    const { stdout: inventory } = await execute("tar", ["-tzf", archive], { maxBuffer: 4 * 1024 * 1024 });
    assert(inventory.trim().split("\n").every(filename => filename.startsWith("package/") && !filename.split("/").includes("..")), "Unsafe native package archive");
    const packageRoot = path.join(staging, "node_modules", state.recipe.packageName);
    fs.mkdirSync(packageRoot, { recursive: true });
    await execute("tar", ["-xzf", archive, "--strip-components=1", "--no-same-owner", "-C", packageRoot]);
    const manifest = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));
    assert.equal(manifest.name, state.recipe.artifact, "Native package name mismatch");
    assert.equal(manifest.version, state.recipe.version, "Native package version mismatch");
    if (provider === "codex") {
      const cli = path.join(state.runtimeRoot, state.recipe.cli);
      for (const relative of ["package.json", "bin"]) fs.cpSync(path.join(cli, relative), path.join(staging, relative), { recursive: true });
    }
    if (provider === "copilot") {
      const runtime = path.join(staging, "runtime");
      fs.mkdirSync(runtime);
      const { materializePinnedCopilotBinary } = await import(pathToFileURL(path.join(state.runtimeRoot, "packages/paperclip-runner/scripts/materialize-copilot-binary.mjs")).href);
      const materialized = materializePinnedCopilotBinary({ packageRoot, targetDirectory: runtime });
      assert.equal(materialized.closureSha256, state.recipe.closureSha256, "Copilot materialization differs from its qualified closure");
      for (const entry of fs.readdirSync(packageRoot)) {
        if (/^(?:package\.json|licen[cs]e.*|notice.*|copyright.*)$/i.test(entry)) fs.cpSync(path.join(packageRoot, entry), path.join(staging, entry), { recursive: true });
      }
      fs.rmSync(path.join(staging, "node_modules"), { recursive: true });
    }
    fs.rmSync(archive);
    fs.rmSync(path.join(staging, ".npm"), { recursive: true, force: true });
    fs.writeFileSync(path.join(staging, ".complete.json"), JSON.stringify({ key: state.key }), { mode: 0o600, flag: "wx" });
    fs.renameSync(staging, state.root);
    installedProvider(state);
    console.error(`[paperclip-native] ${provider} is ready in the persistent cache`);
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
}

function patchFile(filename, replacements) {
  let contents = fs.readFileSync(filename, "utf8");
  for (const [before, after] of replacements) {
    assert.equal(contents.split(before).length, 2, `Unsupported runtime ${filename}: ${before}`);
    contents = contents.replace(before, after);
  }
  fs.writeFileSync(filename, contents);
}

function patchProviderSources(source) {
  const filename = path.join(source, "package.json");
  const manifest = JSON.parse(fs.readFileSync(filename, "utf8"));
  manifest.pnpm ||= {};
  assert(!manifest.pnpm.onlyBuiltDependencies, "Upstream build-script allowlist requires review");
  manifest.pnpm.neverBuiltDependencies = [...new Set([...(manifest.pnpm.neverBuiltDependencies || []), "opencode-ai"])];
  fs.writeFileSync(filename, `${JSON.stringify(manifest, null, 2)}\n`);
  patchFile(path.join(source, "packages/plugins/plugin-workspace-diff/scripts/build-ui.mjs"), [[
    "  sourcemap: true,",
    "  minify: true,\n  sourcemap: false,",
  ]]);
  patchFile(path.join(source, "packages/paperclip-runner/scripts/install-copilot-assets.mjs"), [[
    '  const target = `${platform}-${architecture}`;',
    '  const target = `${platform}-${architecture}`;\n  if (process.env.PAPERCLIP_BUILD_NO_NATIVE_PROVIDERS === "1") return { status: "deferred-to-persistent-cache", target };',
  ]]);
  const helper = `function paperclipImageRuntime() {
  const filename = "/usr/local/lib/paperclip/prepare-runtime.mjs";
  if (!process.getBuiltinModule("node:fs").existsSync(filename)) return undefined;
  const runtime = process.getBuiltinModule("node:module").createRequire(filename)(filename);
  return runtime.hasImageProviderRuntime() ? runtime : undefined;
}\n`;
  const directory = path.join(source, "packages/paperclip-runner/src/drivers");
  patchFile(path.join(directory, "acpx/installation-integrity.ts"), [[
    '  // Keep the selected package authority available when its bundled provider',
    `${helper}
  if ((profile.agent === "codex" || profile.agent === "claude") && resolvePackageJson === defaultPackageJsonResolver) {
    const runtime = await paperclipImageRuntime()?.ensureProviderRuntime(profile.agent);
    if (runtime) {
      const issuer = process.env.PAPERCLIP_ACPX_PROVIDER_PACKAGE_MANIFEST ?? import.meta.url;
      resolvePackageJson = (packageName, issuerPackageJsonPath) => {
        if (packageName === runtime.packageName) return runtime.manifest;
        const filename = realpathSync(resolvePackageJsonFromIssuer(packageName, issuerPackageJsonPath ?? issuer));
        if (!filename.startsWith(runtime.applicationRoot + "/")) throw new Error("Image provider dependency escapes the application tree");
        return filename;
      };
    }
  }
  // Keep the selected package authority available when its bundled provider`,
  ]]);
  patchFile(path.join(directory, "acpx/copilot-installation.ts"), [[
    '  const distributionRoot = join(resolveRunnerProviderAssetsRoot(import.meta.url, "copilot"), platform);',
    `${helper}
  const runtime = await paperclipImageRuntime()?.ensureProviderRuntime("copilot");
  const distributionRoot = runtime?.root ?? join(resolveRunnerProviderAssetsRoot(import.meta.url, "copilot"), platform);`,
  ]]);
  patchFile(path.join(directory, "opencode/opencode-server-driver.ts"), [
    ["export function resolvePinnedOpenCodeCommand(", `${helper}\nexport async function resolvePinnedOpenCodeCommand(`],
    ["): string {\n  try {\n    const platform = target.platform", "): Promise<string> {\n  try {\n    const platform = target.platform"],
    ['    const dependencyRequire = createRequire(manifestPath);', '    const runtime = platform === process.platform && architecture === process.arch ? await paperclipImageRuntime()?.ensureProviderRuntime("opencode") : undefined;\n    const dependencyRequire = createRequire(manifestPath);'],
    ['platformManifest = realpathSync(dependencyRequire.resolve(`${name}/package.json`));', 'platformManifest = realpathSync(runtime?.manifest ?? dependencyRequire.resolve(`${name}/package.json`));'],
    ["input.options.command ?? resolvePinnedOpenCodeCommand(),", "input.options.command ?? await resolvePinnedOpenCodeCommand(),"],
  ]);
  patchFile(path.join(directory, "codex/codex-command.ts"), [[
    "  try {\n    const runnerRequire = createRequire(issuer);",
    `${helper}
  if (paperclipImageRuntime()) {
    try { return resolveCodexOnPath(environment, workingDirectory); } catch {}
    const runtime = paperclipImageRuntime().ensureProviderRuntimeSync("codex");
    if (runtime) return runtime.command;
  }
  try {
    const runnerRequire = createRequire(issuer);`,
  ]]);
}

async function prepareRuntime(sourceDirectory, destinationDirectory) {
const source = fs.realpathSync(sourceDirectory || "/app");
const destination = path.resolve(destinationDirectory || "/runtime/app");
const store = path.join(source, "node_modules/.pnpm");
const copied = new Set();
const dependencies = new Map();
const excluded = new Set(["node_modules", ".git", "__tests__", "tests", "test", "docs", "doc", "examples", "devtools", "coverage", ".cache"]);
const dependencyArtifacts = new Set([".git", ".github", "__tests__", "tests", "test", "examples", "example", "coverage", "benchmarks", "benchmark", ".nyc_output"]);
const platform = { os: process.platform, cpu: process.arch, libc: process.report.getReport().header.glibcVersionRuntime ? "glibc" : "musl" };
const compatibility = new Map();

assert(!destination.startsWith(`${source}/`), "Runtime destination must be outside the build tree");
assert(!fs.existsSync(destination), "Runtime destination must be empty");

patchFile(createRequire(path.join(source, "packages/db/package.json")).resolve("embedded-postgres"), [
  ["const { Client } = pg;", `const { Client } = pg;
async function prepareDataDirectory(directory, uid = process.getuid()) {
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const metadata = await fs.stat(directory);
    if (metadata.uid !== uid) {
        throw new Error("Embedded PostgreSQL data directory " + directory + " must be owned by UID " + uid + "; fix its ownership on the host.");
    }
    if ([0o700, 0o750].includes(metadata.mode & 0o777)) return;
    await fs.chmod(directory, 0o700);
    if (![0o700, 0o750].includes((await fs.stat(directory)).mode & 0o777)) {
        throw new Error("Embedded PostgreSQL data directory " + directory + " must have permissions 0700 or 0750; check the host ACL and mount settings.");
    }
}`],
  ["const randomId = crypto.randomBytes", "yield prepareDataDirectory(this.options.databaseDir, permissionIds.uid);\n            const randomId = crypto.randomBytes"],
  ["ensureBinIsExecutable(postgres);\n            yield new Promise", "yield prepareDataDirectory(this.options.databaseDir, permissionIds.uid);\n            ensureBinIsExecutable(postgres);\n            yield new Promise"],
  ["process.on('exit', (code) => {", "process.stderr?.on('data', (chunk) => this.options.onError(chunk.toString('utf-8')));\n                process.once('error', reject);\n                process.on('close', (code) => {"],
]);
patchFile(path.join(source, "packages/adapter-utils/src/acpx-engine/execute.ts"), [
  ['  const configuredCommand = asString(config.agentCommand, "").trim();', `  if (acpxAgent === "claude" && !executionTargetIsRemote && !env.CLAUDE_CODE_EXECUTABLE) {
    for (const directory of (env.PATH ?? process.env.PATH ?? "").split(path.delimiter).filter(Boolean)) {
      const executable = path.resolve(directory, "claude");
      try {
        await fs.access(executable, fsSync.constants.X_OK);
        if (!(await fs.stat(executable)).isFile()) continue;
        env.CLAUDE_CODE_EXECUTABLE = executable;
        break;
      } catch {}
    }
  }
  const configuredCommand = asString(config.agentCommand, "").trim();`],
]);
const { prepareEmbeddedPostgresNativeRuntime } = await import(pathToFileURL(path.join(source, "packages/db/src/embedded-postgres-native.ts")).href);
await prepareEmbeddedPostgresNativeRuntime();

const materializedPackages = new Set();
const nativeProviders = {};
const nativePackages = new Map();
const launchers = new Map();
const runnerRequire = createRequire(path.join(source, "packages/paperclip-runner/package.json"));
const lockfile = fs.readFileSync(process.env.PAPERCLIP_SOURCE_LOCK || path.join(source, "pnpm-lock.yaml"), "utf8");
const codex = runnerRequire.resolve("@openai/codex/package.json");
const claude = path.join(path.dirname(createRequire(runnerRequire.resolve("@agentclientprotocol/claude-agent-acp/package.json")).resolve("@anthropic-ai/claude-agent-sdk")), "package.json");
const openCode = runnerRequire.resolve("opencode-ai/package.json");
const openCodeManifest = JSON.parse(fs.readFileSync(openCode, "utf8"));
for (const [provider, owner, packageName, executable] of [
  ["codex", codex, `@openai/codex-${platform.os}-${platform.cpu}`, `vendor/${platform.cpu === "x64" ? "x86_64" : "aarch64"}-unknown-linux-musl/bin/codex`],
  ["claude", claude, `@anthropic-ai/claude-agent-sdk-${platform.os}-${platform.cpu}`, "claude"],
  ["opencode", openCode, `opencode-${platform.os}-${platform.cpu}${platform.cpu === "x64" ? "-baseline" : ""}`, "bin/opencode"],
  ...(platform.cpu === "x64" ? [["copilot", path.join(source, "packages/paperclip-runner/package.json"), "@github/copilot-linux-x64", "copilot"]] : []),
]) {
  const declaration = JSON.parse(fs.readFileSync(owner, "utf8")).optionalDependencies?.[packageName];
  assert(declaration, `Missing qualified native declaration: ${packageName}`);
  const alias = declaration.startsWith("npm:") ? declaration.slice(4).match(/^(.+)@([^@]+)$/) : null;
  const artifact = alias ? alias[1] : packageName;
  const version = alias ? alias[2] : declaration;
  assert(/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(version), `Native package version must be exact: ${declaration}`);
  const manifestPath = path.join(store, `paperclip-native-${provider}@${version}`, "node_modules", packageName, "package.json");
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, JSON.stringify({ name: artifact, version, os: [platform.os], cpu: [platform.cpu] }));
  const link = path.join(path.dirname(owner), "node_modules", packageName);
  fs.mkdirSync(path.dirname(link), { recursive: true });
  assert(!fs.existsSync(link), `Unexpected build-time native provider: ${link}`);
  fs.symlinkSync(path.relative(path.dirname(link), path.dirname(manifestPath)), link);
  const key = `${artifact}@${version}`;
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const integrity = lockfile.match(new RegExp(`^  ['\"]?${escaped}['\"]?:\\n    resolution: \\{integrity: (sha512-[^,}\\s]+)`, "m"))?.[1];
  assert(integrity, `Missing lockfile integrity pin for ${key}`);
  const recipe = { packageName, artifact, version, integrity, executable, imagePackage: path.relative(source, path.dirname(manifestPath)) };
  if (provider === "codex") recipe.cli = path.relative(source, path.dirname(codex));
  if (provider === "copilot") {
    const { COPILOT_CLOSURE_SHA256 } = await import(pathToFileURL(path.join(source, "packages/paperclip-runner/dist/drivers/acpx/copilot-installation.js")).href);
    recipe.closureSha256 = COPILOT_CLOSURE_SHA256[`${platform.os}-${platform.cpu}`];
    assert.match(recipe.closureSha256, /^[a-f0-9]{64}$/);
  }
  nativeProviders[provider] = recipe;
  nativePackages.set(path.dirname(manifestPath), { provider, executable });
  launchers.set(path.join(path.dirname(manifestPath), executable), provider);
}
if (platform.cpu === "x64") materializedPackages.add(`opencode-linux-x64@${openCodeManifest.version}`);
const openCodeLauncher = path.resolve(path.dirname(openCode), openCodeManifest.bin.opencode);
assert(openCodeLauncher.startsWith(`${path.dirname(openCode)}/`), "OpenCode launcher must stay inside its package");
launchers.set(openCodeLauncher, "opencode");

function output(filename) {
  const relative = path.relative(source, filename);
  assert(relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), `External dependency: ${filename}`);
  return path.join(destination, relative);
}

function copy(filename, options = {}) {
  fs.mkdirSync(path.dirname(output(filename)), { recursive: true });
  fs.cpSync(filename, output(filename), {
    recursive: true,
    verbatimSymlinks: true,
    mode: fs.constants.COPYFILE_FICLONE,
    ...options,
    filter: candidate => {
      const relative = path.relative(store, candidate).split(path.sep);
      for (const [root, recipe] of nativePackages) {
        if (!candidate.startsWith(`${root}/`)) continue;
        const relative = path.relative(root, candidate);
        return relative === "package.json" || /^(?:licen[cs]e|notice|copyright)/i.test(relative)
          || path.dirname(recipe.executable) === relative || path.dirname(recipe.executable).startsWith(`${relative}/`);
      }
      return !launchers.has(candidate) && (!options.filter || options.filter(candidate))
        && (/[/\\](?:provider-assets|remote-provider-packs)(?:[/\\]|$)/.test(candidate)
          || (!/(?:\.(?:map|tsbuildinfo)|\.d\.[cm]?ts)$/.test(candidate)
            && (!candidate.startsWith(`${store}/`) || !dependencyArtifacts.has(relative[relative[2]?.startsWith("@") ? 4 : 3]))))
        && (!fs.lstatSync(candidate).isSymbolicLink() || supportsPlatform(fs.realpathSync(candidate)));
    },
  });
}

function supportsPlatform(directory) {
  if (!directory.startsWith(`${store}/`)) return true;
  if (compatibility.has(directory)) return compatibility.get(directory);
  const filename = path.join(directory, "package.json");
  if (!fs.existsSync(filename)) return true;
  const manifest = JSON.parse(fs.readFileSync(filename, "utf8"));
  const supported = !materializedPackages.has(`${manifest.name}@${manifest.version}`)
    && Object.entries(platform).every(([field, value]) => {
      const allowed = manifest[field] === undefined ? [] : [].concat(manifest[field]);
      return !allowed.includes(`!${value}`) && (allowed.every(item => item.startsWith("!")) || allowed.includes("any") || allowed.includes(value));
    });
  compatibility.set(directory, supported);
  return supported;
}

function followLinks(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
    if (!fs.lstatSync(output(filename), { throwIfNoEntry: false })) continue;
    if (entry.isSymbolicLink()) visit(fs.realpathSync(filename));
    else if (entry.isDirectory()) followLinks(filename);
  }
}

function visit(directory) {
  output(directory);
  if (!supportsPlatform(directory)) return;
  if (directory.startsWith(`${store}/`)) {
    const group = path.join(store, path.relative(store, directory).split(path.sep)[0], "node_modules");
    if (copied.has(group)) return;
    copied.add(group);
    copy(group);
    followLinks(group);
    return;
  }
  if (copied.has(directory)) return;
  copied.add(directory);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
  const published = manifest.name === "@paperclipai/paperclip-runner" ? ["package.json", "LICENSE", ...manifest.files] : null;
  dependencies.set(manifest.name, manifest.version);
  copy(directory, {
    filter: filename => {
      const relative = path.relative(directory, filename);
      if (/^provider-assets[/\\]copilot(?:[/\\]|$)/.test(relative)) return false;
      if (/^(?:provider-assets|dist[/\\](?:vendor[/\\]paperclip-runner[/\\])?remote-provider-packs)(?:[/\\]|$)/.test(relative)) return true;
      return !relative.split(path.sep).some(part => excluded.has(part))
        && (!published || !relative || published.some(entry => relative === entry || relative.startsWith(`${entry}/`) || entry.startsWith(`${relative}/`)))
        && !(manifest.name === "@paperclipai/paperclip-runner" && ["runner", "dist"].includes(relative.split(path.sep)[0]))
        && !(manifest.name === "@paperclipai/db" && /^(?:src|dist)[/\\]migrations[/\\]meta[/\\]\d+_snapshot\.json$/.test(relative))
        && !/\.(test|spec)\.[cm]?[jt]sx?$/.test(filename);
    },
  });
  if (manifest.name === "@paperclipai/paperclip-runner") {
    execFileSync("cp", ["-al", path.join(destination, "server/dist/vendor/paperclip-runner"), path.join(output(directory), "dist")]);
  }
  const required = new Set(Object.keys(manifest.dependencies || {}));
  const optional = new Set([...Object.keys(manifest.optionalDependencies || {}), ...Object.keys(manifest.peerDependencies || {})]);
  if (manifest.name === "@paperclipai/plugin-workspace-diff") {
    const { buildSync } = createRequire(path.join(source, "package.json"))("esbuild");
    const scan = (entries, options) => buildSync({
      absWorkingDir: source,
      entryPoints: entries.map(entry => path.join(directory, entry)),
      outdir: path.join(destination, ".build/plugin-dependency-scan"),
      bundle: true, write: false, metafile: true, format: "esm", target: "es2022", logLevel: "silent",
      ...options,
    }).metafile;
    const compiled = scan(["dist/index.js", "dist/manifest.js", "dist/worker.js", "dist/ui/index.js"], { packages: "external", platform: "node" });
    assert(!Object.values(compiled.outputs).some(output => output.imports.some(entry => /^@pierre\/diffs(?:\/|$)/.test(entry.path))), "Workspace diff still needs its frontend dependency at runtime");
    const frontend = scan(["src/ui/index.tsx"], { platform: "browser", external: ["react", "react-dom", "react/jsx-runtime", "@paperclipai/plugin-sdk/ui"] });
    const notices = new Set();
    for (const filename of Object.keys(frontend.inputs)) {
      const absolute = path.resolve(source, filename);
      if (!absolute.startsWith(`${store}/`)) continue;
      const relative = path.relative(store, absolute).split(path.sep);
      notices.add(path.join(store, ...relative.slice(0, relative[2]?.startsWith("@") ? 4 : 3)));
    }
    for (const directory of notices) {
      const entries = fs.readdirSync(directory);
      const legalFiles = entries.filter(entry => /licen[cs]e|notice|copyright|copying/i.test(entry));
      if (!legalFiles.length) legalFiles.push(...entries.filter(entry => /^readme(?:\.|$)/i.test(entry)));
      assert(legalFiles.length, `Review bundled package license: ${directory}`);
      for (const entry of ["package.json", ...legalFiles]) copy(path.join(directory, entry));
    }
    required.delete("@pierre/diffs");
    delete manifest.dependencies["@pierre/diffs"];
    fs.writeFileSync(path.join(output(directory), "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  }
  if (["server", "cli"].includes(path.relative(source, directory))) required.add("tsx");
  for (const name of new Set([...required, ...optional])) {
    const link = path.join(directory, "node_modules", name);
    if (!fs.existsSync(link)) {
      assert(!required.has(name) || optional.has(name), `Missing runtime dependency: ${manifest.name} -> ${name}`);
      continue;
    }
    copy(link);
    visit(fs.realpathSync(link));
  }
}

for (const relative of ["package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", ".npmrc", "tsconfig.json", "tsconfig.base.json", "LICENSE", "patches", "skills"]) {
  const filename = path.join(source, relative);
  if (fs.existsSync(filename)) copy(filename);
}
for (const relative of ["server", "cli", "packages/paperclip-runner", "packages/plugins/plugin-workspace-diff", "packages/plugins/create-paperclip-plugin"]) visit(path.join(source, relative));
copy(path.join(source, "ui/dist"), { filter: filename => !filename.endsWith(".map") });
copy(path.join(source, "ui/package.json"));
const standalonePlugins = path.join(source, "packages/plugins/sandbox-providers");
if (fs.existsSync(standalonePlugins)) {
  copy(standalonePlugins, { filter: filename => !path.relative(standalonePlugins, filename).split(path.sep).some(part => excluded.has(part)) });
}

const hoisted = path.join(store, "node_modules");
if (fs.existsSync(hoisted)) {
  const entries = fs.readdirSync(hoisted, { withFileTypes: true }).flatMap(entry => {
    const filename = path.join(hoisted, entry.name);
    return entry.isDirectory() && entry.name.startsWith("@")
      ? fs.readdirSync(filename).map(name => path.join(filename, name)) : [filename];
  });
  for (const filename of entries) {
    if (!fs.lstatSync(filename).isSymbolicLink()) continue;
    const resolved = fs.realpathSync(filename);
    const group = path.join(store, path.relative(store, resolved).split(path.sep)[0], "node_modules");
    if (copied.has(resolved) || copied.has(group)) copy(filename);
  }
}

function verify(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      const resolved = fs.realpathSync(filename);
      assert(resolved.startsWith(`${destination}/`), `Dependency escapes runtime tree: ${filename}`);
    } else if (entry.isDirectory()) verify(filename);
  }
}
for (const [filename, provider] of launchers) {
  fs.mkdirSync(path.dirname(output(filename)), { recursive: true });
  fs.writeFileSync(output(filename), `#!/bin/sh\nset -eu\nexecutable="$(/usr/local/bin/node /usr/local/lib/paperclip/prepare-runtime.mjs --executable ${provider})"\nexec "$executable" "$@"\n`, { mode: 0o755 });
}
verify(destination);
for (const relative of ["server/dist/index.js", "server/node_modules/tsx/dist/loader.mjs", "cli/node_modules/tsx/dist/cli.mjs", "packages/paperclip-runner/dist/bin/paperclip-runnerd", "packages/plugins/plugin-workspace-diff/dist/worker.js", "ui/dist/index.html"]) {
  assert(fs.statSync(path.join(destination, relative)).size > 0, `Missing runtime artifact: ${relative}`);
}
fs.mkdirSync(path.join(destination, ".build"));
fs.writeFileSync(path.join(destination, ".build/runtime.json"), JSON.stringify({
  node: process.version,
  platform,
  lockfileSha256: createHash("sha256").update(fs.readFileSync(path.join(source, "pnpm-lock.yaml"))).digest("hex"),
  workspaces: Object.fromEntries(dependencies),
  nativeProviders,
  materializedPackages: [...materializedPackages],
  dependencyGroups: [...copied].filter(filename => filename.startsWith(`${store}/`)).map(filename => path.relative(store, filename)),
}, null, 2));
console.log(`Prepared ${dependencies.size} runtime workspaces and ${copied.size - dependencies.size} dependency groups`);
}

async function main() {
  const [mode, ...args] = process.argv.slice(2);
  if (mode === "--patch-providers") return patchProviderSources(fs.realpathSync(args[0] || "/app"));
  if (mode === "--hydrate") return hydrateProvider(args[0]);
  if (mode === "--executable") {
    const runtime = await ensureProviderRuntime(args[0]);
    assert(runtime, `No qualified image runtime for ${args[0]}`);
    console.log(runtime.executable);
    return;
  }
  if (mode === "--prefetch") {
    for (const provider of (args[0] || "none").split(",").map(value => value.trim()).filter(value => value && value !== "none")) {
      assert(await ensureProviderRuntime(provider), `Unknown or unsupported native provider: ${provider}`);
    }
    return;
  }
  return prepareRuntime(mode, args[0]);
}

if (process.argv[1] && path.resolve(process.argv[1]) === script) {
  main().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}
