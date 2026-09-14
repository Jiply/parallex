'use strict';

const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const { spawnSync } = require('node:child_process');

/** When Desktop needs a stable IPC endpoint, load its installed native modules without copying them. */
function openArchive(archivePath) {
  const descriptor = fs.openSync(archivePath, 'r');
  const prefix = Buffer.alloc(16);
  fs.readSync(descriptor, prefix, 0, prefix.length, 0);
  const headerSize = prefix.readUInt32LE(12);
  if (headerSize > 64 * 1024 * 1024) throw new Error('Invalid archive header');
  const header = Buffer.alloc(headerSize);
  fs.readSync(descriptor, header, 0, header.length, 16);
  const tree = JSON.parse(header.toString('utf8'));
  const dataOffset = 8 + prefix.readUInt32LE(4);
  const cache = new Map();

  function entry(relative) {
    const normalized = path.posix.normalize(relative);
    if (normalized.startsWith('../') || path.posix.isAbsolute(normalized)) return null;
    let current = tree;
    for (const part of normalized.split('/')) {
      if (part === '.') continue;
      current = current?.files?.[part];
    }
    return current;
  }

  function read(relative) {
    const item = entry(relative);
    if (!item || item.files) throw new Error('Native module is unavailable');
    if (item.link) return read(item.link);
    if (item.unpacked) return fs.readFileSync(path.join(archivePath + '.unpacked', relative));
    const data = Buffer.alloc(item.size);
    if (fs.readSync(descriptor, data, 0, data.length, dataOffset + Number(item.offset)) !== data.length) {
      throw new Error('Incomplete native module');
    }
    return data;
  }

  function resolveFile(relative, depth = 0) {
    if (depth > 8) return null;
    for (const suffix of ['', '.js', '.cjs', '.json', '.node']) {
      const candidate = path.posix.normalize(relative + suffix);
      const item = entry(candidate);
      if (item && !item.files) return item.link ? resolveFile(item.link, depth + 1) : candidate;
    }
    if (!entry(relative)?.files) return null;
    const manifest = path.posix.join(relative, 'package.json');
    if (entry(manifest)) {
      const main = JSON.parse(read(manifest).toString('utf8')).main;
      if (typeof main === 'string') {
        const resolved = resolveFile(path.posix.join(relative, main), depth + 1);
        if (resolved) return resolved;
      }
    }
    return resolveFile(path.posix.join(relative, 'index'), depth + 1);
  }

  function resolve(request, parent) {
    if (request.startsWith('.')) return resolveFile(path.posix.join(path.posix.dirname(parent), request));
    if (request.startsWith(archivePath + path.sep)) return resolveFile(request.slice(archivePath.length + 1));
    let directory = path.posix.dirname(parent);
    while (true) {
      const resolved = resolveFile(path.posix.join(directory, 'node_modules', request));
      if (resolved) return resolved;
      if (directory === '.') return null;
      directory = path.posix.dirname(directory);
    }
  }

  function load(relative) {
    if (cache.has(relative)) return cache.get(relative).exports;
    const filename = path.join(archivePath, relative);
    if (relative.endsWith('.node')) return require(path.join(archivePath + '.unpacked', relative));
    const nativeModule = new Module(filename);
    cache.set(relative, nativeModule);
    nativeModule.filename = filename;
    nativeModule.paths = Module._nodeModulePaths(path.dirname(filename));
    const externalRequire = Module.createRequire(filename);
    function nativeRequire(request) {
      if (Module.isBuiltin(request)) return require(request);
      const resolved = resolve(request, relative);
      return resolved ? load(resolved) : externalRequire(request);
    }
    nativeRequire.resolve = function resolveNative(request) {
      if (Module.isBuiltin(request)) return request;
      const resolved = resolve(request, relative);
      return resolved ? path.join(archivePath, resolved) : externalRequire.resolve(request);
    };
    nativeModule.require = nativeRequire;
    try {
      if (relative.endsWith('.json')) nativeModule.exports = JSON.parse(read(relative).toString('utf8'));
      else nativeModule._compile(read(relative).toString('utf8'), filename);
      nativeModule.loaded = true;
      return nativeModule.exports;
    } catch (error) {
      cache.delete(relative);
      throw error;
    }
  }

  function ipcClientClass() {
    const directory = '.vite/build';
    const names = Object.keys(entry(directory)?.files ?? {})
      .filter(function isScript(name) {
        return name.endsWith('.js');
      })
      .sort(function preferSharedSource(left, right) {
        return Number(right.startsWith('src-')) - Number(left.startsWith('src-'));
      });
    for (const name of names) {
      const relative = path.posix.join(directory, name);
      if (!read(relative).includes('Received broadcast but no handler is configured')) continue;
      const methods = ['sendBroadcast', 'addBroadcastHandler', 'waitUntilInitialized', 'sendRequest'];
      const candidate = Object.values(load(relative)).find(function isIPCClient(value) {
        return (
          typeof value === 'function' &&
          methods.every(function hasMethod(method) {
            return typeof value.prototype?.[method] === 'function';
          })
        );
      });
      if (candidate) return candidate;
    }
    throw new Error('Native IPC client is unavailable');
  }

  return { ipcClientClass };
}

