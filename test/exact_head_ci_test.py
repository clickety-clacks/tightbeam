"""Deterministic contract checks for exact-candidate CI (stdlib only)."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml'


def evaluate(expression, context):
    """Evaluate the small GitHub expression subset this workflow uses."""
    tokens = re.findall(
        r"\s*(&&|\|\||!=|==|[(),]|'[^']*'|startsWith|[A-Za-z_][\w.-]*)", expression)
    if ''.join(tokens) != re.sub(r'\s+', '', expression):
        raise ValueError('unsupported expression: ' + expression)
    words = {'&&': ' and ', '||': ' or ', '!=': ' != ', '==': ' == ',
             '(': '(', ')': ')', ',': ',', 'startsWith': '_starts'}
    code = ''.join(
        words.get(token) or (repr(token[1:-1]) if token.startswith("'")
                             else repr(context[token]))
        for token in tokens)
    return eval(code, {'__builtins__': {}, '_starts': lambda s, p: s.startswith(p)})


class ExactHeadCI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text()
        cls.jobs = dict(re.findall(
            r'^  (test|release|publish-release):\n(.*?)(?=^  [\w-]+:\n|\Z)',
            cls.text, re.M | re.S))

    def test_dispatch_keeps_019_and_tag_triggers(self):
        self.assertIn('branches: ["0.1.*"]', self.text)
        self.assertIn('tags: ["v*.*.*"]', self.text)
        self.assertIn('  pull_request:', self.text)
        self.assertRegex(self.text, r'workflow_dispatch:\n    inputs:\n      candidate_sha:')
        self.assertIn('        required: true\n        type: string', self.text)
        self.assertIn(
            "CI_SOURCE_SHA: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.event_name != 'workflow_dispatch' && github.sha || inputs.candidate_sha }}",
            self.text)
        self.assertNotIn('branches: [main]', self.text)

    def test_pull_request_checks_its_head_and_other_events_keep_their_source(self):
        source = re.search(r'CI_SOURCE_SHA: \$\{\{ (.*?) \}\}', self.text).group(1)
        for event, expected in [('pull_request', 'a' * 40), ('push', 'b' * 40),
                                ('merge_group', 'b' * 40), ('workflow_dispatch', 'c' * 40)]:
            context = {'github.event_name': event, 'github.sha': 'b' * 40,
                       'github.event.pull_request.head.sha': 'a' * 40,
                       'inputs.candidate_sha': 'c' * 40}
            self.assertEqual(evaluate(source, context), expected, event)

    def test_both_jobs_validate_before_exact_checkout(self):
        for name in ('test', 'release'):
            job = self.jobs[name]
            self.assertLess(job.index('Validate exact source SHA'), job.index('uses: actions/checkout'))
            self.assertIn('ref: ${{ env.CI_SOURCE_SHA }}', job)
            self.assertIn('run: test "$(git rev-parse HEAD)" = "$CI_SOURCE_SHA"', job)
            self.assertLess(job.index('Verify exact checkout'), job.index('uses: erlef/setup-beam'))
            first_gate = (
                'run: sh packaging/assemble.sh' if name == 'release'
                else 'run: python3 scripts/verify_shipped_privacy.py'
            )
            self.assertLess(job.index('Verify exact checkout'), job.index(first_gate))
        test_job = self.jobs['test']
        contract_check = 'run: python3 test/exact_head_ci_test.py'
        privacy_check = 'run: python3 scripts/verify_shipped_privacy.py'
        self.assertIn(contract_check, test_job)
        self.assertLess(test_job.index(contract_check), test_job.index(privacy_check))

    def test_full_history_precedes_history_sensitive_checks(self):
        for name in ('test', 'release'):
            job = self.jobs[name]
            checkout = re.search(
                r'uses: actions/checkout@v4\n(.*?)(?=\n      -)', job, re.S).group(1)
            self.assertRegex(checkout, r'(?m)^          fetch-depth: 0$')
        self.assertLess(
            self.jobs['test'].index('uses: actions/checkout'),
            self.jobs['test'].index('run: python3 scripts/verify_public_rule_facts.py'))

    def test_sha_validation_executes_and_rejects_invalid_values(self):
        for name in ('test', 'release'):
            guard = re.search(
                r'run: \|\n          (\[\[.*?\]\] \|\| exit 1)', self.jobs[name]).group(1)
            for value, expected in [('a' * 40, 0), ('', 1), ('a' * 39, 1),
                                    ('a' * 41, 1), ('A' * 40, 1), ('main', 1),
                                    ('a' * 40 + '\n', 1), ('$(false)', 1)]:
                with tempfile.TemporaryDirectory(prefix='exact-head-ci-') as base:
                    result = subprocess.run(
                        ['bash', '-c', guard], cwd=base,
                        env={**os.environ, 'CI_SOURCE_SHA': value})
                self.assertEqual(result.returncode, expected, (name, value))

    def test_checkout_guard_rejects_mismatch(self):
        for name in ('test', 'release'):
            guard = re.search(
                r'run: (test .*CI_SOURCE_SHA")', self.jobs[name]).group(1)
            for actual, expected in [('a' * 40, 0), ('b' * 40, 1)]:
                with tempfile.TemporaryDirectory(prefix='exact-checkout-') as base:
                    result = subprocess.run(
                        ['bash', '-c',
                         'git() { printf "%s" "$ACTUAL_SHA"; }; ' + guard],
                        cwd=base,
                        env={**os.environ, 'CI_SOURCE_SHA': 'a' * 40, 'ACTUAL_SHA': actual})
                self.assertEqual(result.returncode, expected)

    def test_packages_wait_for_tests_and_stamp_candidate(self):
        job = self.jobs['release']
        self.assertIn('    needs: test', job)
        self.assertIn(
            "if: github.event_name != 'merge_group' && "
            "(startsWith(github.ref, 'refs/heads/0.1.') || startsWith(github.ref, 'refs/tags/v'))",
            job)
        self.assertIn('${CI_SOURCE_SHA::7}.tgz', job)
        self.assertNotIn('${GITHUB_SHA::7}.tgz', job)

    def test_only_selected_maintenance_tags_use_directly_affected_mix_checks(self):
        test_job = self.jobs['test']
        targeted_release = re.search(
            r'(?m)^      TARGETED_GUARD_RELEASE: \$\{\{ (.*?) \}\}$', test_job).group(1)
        quiet_release = re.search(
            r'(?m)^      TARGETED_QUIET_RELEASE: \$\{\{ (.*?) \}\}$', test_job).group(1)
        full_suite = re.search(
            r'(?m)^      FULL_SUITE: \$\{\{ (.*?) \}\}$', test_job).group(1)
        targeted_step = re.search(
            r'(?ms)^      - name: Run directly affected successor and wake checks\n'
            r'(.*?)(?=^      - name:|\Z)', test_job).group(1)
        quiet_step = re.search(
            r'(?ms)^      - name: Run directly affected quiet progress checks\n'
            r'(.*?)(?=^      - name:|\Z)', test_job).group(1)
        quiet_condition = re.search(
            r'(?m)^        if: (.*)$', quiet_step).group(1)
        targeted_condition = re.search(
            r'(?m)^        if: (.*)$', targeted_step).group(1)

        cases = [
            ('push', 'refs/tags/v0.1.9+2857', False, True, False),
            ('push', 'refs/tags/v0.1.9+2880', False, False, True),
            ('push', 'refs/tags/v0.1.9+2855', True, False, False),
            ('push', 'refs/tags/v0.1.9+2856', True, False, False),
            ('push', 'refs/tags/v0.1.9+2858', True, False, False),
            ('push', 'refs/tags/v0.1.9+2879', True, False, False),
            ('push', 'refs/tags/v0.1.9+2881', True, False, False),
            ('push', 'refs/tags/v0.1.10+2880', True, False, False),
            ('push', 'refs/tags/v0.1.10+2857', True, False, False),
            ('workflow_dispatch', 'refs/tags/v0.1.9+2857', True, False, False),
            ('workflow_dispatch', 'refs/tags/v0.1.9+2880', True, False, False),
            ('push', 'refs/heads/0.1.9', False, False, False),
            ('pull_request', 'refs/tags/v0.1.9+2857', False, False, False),
            ('pull_request', 'refs/tags/v0.1.9+2880', False, False, False),
            ('merge_group', 'refs/tags/v0.1.9+2880', False, False, False),
        ]
        for event, ref, expected_full, expected_guard, expected_quiet in cases:
            context = {'github.event_name': event, 'github.ref': ref}
            self.assertEqual(evaluate(targeted_release, context), expected_guard)
            self.assertEqual(evaluate(quiet_release, context), expected_quiet)
            self.assertEqual(evaluate(full_suite, context), expected_full)
            context.update({
                'env.TARGETED_GUARD_RELEASE': str(expected_guard).lower(),
                'env.TARGETED_QUIET_RELEASE': str(expected_quiet).lower(),
            })
            self.assertEqual(evaluate(targeted_condition, context),
                             expected_guard or expected_quiet)
            self.assertEqual(evaluate(quiet_condition, context), expected_quiet)

        for name in (
            'Toolchain versions (the parity record)',
            'Put the in-repo harness CLI on PATH (suite prerequisite)',
            'Declare a git identity (suite prerequisite)',
            'cargo build --release (suite prerequisite)',
            'Put the source-built Tightbeam CLI on PATH (suite prerequisite)',
        ):
            step = re.search(
                r'(?ms)^      - name: ' + re.escape(name) +
                r'\n(.*?)(?=^      - name:|\Z)', test_job).group(1)
            condition = re.search(r'(?m)^        if: (.*)$', step).group(1)
            for event, ref, expected_full_suite, expected_targeted, expected_quiet in cases:
                context = {
                    'github.event_name': event,
                    'github.ref': ref,
                    'env.FULL_SUITE': 'true' if expected_full_suite else 'false',
                    'env.TARGETED_GUARD_RELEASE': 'true' if expected_targeted else 'false',
                    'env.TARGETED_QUIET_RELEASE': 'true' if expected_quiet else 'false',
                }
                self.assertEqual(evaluate(condition, context),
                                 expected_full_suite or expected_targeted or expected_quiet,
                                 (name, event, ref))

        for name in ('mix test', 'cargo test'):
            step = re.search(
                r'(?ms)^      - name: ' + re.escape(name) +
                r'\n(.*?)(?=^      - name:|\Z)', test_job).group(1)
            condition = re.search(r'(?m)^        if: (.*)$', step).group(1)
            self.assertEqual(condition, "env.FULL_SUITE == 'true'")

        for selector in (
            'test/late_ruling_handoff_test.exs',
            'test/row_driven_waits_test.exs:1297',
            'test/row_driven_waits_test.exs:305',
            'test/row_driven_waits_test.exs:598',
            'test/row_driven_waits_test.exs:771',
            'test/row_driven_waits_test.exs:1028',
            'test/row_driven_waits_test.exs:1633',
            'test/row_driven_waits_test.exs:1696',
            'test/session_reparent_test.exs:638',
            'test/refix_requires_diagnosis_test.exs:76',
            'test/verification_papertrail_test.exs:383',
        ):
            self.assertIn(selector, targeted_step)

    def test_quiet_selectors_cover_the_affected_notice_and_upgrade_paths(self):
        step = re.search(
            r'(?ms)^      - name: Run directly affected quiet progress checks\n'
            r'(.*?)(?=^      - name:|\Z)', self.jobs['test']).group(1)
        expected = [
            'row_reaction_expression', 'row_reaction_plan', 'row_reaction_store',
            'row_reaction_notice', 'row_reaction_attest', 'row_reaction_request',
            'row_reaction_start', 'row_reaction_handoff_snapshot',
            'row_reaction_terminal_cutover', 'completion_handoff_light_rail',
            'schema_shape',
        ]
        selectors = re.findall(r'test/[a-z_]+_test\.exs', step)
        self.assertEqual(selectors, ['test/' + name + '_test.exs' for name in expected])
        self.assertIn('scripts/verify_mix.sh', step)
        for selector in selectors:
            self.assertTrue((WORKFLOW.parents[2] / selector).is_file(), selector)

    def test_manual_tag_verification_cannot_publish_or_get_write_permission(self):
        release = self.jobs['release']
        publish = self.jobs['publish-release']
        self.assertIn(
            "if: github.event_name != 'workflow_dispatch' && startsWith(github.ref, 'refs/tags/v')",
            release)
        self.assertIn(
            'run: sh scripts/validate_release_tag.sh "$GITHUB_REF_NAME" "$GITHUB_SHA"',
            release)
        self.assertIn('permissions:\n      contents: write', publish)
        self.assertIn('    needs: release', publish)
        self.assertIn(
            "if: github.event_name != 'workflow_dispatch' && startsWith(github.ref, 'refs/tags/v')",
            publish)
        self.assertNotIn('contents: write', self.jobs['test'])
        self.assertNotIn('contents: write', release)
        self.assertIn('permissions:\n  contents: read', self.text)

    def test_merge_group_tests_group_head_under_required_names(self):
        self.assertRegex(self.text, r'(?m)^  merge_group:$')
        source = re.search(r'CI_SOURCE_SHA: \$\{\{ (.*?) \}\}', self.text).group(1)
        context = {'github.event_name': 'merge_group', 'github.sha': 'c' * 40,
                   'github.event.pull_request.head.sha': '',
                   'github.ref': 'refs/heads/gh-readonly-queue/0.1.9/pr-12-' + 'a' * 40,
                   'inputs.candidate_sha': ''}
        self.assertEqual(evaluate(source, context), 'c' * 40)
        test_job = self.jobs['test']
        self.assertIn('    name: ${{ matrix.name }}', test_job)
        self.assertEqual(re.findall(r'(?m)^            name: (\S+)$', test_job),
                         ['linux', 'macos'])
        condition = re.search(r'(?m)^    if: (.*)$', test_job).group(1)
        for event in ('merge_group', 'pull_request', 'push'):
            for mode in ('', 'off', 'on'):
                self.assertTrue(evaluate(condition, {
                    'github.event_name': event, 'inputs.docs_validation': mode}))

    def test_only_explicit_docs_dispatch_skips_existing_matrix(self):
        condition = re.search(r'(?m)^    if: (.*)$', self.jobs['test']).group(1)
        for mode, expected in (('', True), ('off', True), ('on', False)):
            self.assertEqual(evaluate(condition, {
                'github.event_name': 'workflow_dispatch',
                'inputs.docs_validation': mode}), expected)

    def test_docs_dispatch_is_hosted_read_only_and_subject_bound(self):
        job = self.text.split('\n  docs-validation:\n', 1)[1]
        condition = re.search(r'(?m)^    if: (.*)$', job).group(1)
        for event in ('push', 'pull_request', 'merge_group', 'workflow_dispatch'):
            for mode in ('', 'off', 'on'):
                self.assertEqual(evaluate(condition, {
                    'github.event_name': event, 'inputs.docs_validation': mode}),
                    event == 'workflow_dispatch' and mode == 'on')
        self.assertIn('runs-on: ${{ matrix.os }}', job)
        self.assertIn('os: [ubuntu-latest, macos-latest]', job)
        self.assertNotIn('self-hosted', job)
        self.assertIn('permissions:\n      contents: read', job)
        self.assertNotIn('contents: write', job)
        self.assertIn('persist-credentials: false', job)
        self.assertIn('test "$DISPATCH_SHA" = "$CI_SOURCE_SHA"', job)
        self.assertIn('test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"', job)
        self.assertIn('python3 scripts/verify_shipped_privacy.py', job)
        self.assertIn('sh packaging/assemble.sh', job)
        self.assertIn('mix run --no-start scripts/docs_composition_52.exs', job)
        self.assertIn('if: always() && steps.evidence.outputs.path', job)

    def test_merge_group_never_packages_or_publishes(self):
        queue_ref = 'refs/heads/gh-readonly-queue/0.1.9/pr-12-' + 'a' * 40
        conditions = {name: re.search(r'(?m)^    if: (.*)$', self.jobs[name]).group(1)
                      for name in ('release', 'publish-release')}
        # Packaging refuses the event itself, whatever ref it carries.
        for ref in (queue_ref, 'refs/heads/0.1.9', 'refs/tags/v0.1.9'):
            context = {'github.event_name': 'merge_group', 'github.ref': ref}
            self.assertFalse(evaluate(conditions['release'], context), ref)
        # Publication needs packaging, and refuses the queue ref on its own.
        self.assertIn('    needs: release', self.jobs['publish-release'])
        context = {'github.event_name': 'merge_group', 'github.ref': queue_ref}
        self.assertFalse(evaluate(conditions['publish-release'], context))
        for name in ('release', 'publish-release'):
            context = {'github.event_name': 'push', 'github.ref': 'refs/tags/v0.1.9'}
            self.assertTrue(evaluate(conditions[name], context), name)
        context = {'github.event_name': 'push', 'github.ref': 'refs/heads/0.1.9'}
        self.assertTrue(evaluate(conditions['release'], context))

    def test_no_retired_branch_dependency(self):
        self.assertNotIn('release-candidate/', self.text)


if __name__ == '__main__':
    unittest.main()
