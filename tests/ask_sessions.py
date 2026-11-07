"""Run with python3 tests/ask_sessions.py; uses isolated state and fake agent CLIs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, uuid, time
agent = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
prompt = sys.stdin.read()
root = pathlib.Path(os.environ['ASK_TEST_ROOT'])
resume = 'resume' in args if agent == 'codex' else '--resume' in args
if agent == 'codex':
    session = args[-2] if resume else str(uuid.uuid4())
else:
    flag = '--resume' if resume else '--session-id'
    session = args[args.index(flag) + 1]
with (root / 'requests.jsonl').open('a') as f:
    f.write(json.dumps(dict(agent=agent, session=session, resume=resume, args=args, prompt=prompt)) + '\n')
if 'HOLD_THIS_TURN' in prompt:
    if agent == 'codex':
        print(json.dumps(dict(type='thread.started', thread_id=session)), flush=True)
    else:
        print(json.dumps(dict(type='system', subtype='init', session_id=session)), flush=True)
    (root / 'agent-started').write_text(session)
    while not (root / 'release-agent').exists():
        time.sleep(0.02)
if 'FAIL_THIS_TURN' in prompt:
    print('Simulated request failure', file=sys.stderr)
    sys.exit(1)
path = root / (session + '.json')
turns = json.loads(path.read_text()) if path.exists() else []
if resume and not turns:
    sys.exit('Cannot resume unknown session')
turns.append(prompt)
path.write_text(json.dumps(turns))
answer = agent + ' turn ' + str(len(turns)) + ': ' + session
if agent == 'codex':
    print(json.dumps(dict(type='thread.started', thread_id=session)))
    pathlib.Path(args[args.index('-o') + 1]).write_text(answer)
    print(json.dumps(dict(type='turn.completed')))
else:
    print(json.dumps(dict(type='system', subtype='init', session_id=session)), flush=True)
    print(json.dumps(dict(type='result', result=answer, is_error=False)))
'''
COMMON = r'''
vim.opt.runtimepath:prepend(vim.env.ASK_TEST_REPO)
vim.o.columns, vim.o.lines = 140, 40
require('ryuux05.ask')
local function key(lhs, mode)
  local mapping = vim.fn.maparg(lhs, mode or 'n', false, true)
  assert(next(mapping), 'Missing mapping: ' .. lhs)
  if type(mapping.callback) == 'function' then
    mapping.callback()
  else
    vim.api.nvim_feedkeys(vim.keycode(mapping.rhs), 'nx', false)
  end
  vim.cmd.stopinsert()
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
local function panel()
  vim.cmd.AgentPanel()
end
local function submit(question, expected)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { question })
  key('<CR>')
  panel()
  local function latest_reply()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local row, first, last = vim.api.nvim_win_get_cursor(0)[1], 1, #lines
    for index = 1, row do if lines[index]:match('^# ') then first = index end end
    for index = first + 1, #lines do
      if lines[index]:match('^# ') then last = index - 1; break end
    end
    local message = first
    for index = first, last do if lines[index]:match('^## ') then message = index end end
    return table.concat(lines, '\n', message, last)
  end
  assert(vim.wait(5000, function()
    local title = vim.inspect(vim.api.nvim_win_get_config(0).title)
    return not title:find('working…', 1, true) and latest_reply():find(expected, 1, true) ~= nil
  end), latest_reply())
end
local function prompt_agent(agent)
  local title = vim.inspect(vim.api.nvim_win_get_config(0).title)
  assert(title:find(agent, 1, true), title)
end
local function open_file()
  vim.cmd.edit('sample.lua')
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end
'''


def run(env, script):
    source = Path(env['ASK_TEST_ROOT']) / 'check.lua'
    source.write_text(COMMON + '\nlocal ok, err = xpcall(function()\n' + script
                      + '\nend, debug.traceback)\n'
                      + 'if not ok then io.stderr:write(err .. "\\n"); vim.cmd("cquit 1") end\n'
                      + 'vim.cmd("qa!")\n')
    result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
                             '-c', f'luafile {source}'], env=env,
                            cwd=env['ASK_TEST_PROJECT'], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix='nvim-ask-') as directory:
    root = Path(directory).resolve()
    project = root / 'project'
    project.mkdir()
    (project / 'sample.lua').write_text('local value = 1\nprint(value)\n')
    bindir = root / 'bin'
    bindir.mkdir()
    for name in ('codex', 'claude'):
        executable = bindir / name
        executable.write_text(FAKE)
        executable.chmod(0o755)
    env = dict(os.environ, ASK_TEST_ROOT=str(root), ASK_TEST_PROJECT=str(project),
               ASK_TEST_REPO=str(REPO), XDG_STATE_HOME=str(root / 'state'),
               XDG_DATA_HOME=str(root / 'data'), XDG_CACHE_HOME=str(root / 'cache'),
               PATH=str(bindir) + os.pathsep + os.environ['PATH'])
    run(env, r'''
open_file()
key('<CR>')
prompt_agent('Codex')
submit('Remember the first question.', 'codex turn 1:')
key('<Esc>')
key('ga')
assert(text():find('Remember the first question.', 1, true))
key('<CR>')
submit('Continue the conversation.', 'codex turn 2:')
vim.cmd('AgentDefault claude')
key('<Esc>')
vim.api.nvim_win_set_cursor(0, { 2, 0 })
key('<CR>')
prompt_agent('Claude')
submit('A separate Claude conversation.', 'claude turn 1:')
key('i')
submit('Continue Claude.', 'claude turn 2:')
for _, chat in ipairs(require('ryuux05.ask_state').load(vim.fn.getcwd())) do
  for _, message in ipairs(chat.messages) do
    assert(message.row == nil, 'Panel display rows must not be persisted as history')
  end
end
''')
    requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
    assert len(requests) == 4
    for first, second in (requests[:2], requests[2:]):
        assert not first['resume'] and second['resume']
        assert first['session'] == second['session']

    run(env, r'''
-- The saved default is still Claude after a fresh Neovim process.
open_file()
key('<S-CR>')
prompt_agent('Claude')
key('<Esc>')
key('<CR>')
assert(text():find('codex turn 2:', 1, true))
assert(text():find('claude turn 2:', 1, true))
vim.cmd('AgentDefault codex')
-- Changing the default does not switch an existing Claude conversation.
vim.api.nvim_win_set_cursor(0, { vim.fn.search('^# Claude', 'w'), 0 })
key('i')
prompt_agent('Claude')
submit('Still Claude.', 'claude turn 3:')
-- Resume the first conversation after a restart using the original ID.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
key('<CR>')
prompt_agent('Codex')
submit('Continue after restarting Neovim.', 'codex turn 3:')
key('i')
submit('FAIL_THIS_TURN', '**Error:** Simulated request failure')
assert(not text():find('codex turn 4:', 1, true))
key('i')
submit('Recover from the failure.', 'codex turn 4:')
-- Closing the source file must not destroy the conversation.
key('<Esc>')
vim.cmd('bwipeout!')
key('ga')
key('i')
submit('Continue without the original buffer.', 'codex turn 5:')
''')
    requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
    assert requests[4]['agent'] == 'claude' and requests[4]['session'] == requests[2]['session']
    assert all(r['resume'] and r['session'] == requests[0]['session'] for r in requests[5:])
    run(env, r'''
open_file()
key('<S-CR>')
prompt_agent('Codex')
-- Tab is a per-conversation override and does not change the saved default.
key('<Tab>')
prompt_agent('Claude')
key('<Esc>')
key('<S-CR>')
prompt_agent('Codex')
key('<Esc>')
panel()
assert(text():find('codex turn 5:', 1, true))
assert(text():find('claude turn 3:', 1, true))
local selections = 0
vim.ui.select = function() selections = selections + 1 end
vim.ui.input = function(options, callback)
  assert(options.prompt:find('history', 1, true))
  callback(nil)
end
key('/')
assert(selections == 0, 'Canceling search must leave the current conversation alone')
vim.ui.input = function(options, callback) callback('restarting Neovim') end
vim.ui.select = function(items, options, callback)
  assert(#items == 1 and items[1].agent == 'codex', 'Slash must search all saved history')
  callback(items[1])
end
key('/')
assert(vim.api.nvim_get_current_line():find('Codex', 1, true))
vim.ui.select = function(items, options, callback)
  assert(#items == 2, 'Recent history must list both conversations')
  selections = selections + 1
  callback(nil)
end
key('r')
assert(selections == 1, 'r must open the recent-history picker')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
key('q')
assert(not text():find('codex turn 5:', 1, true))
''')
    run(env, r'''
panel()
assert(not text():find('codex turn 5:', 1, true))
assert(text():find('claude turn 3:', 1, true))
''')
    # A different working directory gets its own session list.
    other = root / 'other-project'
    other.mkdir()
    run(dict(env, ASK_TEST_PROJECT=str(other)), r'''
local notices = {}
vim.notify = function(message) table.insert(notices, message) end
panel()
assert(notices[1]:find('No AI sessions yet', 1, true))
''')
    review_setup = r"""
