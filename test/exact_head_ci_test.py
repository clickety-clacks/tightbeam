"""Deterministic contract checks for exact-candidate CI (stdlib only)."""
import ast
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml'


def equal(left, right):
    # Actions ignores case when comparing strings. Keep returned operands
    # unchanged: AND/OR routing returns runner labels, not folded strings.
    if isinstance(left, str) and isinstance(right, str):
        return left.casefold() == right.casefold()
    return left == right


class ActionsComparisons(ast.NodeTransformer):
    def visit_Compare(self, node):
        self.generic_visit(node)
        if len(node.ops) != 1 or not isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
            raise ValueError('unsupported comparison')
        comparison = ast.Call(func=ast.Name(id='_equal', ctx=ast.Load()),
                              args=[node.left, node.comparators[0]], keywords=[])
        if isinstance(node.ops[0], ast.NotEq):
            return ast.UnaryOp(op=ast.Not(), operand=comparison)
        return comparison


def evaluate(expression, context):
    """Evaluate the small GitHub expression subset this workflow uses."""
    token_pattern = re.compile(
        r"\s*(&&|\|\||!=|==|[(),]|'[^']*'|startsWith|[A-Za-z_][\w.-]*)")
    tokens = []
    position = 0
    for match in token_pattern.finditer(expression):
        if expression[position:match.start()].strip():
            raise ValueError('unsupported expression: ' + expression)
        tokens.append(match.group(1))
        position = match.end()
    if expression[position:].strip():
        raise ValueError('unsupported expression: ' + expression)
    words = {'&&': ' and ', '||': ' or ', '!=': ' != ', '==': ' == ',
             '(': '(', ')': ')', ',': ',', 'startsWith': '_starts',
             'format': '_format', 'fromJSON': '_json'}
    code = ''.join(
        words.get(token) or (repr(token[1:-1]) if token.startswith("'")
                             else repr(context[token]))
        for token in tokens)
    tree = ast.fix_missing_locations(ActionsComparisons().visit(ast.parse(code, mode='eval')))
    return eval(compile(tree, '<actions-expression>', 'eval'), {
                       '__builtins__': {}, '_equal': equal,
                       '_starts': lambda s, p: s.startswith(p),
                       '_format': lambda f, *a: f.format(*a), '_json': json.loads})


