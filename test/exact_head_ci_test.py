"""Deterministic contract checks for exact-candidate CI (stdlib only)."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/ci.yml'


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
            "CI_SOURCE_SHA: ${{ github.event_name != 'workflow_dispatch' && github.sha || inputs.candidate_sha }}",
            self.text)
        self.assertNotIn('branches: [main]', self.text)

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

    def test_platforms_and_existing_gates(self):
        for name in ('test', 'release'):
            for platform in ('ubuntu-latest', 'macos-latest'):
                self.assertIn('os: ' + platform, self.jobs[name])
            self.assertIn('otp-version: "28"', self.jobs[name])
            self.assertIn('elixir-version: "1.19.5"', self.jobs[name])
        for command in ('scripts/verify_mix.sh', 'cargo test', 'cargo fmt --check',
                        'mix format --check-formatted'):
            self.assertIn('run: ' + command, self.jobs['test'])
        self.assertIn('run: sh packaging/assemble.sh', self.jobs['release'])

    def test_packages_wait_for_tests_and_stamp_candidate(self):
        job = self.jobs['release']
        self.assertIn('    needs: test', job)
        self.assertIn(
            "if: startsWith(github.ref, 'refs/heads/0.1.') || startsWith(github.ref, 'refs/tags/v')",
            job)
        self.assertIn('${CI_SOURCE_SHA::7}.tgz', job)
        self.assertNotIn('${GITHUB_SHA::7}.tgz', job)

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

    def test_no_retired_branch_dependency(self):
        self.assertNotIn('release-candidate/', self.text)


if __name__ == '__main__':
    unittest.main()
