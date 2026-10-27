"""Fixture tests for the agentic-engineering landing-watch sentinel (stdlib only).

GitHub and the gateway are fakes: no network, credential or live gateway is used.
"""
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROGRAM = Path(__file__).resolve().parents[1] / 'priv/kungfu/agentic-engineering/sentinels/landing-watch'


def load_program():
    loader = importlib.machinery.SourceFileLoader('landing_watch', str(PROGRAM))
    spec = importlib.util.spec_from_loader('landing_watch', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_program()

NOW = dt.datetime(2026, 9, 26, 12, 0, 0, tzinfo=dt.timezone.utc)


def ts(minutes_ago):
    return lw.iso(NOW - dt.timedelta(minutes=minutes_ago))


def check_run(node, name, conclusion='FAILURE', status='COMPLETED', started=5, app=15368,
              required=None):
    run = {'__typename': 'CheckRun', 'id': node, 'name': name, 'status': status,
           'conclusion': conclusion if status == 'COMPLETED' else None,
           'startedAt': ts(started) if started is not None else None,
           'completedAt': ts(started - 1) if status == 'COMPLETED' and started else None,
           'detailsUrl': f'https://example.test/runs/{node}',
           'checkSuite': {'app': None if app is None else {'databaseId': app}}}
    if required is not None:
        run['isRequired'] = required
    return run


def status(context, state='FAILURE', created=5, required=None):
    result = {'__typename': 'StatusContext', 'id': f'S_{context}_{created}', 'context': context,
              'state': state, 'createdAt': ts(created), 'targetUrl': f'https://example.test/{context}'}
    if required is not None:
        result['isRequired'] = required
    return result


def pull(number, state='OPEN', merged=False, merge_oid=None, head='head1', auto=None, queued=False,
         updated=1, events=(), checks=None, checks_oid=None, merge_checks=None,
         test_merge='test-merge', merge_parent=None):
    return {
        'number': number, 'state': state, 'merged': merged,
        'mergeCommit': {'oid': merge_oid} if merge_oid else None,
        'headRefOid': head,
        'autoMergeRequest': {'enabledAt': auto} if auto else None,
        'mergeQueueEntry': {'id': f'MQ_{number}'} if queued else None,
        'updatedAt': ts(updated), 'events': list(events),
        'checks': list(checks or []), 'checks_oid': checks_oid or head,
        'merge_checks': list(merge_checks or []), 'test_merge': test_merge,
        'merge_parent': merge_parent or head,
    }


def event(kind, node, minutes_ago=2, reason=None):
    item = {'__typename': kind, 'id': node, 'createdAt': ts(minutes_ago)}
    if kind == 'RemovedFromMergeQueueEvent':
        item['reason'] = reason
    return item


class FakeGitHub:
    """A small in-memory GitHub answering the watcher's reads, with paging and faults."""

    def __init__(self, page=100):
        self.page = page
        self.pulls = {}
        self.tip_oid = 'tip1'
        self.tip_results = []
        self.rules = []
        self.fail = None  # callable(operation, variables) -> bool
        self.calls = []

    def add(self, *pulls):
        for item in pulls:
            self.pulls[item['number']] = item

    def _page(self, items, variables):
        start = int(variables.get('cursor') or 0)
        chunk = items[start:start + self.page]
        more = start + self.page < len(items)
        return {'pageInfo': {'hasNextPage': more, 'endCursor': str(start + self.page) if more else None},
                'nodes': chunk}

    def graphql(self, query, variables):
        operation = query.split('query ', 1)[1].split('(', 1)[0]
        self.calls.append((operation, dict(variables)))
        if self.fail and self.fail(operation, variables):
            raise lw.ReadError(f'injected failure in {operation}')
        repo = variables['owner'], variables['name']
        assert tuple(part.lower() for part in repo) == ('example', 'repo'), repo
        if operation == 'LandingOpen':
            items = [{'number': p['number'], 'updatedAt': p['updatedAt']}
                     for p in sorted(self.pulls.values(), key=lambda p: p['number']) if p['state'] == 'OPEN']
            return {'repository': {'pullRequests': self._page(items, variables)}}
        if operation == 'LandingRecent':
            items = [{'number': p['number'], 'updatedAt': p['updatedAt']}
                     for p in sorted(self.pulls.values(), key=lambda p: p['updatedAt'], reverse=True)]
            return {'repository': {'pullRequests': self._page(items, variables)}}
        if operation == 'LandingPull':
            item = self.pulls.get(variables['number'])
            if item is None:
                raise lw.ReadError(
                    'gh exited 1: gh: Could not resolve to a PullRequest with the number of '
                    f"{variables['number']}."
                )
            since = variables.get('since')
            events = [e for e in item['events'] if since is None or e['createdAt'] >= since]
            node = {k: item[k] for k in ('number', 'state', 'merged', 'mergeCommit', 'headRefOid',
                                         'autoMergeRequest', 'mergeQueueEntry')}
            node['timelineItems'] = self._page(events, variables)
            return {'repository': {'pullRequest': node}}
        if operation == 'LandingPullChecks':
            item = self.pulls[variables['number']]
            rollup = {'contexts': self._page(item['checks'], variables)} if item['checks'] else None
            commit = {'oid': item['checks_oid'], 'statusCheckRollup': rollup}
            return {'repository': {'pullRequest': {'commits': {'nodes': [{'commit': commit}]}}}}
        if operation == 'LandingMergeChecks':
            item = self.pulls[variables['number']]
            merge = None
            if item['test_merge'] is not None:
                rollup = ({'contexts': self._page(item['merge_checks'], variables)}
                          if item['merge_checks'] else None)
                merge = {'oid': item['test_merge'],
                         'parents': {'nodes': [{'oid': 'base'}, {'oid': item['merge_parent']}]},
                         'statusCheckRollup': rollup}
            return {'repository': {'pullRequest': {'potentialMergeCommit': merge}}}
        if operation == 'LandingTip':
            assert variables['qualified'] == 'refs/heads/main'
            rollup = {'contexts': self._page(self.tip_results, variables)} if self.tip_results else None
            target = {'__typename': 'Commit', 'oid': self.tip_oid, 'statusCheckRollup': rollup}
            return {'repository': {'ref': {'target': target}}}
        raise AssertionError(operation)

    def rest(self, path):
        self.calls.append(('rest', path))
        if self.fail and self.fail('rest', path):
            raise lw.ReadError('injected rules failure')
        assert path.lower().startswith('repos/example/repo/rules/branches/main?per_page=100&page='), path
        return self.rules if path.endswith('page=1') else []


class FakeRunner:
    def __init__(self, github):
        self.github = github
        self.filed = []
        self.checks = []
        self.refuse = None  # callable(args) -> bool
        self.demand = []
        self.demand_error = None
        self.operations = []
        self.claims = 0

    def tightbeam_json(self, args):
        self.operations.append(args[0])
        if args[0] == 'fact-demand':
            if self.demand_error:
                raise self.demand_error
            return {'demand': self.demand}
        if args[0] == 'fact-producer-claim':
            self.claims += 1
            return {'producer': 'landing-watch'}
        raise AssertionError(args)

    def graphql(self, query, variables):
        return self.github.graphql(query, variables)

    def rest(self, path):
        return self.github.rest(path)

    def tightbeam(self, args):
        if self.refuse and self.refuse(args):
            return False, 'refused by fake gateway'
        if '--kind' in args and args[args.index('--kind') + 1] == lw.CHECKS_COMPLETED:
            self.checks.append(list(args))
            return True, '{}'
        self.filed.append(list(args))
        return True, '{}'

    def keys(self, verb='condition'):
        return [a[a.index('--key') + 1] for a in self.filed if a[0] == verb]


class WatcherCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.github = FakeGitHub()
        self.runner = FakeRunner(self.github)
        self.stream = io.StringIO()
        self.log = lw.Log(self.stream)
        self.branch = lw.Branch('Example', 'Repo', 'main', 'pdo:example')
        self.clock = NOW

    def run_once(self, static=''):
        self.runner.login = lambda: 'example-bot'
        return lw.run(['landing-watch', '--once'],
                      {'GH_CONFIG_DIR': self.tmp.name, 'LANDING_REPOS': static},
                      runner=self.runner, log=self.log)


class Settings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def env(self, **extra):
        return {'GH_CONFIG_DIR': self.tmp.name, 'LANDING_REPOS': 'example/repo@main=pdo:example', **extra}

    def test_valid_settings_name_branches_and_process_identity(self):
        branches, process = lw.parse_settings(self.env(
            LANDING_REPOS='Example/Repo@main=pdo:example  example/other@release/1.2=orchestrator:x',
            LANDING_WATCH_AS_PROCESS='landing-watch'))
        self.assertEqual([b.scope for b in branches], ['example/repo@main', 'example/other@release/1.2'])
        self.assertEqual(branches[0].pr_scope(7), 'example/repo#7')
        self.assertEqual(process, 'landing-watch')

    def test_missing_or_malformed_settings_refuse(self):
        bad = [
            {'LANDING_REPOS': 'example/repo@main=pdo:x'},
            {'GH_CONFIG_DIR': os.path.join(self.tmp.name, 'absent'), 'LANDING_REPOS': 'example/repo@main=pdo:x'},
            self.env(LANDING_REPOS='example/repo=pdo:x'),
            self.env(LANDING_REPOS='example/repo@main'),
            self.env(LANDING_REPOS='repo@main=pdo:x'),
            self.env(LANDING_REPOS='example/repo@main=pdo:x example/repo@main=pdo:y'),
            self.env(LANDING_REPOS='example/repo@gh-readonly-queue/main/pr-1-abc=pdo:x'),
            self.env(LANDING_WATCH_AS_PROCESS=''),
            self.env(LANDING_WATCH_AS_PROCESS='two words'),
        ]
        for env in bad:
            with self.subTest(env=env), self.assertRaises(lw.SettingsError):
                lw.parse_settings(env)

    def test_repositories_are_optional(self):
        self.assertEqual(lw.parse_settings({'GH_CONFIG_DIR': self.tmp.name}), ([], None))

    def test_runner_adds_process_identity_only_when_configured(self):
        seen = []

        class Done:
            returncode = 0
            stdout = '{}'
            stderr = ''

        original = lw.subprocess.run
        lw.subprocess.run = lambda argv, **kw: seen.append(argv) or Done()
        try:
            lw.Runner('landing-watch').tightbeam(['condition', '--kind', 'k'])
            lw.Runner(None).tightbeam(['condition', '--kind', 'k'])
        finally:
            lw.subprocess.run = original
        self.assertEqual(seen[0][1], 'fact-producer-claim')
        self.assertEqual(seen[1], ['tightbeam', 'condition', '--kind', 'k', '--as-process', 'landing-watch'])
        self.assertEqual(seen[2][1], 'fact-producer-claim')
        self.assertEqual(seen[3], ['tightbeam', 'condition', '--kind', 'k'])

    def test_runner_passes_numbers_and_strings_and_omits_nulls(self):
        seen = []

        class Done:
            returncode = 0
            stdout = '{"data": {}}'
            stderr = ''

        original = lw.subprocess.run
        lw.subprocess.run = lambda argv, **kw: seen.append((argv, kw.get('env'))) or Done()
        try:
            lw.Runner(None).graphql('query Q { x }', {'owner': 'o', 'number': 3, 'cursor': None})
        finally:
            lw.subprocess.run = original
        self.assertEqual(seen[0][0][1], 'fact-producer-claim')
        argv, env = seen[1]
        self.assertIn('owner=o', argv[argv.index('-f', 4) + 1:])
        self.assertEqual(argv[argv.index('-F') + 1], 'number=3')
        self.assertFalse(any(a.startswith('cursor=') for a in argv))
        self.assertEqual(env['GH_PROMPT_DISABLED'], '1')


class RunningPath(WatcherCase):
    def demand_pr(self, number, *kinds):
        self.runner.demand = [{'kind': kind, 'scope': f'example/repo#{number}'} for kind in kinds]

    def demand_branch(self):
        self.runner.demand = [{'kind': lw.BRANCH_ATTENTION, 'scope': 'example/repo@main'}]

    def keys(self):
        return self.runner.keys()

    def check_keys(self):
        return [args[args.index('--key') + 1] for args in self.runner.checks]

    def test_claim_precedes_demand_and_only_demanded_pr_is_read(self):
        self.github.add(pull(7, checks=[check_run('C1', 'build', 'SUCCESS', required=True)]))
        self.demand_pr(7, lw.CHECKS_COMPLETED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.runner.operations[:2], ['fact-producer-claim', 'fact-demand'])
        self.assertEqual(self.runner.claims, 1)
        self.assertEqual(self.check_keys(), ['pr-checks:example/repo#7:head1:pass'])
        self.assertFalse(any(op in ('LandingOpen', 'LandingRecent', 'LandingTip') for op, _ in self.github.calls))
        before = len(self.github.calls)
        self.runner.demand = []
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(len(self.github.calls), before)

    def test_merged_fact_uses_merge_commit(self):
        self.github.add(pull(7, state='MERGED', merged=True, merge_oid='abc'))
        self.demand_pr(7, lw.SETTLED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), ['landing-fact:example/repo#7:merged:abc'])

    def test_every_queue_removal_has_own_fact(self):
        self.github.add(pull(7, events=[event('RemovedFromMergeQueueEvent', 'RM1'),
                                        event('RemovedFromMergeQueueEvent', 'RM2')]))
        self.demand_pr(7, lw.SETTLED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), ['landing-fact:example/repo#7:removed:RM1',
                                       'landing-fact:example/repo#7:removed:RM2'])

    def test_automerge_disabled_and_closed_are_settled(self):
        self.github.add(pull(7, state='CLOSED', events=[event('AutoMergeDisabledEvent', 'AD'),
                                                       event('ClosedEvent', 'CE')]))
        self.demand_pr(7, lw.SETTLED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), ['landing-fact:example/repo#7:automerge-disabled:AD',
                                       'landing-fact:example/repo#7:closed:CE'])

    def test_blocked_required_check_uses_effective_subject(self):
        self.github.add(pull(7, auto=ts(3), checks=[check_run('head', 'build', 'SUCCESS', required=True)],
                             merge_checks=[check_run('merge', 'build', 'FAILURE', required=True)]))
        self.demand_pr(7, lw.SETTLED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), ['landing-fact:example/repo#7:blocked:' + ts(3) + ':merge'])

    def test_unknown_test_merge_does_not_claim_blocked(self):
        self.github.add(pull(7, auto=ts(3), checks=[check_run('head', 'build', 'FAILURE', required=True)],
                             test_merge=None))
        self.demand_pr(7, lw.SETTLED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), [])

    def test_queued_pull_does_not_file_checks_or_blocked(self):
        self.github.add(pull(7, queued=True, auto=ts(3),
                             checks=[check_run('C1', 'build', 'FAILURE', required=True)]))
        self.demand_pr(7, lw.SETTLED, lw.CHECKS_COMPLETED)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), [])
        self.assertEqual(self.check_keys(), [])

    def test_checks_completed_pass_fail_and_pending(self):
        self.github.add(pull(7, checks=[check_run('C1', 'build', 'SUCCESS', required=True)]),
                        pull(8, checks=[check_run('C2', 'build', 'FAILURE', required=True)]),
                        pull(9, checks=[check_run('C3', 'build', status='IN_PROGRESS', required=True)]))
        self.runner.demand = [{'kind': lw.CHECKS_COMPLETED, 'scope': f'example/repo#{n}'} for n in (7, 8, 9)]
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.check_keys(), ['pr-checks:example/repo#7:head1:pass',
                                             'pr-checks:example/repo#8:head1:fail'])

    def test_new_head_has_new_checks_fact_key(self):
        self.github.add(pull(7, checks=[check_run('C1', 'build', 'FAILURE', required=True)]))
        self.demand_pr(7, lw.CHECKS_COMPLETED)
        self.assertEqual(self.run_once(), 0)
        self.github.add(pull(7, head='head2', checks=[check_run('C2', 'build', 'SUCCESS', required=True)]))
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.check_keys(), ['pr-checks:example/repo#7:head1:fail',
                                             'pr-checks:example/repo#7:head2:pass'])

    def test_demand_only_branch_files_fact_without_owner_wake(self):
        self.github.rules = [{'type': 'required_status_checks',
                              'parameters': {'required_status_checks': [{'context': 'build'}]}}]
        self.github.tip_results = [check_run('C1', 'build', 'FAILURE')]
        self.demand_branch()
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), ['landing-fact:example/repo@main:red:tip1:C1'])
        self.assertFalse(any(args[0] == 'wake' for args in self.runner.filed))

    def test_static_branch_reads_tip_only_and_wakes_owner(self):
        self.github.rules = [{'type': 'required_status_checks',
                              'parameters': {'required_status_checks': [{'context': 'build'}]}}]
        self.github.tip_results = [check_run('C1', 'build', 'FAILURE')]
        self.github.add(pull(7, state='MERGED', merged=True, merge_oid='abc'))
        self.assertEqual(self.run_once('Example/Repo@main=pdo:example'), 0)
        self.assertEqual([op for op, _ in self.github.calls if op != 'rest'], ['LandingTip'])
        self.assertEqual(self.runner.filed[0][0], 'wake')
        self.assertEqual(self.runner.filed[1][0], 'condition')

    def test_failed_demand_read_fails_poll_without_github_read(self):
        self.runner.demand_error = lw.ReadError('gateway read failed')
        self.assertEqual(self.run_once(), 1)
        self.assertEqual(self.github.calls, [])
        self.assertIn('poll failed reason=gateway read failed', self.stream.getvalue())

    def test_real_missing_pr_error_is_skipped_and_other_pr_proceeds(self):
        self.github.add(pull(7, checks=[check_run('C1', 'build', 'SUCCESS', required=True)]))
        self.runner.demand = [{'kind': lw.CHECKS_COMPLETED, 'scope': f'example/repo#{n}'} for n in (8, 7)]
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.check_keys(), ['pr-checks:example/repo#7:head1:pass'])
        self.assertIn('Could not resolve to a PullRequest', self.stream.getvalue())

    def test_read_failure_for_existing_pr_fails_poll(self):
        self.github.add(pull(7))
        self.github.fail = lambda op, variables: op == 'LandingPull'
        self.demand_pr(7, lw.SETTLED)
        self.assertEqual(self.run_once(), 1)

    def test_refused_fact_fails_poll_and_retries_with_same_key(self):
        self.github.add(pull(7, state='MERGED', merged=True, merge_oid='abc'))
        self.demand_pr(7, lw.SETTLED)
        self.runner.refuse = lambda args: args[0] == 'condition'
        self.assertEqual(self.run_once(), 1)
        self.runner.refuse = None
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.keys(), ['landing-fact:example/repo#7:merged:abc'])

    def test_invalid_demand_logged_once_and_other_pr_continues(self):
        self.runner.demand = [
            {'kind': lw.CHECKS_COMPLETED, 'scope': None},
            {'kind': lw.CHECKS_COMPLETED, 'scope': 'example/repo#7'},
        ]
        self.github.add(pull(7, checks=[check_run('pass', 'build', 'SUCCESS', required=True)]))
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.stream.getvalue().count('ignored invalid demand'), 1)