class ExactHeadCI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text()
        cls.jobs = dict(re.findall(
            r'^  (test|release):\n(.*?)(?=^  [\w-]+:\n|\Z)',
            cls.text, re.M | re.S))

    def test_expression_string_comparisons_follow_actions_case_semantics(self):
        # https://docs.github.com/en/actions/reference/workflows-and-actions/expressions
        self.assertTrue(evaluate("'Main' == 'main'", {}))
        self.assertFalse(evaluate("'MAIN' != 'main'", {}))
        self.assertEqual(evaluate("'Main' == 'main' && 'MacOS-Label' || 'fallback'", {}),
                         'MacOS-Label')

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

    def test_manual_tag_verification_cannot_publish_or_get_write_permission(self):
        release = self.jobs['release']
        publish = (WORKFLOW.parent / 'publish-release.yml').read_text()
        self.assertIn(
            "if: github.event_name != 'workflow_dispatch' && startsWith(github.ref, 'refs/tags/v')",
            release)
        self.assertIn(
            'run: sh scripts/validate_release_tag.sh "$GITHUB_REF_NAME" "$GITHUB_SHA"',
            release)
        self.assertNotIn('publish-release:', self.text)
        self.assertNotIn('Create the GitHub Release', self.text)
        self.assertIn('workflow_dispatch:', publish)
        self.assertIn('contents: write', publish)
        self.assertIn('actions: read', publish)
        self.assertIn('run-id: ${{ inputs.candidate_run_id }}', publish)
        self.assertIn('install_approved_sha:', publish)
        self.assertIn('soak_outcome:', publish)
        self.assertIn('sha256sum --check SHA256SUMS', publish)
        self.assertIn('release-candidate-proof-${{ inputs.candidate_sha }}', publish)
        self.assertIn('contents: read', self.text)
        self.assertNotIn('contents: write', self.jobs['test'])
        self.assertNotIn('contents: write', release)


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
        self.assertIn('EXPECTED_BASE: ${{ inputs.candidate_base_sha }}', job)
        self.assertIn('[[ "$EXPECTED_BASE" =~ ^[0-9a-f]{40}$ ]] || exit 1', job)
        self.assertIn('git cat-file -e "$EXPECTED_BASE^{commit}"', job)
        self.assertIn('test "$(git merge-base HEAD "$EXPECTED_BASE")" = "$EXPECTED_BASE"', job)
        self.assertIn('git diff --exit-code "$EXPECTED_BASE" HEAD -- priv', job)
        self.assertNotIn('git rev-parse HEAD^)', job)
        self.assertIn('python3 scripts/verify_shipped_privacy.py', job)
        self.assertIn('sh packaging/assemble.sh', job)
        self.assertIn('mix run --no-start scripts/docs_composition_52.exs', job)
        self.assertIn('if: always() && steps.evidence.outputs.path', job)

    def test_merge_group_never_packages_or_publishes(self):
        queue_ref = 'refs/heads/gh-readonly-queue/0.1.9/pr-12-' + 'a' * 40
        condition = re.search(r'(?m)^    if: (.*)$', self.jobs['release']).group(1)
        # Packaging refuses the event itself, whatever ref it carries.
        for ref in (queue_ref, 'refs/heads/0.1.9', 'refs/tags/v0.1.9'):
            self.assertFalse(evaluate(condition, {
                'github.event_name': 'merge_group', 'github.ref': ref}), ref)
        publish = (WORKFLOW.parent / 'publish-release.yml').read_text()
        self.assertIn('workflow_dispatch:', publish)
        self.assertNotIn('merge_group:', publish)
        self.assertNotIn('on:\n  push:', publish)


    def test_full_suites_run_on_every_event(self):
        # The suites are the gate on pull requests too: no event switch may
        # turn the test job back into a compile-only check.
        self.assertNotIn('FULL_SUITE', self.text)
        job = self.jobs['test']
        steps = job.split('\n      - ')
        for command in ('run: cargo build --release', 'run: scripts/verify_mix.sh',
                        'run: cargo test'):
            matching = [step for step in steps if command in step]
            self.assertEqual(len(matching), 1, command)
            self.assertNotRegex(matching[0], r'(?m)^        if:', command)
        condition = re.search(r'(?m)^    if: (.*)$', job).group(1)
        for event in ('pull_request', 'merge_group', 'push', 'workflow_dispatch'):
            self.assertTrue(evaluate(condition, {
                'github.event_name': event, 'inputs.docs_validation': 'off'}), event)

    def test_runner_routing_by_event_ref_and_platform(self):
        # Evaluate the actual workflow expression: only macOS pushes and
        # manual main suites use the existing self-hosted pool. The main-ref
        # comparison follows Actions' case-insensitive string equality.
        job = self.jobs['test']
        routing = re.search(r'(?m)^    runs-on: \$\{\{ (.*) \}\}$', job).group(1)
        self.assertEqual(re.findall(r'(?m)^          - os: (\S+)$', job),
                         ['ubuntu-24.04', 'macos-latest'])
        refs = ('refs/heads/main', 'refs/heads/Main', 'refs/heads/MAIN',
                'refs/heads/main-fix', 'refs/heads/0.1.16',
                'refs/tags/v0.1.16', 'refs/pull/12/merge',
                'refs/heads/gh-readonly-queue/main/pr-12-' + 'a' * 40)
        for platform, hosted in (('linux', 'ubuntu-24.04'), ('macos', 'macos-latest')):
            for event in ('push', 'workflow_dispatch', 'pull_request', 'merge_group'):
                for ref in refs:
                    # Fork and same-repository PRs must both stay hosted.
                    for fork in (False, True) if event == 'pull_request' else (False,):
                        with self.subTest(platform=platform, event=event, ref=ref, fork=fork):
                            expected = hosted
                            if platform == 'macos' and (
                                    event == 'push' or
                                    (event == 'workflow_dispatch' and
                                     ref.casefold() == 'refs/heads/main')):
                                expected = ['self-hosted', 'tb-macos']
                            self.assertEqual(evaluate(routing, {
                                'matrix.name': platform, 'matrix.os': hosted,
                                'github.event_name': event, 'github.ref': ref,
                                'github.event.pull_request.head.repo.fork': fork,
                            }), expected)

    def test_self_hosted_mac_checks_disk_before_the_suite(self):
        job = self.jobs['test']
        self.assertLess(
            job.index('name: Require free disk space on the self-hosted macOS runner'),
            job.index('run: scripts/verify_mix.sh'))
        self.assertIn("if: runner.os == 'macOS' && runner.environment == 'self-hosted'", job)

    def test_only_a_superseded_pull_request_run_is_cancelled(self):
        group = re.search(r'(?m)^  group: \$\{\{ (.*) \}\}$', self.text).group(1)
        cancel = re.search(r'(?m)^  cancel-in-progress: \$\{\{ (.*) \}\}$', self.text).group(1)
        base = {'github.event.pull_request.number': 12, 'github.run_id': 99}
        self.assertEqual(
            evaluate(group, {**base, 'github.event_name': 'pull_request'}), 'ci-pr-12')
        self.assertTrue(evaluate(cancel, {'github.event_name': 'pull_request'}))
        for event in ('push', 'merge_group', 'workflow_dispatch'):
            self.assertEqual(
                evaluate(group, {**base, 'github.event_name': event}), 'ci-run-99', event)
            self.assertFalse(evaluate(cancel, {'github.event_name': event}), event)

    def test_no_retired_branch_dependency(self):
        self.assertNotIn('release-candidate/', self.text)


if __name__ == '__main__':
    unittest.main()
