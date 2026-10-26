"""Copy tracked inputs into fresh CI workspaces without local build products or keys."""
from pathlib import Path
import shutil
import subprocess

from run_core import ROOT


def copy_tracked(destination: Path, prefix: str = ''):
    destination = destination.resolve()
    if destination.exists() or destination == ROOT or ROOT in destination.parents:
        raise RuntimeError('Build source destination must be new and outside the checkout')
    files = subprocess.check_output(['git', 'ls-files', '-z', '--', prefix or '.'], cwd=ROOT).decode().split('\0')
    files = [name for name in files if name]
    if not files:
        raise RuntimeError('No tracked build inputs')
    destination.mkdir(parents=True)
    for name in files:
        source = ROOT / name
        if source.is_symlink() or not source.is_file():
            raise RuntimeError(f'Build input is missing or not a regular tracked file: {name}')
        relative = Path(name).relative_to(prefix) if prefix else Path(name)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    return destination