class ClaimRenewal(unittest.TestCase):
    def test_time_gate_and_forced_poll_start(self):
        class Claims:
            last_claim_at = None
            calls = 0

            def tightbeam_json(self, args):
                self.calls += 1
                return {}

        runner = Claims()
        original = lw.time.monotonic
        clock = [1000]
        lw.time.monotonic = lambda: clock[0]
        try:
            lw.renew_claim(runner, force=True)
            clock[0] += lw.CLAIM_RENEW_SECONDS - 1
            lw.renew_claim(runner)
            self.assertEqual(runner.calls, 1)
            clock[0] += 1
            lw.renew_claim(runner)
            self.assertEqual(runner.calls, 2)
            lw.renew_claim(runner, force=True)
            self.assertEqual(runner.calls, 3)
        finally:
            lw.time.monotonic = original

    def test_renewal_failure_does_not_abort_filing(self):
        seen = []
        original_renew = lw.renew_claim
        original_run = lw.subprocess.run

        class Done:
            returncode = 0
            stdout = '{}'
            stderr = ''

        lw.renew_claim = lambda runner: (_ for _ in ()).throw(lw.ReadError('claim unavailable'))
        lw.subprocess.run = lambda argv, **kw: seen.append(argv) or Done()
        try:
            self.assertEqual(lw.Runner(None).tightbeam(['condition', '--kind', lw.SETTLED]), (True, '{}'))
            self.assertEqual(seen, [['tightbeam', 'condition', '--kind', lw.SETTLED]])
        finally:
            lw.renew_claim = original_renew
            lw.subprocess.run = original_run


