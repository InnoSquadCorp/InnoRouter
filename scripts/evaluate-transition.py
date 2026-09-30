#!/usr/bin/env python3
"""Transition runs retain legacy full gates, plus policy/docs/exact-SHA proof."""
import importlib.util
import json
import os
from pathlib import Path
spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('ci-policy.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
plan = json.loads(os.environ['CI_PLAN'])
policy.validate_plan(plan)
needs = json.loads(os.environ['CI_NEEDS'])
if set(needs) != set(policy.JOBS) | {'ci-plan'}:
    raise SystemExit('Transition missing/unexpected dependency')
for job in needs:
    selected = job == 'ci-plan' or (job in ('policy', 'documentation', 'remote-consumer') and plan['jobs'][job])
    expected = 'success' if selected else 'skipped'
    if needs[job].get('result') != expected:
        raise SystemExit(f'Transition {job}: expected {expected}')
print('Transition dependencies passed; legacy checks still required.')
