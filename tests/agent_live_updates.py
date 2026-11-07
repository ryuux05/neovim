"""Real idle-terminal checks; local fake CLIs, no keypresses or focus changes."""
import codecs
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time, uuid
root = pathlib.Path(os.environ['ASK_LIVE_ROOT'])
args = sys.argv[1:]
sys.stdin.read()
agent = pathlib.Path(sys.argv[0]).name
session = str(uuid.uuid4())
def emit(event): print(json.dumps(event), flush=True)
if agent == 'codex':
    emit(dict(type='thread.started', thread_id=session))
    emit(dict(type='item.started', item=dict(id='tool', type='command_execution', command='PROGRESS_MARKER', status='in_progress')))
else:
    session = args[args.index('--session-id') + 1]
    emit(dict(type='system', subtype='init', session_id=session))
    emit(dict(type='stream_event', event=dict(type='content_block_start', index=0, content_block=dict(type='tool_use', name='PROGRESS_MARKER'))))
(root / 'target.lua').write_text('LIVE_FILE_MARKER\n')
(root / 'progress-ready').touch()
while not (root / 'draft').exists(): time.sleep(0.02)
if agent == 'codex':
    emit(dict(type='item.updated', item=dict(id='reply', type='agent_message', text='DRAFT_MARKER')))
else:
    emit(dict(type='stream_event', event=dict(type='content_block_delta', index=1, delta=dict(type='text_delta', text='DRAFT_MARKER'))))
(root / 'streaming').touch()
while not (root / 'finish').exists(): time.sleep(0.02)
if agent == 'codex':
    emit(dict(type='item.completed', item=dict(id='reply', type='agent_message', text='FINAL_MARKER')))
    pathlib.Path(args[args.index('-o') + 1]).write_text('FINAL_MARKER')
    emit(dict(type='turn.completed'))
else:
    emit(dict(type='result', result='FINAL_MARKER', is_error=False))
(root / 'finished').touch()
'''
LUA = r'''
vim.opt.runtimepath:prepend(vim.env.ASK_LIVE_REPO)
vim.o.swapfile, vim.o.autoread = false, true
require('ryuux05.agent')
local ask
if vim.env.ASK_LIVE_CASE == 'progress' then ask = require('ryuux05.ask') end
vim.cmd.edit('target.lua')
if vim.env.ASK_LIVE_CASE == 'modified' then
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'UNSAVED_MARKER' })
end
if vim.env.ASK_LIVE_CASE == 'noautoread' then vim.bo.autoread = false end
if vim.env.ASK_LIVE_CASE == 'progress' then
  ask.dock()
  vim.defer_fn(function()
    vim.fn.maparg('<CR>', 'n', false, true).callback()
    vim.cmd.stopinsert()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'Live terminal test' })
    vim.fn.maparg('<CR>', 'n', false, true).callback()
    vim.cmd.stopinsert()
  end, 100)
