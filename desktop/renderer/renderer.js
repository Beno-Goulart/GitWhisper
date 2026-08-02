const $ = (id) => document.getElementById(id);

const state = {
  profile: '',
  binDir: '',
  type: 'function',
  activeTab: 'profile',
};

function setStatus(msg, kind) {
  const el = $('status');
  el.textContent = msg;
  el.className = 'statusbar' + (kind ? ' ' + kind : '');
}

const CHEAT_SHEET = `Conventional Commit types + gitmoji
====================================
feat       ✨  new feature
fix        🐛  bug fix
docs       📝  documentation
test       ✅  tests
style      💄  formatting / code style
refactor   ♻️  refactoring (no behavior change)
perf       ⚡  performance
build      🛠   build system / dependencies
ci         👷  CI configuration
chore      🔧  chores / maintenance
revert     ⏪  revert a change

Generated messages look like:
  ✨ feat(auth): adds Login component
  🐛 fix(api): adds error handling in user.js
  📝 docs: adds README.md
  ✅ test(payments): covers refund flow
  ⚡ perf(search): adds caching

Type is inferred from your diff, with a fallback to the
current branch name when it starts with feat/, fix/, docs/,
test/, chore/, refactor/, perf/, style/, ci/, build/.`;

async function refreshPreview() {
  const res = await window.gw.preview({
    profile: state.profile,
    type: state.type,
    binDir: state.binDir,
  });
  $('profilePreview').textContent = res.text;
  $('profileStatus').textContent = res.status;
}

function setType(t) {
  state.type = t;
  const isBin = t === 'bin';
  $('bindir').disabled = !isBin;
  $('browseBin').disabled = !isBin;
  refreshPreview();
}

function showTab(name) {
  state.activeTab = name;
  const isProfile = name === 'profile';
  $('tabProfile').classList.toggle('active', isProfile);
  $('tabGw').classList.toggle('active', !isProfile);
  const panels = document.querySelectorAll('.tabpanel');
  panels[0].style.display = isProfile ? 'flex' : 'none';
  panels[1].style.display = isProfile ? 'none' : 'flex';
}

async function init() {
  const d = await window.gw.getDefaults();
  state.profile = d.profile;
  state.binDir = d.binDir;
  $('profile').value = state.profile;
  $('bindir').value = state.binDir;
  $('gwPreview').textContent = CHEAT_SHEET;
  refreshPreview();
}

$('profile').addEventListener('input', (e) => {
  state.profile = e.target.value;
  refreshPreview();
});
$('bindir').addEventListener('input', (e) => {
  state.binDir = e.target.value;
  refreshPreview();
});
document.querySelectorAll('input[name="itype"]').forEach((r) => {
  r.addEventListener('change', () => setType(r.value));
});

$('browseProfile').addEventListener('click', async () => {
  const p = await window.gw.pickProfile();
  if (p) { state.profile = p; $('profile').value = p; refreshPreview(); }
});
$('browseBin').addEventListener('click', async () => {
  const p = await window.gw.pickDir('Select the bin directory');
  if (p) { state.binDir = p; $('bindir').value = p; refreshPreview(); }
});

$('tabProfile').addEventListener('click', () => showTab('profile'));
$('tabGw').addEventListener('click', () => showTab('gw'));

$('install').addEventListener('click', async () => {
  setStatus('Installing...');
  const res = await window.gw.install({ profile: state.profile, type: state.type, binDir: state.binDir });
  refreshPreview();
  setStatus(res.message, res.ok ? 'ok' : 'error');
});

$('uninstall').addEventListener('click', async () => {
  setStatus('Uninstalling...');
  const res = await window.gw.uninstall({ profile: state.profile, binDir: state.binDir });
  refreshPreview();
  setStatus(res.message, res.ok ? 'ok' : 'error');
});

$('demoBtn').addEventListener('click', async () => {
  const d = $('demoStatus');
  d.textContent = 'Generating a live suggestion from a temporary git repository...';
  d.className = 'hint';
  const res = await window.gw.demo($('demoDesc').value);
  $('gwPreview').textContent = res.output;
  if (res.ok) { d.textContent = 'Live suggestion from gitwhisper (temp repo).'; d.className = 'hint ok'; }
  else { d.className = 'hint error'; }
});

const backdrop = $('backdrop');
$('project').addEventListener('click', () => {
  $('projDir').value = '';
  backdrop.classList.add('show');
});
$('projBrowse').addEventListener('click', async () => {
  const p = await window.gw.pickDir('Select a git project directory');
  if (p) $('projDir').value = p;
});
$('projCancel').addEventListener('click', () => backdrop.classList.remove('show'));
$('projApply').addEventListener('click', async () => {
  const dir = $('projDir').value.trim();
  if (!dir) { setStatus('Choose a project directory.', 'warn'); return; }
  backdrop.classList.remove('show');
  setStatus('Setting up project...');
  const res = await window.gw.projectSetup({
    dir,
    emoji: $('chkEmoji').checked ? 'y' : 'n',
    defaultFmt: String($('cboDefault').selectedIndex + 1),
    prepare: $('chkPrepare').checked ? 'y' : 'n',
    validate: $('chkValidate').checked ? 'y' : 'n',
  });
  setStatus(res.message, res.ok ? 'ok' : 'error');
});

$('exit').addEventListener('click', () => window.close());

init();
