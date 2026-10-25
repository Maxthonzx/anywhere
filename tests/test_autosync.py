"""Hermetic regression tests: temporary working trees and local bare remotes only."""
import os
import re
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
import plistlib
import shutil

ROOT = Path(__file__).resolve().parents[1]
BASH = (str(Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe')
        if os.name == 'nt' else '/bin/bash')


class AutosyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='anywhere-tests-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / '项目 with spaces'
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(('GIT_', 'ANYWHERE_')):
                self.env.pop(key)
        self.env.update(HOME=str(self.base / 'home'), GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull, ANYWHERE_LOG_DIR=str(self.base / 'logs'),
                        GIT_TERMINAL_PROMPT='0')
        Path(self.env['HOME']).mkdir()
        self.git('init', '-b', 'main', str(self.repo), cwd=self.base)
        self.git('config', 'user.name', 'Test User')
        self.git('config', 'user.email', 'test@example.invalid')
        self.write('notes.txt', 'base\n')
        self.git('add', '.')
        self.git('commit', '-m', 'initial')
        self.origin = self.remote('origin')
        self.git('push', '-u', 'origin', 'main')

    def git(self, *args, cwd=None, check=True):
        return subprocess.run(['git', *args], cwd=cwd or self.repo, env=self.env,
                              text=True, encoding="utf-8", capture_output=True, check=check).stdout.strip()

    def remote(self, name):
        path = self.base / (name + '.git')
        self.git('init', '--bare', str(path), cwd=self.base)
        self.git('remote', 'add', name, path.as_posix())
        return path

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')

    def run_sync(self, *args, ok=True):
        script = (ROOT / 'scripts/autosync.sh').as_posix()
        command = [BASH, script, *args, self.repo.as_posix()]
        if hasattr(self, 'sleep_override'):
            # Set PATH after Git Bash startup, which otherwise prepends its own
            # /usr/bin ahead of the PATH imported from a native Windows process.
            path = self.sleep_override.as_posix()
            if os.name == 'nt':
                path = '/' + path[0].lower() + path[2:]
            command = [BASH, '-c', 'export PATH="$1:$PATH"; shift; source "$0" "$@"',
                       script, path, *args, self.repo.as_posix()]
        result = subprocess.run(command, cwd=self.base, env=self.env, text=True,
                                encoding="utf-8", capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def head(self, repo=None):
        return self.git('rev-parse', 'HEAD' if repo is None else 'refs/heads/main', cwd=repo)

    def test_commit_push_and_repeat(self):
        self.write('notes.txt', 'updated\n')
        self.run_sync()
        self.assertEqual(self.head(), self.head(self.origin))
        message = self.git('log', '-1', '--format=%s')
        self.assertRegex(message, r'^auto: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$')
        before = self.head()
        self.run_sync()
        self.assertEqual(before, self.head())

    def test_hostname_in_commit_message_is_opt_in(self):
        short = subprocess.check_output(['hostname'], text=True, env=self.env).strip().split('.')[0]
        self.env['ANYWHERE_INCLUDE_HOSTNAME'] = '1'
        self.write('notes.txt', 'named\n')
        self.run_sync()
        message = self.git('log', '-1', '--format=%s')
        self.assertRegex(message, r'^auto\(' + re.escape(short) + r'\): \d{4}-\d{2}-\d{2} ')

    def test_default_excludes_extra_remote(self):
        extra = self.remote('extra')
        self.write('new.txt', 'safe\n')
        self.run_sync()
        self.assertEqual(self.git('show-ref', cwd=extra, check=False), '')

    def test_explicit_remotes_and_empty_remote(self):
        extra = self.remote('extra')
        self.git('config', 'anywhere.remotes', 'origin extra')
        self.run_sync()
        self.assertEqual(self.head(extra), self.head())

    def test_sensitive_paths_preserve_index_and_head(self):
        for name in ['.env', '.ENV', 'nested/.env.production', 'private.pem', 'id_ed25519',
                     'ID_RSA', 'id_dsa', '.envrc', 'prod.ENV', '.npmrc']:
            with self.subTest(name=name):
                self.write(name, 'fake test value\n')
                before = self.head()
                index = (self.repo / '.git/index').read_bytes()
                self.run_sync(ok=False)
                self.assertEqual(index, (self.repo / '.git/index').read_bytes())
                self.assertEqual(before, self.head())
                (self.repo / name).unlink()

    def test_ignored_env_and_example_allowed(self):
        self.write('.gitignore', '.env\n')
        self.write('.env', 'fake-only\n')
        self.write('.env.example', 'API_KEY=\n')
        self.run_sync()
        self.assertNotIn('.env\n', self.git('ls-tree', '-r', '--name-only', 'HEAD') + '\n')
        self.assertIn('.env.example', self.git('ls-tree', '-r', '--name-only', 'HEAD'))

    def test_content_token_blocked_and_redacted(self):
        token = 'gh' + 'p_' + 'a' * 36
        self.write('config.txt', token)
        result = self.run_sync(ok=False)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertNotIn(token, (self.base / 'logs/autosync.log').read_text())

    def test_private_key_content_blocked(self):
        self.write('config.txt', '-----BEGIN ' + 'PRIVATE KEY-----\nfake\n')
        self.run_sync(ok=False)

    def test_embedded_url_credentials_blocked(self):
        self.write('config.txt', 'https://' + 'user:fake-password@example.invalid/repo')
        self.run_sync(ok=False)

    def test_staged_secret_even_when_worktree_cleaned_is_not_committed(self):
        self.write('notes.txt', 'gh' + 'p_' + 'b' * 36)
        self.git('add', 'notes.txt')
        self.write('notes.txt', 'safe\n')
        # Candidate commits the working tree, replacing the staged version safely.
        self.run_sync()
        self.assertEqual(self.git('show', 'HEAD:notes.txt'), 'safe')

    def test_outgoing_deleted_secret_blocked(self):
        self.write('.env', 'fake\n')
        self.git('add', '.env'); self.git('commit', '-m', 'unsafe history')
        self.git('rm', '.env'); self.git('commit', '-m', 'remove')
        before = self.head(self.origin)
        self.run_sync(ok=False)
        self.assertEqual(before, self.head(self.origin))

    def test_large_file_preserves_staging(self):
        self.write('staged.txt', 'ready\n'); self.git('add', 'staged.txt')
        index = (self.repo / '.git/index').read_bytes()
        self.env['ANYWHERE_MAX_FILE_BYTES'] = '64'
        self.write('large.dat', 'x' * 65)
        self.run_sync(ok=False)
        self.assertEqual(index, (self.repo / '.git/index').read_bytes())

    def fake_sleep(self, body):
        bins = self.base / 'bin'; bins.mkdir()
        stub = bins / 'sleep'; stub.write_bytes(('#!/bin/sh\n' + body + '\n').encode('utf-8')); stub.chmod(0o755)
        self.sleep_override = bins
        self.env['ANYWHERE_DAEMON'] = '1'

    def test_daemon_detects_equal_size_untracked_edits(self):
        self.write('new.txt', 'first\n')
        self.fake_sleep('printf "other\\n" > new.txt')
        before = self.head()
        self.run_sync()
        self.assertEqual(self.head(), before)
        self.assertIn('postponed', (self.base / 'logs/autosync.log').read_text())

    def test_external_staging_during_inspection_is_kept(self):
        self.write('notes.txt', 'changed\n')
        self.fake_sleep('git add notes.txt')
        before = self.head()
        self.run_sync(ok=False)
        self.assertEqual(self.head(), before)
        self.assertEqual(self.git('show', ':notes.txt'), 'changed')
        self.assertFalse((self.repo / '.git/index.lock').exists())

    def test_commit_hook_failure_preserves_original_index(self):
        self.write('staged.txt', 'ready\n'); self.git('add', 'staged.txt')
        index = (self.repo / '.git/index').read_bytes()
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_bytes(b'#!/bin/sh\nexit 1\n'); hook.chmod(0o755)
        self.write('notes.txt', 'changed\n')
        self.run_sync(ok=False)
        self.assertEqual(index, (self.repo / '.git/index').read_bytes())
        self.assertFalse((self.repo / '.git/index.lock').exists())

    def test_ssh_scheme_without_password_passes_dry_run(self):
        self.git('remote', 'set-url', 'origin', 'ssh://git@example.invalid/repo.git')
        result = self.run_sync('--dry-run')
        self.assertIn('DRY RUN', result.stdout)

    def test_ssh_scheme_with_password_is_rejected(self):
        self.git('remote', 'set-url', 'origin', 'ssh://git:secret@example.invalid/repo.git')
        self.write('notes.txt', 'should-not-sync\n')
        before = self.head()
        self.run_sync('--dry-run', ok=False)
        self.assertEqual(before, self.head())

    def test_https_userinfo_is_rejected(self):
        for url in ('https://token@example.invalid/repo.git', 'https://user:secret@example.invalid/repo.git'):
            with self.subTest(url=url):
                self.git('remote', 'set-url', 'origin', url)
                self.run_sync('--dry-run', ok=False)

    def test_setup_accepts_ssh_scheme_without_password(self):
        result = subprocess.run(
            [BASH, str(ROOT / 'scripts/setup-remotes.sh'),
             'ssh://git@example.invalid/primary.git',
             'ssh://git@example.invalid/mirror.git',
             self.repo.as_posix()],
            env=self.env, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('remote', 'get-url', 'origin'), 'ssh://git@example.invalid/primary.git')

    def test_dry_run_has_no_writes(self):
        self.write('.env', 'fake\n')
        index = (self.repo / '.git/index').read_bytes()
        before = self.head()
        objects = sorted(str(p) for p in (self.repo / '.git/objects').rglob('*'))
        result = self.run_sync('--dry-run')
        self.assertIn('DRY RUN', result.stdout)
        self.assertEqual(before, self.head())
        self.assertEqual(index, (self.repo / '.git/index').read_bytes())
        self.assertEqual(objects, sorted(str(p) for p in (self.repo / '.git/objects').rglob('*')))
        self.assertFalse((self.base / 'logs').exists())
        self.assertFalse((self.repo / '.git/anywhere.lock').exists())

    def test_bad_remote_fails_before_staging(self):
        self.git('config', 'anywhere.remotes', 'origin missing')
        self.write('new.txt', 'safe\n')
        before = self.git('status', '--porcelain')
        self.run_sync(ok=False)
        self.assertEqual(before, self.git('status', '--porcelain'))

    def test_split_push_url_rejected_before_staging(self):
        target = self.base / 'different.git'
        self.git('init', '--bare', str(target), cwd=self.base)
        self.git('remote', 'set-url', '--push', 'origin', target.as_posix())
        self.write('new.txt', 'safe\n')
        before = self.head()
        self.run_sync(ok=False)
        self.assertEqual(self.head(), before)
        self.assertEqual(self.git('show-ref', cwd=target, check=False), '')

    def test_changed_url_empty_remote_checks_full_history(self):
        self.write('.env', 'fake\n'); self.git('add', '.'); self.git('commit', '-m', 'unsafe')
        self.git('rm', '.env'); self.git('commit', '-m', 'remove')
        self.git('push', 'origin', 'main')
        target = self.base / 'new-empty.git'
        self.git('init', '--bare', str(target), cwd=self.base)
        self.git('remote', 'set-url', 'origin', target.as_posix())
        self.write('new.txt', 'safe\n')
        self.run_sync(ok=False)
        self.assertEqual(self.git('show-ref', cwd=target, check=False), '')

    def test_changed_url_empty_remote_without_new_changes(self):
        target = self.base / 'new-empty.git'
        self.git('init', '--bare', str(target), cwd=self.base)
        self.git('remote', 'set-url', 'origin', target.as_posix())
        self.run_sync()
        self.assertEqual(self.head(target), self.head())

    def test_remote_change_in_commit_hook_refuses_push(self):
        destination = self.base / 'redirect.git'
        self.git('init', '--bare', str(destination), cwd=self.base)
        self.env['ANYWHERE_TEST_DEST'] = destination.as_posix()
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_bytes(b'#!/bin/sh\ngit remote set-url origin "$ANYWHERE_TEST_DEST"\n')
        hook.chmod(0o755)
        self.write('new.txt', 'safe\n')
        self.run_sync(ok=False)
        self.assertEqual(self.git('show-ref', cwd=destination, check=False), '')

    def test_example_env_case_is_allowed_but_token_is_not(self):
        self.write('.ENV.example', 'API_KEY=\n')
        self.run_sync()
        self.assertIn('.ENV.example', self.git('ls-tree', '-r', '--name-only', 'HEAD'))
        token = 'gh' + 'p_' + 'e' * 36
        self.write('.env.example', token + '\n')
        result = self.run_sync(ok=False)
        self.assertNotIn(token, result.stdout + result.stderr)

    def test_secret_in_author_header_blocked(self):
        token = 'gh' + 'p_' + 'd' * 36
        self.git('commit', '--allow-empty', '-m', 'metadata',
                 '--author=Tester <' + token + '@example.invalid>')
        before = self.head(self.origin)
        result = self.run_sync(ok=False)
        self.assertEqual(before, self.head(self.origin))
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertNotIn(token, (self.base / 'logs/autosync.log').read_text(encoding='utf-8'))

    def test_symlink_history_is_pushed(self):
        self.write('target.txt', 'target\n')
        sha = self.git('hash-object', '-w', 'target.txt')
        self.git('update-index', '--add', 'target.txt')
        self.git('update-index', '--add', '--cacheinfo', '120000,' + sha + ',the-link')
        self.git('commit', '-m', 'symlink')
        self.run_sync()
        self.assertIn(sha, self.git('rev-list', '--objects', '--all', cwd=self.origin))

    def test_gitlink_is_rejected_without_false_credential_error(self):
        sha = '0123456789abcdef0123456789abcdef01234567'
        self.git('update-index', '--add', '--cacheinfo', '160000,' + sha + ',vendor/lib')
        self.git('commit', '-m', 'gitlink')
        self.git('config', 'push.recurseSubmodules', 'on-demand')
        before = self.head(self.origin)
        index = (self.repo / '.git/index').read_bytes()
        result = self.run_sync(ok=False)
        self.assertEqual(before, self.head(self.origin))
        self.assertEqual(index, (self.repo / '.git/index').read_bytes())
        self.assertIn('160000', self.git('ls-tree', '-r', 'HEAD'))
        self.assertIn('Submodule gitlink is not supported', result.stderr)
        self.assertNotIn('rotate', result.stderr.lower())
        self.assertNotIn('could not get object info', result.stderr)

    @unittest.skipUnless(os.name != 'nt', 'POSIX process groups')
    def test_signal_during_merge_aborts(self):
        self.write('.gitattributes', 'notes.txt merge=sleepy\n')
        self.git('add', '.gitattributes')
        self.git('commit', '-m', 'attr')
        self.git('push', 'origin', 'main')
        marker = self.base / 'merge-started'
        self.env['ANYWHERE_MERGE_MARKER'] = str(marker)
        self.git('config', 'merge.sleepy.driver', 'printf x > "$ANYWHERE_MERGE_MARKER"; sleep 30')
        other = self.base / 'other'
        self.git('clone', self.origin.as_posix(), str(other), cwd=self.base)
        self.git('checkout', 'main', cwd=other)
        self.git('config', 'user.name', 'Other', cwd=other)
        self.git('config', 'user.email', 'other@example.invalid', cwd=other)
        (other / 'notes.txt').write_text('remote edit\n', encoding='utf-8')
        self.git('add', '.', cwd=other)
        self.git('commit', '-m', 'remote', cwd=other)
        self.git('push', 'origin', 'main', cwd=other)
        remote_head = self.head(self.origin)
        self.write('notes.txt', 'local edit\n')
        script = (ROOT / 'scripts/autosync.sh').as_posix()
        proc = subprocess.Popen([BASH, script, self.repo.as_posix()], cwd=self.base, env=self.env,
                                text=True, encoding='utf-8', stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        index_lock = self.repo / '.git' / 'index.lock'
        deadline = time.time() + 20
        while time.time() < deadline and not marker.exists():
            if proc.poll() is not None:
                out, err = proc.communicate()
                self.fail('sync exited before merge driver started\n' + out + err)
            time.sleep(0.05)
        self.assertTrue(marker.exists(), 'merge driver did not start')
        os.killpg(proc.pid, signal.SIGINT)
        out, err = proc.communicate(timeout=20)
        self.assertFalse((self.repo / '.git/MERGE_HEAD').exists(), out + err)
        self.assertFalse(index_lock.exists(), out + err)
        self.assertFalse((self.repo / '.git/anywhere.lock').exists(), out + err)
        self.assertEqual(list(self.repo.glob('.merge_file_*')), [], out + err)
        self.assertEqual(remote_head, self.head(self.origin))
        self.assertEqual(self.git('show', 'HEAD:notes.txt'), 'local edit')
        self.assertEqual(proc.returncode, 130, out + err)

    def test_secret_in_outgoing_commit_message_blocked(self):
        token = 'gh' + 'p_' + 'c' * 36
        self.write('notes.txt', 'safe update\n'); self.git('add', '.')
        self.git('commit', '-m', token)
        before = self.head(self.origin)
        result = self.run_sync(ok=False)
        self.assertEqual(before, self.head(self.origin))
        self.assertNotIn(token, result.stdout + result.stderr)

    def test_multiple_push_urls_rejected(self):
        self.git('remote', 'set-url', '--add', '--push', 'origin', self.origin.as_posix())
        self.git('remote', 'set-url', '--add', '--push', 'origin', (self.base / 'other.git').as_posix())
        self.run_sync(ok=False)

    def test_setup_clears_stale_push_url(self):
        self.git('remote', 'set-url', '--push', 'origin', (self.base / 'wrong.git').as_posix())
        self.test_setup_remotes_explicit_and_preserves_config()
        self.assertEqual(self.git('remote', 'get-url', '--push', 'origin'), self.origin.as_posix())

    def test_invalid_limit(self):
        self.env['ANYWHERE_MAX_FILE_BYTES'] = 'bad'
        self.run_sync(ok=False)

    def test_detached_head_skipped(self):
        self.git('checkout', '--detach')
        self.write('new.txt', 'safe\n')
        self.assertIn('detached', self.run_sync().stdout)
        self.assertTrue(self.git('status', '--porcelain'))

    def test_live_lock_skipped(self):
        lock = self.repo / '.git/anywhere.lock'; lock.mkdir()
        # Git Bash uses MSYS PIDs; a native Python PID is not a shell PID.
        helper = subprocess.Popen([BASH, '-c', 'echo $$ > "$1"; read -r _',
                                   'test-lock', (lock / 'pid').as_posix()], env=self.env,
                                  stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def stop_helper():
            helper.stdin.close()
            try:
                helper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                helper.kill(); helper.wait()
        self.addCleanup(stop_helper)
        for _ in range(100):
            if (lock / 'pid').exists():
                break
            time.sleep(0.05)
        self.assertTrue((lock / 'pid').exists())
        self.write('new.txt', 'safe\n')
        self.assertIn('already running', self.run_sync().stdout)
        self.assertTrue(lock.exists())

    def test_stale_lock_reclaimed(self):
        lock = self.repo / '.git/anywhere.lock'; lock.mkdir()
        (lock / 'pid').write_text('2147483647')
        self.run_sync()
        self.assertFalse(lock.exists())

    def test_index_lock_skipped(self):
        (self.repo / '.git/index.lock').touch()
        self.write('new.txt', 'safe\n')
        self.assertIn('locked', self.run_sync().stdout)
        self.assertTrue(self.git('status', '--porcelain'))

    def test_in_progress_merge_blocked(self):
        (self.repo / '.git/MERGE_HEAD').write_text(self.head() + '\n')
        self.run_sync(ok=False)

    def test_network_failure_retains_commit_and_nonzero(self):
        self.git('remote', 'set-url', 'origin', (self.base / 'absent.git').as_posix())
        self.write('new.txt', 'safe\n')
        result = self.run_sync(ok=False)
        self.assertIn('One or more remotes failed', result.stderr)
        self.assertNotIn('unbound variable', result.stderr)
        self.assertEqual(self.git('show', 'HEAD:new.txt'), 'safe')

    def test_conflict_aborts_without_push(self):
        other = self.base / 'other'
        self.git('clone', self.origin.as_posix(), str(other), cwd=self.base)
        self.git('checkout', 'main', cwd=other)
        self.git('config', 'user.name', 'Other', cwd=other)
        self.git('config', 'user.email', 'other@example.invalid', cwd=other)
        (other / 'notes.txt').write_text('remote edit\n')
        self.git('add', '.', cwd=other); self.git('commit', '-m', 'remote', cwd=other)
        self.git('push', 'origin', 'main', cwd=other)
        remote_head = self.head(self.origin)
        self.write('notes.txt', 'local edit\n')
        self.run_sync(ok=False)
        self.assertEqual(remote_head, self.head(self.origin))
        self.assertFalse((self.repo / '.git/MERGE_HEAD').exists())
        self.assertEqual(self.git('show', 'HEAD:notes.txt'), 'local edit')

    def test_missing_identity_rejected(self):
        self.git('config', '--unset', 'user.name')
        self.git('config', '--unset', 'user.email')
        self.write('new.txt', 'safe\n')
        self.run_sync(ok=False)

    def test_setup_remotes_explicit_and_preserves_config(self):
        self.git('config', 'remote.origin.customSetting', 'keep')
        result = subprocess.run([BASH, str(ROOT / 'scripts/setup-remotes.sh'),
                                 self.origin.as_posix(), (self.base / 'mirror.git').as_posix(), self.repo.as_posix()],
                                env=self.env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('config', 'anywhere.remotes'), 'origin github')
        self.assertEqual(self.git('config', 'remote.origin.customSetting'), 'keep')

    @unittest.skipUnless(os.uname().sysname == 'Darwin' if hasattr(os, 'uname') else False, 'macOS installer')
    def test_mac_plist_escaping_and_uninstall(self):
        special = self.base / "project & <tag> 'quoted'"
        self.repo.rename(special); self.repo = special
        bins = self.base / 'bin'; bins.mkdir()
        stub = bins / 'launchctl'; stub.write_text('#!/bin/sh\nexit 0\n'); stub.chmod(0o755)
        fake_git = bins / 'git'; fake_git.write_bytes(b'#!/bin/sh\nexit 88\n'); fake_git.chmod(0o755)
        self.env['PATH'] = str(bins) + os.pathsep + self.env['PATH']
        result = subprocess.run([BASH, str(ROOT / 'scripts/install-mac.sh'), self.repo.as_posix(), '60'],
                                env=self.env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        plists = list((Path(self.env['HOME']) / 'Library/LaunchAgents').glob('*.plist'))
        self.assertEqual(len(plists), 1)
        with plists[0].open('rb') as handle:
            data = plistlib.load(handle)
        self.assertEqual(data['ProgramArguments'][2], str(self.repo))
        launch_env = self.env.copy(); launch_env.update(data['EnvironmentVariables'])
        result = subprocess.run(data['ProgramArguments'], env=launch_env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        subprocess.run([BASH, str(ROOT / 'scripts/uninstall-mac.sh'), self.repo.as_posix()],
                       env=self.env, capture_output=True, check=True)
        self.assertFalse(plists[0].exists())

    def mirror_source(self):
        sources = self.base / 'sources'; sources.mkdir()
        source = sources / 'sample.git'
        self.git('clone', '--bare', self.repo.as_posix(), str(source), cwd=self.base)
        config = self.base / 'mirror-gitconfig'
        self.env['GIT_CONFIG_GLOBAL'] = str(config)
        self.git('config', '--global', 'url.' + sources.as_posix() + '/.insteadOf', 'https://github.com/test-owner/')
        destinations = self.base / 'destinations'; destinations.mkdir()
        destination = destinations / 'sample.git'
        self.git('init', '--bare', str(destination), cwd=self.base)
        return destinations, destination

    def run_mirror(self, destinations, ok=True):
        script = (ROOT / 'scripts/mirror-github.sh').as_posix()
        command = [BASH, script, 'test-owner', destinations.as_posix(), 'sample']
        if hasattr(self, 'git_override'):
            path = self.git_override.as_posix()
            if os.name == 'nt':
                path = '/' + path[0].lower() + path[2:]
            command = [BASH, '-c', 'export PATH="$1:$PATH"; shift; source "$0" "$@"',
                       script, path, 'test-owner', destinations.as_posix(), 'sample']
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_mirror_local_rewrite_pushes_safe_history(self):
        destinations, destination = self.mirror_source()
        self.run_mirror(destinations)
        self.assertEqual(self.head(destination), self.head())

    def test_mirror_blocks_deleted_historical_secret(self):
        self.write('.env', 'fake\n'); self.git('add', '.'); self.git('commit', '-m', 'unsafe')
        self.git('rm', '.env'); self.git('commit', '-m', 'remove')
        destinations, destination = self.mirror_source()
        self.run_mirror(destinations, ok=False)
        self.assertEqual(self.git('show-ref', cwd=destination, check=False), '')

    def test_mirror_blocks_annotated_tag_message_secret(self):
        token = 'gh' + 'p_' + 't' * 36
        self.git('tag', '-a', 'test-tag', '-m', token)
        destinations, destination = self.mirror_source()
        result = self.run_mirror(destinations, ok=False)
        self.assertEqual(self.git('show-ref', cwd=destination, check=False), '')
        self.assertNotIn(token, result.stdout + result.stderr)

    def test_mirror_enumeration_failure_blocks_push(self):
        destinations, destination = self.mirror_source()
        bins = self.base / 'git-bin'; bins.mkdir()
        self.env['ANYWHERE_REAL_GIT'] = Path(shutil.which('git')).as_posix()
        wrapper = bins / 'git'
        wrapper.write_bytes(b'#!/bin/sh\nfor arg in "$@"; do [ "$arg" != rev-list ] || exit 9; done\nexec "$ANYWHERE_REAL_GIT" "$@"\n')
        wrapper.chmod(0o755); self.git_override = bins
        result = self.run_mirror(destinations, ok=False)
        self.assertIn('enumeration failed', result.stderr)
        self.assertEqual(self.git('show-ref', cwd=destination, check=False), '')

    def test_mirror_requires_explicit_repositories(self):
        result = subprocess.run([BASH, str(ROOT / 'scripts/mirror-github.sh')],
                                env=self.env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 2)

    def test_mirror_dry_run_allows_ssh_destination_without_password(self):
        result = subprocess.run(
            [BASH, str(ROOT / 'scripts/mirror-github.sh'), '--dry-run',
             'example-user', 'ssh://git@example.invalid/team', 'repo'],
            env=self.env, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mirror_dry_run_no_writes(self):
        result = subprocess.run([BASH, str(ROOT / 'scripts/mirror-github.sh'), '--dry-run',
                                 'example-user', 'https://example.invalid/team', 'repo'],
                                env=self.env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((Path(self.env['HOME']) / '.anywhere').exists())


if __name__ == '__main__':
    unittest.main()