vim.cmd.enew()
vim.api.nvim_buf_set_name(0, 'octo://example/repo/review/1/file/RIGHT/sample.lua')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local value = 1' })
require('ryuux05.ask').attach(vim.api.nvim_get_current_buf(), function(buf, l1, l2)
  return {
    review = true,
    label = 'review.lua:1',
    source = { path = vim.api.nvim_buf_get_name(buf), l1 = l1, l2 = l2 },
    context = 'Read-only review fixture',
    range = function(b) if b == buf then return l1, l2 end end,
  }
end)
"""
    run(env, review_setup + r"""
key('<CR>')
submit('Review this code.', 'codex turn 1:')
""")
    run(env, review_setup + r"""
key('<CR>')
assert(text():find('Review this code.', 1, true))
key('i')
local footer = vim.inspect(vim.api.nvim_win_get_config(0).footer)
assert(not footer:find('edit', 1, true), 'Restored reviews must remain read-only')
submit('Continue the review.', 'codex turn 2:')
""")
    requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
    assert requests[-1]['resume'] and requests[-1]['session'] == requests[-2]['session']

    # The durable worker outlives a killed Neovim, without an agent service call.
    def backend(request):
        command = ['python3', str(REPO / 'scripts' / 'ask_store.py'), '--root', str(root / 'state' / 'nvim' / 'ask')]
        result = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr + result.stdout
        return json.loads(result.stdout)['result']

    def wait_for(predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.02)
        raise AssertionError('Timed out waiting for crash recovery')

    crash_source = root / 'crash.lua'
    crash_source.write_text(COMMON + r"""
