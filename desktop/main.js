const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const GW_VERSION = '1.0.0';
const MARKER_START = '# >>> GitWhisper >>>';
const MARKER_END = '# <<< GitWhisper <<<';

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function readFileSafe(p) {
  try { return fs.readFileSync(p, 'utf8'); } catch { return ''; }
}

function scriptPaths() {
  const res = process.resourcesPath
    ? path.join(process.resourcesPath, 'scripts')
    : path.join(__dirname, '..');
  return {
    ps1: path.join(res, 'gitwhisper.ps1'),
    sh: path.join(res, 'gitwhisper.sh'),
    python: path.join(res, 'python'),
  };
}

function copyDirRecursive(src, dest) {
  if (!fs.existsSync(src)) return;
  fs.mkdirSync(dest, { recursive: true });
  const names = fs.readdirSync(src);
  for (const name of names) {
    const s = path.join(src, name);
    const d = path.join(dest, name);
    if (fs.statSync(s).isDirectory()) copyDirRecursive(s, d);
    else fs.copyFileSync(s, d);
  }
}

function isPowerShellProfile(p) {
  const ext = path.extname(p).toLowerCase();
  if (ext === '.ps1') return true;
  return /powershell/i.test(p);
}

function testInstalled(profile) {
  return readFileSafe(profile).includes(MARKER_START);
}

function removeProfileBlock(profile) {
  if (!fs.existsSync(profile)) return;
  let content = readFileSafe(profile);
  if (!content) return;
  const re = new RegExp('[\\r\\n]*' + escapeRegex(MARKER_START) + '[\\s\\S]*?' + escapeRegex(MARKER_END) + '[\\r\\n]*', 'g');
  content = content.replace(re, '\r\n');
  fs.writeFileSync(profile, content, 'utf8');
}

function getBinDirFromProfile(profile) {
  const content = readFileSafe(profile);
  if (!content) return '';
  let m = content.match(/export PATH="([^"]*?):\$PATH"/);
  if (m) return m[1];
  m = content.match(/\$env:Path\s*=\s*"([^"]*?);\$env:Path"/);
  if (m) return m[1];
  return '';
}

function ensureProfile(profile) {
  fs.mkdirSync(path.dirname(profile), { recursive: true });
  if (!fs.existsSync(profile)) fs.writeFileSync(profile, '', 'utf8');
}

function installHome() {
  return path.join(os.homedir(), '.gitwhisper');
}

function install({ profile, type, binDir }) {
  if (!profile) return { ok: false, message: 'Enter a profile file path first.' };
  const { ps1, sh, python } = scriptPaths();
  const home = installHome();
  fs.mkdirSync(home, { recursive: true });
  if (fs.existsSync(ps1)) fs.copyFileSync(ps1, path.join(home, 'gitwhisper.ps1'));
  if (fs.existsSync(sh)) fs.copyFileSync(sh, path.join(home, 'gitwhisper.sh'));
  copyDirRecursive(python, path.join(home, 'python'));
  ensureProfile(profile);
  removeProfileBlock(profile);
  const isPs = isPowerShellProfile(profile);
  const script = path.join(home, isPs ? 'gitwhisper.ps1' : 'gitwhisper.sh');
  let block;
  if (type === 'bin') {
    fs.mkdirSync(binDir, { recursive: true });
    const cmd = '@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "' + script + '" %*\r\n';
    fs.writeFileSync(path.join(binDir, 'gitwhisper.cmd'), cmd, 'ascii');
    const bashShim = '#!/usr/bin/env bash\nexec bash "' + path.join(home, 'gitwhisper.sh') + '" "$@"\n';
    fs.writeFileSync(path.join(binDir, 'gitwhisper'), bashShim, 'utf8');
    block = isPs
      ? '\n' + MARKER_START + '\n$env:Path = "' + binDir + ';$env:Path"\n' + MARKER_END + '\n'
      : '\n' + MARKER_START + '\nexport PATH="' + binDir + ':$PATH"\n' + MARKER_END + '\n';
  } else {
    const fn = isPs
      ? 'function gitwhisper { & \'' + script + '\' @args }'
      : 'gitwhisper() { bash "' + script + '" "$@"; }';
    block = '\n' + MARKER_START + '\n' + fn + '\n' + MARKER_END + '\n';
  }
  fs.appendFileSync(profile, block, 'utf8');
  return { ok: true, message: 'Installed. Restart your terminal or run: . $PROFILE' };
}