FAKE_GH = r'''#!{python}
import json, os, sys
args = sys.argv[1:]
mode = os.environ.get('FAKE_GH_MODE', 'ok')
if args[:2] == ['api', 'user']:
    if mode == 'unauthorized':
        sys.stderr.write('HTTP 401: Bad credentials (https://api.github.com/user)\n')
        sys.exit(1)
    print('example-bot')
    sys.exit(0)
if args[:2] == ['api', 'graphql']:
    query = next(a for a in args if a.startswith('query='))
    op = query.split('query ', 1)[1].split('(', 1)[0]
    empty = {{'pageInfo': {{'hasNextPage': False, 'endCursor': None}}, 'nodes': []}}
    if op in ('LandingOpen', 'LandingRecent'):
        data = {{'repository': {{'pullRequests': empty}}}}
    else:
        data = {{'repository': {{'ref': {{'target': {{'__typename': 'Commit', 'oid': 'tip', 'statusCheckRollup': None}}}}}}}}
    print(json.dumps({{'data': data}}))
    sys.exit(0)
if args[0] == 'api' and '/rules/branches/' in args[1]:
    print('[]')
    sys.exit(0)
sys.exit(9)
'''

FAKE_TIGHTBEAM = r'''#!{python}
import sys
with open({log!r}, 'a') as handle:
    handle.write(' '.join(sys.argv[1:]) + '\n')
if sys.argv[1] == 'fact-demand':
    print('{{"demand": []}}')
else:
    print('{{}}')
'''


