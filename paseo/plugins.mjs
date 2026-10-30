import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const home = process.env.PASEO_HOME || path.join(os.homedir(), '.paseo');
const sources = [...new Set((process.env.PASEO_PLUGINS || '').split(',').map(s => s.trim()).filter(Boolean))];
const stateFile = path.join(home, 'container-plugin-sources.json');
const log = message => console.log(`[paseo-plugins] ${message}`);

function cli(args, timeout = 20_000) {
  return JSON.parse(execFileSync('paseo', [...args, '--home', home, '--json'], {
    encoding: 'utf8',
    timeout,
    maxBuffer: 4 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  }));
}

function describeError(error) {
  return error.stderr?.toString().trim() || error.message;
}

function prepare() {
  const configured = cli(['daemon', 'config', 'get', 'pluginsEnabled']);
  // 显式配置清单即选择启用插件；已有的总开关值始终由用户控制。
  if (!configured.set) {
    cli(['daemon', 'config', 'set', 'pluginsEnabled', 'true']);
    log('Enabled plugins for initial setup');
  } else if (configured.value === false) {
    log('Plugins are globally disabled; preserving this setting');
  }
}

function readSources() {
  try {
    const saved = JSON.parse(readFileSync(stateFile, 'utf8'));
    if (!saved || Array.isArray(saved) || typeof saved !== 'object' ||
        Object.values(saved).some(value => typeof value !== 'string')) {
      throw new Error('Invalid source mapping');
    }
    return new Map(Object.entries(saved));
  } catch (error) {
    if (error.code !== 'ENOENT') log(`Cannot read source mapping; rediscovering installed plugins: ${describeError(error)}`);
    return new Map();
  }
}

function saveSources(saved) {
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const temporary = `${stateFile}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(Object.fromEntries(saved), null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, stateFile);
}

// 已手工安装的 registry 插件也直接复用；registry ID 可能与运行时 ID 不同。
function registryMatches(source, plugin) {
  const registry = plugin.installation?.identity?.registry;
  if (!registry) return false;
  const defaultUrl = (process.env.PASEO_PLUGIN_REGISTRY || 'https://plugins.paseo.sh').replace(/\/+$/, '');
  if (source === registry.id && registry.url.replace(/\/+$/, '') === defaultUrl) return true;
  const url = new URL(registry.url);
  return url.pathname.replace(/\/+$/, '') === '' && source === `${url.host}/${registry.id}`;
}

async function waitForPlugins() {
  const deadline = Date.now() + 90_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const plugins = cli(['plugin', 'ls']);
      if (!Array.isArray(plugins)) throw new Error('Unexpected plugin list response');
      return plugins;
    } catch (error) {
      lastError = error;
      await delay(1_000);
    }
  }
  throw new Error(`Daemon did not become ready; retrying on next start: ${describeError(lastError)}`);
}

async function install() {
  const plugins = await waitForPlugins();
  const saved = readSources();
  for (const source of sources) {
    try {
      const existing = plugins.find(plugin => plugin.id === saved.get(source) || registryMatches(source, plugin));
      if (existing) {
        saved.set(source, existing.id);
        log(`${source}: already installed (${existing.id}); keeping its version and enabled state`);
      } else {
        log(`${source}: installing`);
        const plugin = cli(['plugin', 'install', source], 300_000);
        if (typeof plugin.id !== 'string' || plugin.status === 'failed') {
          throw new Error(plugin.error || 'Unexpected plugin install response');
        }
        plugins.push(plugin);
        saved.set(source, plugin.id);
        log(`${source}: installed (${plugin.id}, ${plugin.status})`);
      }
      saveSources(saved);
    } catch (error) {
      log(`${source}: initialization failed; retrying on next start: ${describeError(error)}`);
    }
  }
}

if (sources.length && !(sources.length === 1 && sources[0] === 'none')) {
  try {
    if (process.argv[2] === 'prepare') prepare();
    else if (process.argv[2] === 'install') await install();
    else throw new Error('Expected prepare or install');
  } catch (error) {
    log(describeError(error));
    process.exitCode = 1;
  }
}
