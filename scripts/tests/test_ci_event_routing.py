"""Exercise the actual native admission expressions, including their negative paths."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def condition(source, job):
    block = source.split('\n  ' + job + ':\n', 1)[1]
    block = re.split(r'\n  [\w-]+:\n', block, maxsplit=1)[0]
    found = re.search(r'^    if: (.+)(?:\n|$)', block, re.M)
    value = found[1]
    if value == '>-':
        value = ' '.join(re.match(r'(?:      .*\n)+', block[found.end():])[0].split())
    return value.removeprefix('${{ ').removesuffix(' }}')


class GitHubString(str):
    # GitHub compares strings case-insensitively. Use its documented semantics
    # for these string-only predicates, not Python's default string equality.
    def __eq__(self, other):
        if not isinstance(other, str):
            return NotImplemented
        return self.lower() == other.lower()

    def __ne__(self, other):
        equal = self.__eq__(other)
        return NotImplemented if equal is NotImplemented else not equal


def expression_value(expression, values):
    for key in sorted(values, key=len, reverse=True):
        value = repr(values[key])
        expression = expression.replace(key, 'string(' + value + ')' if isinstance(values[key], str) else value)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'\bfalse\b', 'False', expression)
    expression = re.sub(r'!(?!=)', ' not ', expression).replace('always()', 'True')
    return eval(expression.strip(), {'__builtins__': {}, 'string': GitHubString,
                                    'format': lambda value, *args: value.format(*args),
                                    'contains': lambda values, item: any(str(value).lower() == item.lower() for value in values),
                                    'startsWith': lambda value, prefix: value.lower().startswith(prefix.lower())})


def evaluate(expression, values):
    return bool(expression_value(expression, values))


class PRMetadataAdmissionTests(unittest.TestCase):
    def test_metadata_queues_and_revalidates_a_fixed_required_context(self):
        source = (ROOT / '.github/workflows/ci.yml').read_text()
        title = source.split('run-name: >-\n', 1)[1].split('\non:', 1)[0].strip()[3:-3]
        concurrency = source.split('  group: ci-${{ github.workflow }}-${{ ', 1)[1].split(' }}', 1)[0]
        required = source.split('  ci-required:\n', 1)[1]
        self.assertIn('    name: CI Required\n', required)
        cancel = source.split('  cancel-in-progress: ${{ ', 1)[1].split(' }}', 1)[0]
        queue = source.split('  queue: ${{ ', 1)[1].split(' }}', 1)[0]
        gate = required.split('      - name: Verify prior validation for metadata\n', 1)[1]
        gate_condition = gate.split('        if: ${{ ', 1)[1].split(' }}', 1)[0]
        for action, label, base, ignored in [
                ('opened', '', '', False), ('synchronize', '', '', False), ('reopened', '', '', False),
                ('labeled', 'release-validation', '', False), ('unlabeled', 'release-validation', '', False),
                ('labeled', 'Release-Validation', '', False), ('unlabeled', 'RELEASE-VALIDATION', '', False),
                ('labeled', 'documentation', '', True), ('unlabeled', 'bug', '', True),
                ('labeled', '', '', False), ('edited', '', '', True),
                ('edited', '', {'ref': {'from': 'develop'}}, False)]:
            values = {'github.event_name': 'pull_request', 'github.event.action': action,
                      'github.event.label.name': label, 'github.event.changes.base': base,
                      'github.event.pull_request.number': 45, 'github.event.pull_request.head.sha': 'a' * 40,
                      'github.event.pull_request.base.sha': 'b' * 40, 'github.workflow_sha': 'c' * 40,
                      'github.event.pull_request.labels.*.name': [], 'github.sha': 'c' * 40, 'github.run_id': 123, 'github.ref': 'refs/pull/45/merge', 'inputs.dependabot_merge_pr': ''}
            with self.subTest(action=action, label=label, base=base):
                self.assertEqual(evaluate(condition(source, 'ci-plan'), values), not ignored)
                self.assertTrue(evaluate(condition(source, 'ci-required'), values))
                self.assertEqual(evaluate(gate_condition, values), ignored)
                self.assertEqual(evaluate(cancel, values), not ignored)
                self.assertEqual(expression_value(queue, values), 'max' if ignored else 'single')
                self.assertEqual(expression_value(title, values).startswith('CI metadata-only v1 '), ignored)
                self.assertEqual(expression_value(concurrency, values), 45)
        for event in ['push', 'merge_group', 'workflow_dispatch']:
            values.update({'github.event_name': event, 'github.event.action': 'edited', 'github.event.changes.base': ''})
            self.assertTrue(evaluate(condition(source, 'ci-plan'), values))
            self.assertEqual(expression_value(queue, values), 'single')
            self.assertTrue(evaluate(cancel, values))
            self.assertTrue(evaluate(condition(source, 'ci-required'), values))

    def test_metadata_runs_allocate_no_other_runner(self):
        source = (ROOT / '.github/workflows/ci.yml').read_text()
        for block in re.split(r'\n  [\w-]+:\n', source.split('jobs:\n',1)[1])[1:]:
            if '    name: CI Plan\n' in block or '    name: CI Required\n' in block:
                continue
            self.assertRegex(block, r'    needs: (?:ci-plan|\[ci-plan[,\]])')
            self.assertNotIn('always()', block.split('    steps:', 1)[0])
