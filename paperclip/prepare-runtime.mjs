import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const source = fs.realpathSync(process.argv[2] || "/app");
const destination = path.resolve(process.argv[3] || "/runtime/app");
const store = path.join(source, "node_modules/.pnpm");
const copied = new Set();
const dependencies = new Map();
const excluded = new Set(["node_modules", ".git", "__tests__", "tests", "test", "docs", "doc"]);
const platform = { os: process.platform, cpu: process.arch, libc: process.report.getReport().header.glibcVersionRuntime ? "glibc" : "musl" };
const compatibility = new Map();

assert(!destination.startsWith(`${source}/`), "Runtime destination must be outside the build tree");
assert(!fs.existsSync(destination), "Runtime destination must be empty");

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
    filter: candidate => (!options.filter || options.filter(candidate))
      && (!fs.lstatSync(candidate).isSymbolicLink() || supportsPlatform(fs.realpathSync(candidate))),
  });
}

function supportsPlatform(directory) {
  if (!directory.startsWith(`${store}/`)) return true;
  if (compatibility.has(directory)) return compatibility.get(directory);
  const filename = path.join(directory, "package.json");
  if (!fs.existsSync(filename)) return true;
  const manifest = JSON.parse(fs.readFileSync(filename, "utf8"));
  const supported = Object.entries(platform).every(([field, value]) => {
    const allowed = manifest[field] === undefined ? [] : [].concat(manifest[field]);
    return !allowed.includes(`!${value}`) && (allowed.every(item => item.startsWith("!")) || allowed.includes("any") || allowed.includes(value));
  });
  compatibility.set(directory, supported);
  return supported;
}

function followLinks(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
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
  dependencies.set(manifest.name, manifest.version);
  copy(directory, {
    filter: filename => {
      const relative = path.relative(directory, filename);
      return !relative.split(path.sep).some(part => excluded.has(part))
        && !(manifest.name === "@paperclipai/paperclip-runner" && relative.split(path.sep)[0] === "runner")
        && !/\.(map|tsbuildinfo)$/.test(filename)
        && !/\.(test|spec)\.[cm]?[jt]sx?$/.test(filename);
    },
  });
  const required = new Set(Object.keys(manifest.dependencies || {}));
  const optional = new Set([...Object.keys(manifest.optionalDependencies || {}), ...Object.keys(manifest.peerDependencies || {})]);
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
  dependencyGroups: [...copied].filter(filename => filename.startsWith(`${store}/`)).map(filename => path.relative(store, filename)),
}, null, 2));
console.log(`Prepared ${dependencies.size} runtime workspaces and ${copied.size - dependencies.size} dependency groups`);