function uninstall({ profile, binDir }) {
  if (!profile) return { ok: false, message: 'Enter a profile file path first.' };
  if (!testInstalled(profile)) return { ok: false, message: 'GitWhisper is not installed in ' + profile + '.' };
  const fromProfile = getBinDirFromProfile(profile);
  removeProfileBlock(profile);
  const dirs = Array.from(new Set([binDir, fromProfile].filter(Boolean)));
  let removed = 0;
  for (const d of dirs) {
    for (const f of ['gitwhisper.cmd', 'gitwhisper.ps1', 'gitwhisper']) {
      const p = path.join(d, f);
      if (fs.existsSync(p)) { fs.unlinkSync(p); removed++; }
    }
  }
  const home = installHome();
  for (const f of ['gitwhisper.ps1', 'gitwhisper.sh']) {
    const p = path.join(home, f);
    if (fs.existsSync(p)) { fs.unlinkSync(p); removed++; }
  }
  const py = path.join(home, 'python');
  if (fs.existsSync(py)) { fs.rmSync(py, { recursive: true, force: true }); removed++; }
  return { ok: true, message: removed > 0 ? 'Uninstalled. Removed ' + removed + ' file(s).' : 'Uninstalled.' };
}

function preview({ profile, type, binDir }) {
  const b = binDir || path.join(os.homedir(), '.local', 'bin');
  const installed = profile ? testInstalled(profile) : false;
  const isPs = isPowerShellProfile(profile || '');
  const home = installHome();
  const script = path.join(home, isPs ? 'gitwhisper.ps1' : 'gitwhisper.sh');
  const lines = [];
  let status;
  if (type === 'bin') {
    lines.push('Wrapper files to be created:');
    lines.push('  ' + path.join(b, 'gitwhisper.cmd'));
    lines.push('  ' + path.join(b, 'gitwhisper'));
    lines.push('');
    lines.push('Scripts will be copied to:');
    lines.push('  ' + path.join(home, 'gitwhisper.ps1'));
    lines.push('  ' + path.join(home, 'gitwhisper.sh'));
    lines.push('  ' + path.join(home, 'python', ''));
    lines.push('');
    lines.push('Block to be appended to the profile:');
    lines.push('');
    lines.push(isPs
      ? MARKER_START + '\n$env:Path = "' + b + ';$env:Path"\n' + MARKER_END
      : MARKER_START + '\nexport PATH="' + b + ':$PATH"\n' + MARKER_END);
    const binInstalled = fs.existsSync(path.join(b, 'gitwhisper.cmd')) || fs.existsSync(path.join(b, 'gitwhisper'));
    const bits = [];
    if (installed) bits.push('profile has a GitWhisper block');
    if (binInstalled) bits.push('wrapper files already exist');
    status = bits.length ? bits.join('; ') + ' - Install will replace them.' : 'Nothing installed yet - Install will create these files.';
  } else {
    lines.push('Scripts will be copied to:');
    lines.push('  ' + path.join(home, 'gitwhisper.ps1'));
    lines.push('  ' + path.join(home, 'gitwhisper.sh'));
    lines.push('  ' + path.join(home, 'python', ''));
    lines.push('');
    lines.push('Function to be appended to the profile:');
    lines.push('');
    const fn = isPs
      ? 'function gitwhisper { & \'' + script + '\' @args }'
      : 'gitwhisper() { bash "' + script + '" "$@"; }';
    lines.push(MARKER_START + '\n' + fn + '\n' + MARKER_END);
    status = installed
      ? 'A GitWhisper block already exists in this profile - Install will replace it.'
      : 'Nothing installed yet - Install will append this function.';
  }
  return {
    text: lines.join('\r\n'),
    status: profile ? status : 'Enter a profile file path to see the preview.',
  };
}

function run(cmd, args, cwd, stdin) {
  const r = spawnSync(cmd, args, { cwd, input: stdin, encoding: 'utf8', windowsHide: true });
  if (r.status !== 0) {
    throw new Error(cmd + ' ' + args.join(' ') + ' failed: ' + (r.stderr || '').trim());
  }
  return r.stdout;
}

function powershellCommand() {
  const p = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return fs.existsSync(p) ? p : 'pwsh';
}

