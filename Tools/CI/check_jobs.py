#!/usr/bin/env python3
"""A stable required check: all declared CI jobs must have actually succeeded."""
import json
import os

REQUIRED = {'core', 'node', 'offline', 'android', 'app'}


def validate(needs):
    if not isinstance(needs, dict) or set(needs) != REQUIRED:
        raise ValueError('Missing or unexpected CI job results')
    results = {name: value.get('result') if isinstance(value, dict) else None for name, value in needs.items()}
    if any(value != 'success' for value in results.values()):
        raise ValueError(f'CI jobs did not all succeed: {results}')
    return results


if __name__ == '__main__':
    try:
        results = validate(json.loads(os.environ['CI_JOB_RESULTS']))
    except (KeyError, ValueError, TypeError) as error:
        raise SystemExit(str(error))
    print(json.dumps({'status': 'passed', 'jobs': results}, indent=2))
