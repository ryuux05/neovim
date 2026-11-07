"""Storage contract tests: python3 tests/test_ask_store.py."""
import copy
import hashlib
import importlib.util
import json
import multiprocessing
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('ask_store', Path(__file__).resolve().parents[1] / 'scripts' / 'ask_store.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


def race_save(root, chat, barrier, results):
    barrier.wait()
    try:
        storage.Store(root).save(chat, 1)
        results.put('saved')
    except storage.StoreError:
        results.put('conflict')


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ask-journal-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = storage.Store(self.root)
        self.chat = {
            'key': 'a' * 64, 'cwd': str(self.root), 'agent': 'codex',
            'created': 1.0, 'label': 'parser.lua:1',
            'messages': [{'role': 'You', 'text': 'Fix parser regression 日本語'}],
        }

    def test_torn_tail_recovers_and_next_append_preserves_complete_records(self):
        self.store.save(self.chat)
        path = self.store.journal(self.chat['cwd'], self.chat['key'])
        original = path.read_bytes()
        with path.open('ab') as file:
            file.write(b'{"v":1,"seq":2,"op":"patch"')
        self.assertEqual(self.store.get(self.chat['cwd'], self.chat['key'])['messages'], self.chat['messages'])
        changed = dict(self.chat, id='provider-session', started=True)
        self.store.save(changed, 1)
        self.assertTrue(path.read_bytes().startswith(original))
        self.assertEqual(self.store.get(self.chat['cwd'], self.chat['key'])['id'], 'provider-session')
        self.assertEqual(self.store.rebuild(), 1)

    def test_complete_corrupt_record_is_not_silently_skipped(self):
        self.store.save(self.chat)
        path = self.store.journal(self.chat['cwd'], self.chat['key'])
        with path.open('ab') as file:
            file.write(b'not JSON\n')
        with self.assertRaises(storage.StoreError):
            self.store.get(self.chat['cwd'], self.chat['key'])

    def test_session_id_append_does_not_duplicate_transcript(self):
        self.chat['messages'] = [{'role': 'You', 'text': 'history ' * 10000}]
        self.store.save(self.chat)
        self.store.save(dict(self.chat, id='session', started=True), 1)
        lines = self.store.journal(self.chat['cwd'], self.chat['key']).read_bytes().splitlines()
        self.assertLess(len(lines[1]), 500)
        self.assertEqual(self.store.get(self.chat['cwd'], self.chat['key'])['messages'], self.chat['messages'])

    def test_timestamp_rounding_across_json_encoders_does_not_break_resume(self):
        self.chat['created'] = 1712345678.1234567
        self.store.save(self.chat)
        restored = dict(self.chat, created=float(format(self.chat['created'], '.14g')),
                        id='existing-session', started=True)
        self.store.save(restored, 1)
        current = self.store.get(self.chat['cwd'], self.chat['key'])
        self.assertEqual(current['created'], self.chat['created'])
        self.assertEqual(current['id'], 'existing-session')

    def test_retry_and_rebuild_are_idempotent(self):
        self.assertEqual(self.store.save(self.chat)['revision'], 1)
        self.assertEqual(self.store.save(self.chat, 0)['revision'], 1)
        self.assertEqual(self.store.rebuild(), 1)
        self.assertEqual(self.store.rebuild(), 1)
        self.assertEqual(len(self.store.search('parser regression')), 1)
        self.assertEqual(len(self.store.load(self.chat['cwd'])), 1)

    def test_retry_cannot_acknowledge_a_record_while_fsync_still_fails(self):
        self.store.save(self.chat)
        changed = dict(self.chat, id='session', started=True)
        with mock.patch.object(storage.os, 'fsync', side_effect=OSError('sync failed')):
            with self.assertRaises(OSError):
                self.store.save(changed, 1)
            # A complete but unacknowledged record may already be readable.
            # Identical retries must still establish durability before success.
            with self.assertRaises(OSError):
                self.store.save(changed, 1)
        self.assertEqual(self.store.save(changed, 1)['revision'], 2)

    def test_delete_retry_must_sync_an_unacknowledged_tombstone(self):
        self.store.save(self.chat)
        with mock.patch.object(storage.os, 'fsync', side_effect=OSError('sync failed')):
            for _ in range(2):
                with self.assertRaises(OSError):
                    self.store.delete(self.chat['cwd'], self.chat['key'], 1)
        self.store.delete(self.chat['cwd'], self.chat['key'], 1)
        self.assertIsNone(self.store.get(self.chat['cwd'], self.chat['key']))

    def test_preference_retry_must_sync_an_unacknowledged_change(self):
        self.store.preference('codex')
        with mock.patch.object(storage.os, 'fsync', side_effect=OSError('sync failed')):
            for _ in range(2):
                with self.assertRaises(OSError):
                    self.store.preference('claude')
        self.assertEqual(self.store.preference('claude'), 'claude')

    def test_delete_tombstone_defeats_stale_save_and_legacy_reimport(self):
        legacy = self.root / 'sessions' / hashlib.sha256(self.chat['cwd'].encode()).hexdigest()
        legacy.mkdir(parents=True)
        (legacy / (self.chat['key'] + '.json')).write_text(json.dumps(self.chat))
        self.assertEqual(len(self.store.load(self.chat['cwd'])), 1)
        self.store.delete(self.chat['cwd'], self.chat['key'], 1)
        with self.assertRaises(storage.StoreError):
            self.store.save(self.chat, 1)
        self.assertIsNone(self.store.get(self.chat['cwd'], self.chat['key']))
        self.assertEqual(self.store.rebuild(), 0)
        self.assertEqual(self.store.load(self.chat['cwd']), [])
        self.assertEqual(self.store.search('regression'), [])
        self.assertEqual(self.store.delete(self.chat['cwd'], self.chat['key'], 1)['warning'], None)

    def test_existing_snapshots_and_default_migrate_once_without_modifying_backups(self):
        legacy = self.root / 'sessions' / hashlib.sha256(self.chat['cwd'].encode()).hexdigest()
        legacy.mkdir(parents=True)
        path = legacy / (self.chat['key'] + '.json')
        self.chat.update(id='original-session', started=True, review=True)
        original = json.dumps(self.chat)
        path.write_text(original)
        (self.root / 'settings.json').write_text('{"default_agent":"claude"}')
        self.assertEqual(self.store.preference(), 'claude')
        for _ in range(2):
            chats = self.store.load(self.chat['cwd'])
            self.assertEqual(chats[0]['id'], 'original-session')
            self.assertTrue(chats[0]['review'])
            self.assertEqual(chats[0]['revision'], 1)
        self.assertEqual(path.read_text(), original)
        self.store.preference('codex')
        self.assertEqual(self.store.preference(), 'codex')
        self.assertEqual((self.root / 'settings.json').read_text(), '{"default_agent":"claude"}')

    def test_missing_corrupt_and_stale_index_rebuild_from_journals(self):
        self.store.save(self.chat)
        database = self.root / 'index.sqlite3'
        database.unlink()
        self.assertEqual(len(self.store.search('日本語')), 1)
        database.write_bytes(b'broken disposable index')
        self.assertEqual(len(self.store.search('parser')), 1)
        with mock.patch.object(self.store, 'index_warning', return_value='index unavailable'):
            changed = copy.deepcopy(self.chat)
            changed['messages'].append({'role': 'Codex', 'text': 'Durable comet response'})
            result = self.store.save(changed, 1)
        self.assertEqual(result['revision'], 2)
        self.assertIn('unavailable', result['warning'])
        self.assertEqual(len(self.store.search('comet')), 1)
        with sqlite3.connect(database) as connection:
            self.assertEqual(connection.execute('PRAGMA integrity_check').fetchone()[0], 'ok')

    def test_search_quotes_punctuation_unicode_and_cross_project(self):
        self.store.save(self.chat)
        other = dict(self.chat, key='b' * 64, cwd=str(self.root / 'other'))
        self.store.save(other)
        for query in ('parser regression', "parser' OR 1=1 --", '"parser"', '日本語'):
            results = self.store.search(query)
            # Ordinary keyword terms are quoted and bound, never executed as SQL.
            if query == "parser' OR 1=1 --":
                self.assertEqual(results, [])
            else:
                self.assertEqual(len(results), 2)
        self.assertEqual(len(self.store.load(self.chat['cwd'])), 1)

    def test_concurrent_writers_have_one_winner(self):
        self.store.save(self.chat)
        context = multiprocessing.get_context('spawn')
        barrier, results = context.Barrier(2), context.Queue()
        writers = []
        for answer in ('first writer', 'second writer'):
            changed = copy.deepcopy(self.chat)
            changed['messages'].append({'role': 'Codex', 'text': answer})
            process = context.Process(target=race_save, args=(str(self.root), changed, barrier, results))
            process.start()
            writers.append(process)
        for process in writers:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        self.assertCountEqual([results.get(timeout=1), results.get(timeout=1)], ['saved', 'conflict'])
        self.assertEqual(self.store.get(self.chat['cwd'], self.chat['key'])['revision'], 2)

    def test_live_turn_can_be_read_but_not_overwritten_or_deleted(self):
        self.store.save(self.chat)
        with storage.locked(self.store.turn_lock(self.chat['cwd'], self.chat['key'])):
            current = self.store.get(self.chat['cwd'], self.chat['key'])
            self.assertTrue(current['active'])
            self.assertEqual(len(self.store.search('parser')), 1)
            with self.assertRaises(storage.StoreError):
                self.store.save(self.chat, 1)
            with self.assertRaises(storage.StoreError):
                self.store.delete(self.chat['cwd'], self.chat['key'], 1)
            self.store.save(dict(self.chat, key='b' * 64))
        self.assertFalse(self.store.get(self.chat['cwd'], self.chat['key'])['active'])

    def test_no_agent_launch_when_pending_turn_cannot_be_fsynced(self):
        self.store.save(self.chat)
        pending = copy.deepcopy(self.chat)
        pending['messages'] += [{'role': 'You', 'text': 'next'}, {'role': 'Codex'}]
        with mock.patch.object(storage.os, 'fsync', side_effect=OSError('disk failure')):
            with mock.patch.object(storage.subprocess, 'Popen') as launch:
                with self.assertRaises(OSError):
                    self.store.run_turn(pending, 1, 'ask', 'test', lambda event: None)
                launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
