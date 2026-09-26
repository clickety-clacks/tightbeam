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
        assert repo == ('Example', 'Repo'), repo
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
                return {'repository': {'pullRequest': None}}
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
        assert path.startswith('repos/Example/Repo/rules/branches/main?per_page=100&page='), path
        return self.rules if path.endswith('page=1') else []


class FakeRunner:
    def __init__(self, github):
        self.github = github
        self.filed = []
        self.refuse = None  # callable(args) -> bool

    def graphql(self, query, variables):
        return self.github.graphql(query, variables)

    def rest(self, path):
        return self.github.rest(path)

    def tightbeam(self, args):
        if self.refuse and self.refuse(args):
            return False, 'refused by fake gateway'
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

    def watcher(self):
        return lw.Watcher(self.branch, self.runner, self.tmp.name, self.log, clock=lambda: self.clock)

    def save_state(self, watermark_minutes_ago=30, tracked=()):
        self.watcher().save(NOW - dt.timedelta(minutes=watermark_minutes_ago), set(tracked))

    def state(self):
        with open(os.path.join(self.tmp.name, 'example-repo-main.json')) as handle:
            return json.load(handle)

    def poll(self):
        return self.watcher().poll()


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
        self.assertEqual(branches[1].state_name, 'example-other-release-1.2.json')
        self.assertEqual(process, 'landing-watch')

    def test_missing_or_malformed_settings_refuse(self):
        bad = [
            {'LANDING_REPOS': 'example/repo@main=pdo:x'},
            {'GH_CONFIG_DIR': os.path.join(self.tmp.name, 'absent'), 'LANDING_REPOS': 'example/repo@main=pdo:x'},
            {'GH_CONFIG_DIR': self.tmp.name},
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

    def test_state_directory_follows_xdg(self):
        self.assertEqual(lw.state_dir({'XDG_STATE_HOME': '/s', 'HOME': '/h'}), '/s/landing-watch')
        self.assertEqual(lw.state_dir({'HOME': '/h'}), '/h/.local/state/landing-watch')

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
        self.assertEqual(seen[0], ['tightbeam', 'condition', '--kind', 'k', '--as-process', 'landing-watch'])
        self.assertEqual(seen[1], ['tightbeam', 'condition', '--kind', 'k'])

    def test_runner_passes_numbers_and_strings_and_omits_nulls(self):
        seen = []

        class Done:
            returncode = 0
            stdout = '{"data": {}}'
            stderr = ''

        original = lw.subprocess.run
        lw.subprocess.run = lambda argv, **kw: seen.append((argv, kw['env'])) or Done()
        try:
            lw.Runner(None).graphql('query Q { x }', {'owner': 'o', 'number': 3, 'cursor': None})
        finally:
            lw.subprocess.run = original
        argv, env = seen[0]
        self.assertIn('owner=o', argv[argv.index('-f', 4) + 1:])
        self.assertEqual(argv[argv.index('-F') + 1], 'number=3')
        self.assertFalse(any(a.startswith('cursor=') for a in argv))
        self.assertEqual(env['GH_PROMPT_DISABLED'], '1')


class PullFacts(WatcherCase):
    def test_merge_files_settled_with_merge_commit_key(self):
        self.github.add(pull(123, state='MERGED', merged=True, merge_oid='ab12'))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.filed, [['condition', '--kind', 'landing.settled', '--scope',
                                              'example/repo#123', '--key',
                                              'landing-fact:example/repo#123:merged:ab12']])
        self.assertIn('episode merged pr=example/repo#123 commit=ab12', self.stream.getvalue())

    def test_each_queue_removal_is_its_own_fact_and_reason_is_logged_verbatim(self):
        self.github.add(pull(123, events=[
            event('RemovedFromMergeQueueEvent', 'RM_1', reason='The merge commit could not be created'),
            event('RemovedFromMergeQueueEvent', 'RM_2', reason=None)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#123:removed:RM_1',
                                              'landing-fact:example/repo#123:removed:RM_2'])
        log = self.stream.getvalue()
        self.assertIn('reason=The merge commit could not be created', log)
        self.assertIn('event=RM_2 reason=unspecified', log)

    def test_automerge_disabled_and_closed_repeat_per_event_when_not_merged(self):
        self.github.add(pull(123, state='CLOSED', events=[
            event('AutoMergeDisabledEvent', 'AD_1', 9), event('AutoMergeDisabledEvent', 'AD_2', 8),
            event('ClosedEvent', 'CE_1', 7), event('ClosedEvent', 'CE_2', 3)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), [
            'landing-fact:example/repo#123:automerge-disabled:AD_1',
            'landing-fact:example/repo#123:automerge-disabled:AD_2',
            'landing-fact:example/repo#123:closed:CE_1',
            'landing-fact:example/repo#123:closed:CE_2'])

    def test_merged_pull_files_no_disabled_or_closed_fact(self):
        self.github.add(pull(123, state='MERGED', merged=True, merge_oid='ab12', events=[
            event('AutoMergeDisabledEvent', 'AD_1'), event('ClosedEvent', 'CE_1')]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#123:merged:ab12'])

    def test_one_occurrence_with_two_events_files_both(self):
        self.github.add(pull(123, events=[event('RemovedFromMergeQueueEvent', 'RM_1'),
                                          event('AutoMergeDisabledEvent', 'AD_1')]))
        self.assertTrue(self.poll())
        self.assertEqual(sorted(self.runner.keys()), ['landing-fact:example/repo#123:automerge-disabled:AD_1',
                                                      'landing-fact:example/repo#123:removed:RM_1'])

    def test_blocked_on_failing_required_check(self):
        self.github.add(pull(123, auto='2026-09-26T11:00:00Z', checks=[
            check_run('CR_1', 'linux', required=True), check_run('CR_2', 'macos', 'SUCCESS', required=True)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(),
                         ['landing-fact:example/repo#123:blocked:2026-09-26T11:00:00Z:CR_1'])

    def test_blocked_by_failing_required_status_uses_context_and_time(self):
        self.github.add(pull(123, auto='2026-09-26T11:00:00Z', checks=[status('ci/legacy', 'ERROR', 4, True)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), [
            f'landing-fact:example/repo#123:blocked:2026-09-26T11:00:00Z:ci/legacy@{ts(4)}'])

    def test_effective_test_merge_failure_overrides_successful_head(self):
        self.github.add(pull(123, auto='E',
                             checks=[check_run('H', 'linux', 'SUCCESS', required=True)],
                             merge_checks=[status('linux', 'FAILURE', 2, True)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), [f'landing-fact:example/repo#123:blocked:E:linux@{ts(2)}'])

    def test_effective_test_merge_success_overrides_failing_head(self):
        self.github.add(pull(123, auto='E', checks=[check_run('H', 'linux', required=True)],
                             merge_checks=[status('linux', 'SUCCESS', 2, True)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.filed, [])

    def test_head_is_effective_when_test_merge_has_no_status(self):
        self.github.add(pull(123, auto='E', checks=[check_run('H', 'linux', required=True)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#123:blocked:E:H'])

    def test_required_check_only_on_test_merge_is_observed(self):
        self.github.add(pull(123, auto='E', merge_checks=[check_run('M', 'linux', required=True)]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#123:blocked:E:M'])

    def test_missing_or_stale_test_merge_is_unknown(self):
        cases = (
            pull(123, auto='E', checks=[check_run('H', 'linux', required=True)], test_merge=None),
            pull(123, auto='E', checks=[check_run('H', 'linux', required=True)], merge_parent='old-head'),
        )
        for item in cases:
            with self.subTest(test_merge=item['test_merge']):
                self.runner.filed.clear()
                self.github.add(item)
                self.assertTrue(self.poll())
                self.assertEqual(self.runner.filed, [])

    def test_required_check_run_and_status_with_same_name_both_count(self):
        self.github.add(pull(123, auto='E', merge_checks=[
            status('linux', 'FAILURE', 9, True),
            check_run('C', 'linux', 'SUCCESS', started=2, required=True),
        ]))
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), [f'landing-fact:example/repo#123:blocked:E:linux@{ts(9)}'])

    def test_not_blocked_cases(self):
        cases = {
            'optional check fails': pull(1, auto='E', checks=[check_run('C', 'lint', required=False),
                                                              check_run('D', 'linux', 'SUCCESS', required=True)]),
            'required check pending': pull(2, auto='E', checks=[check_run('C', 'linux', status='IN_PROGRESS',
                                                                          required=True)]),
            'rerun queued after failure': pull(3, auto='E', checks=[
                check_run('C', 'linux', started=9, required=True),
                check_run('D', 'linux', status='QUEUED', started=None, required=True)]),
            'rerun passed after failure': pull(4, auto='E', checks=[
                check_run('C', 'linux', started=9, required=True),
                check_run('D', 'linux', 'SUCCESS', started=3, required=True)]),
            'already queued': pull(5, auto='E', queued=True, checks=[check_run('C', 'linux', required=True)]),
            'auto-merge off': pull(6, checks=[check_run('C', 'linux', required=True)]),
            'no results': pull(7, auto='E'),
            'rollup is for another commit': pull(8, auto='E', checks_oid='old',
                                                 checks=[check_run('C', 'linux', required=True)]),
            'expected status': pull(9, auto='E', checks=[status('ci/legacy', 'EXPECTED', required=True)]),
        }
        self.github.add(*cases.values())
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.filed, [])

    def test_rerun_failure_and_reenable_make_new_blocked_episodes(self):
        item = pull(123, auto='2026-09-26T11:00:00Z', checks=[check_run('CR_1', 'linux', started=20,
                                                                        required=True)])
        self.github.add(item)
        self.assertTrue(self.poll())
        item['checks'].append(check_run('CR_2', 'linux', started=4, required=True))
        self.assertTrue(self.poll())
        item['autoMergeRequest'] = {'enabledAt': '2026-09-26T11:50:00Z'}
        self.assertTrue(self.poll())
        self.assertEqual(sorted(set(self.runner.keys())), [
            'landing-fact:example/repo#123:blocked:2026-09-26T11:00:00Z:CR_1',
            'landing-fact:example/repo#123:blocked:2026-09-26T11:00:00Z:CR_2',
            'landing-fact:example/repo#123:blocked:2026-09-26T11:50:00Z:CR_2'])

    def test_only_the_two_fact_kinds_and_no_other_wakes(self):
        self.github.add(pull(1, state='MERGED', merged=True, merge_oid='m'),
                        pull(2, auto='E', checks=[check_run('C', 'linux', required=True)]),
                        pull(3, auto='E', checks=[check_run('G', 'linux', 'SUCCESS', required=True)]))
        self.github.rules = [{'type': 'required_status_checks',
                              'parameters': {'required_status_checks': [{'context': 'linux'}]}}]
        self.github.tip_results = [check_run('T', 'linux', 'SUCCESS')]
        self.assertTrue(self.poll())
        kinds = {a[a.index('--kind') + 1] for a in self.runner.filed if a[0] == 'condition'}
        self.assertEqual(kinds, {'landing.settled'})
        self.assertEqual([a for a in self.runner.filed if a[0] == 'wake'], [])


class TipFacts(WatcherCase):
    def require(self, *checks):
        self.github.rules = [{'type': 'pull_request', 'parameters': {}},
                             {'type': 'required_status_checks',
                              'parameters': {'required_status_checks': list(checks)}}]

    def test_red_tip_wakes_owner_before_filing_fact_with_distinct_keys(self):
        self.require({'context': 'linux'}, {'context': 'macos'})
        self.github.tip_oid = 'cd34'
        self.github.tip_results = [check_run('CR_9', 'macos'), check_run('CR_8', 'linux', 'SUCCESS'),
                                   check_run('CR_7', 'docs')]
        self.assertTrue(self.poll())
        wake, fact = self.runner.filed
        self.assertEqual(wake[:9], ['wake', '--role', 'pdo:example', '--when-fact', 'landing.branch-attention',
                                    '--when-scope', 'example/repo@main', '--fallback-after', '10m'])
        self.assertEqual(wake[wake.index('--key') + 1], 'landing-wake:example/repo@main:red:cd34:CR_9')
        prompt = wake[wake.index('--prompt') + 1]
        for part in ('example/repo@main', 'cd34', 'macos', 'https://example.test/runs/CR_9'):
            self.assertIn(part, prompt)
        self.assertEqual(fact, ['condition', '--kind', 'landing.branch-attention', '--scope',
                                'example/repo@main', '--key', 'landing-fact:example/repo@main:red:cd34:CR_9'])
        self.assertNotEqual(wake[wake.index('--key') + 1], fact[-1])

    def test_rerun_on_same_tip_fails_again_as_new_episode(self):
        self.require({'context': 'macos'})
        self.github.tip_results = [check_run('CR_1', 'macos', started=20)]
        self.assertTrue(self.poll())
        self.github.tip_results.append(check_run('CR_2', 'macos', started=3))
        self.assertTrue(self.poll())
        self.assertEqual(sorted(set(self.runner.keys())), ['landing-fact:example/repo@main:red:tip1:CR_1',
                                                           'landing-fact:example/repo@main:red:tip1:CR_2'])

    def test_unrequired_missing_and_pending_results_file_nothing(self):
        self.require({'context': 'linux'}, {'context': 'macos'})
        self.github.tip_results = [check_run('A', 'docs'), check_run('B', 'linux', status='IN_PROGRESS')]
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.filed, [])

    def test_failing_commit_status_counts_on_the_tip(self):
        self.require({'context': 'ci/legacy'})
        self.github.tip_results = [status('ci/legacy', 'FAILURE', 6)]
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), [f'landing-fact:example/repo@main:red:tip1:ci/legacy@{ts(6)}'])

    def test_required_status_failure_is_not_masked_by_same_name_check_success(self):
        self.require({'context': 'linux'})
        self.github.tip_results = [status('linux', 'FAILURE', 9),
                                   check_run('C', 'linux', 'SUCCESS', started=2)]
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), [f'landing-fact:example/repo@main:red:tip1:linux@{ts(9)}'])

    def test_required_app_passes_then_other_app_fails_files_nothing(self):
        self.require({'context': 'linux', 'integration_id': 15368})
        self.github.tip_results = [check_run('A', 'linux', 'SUCCESS', started=9, app=15368),
                                   check_run('B', 'linux', 'FAILURE', started=2, app=999)]
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.filed, [])

    def test_required_app_fails_then_other_app_passes_files_fact(self):
        self.require({'context': 'linux', 'integration_id': 15368})
        self.github.tip_results = [check_run('A', 'linux', 'FAILURE', started=9, app=15368),
                                   check_run('B', 'linux', 'SUCCESS', started=2, app=999)]
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo@main:red:tip1:A'])

    def test_unprovable_source_with_required_app_is_unknown(self):
        self.require({'context': 'linux', 'integration_id': 15368})
        for other in (status('linux', 'SUCCESS', 2), check_run('N', 'linux', 'SUCCESS', started=2, app=None)):
            with self.subTest(other=other['__typename']):
                self.runner.filed.clear()
                self.github.tip_results = [check_run('A', 'linux', 'FAILURE', started=9, app=15368), other]
                self.assertTrue(self.poll())
                self.assertEqual(self.runner.filed, [])

    def test_requirement_without_app_matches_by_name_from_any_source(self):
        self.require({'context': 'linux'})
        self.github.tip_results = [check_run('A', 'linux', 'SUCCESS', started=9, app=15368),
                                   check_run('B', 'linux', 'FAILURE', started=2, app=999)]
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo@main:red:tip1:B'])

    def test_refused_wake_skips_its_fact_and_holds_the_watermark(self):
        self.require({'context': 'macos'})
        self.github.tip_results = [check_run('CR_9', 'macos')]
        self.save_state(30)
        before = self.state()
        self.runner.refuse = lambda args: args[0] == 'wake'
        self.assertFalse(self.poll())
        self.assertEqual(self.runner.filed, [])
        self.assertEqual(self.state(), before)
        self.assertIn('refused wake key=landing-wake:example/repo@main:red:tip1:CR_9', self.stream.getvalue())
        self.runner.refuse = None
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo@main:red:tip1:CR_9'])


class Observation(WatcherCase):
    def test_every_page_of_every_connection_is_read(self):
        self.github.page = 2
        self.github.add(*[pull(n, auto='E', events=[event('AutoMergeDisabledEvent', f'AD_{n}_{i}')
                                                    for i in range(3)],
                               checks=[check_run(f'C{n}_{i}', 'x', 'SUCCESS', required=True)
                                       for i in range(2)] + [check_run(f'F{n}', 'linux', required=True)])
                          for n in range(1, 6)])
        self.github.rules = [{'type': 'required_status_checks',
                              'parameters': {'required_status_checks': [{'context': 'linux'}]}}]
        self.github.tip_results = [check_run('T1', 'x', 'SUCCESS'), check_run('T2', 'y', 'SUCCESS'),
                                   check_run('T3', 'linux')]
        self.assertTrue(self.poll())
        keys = self.runner.keys()
        self.assertEqual(len([k for k in keys if ':automerge-disabled:' in k]), 15)
        self.assertEqual(len([k for k in keys if ':blocked:' in k]), 5)
        self.assertIn('landing-fact:example/repo@main:red:tip1:T3', keys)

    def test_recent_read_stops_at_the_watermark_overlap(self):
        self.github.page = 1
        self.github.add(pull(1, state='CLOSED', updated=5), pull(2, state='CLOSED', updated=35),
                        pull(3, state='CLOSED', updated=50), pull(4, state='CLOSED', updated=500))
        self.save_state(30)
        self.assertTrue(self.poll())
        recent = [v for op, v in self.github.calls if op == 'LandingRecent']
        self.assertEqual(len(recent), 3)  # stops on the page holding PR 3, older than watermark - 10 minutes
        read = [v['number'] for op, v in self.github.calls if op == 'LandingPull']
        self.assertEqual(read, [1, 2])

    def test_recent_read_keeps_cutoff_boundary_and_excludes_older_nodes_on_same_page(self):
        self.github.add(pull(1, state='CLOSED', updated=39), pull(2, state='CLOSED', updated=40),
                        pull(3, state='CLOSED', updated=41), pull(4, state='CLOSED', updated=42))
        self.save_state(30)
        self.assertTrue(self.poll())
        recent = [v for op, v in self.github.calls if op == 'LandingRecent']
        self.assertEqual(len(recent), 1)
        read = [v['number'] for op, v in self.github.calls if op == 'LandingPull']
        self.assertEqual(read, [1, 2])

    def test_since_applies_to_tracked_pulls_and_first_seen_pulls_read_all_history(self):
        self.github.add(pull(1, auto='E', events=[event('AutoMergeDisabledEvent', 'OLD', 600)]),
                        pull(2, events=[event('AutoMergeDisabledEvent', 'OLD2', 600)]))
        self.save_state(30, tracked=[1])
        self.assertTrue(self.poll())
        since = {v['number']: v.get('since') for op, v in self.github.calls if op == 'LandingPull'}
        self.assertEqual(since, {1: ts(40), 2: None})
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#2:automerge-disabled:OLD2'])

    def test_partial_read_files_only_positive_facts_and_holds_the_watermark(self):
        self.github.page = 1
        self.github.add(pull(1, state='MERGED', merged=True, merge_oid='m1', updated=1),
                        pull(2, auto='E', events=[event('RemovedFromMergeQueueEvent', 'RM'),
                                                  event('AutoMergeDisabledEvent', 'AD')],
                             checks=[check_run('C', 'linux', required=True)], updated=2))
        self.github.fail = lambda op, v: op == 'LandingPull' and v['number'] == 2 and v.get('cursor') == '1'
        self.save_state(30)
        before = self.state()
        self.assertFalse(self.poll())
        self.assertEqual(sorted(self.runner.keys()), ['landing-fact:example/repo#1:merged:m1',
                                                      'landing-fact:example/repo#2:removed:RM'])
        self.assertEqual(self.state(), before)
        self.assertIn('poll failed branch=example/repo@main', self.stream.getvalue())

    def test_error_in_a_late_read_withholds_every_absence_fact(self):
        self.github.add(pull(1, state='CLOSED', events=[event('ClosedEvent', 'CE')]),
                        pull(2, auto='E', checks=[check_run('C', 'linux', required=True)]))
        self.github.rules = [{'type': 'required_status_checks',
                              'parameters': {'required_status_checks': [{'context': 'linux'}]}}]
        self.github.tip_results = [check_run('T', 'linux')]
        self.github.fail = lambda op, v: op == 'LandingTip'
        self.assertFalse(self.poll())
        self.assertEqual(self.runner.filed, [])

    def test_null_nodes_are_incomplete_reads(self):
        for operation in ('LandingOpen', 'LandingPull', 'LandingTip'):
            with self.subTest(operation=operation):
                self.runner.filed.clear()
                github = FakeGitHub()
                github.add(pull(1, state='CLOSED', events=[event('ClosedEvent', 'CE')]))
                original = github.graphql

                def nulling(query, variables, original=original, operation=operation):
                    data = original(query, variables)
                    if query.split('query ', 1)[1].startswith(operation):
                        if operation == 'LandingOpen':
                            data['repository']['pullRequests']['nodes'].append(None)
                        elif operation == 'LandingPull':
                            data['repository']['pullRequest'] = None
                        else:
                            data['repository']['ref'] = None
                    return data

                github.graphql = nulling
                self.runner.github = github
                self.assertFalse(self.poll())
                self.assertEqual(self.runner.filed, [])

    def test_rules_error_withholds_absence_facts(self):
        self.github.add(pull(1, state='CLOSED', events=[event('ClosedEvent', 'CE')]))
        self.github.fail = lambda op, v: op == 'rest'
        self.assertFalse(self.poll())
        self.assertEqual(self.runner.filed, [])


class State(WatcherCase):
    def test_cold_start_uses_24_hours_and_saves_open_pulls(self):
        self.github.page = 1
        self.github.add(pull(1), pull(2, state='CLOSED', updated=23 * 60),
                        pull(3, state='CLOSED', updated=25 * 60), pull(4, state='CLOSED', updated=30 * 60))
        self.assertTrue(self.poll())
        read = [v['number'] for op, v in self.github.calls if op == 'LandingPull']
        self.assertEqual(read, [1, 2])  # the recent read excludes the first pull older than 24 hours + overlap
        self.assertEqual(self.state(), {'version': 1, 'watermark': lw.iso(NOW), 'tracked': [1]})

    def test_cold_start_excludes_old_nodes_from_the_first_recent_page(self):
        self.github.add(pull(1, state='CLOSED', updated=23 * 60),
                        pull(2, state='CLOSED', updated=24 * 60),
                        pull(3, state='CLOSED', updated=25 * 60))
        self.assertTrue(self.poll())
        recent = [v for op, v in self.github.calls if op == 'LandingRecent']
        self.assertEqual(len(recent), 1)
        read = [v['number'] for op, v in self.github.calls if op == 'LandingPull']
        self.assertEqual(read, [1, 2])

    def test_resume_reads_tracked_pull_that_merged_during_an_outage(self):
        self.github.add(pull(7, state='MERGED', merged=True, merge_oid='mm', updated=3 * 24 * 60))
        self.save_state(3 * 24 * 60 + 30, tracked=[7])
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#7:merged:mm'])
        self.assertEqual(self.state()['tracked'], [])

    def test_refused_fact_holds_watermark_and_retries(self):
        self.github.add(pull(1, state='CLOSED', events=[event('ClosedEvent', 'CE')]))
        self.save_state(30)
        before = self.state()
        self.runner.refuse = lambda args: True
        self.assertFalse(self.poll())
        self.assertEqual(self.state(), before)
        self.assertIn('refused fact key=landing-fact:example/repo#1:closed:CE reason=refused by fake gateway',
                      self.stream.getvalue())
        self.runner.refuse = None
        self.assertTrue(self.poll())
        self.assertEqual(self.state()['watermark'], lw.iso(NOW))

    def test_repeat_polls_reuse_keys_and_log_each_episode_once(self):
        self.github.add(pull(1, state='CLOSED', events=[event('ClosedEvent', 'CE')]))
        self.assertTrue(self.poll())
        self.clock = NOW + dt.timedelta(minutes=1)
        self.assertTrue(self.poll())
        self.assertEqual(self.runner.keys(), ['landing-fact:example/repo#1:closed:CE'] * 2)
        self.assertEqual(self.stream.getvalue().count('episode closed'), 1)

    def test_state_write_is_atomic_and_leaves_no_temporary_file(self):
        self.save_state(30, tracked=[3, 1])
        self.assertEqual(os.listdir(self.tmp.name), ['example-repo-main.json'])
        self.assertEqual(self.state()['tracked'], [1, 3])
        original = os.replace
        os.replace = lambda *a: (_ for _ in ()).throw(OSError('disk full'))
        try:
            with self.assertRaises(OSError):
                self.save_state(1, tracked=[9])
        finally:
            os.replace = original
        self.assertEqual(os.listdir(self.tmp.name), ['example-repo-main.json'])
        self.assertEqual(self.state()['tracked'], [1, 3])

    def test_malformed_state_refuses(self):
        path = os.path.join(self.tmp.name, 'example-repo-main.json')
        for body in ('not json', '{"version": 2, "watermark": "2026-09-26T00:00:00Z", "tracked": []}',
                     '{"version": 1, "watermark": "yesterday", "tracked": []}',
                     '{"version": 1, "watermark": "2026-09-26T00:00:00Z", "tracked": ["1"]}'):
            with self.subTest(body=body):
                with open(path, 'w') as handle:
                    handle.write(body)
                with self.assertRaises(lw.SettingsError):
                    self.watcher().load()


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

    def test_once_polls_and_saves_state(self):
        done = self.run_program('--once', LANDING_WATCH_AS_PROCESS='landing-watch')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('start login=example-bot branches=example/repo@main', done.stderr)
        state = json.loads((Path(self.tmp.name) / 'state/landing-watch/example-repo-main.json').read_text())
        self.assertEqual((state['version'], state['tracked']), (1, []))
        self.assertFalse(self.calls.exists())  # nothing to file on an empty repository


if __name__ == '__main__':
    unittest.main()