open_file()
key('<S-CR>')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'HOLD_THIS_TURN until released.' })
key('<CR>')
vim.wait(60000)
vim.cmd('qa!')
""")
    editor = subprocess.Popen(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
                              '-c', f'luafile {crash_source}'], env=env, cwd=project,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda: (root / 'agent-started').exists())
        session = (root / 'agent-started').read_text()
        def recovered():
            return next((chat for chat in backend(dict(op='load', cwd=str(project))) if chat.get('id') == session), None)
        current = wait_for(recovered)
        assert current['active'] and current['started']
        editor.kill()
        editor.communicate(timeout=5)
        # Killing the UI must not release ownership of its still-running CLI.
        current = recovered()
        assert current['active'] and current['id'] == session
        run(env, r"""
panel()
vim.api.nvim_win_set_cursor(0, { vim.fn.search('HOLD_THIS_TURN', 'w'), 0 })
local original = vim.api.nvim_get_current_buf()
key('<CR>')
assert(vim.api.nvim_get_current_buf() == original, 'A second turn must not start while the original is running')
""")
    finally:
        if editor.poll() is None:
            editor.kill()
            editor.communicate(timeout=5)
        (root / 'release-agent').touch()
    wait_for(lambda: (lambda chat: chat and not chat['active'] and not chat.get('interrupted'))(recovered()))
    run(env, r"""
