"""Deterministic contract checks for the prelanding CI entry point (stdlib only)."""
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

    def test_dispatch_is_explicit_and_preserves_events(self):
        self.assertIn('branches: [main]', self.text)
        self.assertIn('tags: ["v*.*.*"]', self.text)
        self.assertIn('  pull_request:', self.text)
        self.assertRegex(self.text, r'workflow_dispatch:\n    inputs:\n      candidate_sha:')
        self.assertIn('        required: true\n        type: string', self.text)
        self.assertIn("CI_SOURCE_SHA: ${{ github.event_name != 'workflow_dispatch' && github.sha || inputs.candidate_sha }}", self.text)

    def test_both_jobs_validate_before_exact_checkout(self):
        for name in ('test', 'release'):
            job = self.jobs[name]
            self.assertLess(job.index('Validate exact source SHA'), job.index('uses: actions/checkout'))
            self.assertIn('ref: ${{ env.CI_SOURCE_SHA }}', job)
            self.assertIn('run: test "$(git rev-parse HEAD)" = "$CI_SOURCE_SHA"', job)
            self.assertLess(job.index('Verify exact checkout'), job.index('uses: erlef/setup-beam'))

    def test_sha_validation_executes_and_rejects_invalid_values(self):
        for name in ('test', 'release'):
            guard = re.search(r'run: \|\n          (\[\[.*?\]\] \|\| exit 1)', self.jobs[name]).group(1)
            for value, expected in [('a' * 40, 0), ('', 1), ('a' * 39, 1),
                                    ('a' * 41, 1), ('A' * 40, 1), ('main', 1),
                                    ('a' * 40 + '\n', 1), ('$(false)', 1)]:
                with tempfile.TemporaryDirectory(prefix='exact-head-ci-') as base:
                    result = subprocess.run(['bash', '-c', guard], cwd=base,
                                            env={**os.environ, 'CI_SOURCE_SHA': value})
                self.assertEqual(result.returncode, expected, (name, value))

    def test_checkout_guard_rejects_mismatch(self):
        for name in ('test', 'release'):
            guard = re.search(r'run: (test .*CI_SOURCE_SHA")', self.jobs[name]).group(1)
            for actual, expected in [('a' * 40, 0), ('b' * 40, 1)]:
                with tempfile.TemporaryDirectory(prefix='exact-checkout-') as base:
                    result = subprocess.run(['bash', '-c',
                        'git() { printf "%s" "$ACTUAL_SHA"; }; ' + guard], cwd=base,
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
        self.assertIn("if: github.event_name == 'workflow_dispatch' ||", job)
        self.assertIn('${CI_SOURCE_SHA::7}.tgz', job)
        self.assertNotIn('${GITHUB_SHA::7}.tgz', job)

    def test_verification_never_publishes_or_needs_write(self):
        self.assertIn('permissions:\n  contents: read', self.text)
        for name in ('test', 'release'):
            self.assertNotIn('contents: write', self.jobs[name])
        self.assertIn("if: github.event_name != 'workflow_dispatch' && startsWith(github.ref, 'refs/tags/v')",
                      self.jobs['publish-release'])
        self.assertIn('    needs: release', self.jobs['publish-release'])

    def test_no_retired_branch_dependency(self):
        self.assertNotIn('release-candidate/', self.text)


if __name__ == '__main__':
    unittest.main()