class Process(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin = root / 'bin'
        self.bin.mkdir()
        self.calls = root / 'tightbeam.log'
        for name, body in (('gh', FAKE_GH.format(python=sys.executable)),
                           ('tightbeam', FAKE_TIGHTBEAM.format(python=sys.executable, log=str(self.calls)))):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        (root / 'gh-config').mkdir()
        self.env = {'PATH': f'{self.bin}{os.pathsep}{os.environ["PATH"]}', 'HOME': str(root),
                    'XDG_STATE_HOME': str(root / 'state'), 'GH_CONFIG_DIR': str(root / 'gh-config'),
                    'LANDING_REPOS': 'Example/Repo@main=pdo:example'}

    def run_program(self, *args, **env):
        return subprocess.run([sys.executable, str(PROGRAM), *args], env={**self.env, **env},
                              capture_output=True, text=True, timeout=60)

    def test_program_is_executable_python(self):
        self.assertTrue(os.access(PROGRAM, os.X_OK))
        self.assertTrue(PROGRAM.read_text().startswith('#!/usr/bin/env python3\n'))

    def test_bad_settings_exit_2(self):
        done = self.run_program('--once', LANDING_REPOS='nonsense')
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn('LANDING_REPOS entry is malformed', done.stderr)

    def test_failed_login_exits_3(self):
        done = self.run_program('--once', FAKE_GH_MODE='unauthorized')
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn('Bad credentials', done.stderr)

    def test_once_claims_and_checks_static_tip(self):
        done = self.run_program('--once', LANDING_WATCH_AS_PROCESS='landing-watch')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('start login=example-bot branches=example/repo@main', done.stderr)
        calls = self.calls.read_text()
        self.assertIn('fact-producer-claim', calls)
        self.assertIn('fact-demand --kind-prefix landing. --kind-prefix pr.', calls)

    def test_once_without_static_repositories(self):
        done = self.run_program('--once', LANDING_REPOS='')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('fact-demand', self.calls.read_text())


if __name__ == '__main__':
    unittest.main()