/** When a router starts or changes connection, publish only its local process readiness. */
function start() {
  const [archiveArgument, homeArgument] = process.argv.slice(2);
  if (!archiveArgument || !homeArgument) throw new Error('Missing router arguments');
  const archivePath = path.resolve(archiveArgument);
  const profileHome = path.resolve(homeArgument);
  process.umask(0o077);
  process.env.CODEX_HOME = profileHome;
  const directory = path.join(profileHome, 'ipc');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const directoryStat = fs.lstatSync(directory);
  if (!directoryStat.isDirectory() || directoryStat.uid !== process.getuid()) throw new Error('Invalid IPC directory');
  fs.chmodSync(directory, 0o700);
  // Keep the native router's legacy temporary-socket fallback inside this billing profile.
  process.env.TMPDIR = directory;
  const statusPath = path.join(directory, 'parallex-router.json');
  const lockPath = path.join(directory, 'parallex-router.lock');
  const temporary = path.join(directory, '.parallex-router-' + process.pid + '.json');
  const initial = { pid: process.pid, ready: false, ownsRouter: false };
  // lockf's descriptor mode leaves the kernel lock on our shared open file description.
  // Keep this inode permanently; closing the descriptor, including on a crash, releases it.
  const lockDescriptor = fs.openSync(lockPath, fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
  fs.fchmodSync(lockDescriptor, 0o600);
  const lock = spawnSync('/usr/bin/lockf', ['-s', '-t', '0', '3'], {
    stdio: ['ignore', 'ignore', 'ignore', lockDescriptor],
    timeout: 5000,
  });
  if (lock.status !== 0) {
    fs.closeSync(lockDescriptor);
    if (lock.status === 75) return;
    throw new Error('Could not acquire the native router lock');
  }
  function cleanup() {
    try {
      if (JSON.parse(fs.readFileSync(statusPath, 'utf8')).pid === process.pid) fs.unlinkSync(statusPath);
    } catch {}
    try {
      fs.unlinkSync(temporary);
    } catch {}
    fs.closeSync(lockDescriptor);
  }
  process.on('exit', cleanup);
  fs.writeFileSync(temporary, JSON.stringify(initial), { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, statusPath);

  let client;
  let lastStatus = JSON.stringify(initial);
  function publish() {
    const status = JSON.stringify({
      pid: process.pid,
      ready: Boolean(client?.socket?.writable && client.getClientId() !== 'initializing-client'),
      ownsRouter: client?.routerManager?.routerStarted === true,
    });
    if (status === lastStatus) return;
    fs.writeFileSync(temporary, status, { mode: 0o600, flag: 'wx' });
    fs.renameSync(temporary, statusPath);
    lastStatus = status;
  }
  function stop() {
    client?.dispose();
    process.exit(0);
  }
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  let reported = false;
  function reportNonFatal() {
    if (reported) return;
    reported = true;
    process.stderr.write('Parallex native IPC router reported a connection error.\n');
  }
  const IPCClient = openArchive(archivePath).ipcClientClass();
  client = new IPCClient('parallex-router', { reportNonFatal });
  client.addAnyBroadcastHandler(function receiveBroadcast() {});
  client.waitUntilInitialized().then(publish).catch(reportNonFatal);
  setInterval(function refreshStatus() {
    try {
      publish();
    } catch {
      reportNonFatal();
    }
  }, 250);
}

try {
  start();
} catch {
  process.stderr.write('Parallex could not start the installed native IPC router.\n');
  process.exitCode = 1;
}
