"""Run with python3 tests/ask_sessions.py; uses isolated state and fake agent CLIs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, uuid
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
    print(answer)
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
  assert(vim.wait(5000, function() return text():find(expected, 1, true) ~= nil end), text())
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
    root = Path(directory)
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
    print('PASS: provider defaults, session continuity, restart recovery, failure recovery, deletion, project isolation, read-only reviews')
