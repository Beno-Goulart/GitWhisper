const Module = require('module');
const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'electron') {
    return {
      app: {
        whenReady: () => ({ then: () => {} }),
        on: () => {},
        quit: () => {},
      },
      BrowserWindow: class {
        constructor() {}
        setMenuBarVisibility() {}
        loadFile() {}
        static getAllWindows() { return []; }
        static fromWebContents() { return null; }
      },
      ipcMain: { handle: () => {} },
      dialog: {
        showSaveDialog: async () => ({ canceled: true }),
        showOpenDialog: async () => ({ canceled: true }),
      },
    };
  }
  return origLoad.apply(this, arguments);
};

const fs = require('fs');
const path = require('path');
const os = require('os');
const main = require(path.join(__dirname, '..', 'desktop', 'main.js'));

let pass = 0, fail = 0;
function check(name, cond) {
  if (cond) { pass++; console.log('ok   ' + name); }
  else { fail++; console.log('FAIL ' + name); }
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gw-electron-test-'));
const psProfile = path.join(tmp, 'ps-profile.ps1');
const shProfile = path.join(tmp, 'bash-profile');
const binDir = path.join(tmp, 'bin');
const projDir = path.join(tmp, 'proj');
fs.mkdirSync(projDir, { recursive: true });

(async () => {
  console.log('-- scriptPaths fallback (repo root) --');
  const sp = main.scriptPaths();
  check('ps1 script resolved', fs.existsSync(sp.ps1));
  check('sh script resolved', fs.existsSync(sp.sh));
  check('modules dir resolved', fs.existsSync(sp.modules) && fs.readdirSync(sp.modules).some((n) => n.endsWith('.ps1')) && fs.readdirSync(sp.modules).some((n) => n.endsWith('.sh')));

  console.log('-- preview function mode --');
  const p1 = main.preview({ profile: psProfile, type: 'function' });
  check('preview contains function', p1.text.includes('function gitwhisper'));
  check('preview marks not installed', /Nothing installed yet/.test(p1.status));

  console.log('-- install function mode --');
  const r1 = main.install({ profile: psProfile, type: 'function', binDir });
  check('install ok', r1.ok === true);
  check('profile block written', main.testInstalled(psProfile));
  const content1 = fs.readFileSync(psProfile, 'utf8');
  check('profile has function', content1.includes('function gitwhisper'));
  check('scripts copied home', fs.existsSync(path.join(os.homedir(), '.gitwhisper', 'gitwhisper.ps1')));
  check('modules copied home', fs.existsSync(path.join(os.homedir(), '.gitwhisper', 'modules', 'lib.ps1')));

  const p2 = main.preview({ profile: psProfile, type: 'function' });
  check('preview detects installed', /already exists/.test(p2.status));

  console.log('-- install bin mode (replace) --');
  const r2 = main.install({ profile: psProfile, type: 'bin', binDir });
  check('install bin ok', r2.ok === true);
  const content2 = fs.readFileSync(psProfile, 'utf8');
  check('function block replaced by PATH block', content2.includes('$env:Path') && !content2.includes('function gitwhisper'));
  check('cmd wrapper created', fs.existsSync(path.join(binDir, 'gitwhisper.cmd')));
  check('sh wrapper created', fs.existsSync(path.join(binDir, 'gitwhisper')));
  check('single block in profile', (content2.match(/# >>> GitWhisper >>>/g) || []).length === 1);
  const binFromProfile = main.getBinDirFromProfile(psProfile);
  check('bin dir parsed from profile', binFromProfile === binDir);

  console.log('-- uninstall --');
  const r3 = main.uninstall({ profile: psProfile, binDir });
  check('uninstall ok', r3.ok === true);
  check('block removed', !main.testInstalled(psProfile));
  check('cmd wrapper removed', !fs.existsSync(path.join(binDir, 'gitwhisper.cmd')));
  check('sh wrapper removed', !fs.existsSync(path.join(binDir, 'gitwhisper')));

  const r4 = main.uninstall({ profile: psProfile, binDir });
  check('uninstall idempotent (not installed msg)', r4.ok === false && /not installed/i.test(r4.message));

  console.log('-- sh profile function mode --');
  const r5 = main.install({ profile: shProfile, type: 'function', binDir });
  check('install sh ok', r5.ok === true);
  const scontent = fs.readFileSync(shProfile, 'utf8');
  check('sh profile has bash function', scontent.includes('gitwhisper() { bash'));

  console.log('-- project setup --');
  const { execFileSync } = require('child_process');
  execFileSync('git', ['init', '-q'], { cwd: projDir });
  const r6 = main.projectSetup({ dir: projDir, emoji: 'y', defaultFmt: '1', prepare: 'y', validate: 'y' });
  check('project setup ok', r6.ok === true, r6.message);
  check('config written', fs.existsSync(path.join(projDir, '.gitwhisperconfig')));

  console.log('-- project setup rejects non-git dir --');
  const r7 = main.projectSetup({ dir: tmp, emoji: 'y', defaultFmt: '1', prepare: 'y', validate: 'y' });
  check('rejects non-git dir', r7.ok === false && /No .git/.test(r7.message));

  console.log('-- demo --');
  const d1 = main.demo('adds a login form with validation');
  check('demo ok', d1.ok === true, JSON.stringify(d1));
  check('demo output has conventional prefix', /^(feat|fix|docs|test|chore|refactor|perf|style|ci|build|✨|🐛|📝)/.test(d1.output), JSON.stringify(d1));

  console.log('-- defaults --');
  const def = main.getDefaults();
  check('defaults has profile + binDir', !!def.profile && !!def.binDir);

  console.log('-- empty profile file handling --');
  const emptyProf = path.join(tmp, 'empty-profile');
  fs.writeFileSync(emptyProf, '', 'utf8');
  main.install({ profile: emptyProf, type: 'function', binDir });
  check('install onto empty profile ok', main.testInstalled(emptyProf));
  main.uninstall({ profile: emptyProf, binDir });
  check('uninstall empty profile ok', !main.testInstalled(emptyProf));

  console.log('\nRESULT: ' + pass + ' passed, ' + fail + ' failed');
  try { fs.rmSync(path.join(os.homedir(), '.gitwhisper'), { recursive: true, force: true }); } catch {}
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
  process.exit(fail ? 1 : 0);
})();