end
vim.fn.writefile({ 'ready' }, vim.env.ASK_LIVE_ROOT .. '/ready')
vim.defer_fn(function()
  local buf = vim.fn.bufnr('target.lua')
  vim.fn.writefile({ vim.json.encode({ lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    modified = vim.bo[buf].modified, autoread = vim.bo[buf].autoread, mode = vim.fn.mode(),
    cmdwin = vim.fn.getcmdwintype(), name = vim.api.nvim_buf_get_name(buf), disk = vim.fn.readfile('target.lua') }) },
    vim.env.ASK_LIVE_ROOT .. '/diagnostic.json')
end, 1500)
'''


class Screen:
    """Read the cursor/erase operations used by Neovim's basic xterm UI."""
    def __init__(self):
        self.rows = [list(' ' * 140) for _ in range(40)]
        self.row = self.col = 0
        self.saved = (0, 0)
        self.pending = ''
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.last = ' '

    def put(self, char):
        self.rows[self.row][min(self.col, 139)] = char
        self.last = char
        self.col = min(self.col + 1, 139)

    def feed(self, chunk):
        self.pending += self.decoder.decode(chunk)
        while self.pending:
            if self.pending.startswith('\x1b['):
                match = re.match(r'\x1b\[([0-?]*)([ -/]*)([@-~])', self.pending)
                if not match: return
                args, _, command = match.groups()
                self.pending = self.pending[match.end():]
                if args.startswith('?') or args.startswith('>') or command == 'm': continue
                values = [int(value or '0') for value in args.split(';')]
                count = values[0] or 1
                if command in ('H', 'f'):
                    self.row, self.col = (values[0] or 1) - 1, (values[1] or 1) - 1 if len(values) > 1 else 0
                elif command == 'A': self.row -= count
                elif command == 'B': self.row += count
                elif command == 'C': self.col += count
                elif command == 'D': self.col -= count
                elif command == 'G': self.col = count - 1
                elif command == 'd': self.row = count - 1
                elif command == 'J':
                    if values[0] == 2: self.rows = [list(' ' * 140) for _ in range(40)]
                    elif values[0] == 0:
                        self.rows[self.row][self.col:] = list(' ' * (140 - self.col))
                        for row in range(self.row + 1, 40): self.rows[row] = list(' ' * 140)
                elif command == 'K':
                    start = 0 if values[0] in (1, 2) else self.col
                    end = self.col + 1 if values[0] == 1 else 140
                    self.rows[self.row][start:end] = list(' ' * (end - start))
                elif command == 'X':
                    end = min(self.col + count, 140)
                    self.rows[self.row][self.col:end] = list(' ' * (end - self.col))
                elif command == 'b':
                    for _ in range(count): self.put(self.last)
                elif command == 's': self.saved = (self.row, self.col)
                elif command == 'u': self.row, self.col = self.saved
                self.row, self.col = max(0, min(self.row, 39)), max(0, min(self.col, 139))
            elif self.pending.startswith(('\x1b]', '\x1bP')):
                match = re.search(r'\x07|\x1b\\', self.pending)
                if not match: return
                self.pending = self.pending[match.end():]
            elif self.pending.startswith('\x1b'):
                if len(self.pending) < 2: return
                length = 3 if self.pending[1] in '()' else 2
                if len(self.pending) < length: return
                self.pending = self.pending[length:]
            else:
                char, self.pending = self.pending[0], self.pending[1:]
                if char == '\r': self.col = 0
                elif char == '\n': self.row = min(self.row + 1, 39)
                elif char == '\b': self.col = max(self.col - 1, 0)
                elif char == '\t': self.col = min((self.col // 8 + 1) * 8, 139)
                elif char >= ' ': self.put(char)

    def __contains__(self, text):
        return text in '\n'.join(''.join(row) for row in self.rows)


class LiveTests(unittest.TestCase):
    def launch(self, case, agent='codex'):
        temp = tempfile.TemporaryDirectory(prefix='nvim-live-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        bindir = root / 'bin'
        bindir.mkdir()
        for name in ('codex', 'claude'):
            path = bindir / name
            path.write_text(FAKE)
            path.chmod(0o755)
        if case != 'created':
            (root / 'target.lua').write_text('BASELINE_MARKER\n')
        settings = root / 'state' / 'nvim' / 'ask' / 'settings.json'
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps(dict(default_agent=agent)))
        init = root / 'init.lua'
        init.write_text(LUA)
        env = dict(os.environ, TERM='xterm-256color', NVIM_APPNAME='nvim', ASK_LIVE_ROOT=str(root),
                   ASK_LIVE_REPO=str(REPO), ASK_LIVE_CASE=case, ASK_LIVE_AGENT=agent,
                   XDG_STATE_HOME=str(root / 'state'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), PATH=str(bindir) + os.pathsep + os.environ['PATH'])
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
        process = subprocess.Popen(['nvim', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'luafile ' + str(init)],
                                   cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
                                   start_new_session=True)
        os.close(slave)
        screen = Screen()
        terminal_queries = bytearray()
        replies = {
            b'\x1b]11;?\x07': b'\x1b]11;rgb:0000/0000/0000\x07',
            b'\x1b]11;?\x1b\\': b'\x1b]11;rgb:0000/0000/0000\x1b\\',
            b'\x1b]10;?\x07': b'\x1b]10;rgb:ffff/ffff/ffff\x07',
            b'\x1b]10;?\x1b\\': b'\x1b]10;rgb:ffff/ffff/ffff\x1b\\',
            b'\x1b[6n': b'\x1b[1;1R',
            b'\x1b[5n': b'\x1b[0n',
        }

        def pump(predicate, timeout=4):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.02)[0]:
                    try:
                        chunk = os.read(master, 65536)
                        screen.feed(chunk)
                        terminal_queries.extend(chunk)
                        # Terminal capability replies are protocol, not user input.
                        for query, reply in replies.items():
                            if query in terminal_queries:
                                os.write(master, reply)
                                terminal_queries[:] = terminal_queries.replace(query, b'')
                        terminal_queries[:] = terminal_queries[-128:]
                    except OSError:
                        break
                if predicate():
                    return
            self.fail('Idle terminal did not update:\n' + '\n'.join(''.join(row) for row in screen.rows) + '\nState: ' + ((root / 'diagnostic.json').read_text() if (root / 'diagnostic.json').exists() else 'unavailable'))

        def cleanup():
            (root / 'draft').touch()
            (root / 'finish').touch()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            if (root / 'progress-ready').exists():
                deadline = time.monotonic() + 3
                while not (root / 'finished').exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                # The supervisor commits after the CLI emits its final line.
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    busy = False
                    for lock in (root / 'state').rglob('*.lock'):
                        with lock.open('rb') as file:
                            try:
                                fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            except BlockingIOError:
                                busy = True
                    if not busy: break
                    time.sleep(0.02)
            os.close(master)
        self.addCleanup(cleanup)
        pump(lambda: (root / 'ready').exists())
        return root, screen, pump

    def test_codex_progress_and_answer_appear_without_input(self):
        self.progress('codex')

    def test_claude_progress_and_answer_appear_without_input(self):
        self.progress('claude')

    def progress(self, agent):
        root, screen, pump = self.launch('progress', agent)
        pump(lambda: (root / 'progress-ready').exists())
        pump(lambda: 'PROGRESS_MARKER' in screen)
        pump(lambda: 'LIVE_FILE_MARKER' in screen)
        (root / 'draft').touch()
        pump(lambda: 'DRAFT_MARKER' in screen)
        self.assertFalse((root / 'finished').exists(), 'Draft must appear before the agent finishes')
        (root / 'finish').touch()
        pump(lambda: 'FINAL_MARKER' in screen)

    def test_file_created_by_agent_reloads_without_load_prompt(self):
        root, screen, pump = self.launch('created')
        (root / 'target.lua').write_text('DISK_MARKER\n')
        pump(lambda: 'DISK_MARKER' in screen)
        self.assertNotIn('(L)oad', screen)

    def test_existing_clean_file_reloads_without_input(self):
        root, screen, pump = self.launch('existing')
        (root / 'target.lua').write_text('DISK_MARKER\n')
        pump(lambda: 'DISK_MARKER' in screen)

    def test_unsaved_edits_are_preserved(self):
        root, screen, pump = self.launch('modified')
        pump(lambda: 'UNSAVED_MARKER' in screen)
        (root / 'target.lua').write_text('DISK_MARKER\n')
        # Let the autoreload check run while the editor receives no input.
        deadline = time.monotonic() + 1.5
        pump(lambda: time.monotonic() >= deadline, timeout=2)
        self.assertEqual((root / 'target.lua').read_text(), 'DISK_MARKER\n')
        self.assertNotIn('DISK_MARKER', screen)

    def test_local_noautoread_is_respected(self):
        root, screen, pump = self.launch('noautoread')
        pump(lambda: 'BASELINE_MARKER' in screen)
        (root / 'target.lua').write_text('DISK_MARKER\n')
        deadline = time.monotonic() + 1
        pump(lambda: time.monotonic() >= deadline, timeout=2)
        self.assertIn('BASELINE_MARKER', screen)
        self.assertNotIn('DISK_MARKER', screen)


if __name__ == '__main__':
    unittest.main()