vim.ui.select = function(items, options, callback) callback(items[1]) end
vim.cmd('AgentSearch HOLD_THIS_TURN')
assert(text():find('codex turn 1:', 1, true))
key('i')
submit('Continue the recovered conversation.', 'codex turn 2:')
vim.cmd.AgentIndexRebuild()
""")
    requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
    assert requests[-1]['session'] == session and requests[-1]['resume']

    # A killed supervisor must not release its agent child's inherited lock.
    (root / 'release-agent').unlink()
    (root / 'agent-started').unlink()
    orphan_chat = dict(key='c' * 64, cwd=str(project), agent='codex', created=time.time(),
                       label='supervisor.lua:1', messages=[
                           dict(role='You', text='SUPERVISOR_RESTART HOLD_THIS_TURN'), dict(role='Codex')])
    request = dict(op='run', chat=orphan_chat, revision=0, mode='ask', prompt='HOLD_THIS_TURN')
    command = ['python3', str(REPO / 'scripts' / 'ask_store.py'), '--root', str(root / 'state' / 'nvim' / 'ask')]
    worker = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, env=env)
    try:
        worker.stdin.write(json.dumps(request))
        worker.stdin.close()
        worker.stdin = None
        assert json.loads(worker.stdout.readline())['type'] == 'accepted'
        event = json.loads(worker.stdout.readline())
        assert event['type'] == 'session'
        orphan_session = event['id']
        worker.kill()
        worker.communicate(timeout=5)
        current = backend(dict(op='get', cwd=str(project), key=orphan_chat['key']))
        assert current['active'], 'The live agent child must still own the turn lock'
        rejected = subprocess.run(command, input=json.dumps(request), text=True,
                                  capture_output=True, env=env, timeout=5)
        assert rejected.returncode == 1
        assert 'working in another process' in json.loads(rejected.stdout)['error']
    finally:
        if worker.poll() is None:
            worker.kill()
            worker.communicate(timeout=5)
        (root / 'release-agent').touch()
    wait_for(lambda: not backend(dict(op='get', cwd=str(project), key=orphan_chat['key']))['active'])
    run(env, r"""
vim.ui.select = function(items, options, callback) callback(items[1]) end
vim.cmd('AgentSearch SUPERVISOR_RESTART')
assert(text():find('Interrupted', 1, true))
key('i')
submit('Continue after supervisor recovery.', 'codex turn 2:')
""")
    requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
    assert requests[-1]['resume'] and requests[-1]['session'] == orphan_session, (orphan_session, requests[-2:])

    # Upstream Arch docks and per-tab panels must coexist with history search.
    run(env, r"""
require('ryuux05.arch')
vim.o.wrap = false
vim.cmd('Arch notes/design.md')
local tab, notes = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
assert(vim.fn.expand('%:t') == 'design.md')
assert(not vim.wo[notes][0].wrap, 'Docking must preserve the file window options')
local dock
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
  if win ~= notes then dock = win end
end
assert(dock and vim.api.nvim_win_get_config(dock).relative == '', 'Arch must keep a docked split')
assert(vim.wo[dock][0].winbar:find('/ history', 1, true))
vim.api.nvim_set_current_win(dock)
vim.ui.select = function(items, options, callback)
  assert(#items > 0)
  callback(items[1])
end
key('r')
assert(vim.api.nvim_get_current_win() == dock, 'History selection must reuse the dock')
key('m')
assert(vim.api.nvim_win_get_config(dock).relative == '', 'm must not turn a dock into a float')
vim.ui.input = function(options, callback) callback('SUPERVISOR_RESTART') end
key('/')
assert(vim.api.nvim_get_current_win() == dock)
vim.cmd.tabnew()
panel()
local floating = vim.api.nvim_get_current_win()
assert(floating ~= dock and vim.api.nvim_win_get_config(floating).relative == 'editor')
vim.api.nvim_set_current_tabpage(tab)
panel()
assert(vim.api.nvim_get_current_win() == dock, 'Each tab must retain its own panel window')
assert(vim.api.nvim_win_is_valid(floating))
""")
    print('PASS: sessions, crash recovery, search, Arch docking and per-tab panels')
