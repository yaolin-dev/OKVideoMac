"""Validate complete XCTest output; never infer success from an exit code alone."""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET


class InvalidResults(ValueError):
    pass


DISCOVERED = re.compile(r"^[A-Za-z_][\w.]*/[A-Za-z_]\w*$")
STARTED = re.compile(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' started\.$", re.M)
COMPLETED = re.compile(
    r"^Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|skipped|failed) \(([0-9.]+) seconds\)\.$", re.M
)
SKIP_REASON = re.compile(r"-\[([^ ]+) ([^\]]+)\] : Test skipped - (.*)")
TOTAL = re.compile(
    r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)"
)


def discovered_tests(text: str) -> set[str]:
    names = [line.strip() for line in text.splitlines() if DISCOVERED.fullmatch(line.strip())]
    if not names or len(names) != len(set(names)):
        raise InvalidResults("Test discovery was empty or contained duplicate identities")
    return set(names)


def xctest_results(text: str, discovered: set[str], allowed_skips: dict[str, str], exit_code: int) -> dict:
    if exit_code != 0:
        raise InvalidResults(f"Test process exited with {exit_code}")
    if not discovered:
        raise InvalidResults("No discovered tests")
    stale = set(allowed_skips) - discovered
    if stale:
        raise InvalidResults(f"Skip policy references missing tests: {sorted(stale)}")
    starts = [f"{group}/{name}" for group, name in STARTED.findall(text)]
    reasons = {f"{group}/{name}": reason.strip() for group, name, reason in SKIP_REASON.findall(text)}
    cases = [dict(id=f"{group}/{name}", classname=group, name=name, status=status, seconds=float(seconds))
             for group, name, status, seconds in COMPLETED.findall(text)]
    identities = [c['id'] for c in cases]
    if len(starts) != len(set(starts)) or len(identities) != len(set(identities)):
        raise InvalidResults("Duplicate test starts/completions")
    if set(starts) != discovered or set(identities) != discovered:
        raise InvalidResults("Discovered, started and completed test identities differ")
    for case in cases:
        if case['status'] == 'skipped':
            reason = reasons.get(case['id'], '')
            if case['id'] not in allowed_skips or reason != allowed_skips[case['id']]:
                raise InvalidResults(f"Unapproved skip or changed reason: {case['id']}")
            case['reason'] = reason
    counts = {key: sum(c['status'] == key for c in cases) for key in ('passed', 'skipped', 'failed')}
    totals = TOTAL.findall(text)
    if not totals:
        raise InvalidResults("Missing XCTest aggregate summary")
    total, skipped, failures, unexpected = totals[-1]
    if (int(total), int(skipped or 0), int(failures), int(unexpected)) != (len(cases), counts['skipped'], counts['failed'], 0):
        raise InvalidResults("XCTest aggregate disagrees with individual results")
    if counts['failed'] or not counts['passed'] or "Test Suite 'All tests' passed at " not in text:
        raise InvalidResults("The complete suite did not pass, or all tests were skipped")
    return dict(total=len(cases), **counts, cases=cases)


def write_junit(path, result: dict, name: str) -> None:
    suite = ET.Element('testsuite', name=name, tests=str(result['total']), failures=str(result['failed']),
                       errors='0', skipped=str(result['skipped']))
    for case in result['cases']:
        node = ET.SubElement(suite, 'testcase', classname=case['classname'], name=case['name'], time=str(case['seconds']))
        if case['status'] == 'skipped':
            ET.SubElement(node, 'skipped', message=case['reason'])
    ET.indent(suite)
    ET.ElementTree(suite).write(path, encoding='utf-8', xml_declaration=True)
