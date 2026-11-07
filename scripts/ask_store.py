"""Durable AI panel journals, a rebuildable search index, and turn supervision."""
import argparse
from contextlib import contextmanager
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid


class StoreError(Exception):
    pass


class WorkerInterrupted(BaseException):
    pass


def ensure_directory(path):
    if path.is_dir():
        return
    ensure_directory(path.parent)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextmanager
def locked(path, exclusive=True, blocking=True):
    ensure_directory(path.parent)
    with path.open('a+b') as file:
        mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        try:
            fcntl.flock(file, mode | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError as exc:
            raise StoreError('Conversation is working in another process') from exc
        try:
            yield file
        finally:
            # Closing, rather than explicit LOCK_UN, preserves an inherited turn
            # lock if a supervisor dies while its agent child is still alive.
            pass


def replay(file):
    file.seek(0)
    data, revision, deleted, committed = {}, 0, False, 0
    for line in file:
        if not line.endswith(b'\n'):
            break
        try:
            event = json.loads(line)
            if event['v'] != 1 or event['seq'] != revision + 1 or deleted:
                raise ValueError('invalid event order')
            if event['op'] == 'delete':
                deleted = True
                data = {}
            elif event['op'] == 'patch':
                data.update(event.get('set', {}))
                for field in event.get('unset', []):
                    data.pop(field, None)
                if 'messages' in event:
                    suffix = event['messages']
                    messages = data.get('messages', [])
                    start = suffix['from']
                    if not isinstance(start, int) or not 0 <= start <= len(messages):
                        raise ValueError('invalid message suffix')
                    data['messages'] = messages[:start] + suffix['items']
            else:
                raise ValueError('unknown operation')
            revision = event['seq']
            committed += len(line)
        except (ValueError, TypeError, KeyError) as exc:
            raise StoreError('Corrupt committed journal record') from exc
    return data, revision, deleted, committed


def durable(file):
    file.flush()
    os.fsync(file.fileno())
    fd = os.open(Path(file.name).parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def append(file, event, committed):
    # An incomplete final record was never committed. Repair only that tail.
    file.truncate(committed)
    file.seek(0, os.SEEK_END)
    encoded = (json.dumps(event, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    file.write(encoded)
    durable(file)


def patch(old, new, revision):
    event = {'v': 1, 'seq': revision + 1, 'op': 'patch', 'at': time.time()}
    changed = {key: value for key, value in new.items() if key != 'messages' and old.get(key) != value}
    removed = [key for key in old if key not in new and key != 'messages']
    if changed:
        event['set'] = changed
    if removed:
        event['unset'] = removed
    before, after = old.get('messages', []), new.get('messages', [])
    prefix = 0
    while prefix < min(len(before), len(after)) and before[prefix] == after[prefix]:
        prefix += 1
    if prefix != len(before) or prefix != len(after) or ('messages' in new and 'messages' not in old):
        event['messages'] = {'from': prefix, 'items': after[prefix:]}
    return event


def validate_chat(chat):
    if not isinstance(chat, dict):
        raise StoreError('Invalid conversation')
    for field in ('key', 'cwd', 'label', 'agent'):
        if not isinstance(chat.get(field), str):
            raise StoreError('Invalid conversation ' + field)
    if not re.fullmatch(r'[a-f0-9]{64}', chat['key']) or chat['agent'] not in ('codex', 'claude'):
        raise StoreError('Invalid conversation identity')
    if not isinstance(chat.get('created'), (int, float)) or not isinstance(chat.get('messages'), list):
        raise StoreError('Invalid conversation history')
    if chat.get('started') and not isinstance(chat.get('id'), str):
        raise StoreError('Missing agent session ID')
    for message in chat['messages']:
        if not isinstance(message, dict) or not isinstance(message.get('role'), str):
            raise StoreError('Invalid message')
        if message.get('text') is not None and not isinstance(message['text'], str):
            raise StoreError('Invalid message text')
    source = chat.get('source')
    if source is not None and (not isinstance(source, dict) or not isinstance(source.get('path'), str)
        or not isinstance(source.get('l1'), int) or not isinstance(source.get('l2'), int)
        or not 1 <= source['l1'] <= source['l2']):
        raise StoreError('Invalid source range')


class Store:
    def __init__(self, root):
        self.root = Path(root)

    def journal(self, cwd, key):
        if not isinstance(cwd, str) or not isinstance(key, str) or not re.fullmatch(r'[a-f0-9]{64}', key):
            raise StoreError('Invalid conversation reference')
        project = hashlib.sha256(cwd.encode()).hexdigest()
        return self.root / 'journal' / project / (key + '.jsonl')

    def turn_lock(self, cwd, key):
        return self.journal(cwd, key).with_suffix('.lock')

    def busy(self, cwd, key):
        try:
            with locked(self.turn_lock(cwd, key), blocking=False):
                return False
        except StoreError:
            return True

    def view(self, data, revision):
        value = copy.deepcopy(data)
        value['revision'] = revision
        value['active'] = self.busy(data['cwd'], data['key'])
        return value

    def _save(self, chat, expected_revision):
        validate_chat(chat)
        path = self.journal(chat['cwd'], chat['key'])
        with locked(path) as file:
            previous, revision, deleted, size = replay(file)
            if deleted:
                raise StoreError('Conversation was deleted; start a new conversation')
            if revision:
                if any(previous.get(field) != chat.get(field) for field in ('key', 'cwd', 'agent')):
                    raise StoreError('Conversation identity cannot change')
                # Creation time belongs to storage. Lua's JSON encoder rounds
                # floats, so a restored timestamp must not redefine identity.
                chat = dict(chat, created=previous['created'])
            if previous == chat:
                durable(file)
                return revision
            if revision != expected_revision:
                raise StoreError('Conversation changed elsewhere; reload it with :AgentSearch')
            append(file, patch(previous, chat, revision), size)
            return revision + 1

    def save(self, chat, revision=0):
        with locked(self.turn_lock(chat['cwd'], chat['key']), blocking=False):
            revision = self._save(chat, revision)
        return {'revision': revision, 'warning': self.index_warning()}

    def delete(self, cwd, key, revision):
        path = self.journal(cwd, key)
        with locked(self.turn_lock(cwd, key), blocking=False):
            with locked(path) as file:
                _, current, deleted, size = replay(file)
                if not deleted:
                    if current != revision:
                        raise StoreError('Conversation changed elsewhere; reload it before deleting')
                    append(file, {'v': 1, 'seq': current + 1, 'op': 'delete', 'at': time.time()}, size)
                else:
                    durable(file)
        return {'warning': self.index_warning()}

    def _migrate(self, cwd=None, key=None):
        base = self.root / 'sessions'
        pattern = (hashlib.sha256(cwd.encode()).hexdigest() + '/' + (key or '*') + '.json') if cwd else '*/*.json'
        for path in base.glob(pattern):
            try:
                chat = json.loads(path.read_text())
                validate_chat(chat)
                if cwd is not None and chat['cwd'] != cwd:
                    raise StoreError('Legacy conversation has the wrong working directory')
                if path.stem != chat['key']:
                    raise StoreError('Legacy conversation has the wrong key')
                target = self.journal(chat['cwd'], chat['key'])
                with locked(self.turn_lock(chat['cwd'], chat['key']), blocking=False):
                    with locked(target) as file:
                        _, revision, _, size = replay(file)
                        if not revision:
                            append(file, patch({}, chat, 0), size)
            except (ValueError, OSError, StoreError):
                # Invalid legacy input remains untouched for manual recovery.
                continue

    def get(self, cwd, key):
        path = self.journal(cwd, key)
        self._migrate(cwd, key)
        if not path.exists():
            return None
        with locked(path, exclusive=False) as file:
            data, revision, deleted, _ = replay(file)
        if deleted or not revision:
            return None
        validate_chat(data)
        return self.view(data, revision)

    def load(self, cwd):
        self._migrate(cwd)
        project = hashlib.sha256(cwd.encode()).hexdigest()
        chats = []
        for path in (self.root / 'journal' / project).glob('*.jsonl'):
            value = self.get(cwd, path.stem)
            if value:
                chats.append(value)
        chats.sort(key=lambda chat: chat['created'])
        return chats

    def preference(self, agent=None):
        path = self.root / 'settings.jsonl'
        with locked(path) as file:
            data, revision, _, size = replay(file)
            if not revision:
                legacy = self.root / 'settings.json'
                if legacy.exists():
                    value = json.loads(legacy.read_text()).get('default_agent')
                    if value in ('codex', 'claude'):
                        data = {'default_agent': value}
                        append(file, patch({}, data, 0), size)
                        revision, size = 1, file.tell()
            if agent is not None:
                if agent not in ('codex', 'claude'):
                    raise StoreError('Choose codex or claude')
                desired = {'default_agent': agent}
                if desired != data:
                    append(file, patch(data, desired, revision), size)
                    data = desired
                else:
                    durable(file)
        return data.get('default_agent', 'codex')

    @contextmanager
    def index(self, rebuild=False):
        with locked(self.root / 'index.lock'):
            database = self.root / 'index.sqlite3'
            if rebuild:
                database.unlink(missing_ok=True)
            connection = sqlite3.connect(database, timeout=5)
            try:
                try:
                    self._schema(connection)
                except sqlite3.DatabaseError:
                    connection.close()
                    database.rename(database.with_name('index.corrupt-' + uuid.uuid4().hex + '.sqlite3'))
                    connection = sqlite3.connect(database, timeout=5)
                    self._schema(connection)
                self._sync(connection)
                yield connection
            finally:
                connection.close()

    @staticmethod
    def _schema(connection):
        connection.executescript('''
          CREATE TABLE IF NOT EXISTS conversations (
            path TEXT PRIMARY KEY, cwd TEXT, key TEXT, agent TEXT, label TEXT,
            created REAL, updated REAL, revision INTEGER, deleted INTEGER,
            data TEXT, size INTEGER, mtime INTEGER
          );
          CREATE VIRTUAL TABLE IF NOT EXISTS conversation_fts USING fts5(
            path UNINDEXED, label, body
          );
        ''')

    def _sync(self, connection):
        self._migrate()
        for path in (self.root / 'journal').glob('*/*.jsonl'):
            stat = path.stat()
            previous = connection.execute('SELECT revision, size, mtime FROM conversations WHERE path=?', (str(path),)).fetchone()
            if previous and previous[1:] == (stat.st_size, stat.st_mtime_ns):
                continue
            with locked(path, exclusive=False) as file:
                data, revision, deleted, _ = replay(file)
                stat = os.fstat(file.fileno())
            if not revision:
                continue
            # The index lock serializes projections. Journal revisions still guard
            # against indexing an older observed state during concurrent appends.
            if previous and previous[0] > revision:
                continue
            if not deleted:
                validate_chat(data)
            updated = stat.st_mtime
            with connection:
                connection.execute('''INSERT INTO conversations VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                  ON CONFLICT(path) DO UPDATE SET cwd=excluded.cwd, key=excluded.key,
                  agent=excluded.agent, label=excluded.label, created=excluded.created,
                  updated=excluded.updated, revision=excluded.revision, deleted=excluded.deleted,
                  data=excluded.data, size=excluded.size, mtime=excluded.mtime''',
                  (str(path), data.get('cwd'), path.stem, data.get('agent'), data.get('label'),
                   data.get('created'), updated, revision, int(deleted), json.dumps(data), stat.st_size, stat.st_mtime_ns))
                connection.execute('DELETE FROM conversation_fts WHERE path=?', (str(path),))
                if not deleted:
                    body = '\n'.join(message.get('text') or '' for message in data['messages'])
                    connection.execute('INSERT INTO conversation_fts VALUES (?,?,?)', (str(path), data['label'], body))

    def index_warning(self):
        try:
            with self.index():
                pass
        except (OSError, sqlite3.Error, StoreError) as exc:
            return 'Conversation saved; search index needs rebuilding: ' + str(exc)
        return None

    def rebuild(self):
        with self.index(rebuild=True) as connection:
            return connection.execute('SELECT count(*) FROM conversations WHERE deleted=0').fetchone()[0]

    def search(self, query):
        words = re.findall(r'\w+', query, flags=re.UNICODE)
        with self.index() as connection:
            connection.row_factory = sqlite3.Row
            if words:
                expression = ' AND '.join('"' + word.replace('"', '""') + '"' for word in words)
                rows = connection.execute('''SELECT c.cwd,c.key,c.agent,c.label,c.updated,
                    snippet(conversation_fts,2,'[',']',' … ',20) AS snippet
                  FROM conversation_fts JOIN conversations c ON c.path=conversation_fts.path
                  WHERE conversation_fts MATCH ? AND c.deleted=0
                  ORDER BY bm25(conversation_fts), c.updated DESC LIMIT 100''', (expression,))
            else:
                rows = connection.execute('''SELECT cwd,key,agent,label,updated,'' AS snippet
                    FROM conversations WHERE deleted=0 ORDER BY updated DESC LIMIT 100''')
            return [dict(row) for row in rows]

    def run_turn(self, chat, revision, mode, prompt, emit):
        validate_chat(chat)
        # Stable turn inode is independent from the journal read lock, so search
        # and recovery reads remain available while the CLI is running.
        with locked(self.turn_lock(chat['cwd'], chat['key']), blocking=False) as turn:
            chat = copy.deepcopy(chat)
            chat['interrupted'] = True
            if chat['agent'] == 'claude' and not chat.get('id'):
                chat['id'] = str(uuid.uuid4())
            revision = self._save(chat, revision)
            warning = self.index_warning()
            emit({'type': 'accepted', 'revision': revision, 'id': chat.get('id'), 'started': chat.get('started', False)})
            error, answer, process = None, None, None
            try:
                ensure_directory(self.root / 'work')
                with tempfile.TemporaryDirectory(prefix='turn-', dir=self.root / 'work') as work:
                    output = Path(work) / 'answer.txt'
                    command = agent_command(chat, mode, output)
                    with tempfile.TemporaryFile() as stdin, tempfile.TemporaryFile() as stderr:
                        stdin.write(prompt.encode())
                        stdin.seek(0)
                        process = subprocess.Popen(command, cwd=chat['cwd'], stdin=stdin,
                            stdout=subprocess.PIPE, stderr=stderr, text=True, encoding='utf-8', errors='replace', start_new_session=True,
                            pass_fds=(turn.fileno(),))
                        for line in process.stdout:
                            try:
                                event = json.loads(line)
                            except ValueError:
                                continue
                            if not isinstance(event, dict):
                                continue
                            session = None
                            if chat['agent'] == 'codex' and event.get('type') == 'thread.started':
                                session = event.get('thread_id')
                            elif chat['agent'] == 'claude' and event.get('type') == 'system' and event.get('subtype') == 'init':
                                session = event.get('session_id')
                            if isinstance(session, str) and session:
                                chat['id'], chat['started'] = session, True
                                revision = self._save(chat, revision)
                                emit({'type': 'session', 'id': session, 'started': True, 'revision': revision})
                            if event.get('type') in ('error', 'turn.failed'):
                                detail = event.get('error') or {}
                                error = event.get('message') or (detail.get('message') if isinstance(detail, dict) else str(detail))
                            if chat['agent'] == 'claude' and event.get('type') == 'result':
                                if event.get('is_error'):
                                    error = event.get('result') or 'Claude request failed'
                                else:
                                    answer = event.get('result')
                        code = process.wait()
                        stderr.seek(0)
                        diagnostic = stderr.read().decode(errors='replace')[-4000:].strip()
                        if code != 0:
                            error = error or diagnostic or 'Agent exited with status ' + str(code)
                        if chat['agent'] == 'codex' and output.exists():
                            answer = output.read_text()
                        if error or answer is None:
                            error = error or diagnostic or 'Agent exited without a response'
                        if not chat.get('started'):
                            error = error or 'Agent did not confirm a session ID'
            except BaseException as exc:
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                error = str(exc) or type(exc).__name__
            chat['interrupted'], chat['failed'] = False, bool(error)
            chat['messages'][-1]['text'] = '**Error:** ' + error if error else answer.strip()
            if not error:
                chat.pop('context', None)
            revision = self._save(chat, revision)
            warning = self.index_warning() or warning
            emit({'type': 'complete', 'answer': None if error else answer.strip(), 'error': error,
                  'revision': revision, 'id': chat.get('id'), 'started': chat.get('started', False), 'warning': warning})


def agent_command(chat, mode, output):
    edit = mode == 'edit' and not chat.get('review')
    sandbox = 'workspace-write' if edit else 'read-only'
    if chat['agent'] == 'codex':
        if chat.get('started'):
            return ['codex', 'exec', 'resume', '--skip-git-repo-check', '--json', '-c',
                    'sandbox_mode="' + sandbox + '"', '-o', str(output), chat['id'], '-']
        return ['codex', 'exec', '--sandbox', sandbox, '--skip-git-repo-check', '--json', '-o', str(output), '-']
    tools = '' if chat.get('review') else 'Read,Grep,Glob,Edit,Write' if edit else 'Read,Grep,Glob'
    command = ['claude', '-p', '--tools', tools, '--output-format', 'stream-json', '--verbose',
               '--resume' if chat.get('started') else '--session-id', chat['id']]
    if edit:
        command += ['--permission-mode', 'acceptEdits']
    return command


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    args = parser.parse_args()
    store = Store(args.root)
    output_open = True

    def emit(value):
        nonlocal output_open
        if output_open:
            try:
                print(json.dumps(value), flush=True)
            except BrokenPipeError:
                output_open = False
                # Keep journal commits working after the UI's output pipe closes.
                os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())

    try:
        request = json.load(sys.stdin)
        operation = request['op']
        if operation == 'run':
            def interrupted(signum, frame):
                raise WorkerInterrupted('Agent worker interrupted')
            signal.signal(signal.SIGTERM, interrupted)
            signal.signal(signal.SIGHUP, interrupted)
            store.run_turn(request['chat'], request.get('revision', 0), request['mode'], request['prompt'], emit)
            return
        if operation == 'default':
            result = store.preference(request.get('agent'))
        elif operation == 'save':
            result = store.save(request['chat'], request.get('revision', 0))
        elif operation == 'delete':
            result = store.delete(request['cwd'], request['key'], request['revision'])
        elif operation == 'load':
            result = store.load(request['cwd'])
        elif operation == 'get':
            result = store.get(request['cwd'], request['key'])
        elif operation == 'search':
            result = store.search(request.get('query', ''))
        elif operation == 'rebuild':
            result = store.rebuild()
        else:
            raise StoreError('Unknown storage operation')
        emit({'ok': True, 'result': result})
    except (OSError, ValueError, KeyError, StoreError, sqlite3.Error) as exc:
        emit({'ok': False, 'error': str(exc)})
        sys.exit(1)


if __name__ == '__main__':
    main()