function demo(description) {
  const desc = (description || '').trim() || 'adds a small feature';
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gw-demo-'));
  try {
    run('git', ['init', '-q'], tmp);
    run('git', ['config', 'user.name', 'GitWhisper Demo'], tmp);
    run('git', ['config', 'user.email', 'gitwhisper@example.com'], tmp);
    const tree = run('git', ['write-tree'], tmp).trim();
    const commit = run('git', ['commit-tree', tree], tmp, 'baseline').trim();
    run('git', ['update-ref', 'HEAD', commit], tmp);
    run('git', ['reset', '-q'], tmp);
    const words = desc.split(/\s+/).filter(Boolean);
    const word = words[words.length - 1].replace(/[^A-Za-z0-9_$]/g, '') || 'feature';
    fs.writeFileSync(path.join(tmp, 'demo.js'), 'const ' + word + ' = { ok: true };\nexport default ' + word + ';\n', 'utf8');
    run('git', ['add', 'demo.js'], tmp);
    const ps = powershellCommand();
    const r = spawnSync(ps, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPaths().ps1, 'suggest'], {
      cwd: tmp, encoding: 'utf8', windowsHide: true,
    });
    if (r.status !== 0) throw new Error((r.stderr || '').trim() || 'suggest failed');
    const out = (r.stdout || '').trim();
    return { ok: true, output: out || '(no suggestion generated - the temp repo produced no diff)' };
  } catch (e) {
    return { ok: false, output: 'Could not generate a live example: ' + e.message };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function projectSetup({ dir, emoji, defaultFmt, prepare, validate }) {
  if (!dir) return { ok: false, message: 'Choose a project directory.' };
  if (!fs.existsSync(path.join(dir, '.git'))) return { ok: false, message: 'No .git directory found in ' + dir + '.' };
  const config = '\n# GitWhisper configuration\n# Created by the GitWhisper installer.\n\n[general]\nemoji = ' + emoji +
    '\ndefault = ' + defaultFmt + '\n\n[hooks]\nprepare = ' + prepare + '\nvalidate = ' + validate + '\n';
  fs.writeFileSync(path.join(dir, '.gitwhisperconfig'), config, 'utf8');
  const script = path.join(installHome(), 'gitwhisper.ps1');
  const r = spawnSync(powershellCommand(), ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, 'init'], {
    cwd: dir, encoding: 'utf8', windowsHide: true,
  });
  if (r.status !== 0) return { ok: false, message: 'init failed: ' + (r.stderr || '').trim() };
  return { ok: true, message: 'Project ' + dir + ' is ready (config + hooks installed).' };
}

function getDefaults() {
  const profile = path.join(os.homedir(), 'Documents', 'WindowsPowerShell', 'Microsoft.PowerShell_profile.ps1');
  return {
    profile: fs.existsSync(profile) ? profile : profile,
    binDir: path.join(os.homedir(), '.local', 'bin'),
    home: os.homedir(),
    version: GW_VERSION,
  };
}

function createWindow() {
  const win = new BrowserWindow({
    width: 940,
    height: 800,
    minWidth: 720,
    minHeight: 600,
    title: 'GitWhisper Installer v' + GW_VERSION,
    backgroundColor: '#0f172a',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

ipcMain.handle('gw:defaults', () => getDefaults());
ipcMain.handle('gw:preview', (_e, opts) => preview(opts));
ipcMain.handle('gw:install', (_e, opts) => install(opts));
ipcMain.handle('gw:uninstall', (_e, opts) => uninstall(opts));
ipcMain.handle('gw:demo', (_e, desc) => demo(desc));
ipcMain.handle('gw:projectSetup', (_e, opts) => projectSetup(opts));

ipcMain.handle('gw:pickProfile', async (e) => {
  const win = BrowserWindow.fromWebContents(e.sender);
  const r = await dialog.showSaveDialog(win, {
    title: 'Select the shell profile file',
    defaultPath: getDefaults().profile,
    filters: [
      { name: 'Profile files', extensions: ['ps1', 'bashrc', 'zshrc', 'profile'] },
      { name: 'All files', extensions: ['*'] },
    ],
  });
  return r.canceled ? '' : r.filePath;
});

ipcMain.handle('gw:pickDir', async (e, opts) => {
  const win = BrowserWindow.fromWebContents(e.sender);
  const r = await dialog.showOpenDialog(win, {
    title: opts && opts.title ? opts.title : 'Select a directory',
    properties: ['openDirectory', 'createDirectory'],
  });
  return r.canceled ? '' : r.filePaths[0];
});

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

module.exports = {
  install,
  uninstall,
  preview,
  demo,
  projectSetup,
  getDefaults,
  scriptPaths,
  testInstalled,
  getBinDirFromProfile,
};
