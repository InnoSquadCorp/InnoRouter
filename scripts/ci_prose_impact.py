#!/usr/bin/env python3
"""Exact-Git prose-only proof. No compiler, package resolution, or network access."""
import difflib
import re
import subprocess
from pathlib import Path

SHA = re.compile(r'[0-9a-f]{40}')
ROOT_DOCS = {'README.md', 'README.ko.md', 'CONTRIBUTING.md'}
FUNDING = '.github/FUNDING.yml'


def eligible(path):
    if not isinstance(path, str) or not path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        return False
    if path.startswith('/') or '\\' in path or any(p in ('', '.', '..') for p in path.split('/')):
        return False
    if path == FUNDING:
        return True
    if path in ROOT_DOCS:
        return True
    parts = path.lower().split('/')
    if parts[0] != 'docs' or not path.endswith('.md'):
        return False
    # Release instructions/evidence, machine contracts, policy and generators
    # never become prose merely because they have a Markdown extension.
    return not any(any(token in p for token in ('release', 'changelog', 'version', 'contract', 'generator', 'plugin'))
                   or p in ('agents.md', 'claude.md', 'security.md') for p in parts[1:])


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.PIPE)


def text_blob(root, revision, path):
    entry = git(root, 'ls-tree', '-z', revision, '--', path)
    if not entry:
        return None
    entries = entry.split(b'\0')
    if len(entries) != 2 or entries[-1]:
        raise ValueError('ambiguous Git tree entry')
    metadata, actual = entries[0].split(b'\t', 1)
    mode, kind, oid = metadata.decode('ascii').split()
    if actual.decode('utf-8') != path or mode != '100644' or kind != 'blob':
        raise ValueError('prose optimization requires ordinary non-executable files')
    raw = git(root, 'cat-file', 'blob', oid)
    if len(raw) > 1024 * 1024 or b'\0' in raw:
        raise ValueError('not a bounded text document')
    return raw.decode('utf-8', errors='strict')


def protected_blocks(text):
    """Freeze every fenced block regardless of language, including nested fences.

    Indentation, raw HTML, directives and inline-code edits are conservatively
    rejected below. This is intentionally narrower than a Markdown compiler.
    """
    blocks, active, lines = [], None, []
    for line in text.splitlines(keepends=True):
        fence = re.search(r'(`{3,}|~{3,})', line)
        if active:
            lines.append(line)
            if fence and fence[1][0] == active[0] and len(fence[1]) >= len(active):
                blocks.append(''.join(lines)); active, lines = None, []
        elif fence:
            active, lines = fence[1], [line]
    if active:
        raise ValueError('unterminated or ambiguous Markdown fence')
    return blocks


def static_text(text):
    if any(re.match(r'^(<<<<<<<|=======|>>>>>>>)(?: |$)', line) for line in text.splitlines()):
        raise ValueError('unresolved merge conflict marker in documentation')
    if any(ord(c) < 32 and c not in '\r\n\t' for c in text):
        raise ValueError('control characters in documentation')


def changed_sensitive_lines(old, new):
    sensitive = re.compile(r'^(?:\s{4}|\t)|`|~{3,}|<|>|\{%|\{\{|^\s*@|^\s*---\s*$|^\s*\.\.|\b[0-9]+\.[0-9]+\.[0-9]+\b')
    for line in difflib.ndiff(old.splitlines(), new.splitlines()):
        if line[:2] in ('+ ', '- ') and sensitive.search(line[2:]):
            return True
    return False


def funding_safe(text):
    # GitHub FUNDING has a tiny scalar/list schema. Avoid YAML execution,
    # aliases, tags and flow objects; public-operations checks run separately.
    keys = {'github', 'patreon', 'open_collective', 'ko_fi', 'tidelift',
            'community_bridge', 'liberapay', 'issuehunt', 'lfx_crowdfunding',
            'polar', 'buy_me_a_coffee', 'thanks_dev', 'custom'}
    seen = set()
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.fullmatch(r'([a-z_]+):[ \t]*(.*)', line)
        if not match or match[1] not in keys or match[1] in seen:
            raise ValueError('unrecognized FUNDING schema')
        seen.add(match[1])
        value = match[2].split(' #', 1)[0].strip()
        if value.startswith('#'):
            value = ''
        scalar = r"(?:[A-Za-z0-9_./:@?=%+#~\-]+|'[^'\n]*'|\"[^\"\\\n]*\")"
        if value and not (re.fullmatch(scalar, value) or
                          re.fullmatch(r'\[\s*(?:' + scalar + r'\s*(?:,\s*' + scalar + r'\s*)*)?\]', value)):
            raise ValueError('unsupported or malformed FUNDING value')
    if not seen:
        raise ValueError('empty FUNDING configuration')


def prove(root, base, head):
    """Return proof only for an entire verified prose-only diff; otherwise None.

    Git/parser errors are left visible to the caller, which must select full CI.
    """
    if not SHA.fullmatch(base or '') or not SHA.fullmatch(head or ''):
        raise ValueError('prose anchors must be exact commit SHAs')
    merge = git(root, 'merge-base', base, head).decode('ascii').strip()
    if not SHA.fullmatch(merge):
        raise ValueError('invalid merge base')
    raw = git(root, 'diff', '--name-status', '-z', '--no-renames', merge, head)
    tokens = raw.decode('utf-8', errors='strict').split('\0')
    if tokens.pop() != '' or len(tokens) % 2:
        raise ValueError('invalid changed-file stream')
    if not tokens:
        return None
    paths = []
    for status, path in zip(tokens[::2], tokens[1::2]):
        if status not in ('A', 'M', 'D') or not eligible(path):
            return None
        old, new = text_blob(root, merge, path), text_blob(root, head, path)
        if (status == 'A' and old is not None) or (status == 'D' and new is not None):
            raise ValueError('unexpected file status')
        old, new = old or '', new or ''
        static_text(old); static_text(new)
        if path == FUNDING:
            if not new:  # Removing sponsorship configuration is conservative.
                return None
            funding_safe(new)
        elif protected_blocks(old) != protected_blocks(new) or changed_sensitive_lines(old, new):
            return None
        paths.append(path)
    return {'base': base, 'head': head, 'merge_base': merge, 'paths': paths}


def validate(proof, paths):
    if not isinstance(proof, dict) or set(proof) != {'base', 'head', 'merge_base', 'paths'}:
        raise ValueError('invalid prose proof shape')
    if any(not isinstance(proof[k], str) or not SHA.fullmatch(proof[k]) for k in ('base', 'head', 'merge_base')):
        raise ValueError('invalid prose proof anchors')
    if not isinstance(proof['paths'], list) or not proof['paths'] or proof['paths'] != paths:
        raise ValueError('prose proof does not cover the exact changed paths')
    if len(set(paths)) != len(paths) or not all(eligible(path) for path in paths):
        raise ValueError('invalid prose proof path')


def revalidate(proof, root, event_name, event):
    validate(proof, proof.get('paths', []))
    if event_name != 'pull_request':
        raise ValueError('prose skips apply only to pull requests')
    pr = event['pull_request']
    if proof['base'] != pr['base']['sha'] or proof['head'] != pr['head']['sha']:
        raise ValueError('prose proof is not for the current PR base/head')
    if prove(root, proof['base'], proof['head']) != proof:
        raise ValueError('prose proof does not match exact Git content')
