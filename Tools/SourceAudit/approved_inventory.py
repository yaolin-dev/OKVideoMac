"""Reviewed executable paths, independent of a package's self-declared SBOM."""
import json
from pathlib import Path

def expected_paths():
    path=Path(__file__).resolve().parents[2]/'ThirdParty/approved-macho-paths.json'
    rows=json.loads(path.read_text())
    if len(rows) != len(set(rows)):
        raise SystemExit('Duplicate approved Mach-O paths')
    return set(rows)

def require_approved(actual):
    expected=expected_paths()
    actual=set(actual)
    if actual != expected:
        raise SystemExit(f'Unapproved executable inventory: missing={sorted(expected-actual)}, unexpected={sorted(actual-expected)}')
    return len(expected)
