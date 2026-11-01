#!/usr/bin/env python3
"""Fail packaging when host health expectations, Gradle or APK versions disagree."""
import argparse
from pathlib import Path
import re
import sys


def single(pattern, text, label):
    values = re.findall(pattern, text, re.MULTILINE)
    if len(values) != 1:
        raise ValueError('Expected one literal ' + label)
    return values[0]


def validate(runtime, gradle, apk_name=None, apk_code=None):
    host = (single(r'^\s*static let bridgeVersion = "([0-9.]+)"\s*$', runtime, 'host versionName'),
            int(single(r'^\s*static let bridgeVersionCode = ([0-9]+)\s*$', runtime, 'host versionCode')))
    android = (single(r'^\s*versionName = "([0-9.]+)"\s*$', gradle, 'Gradle versionName'),
               int(single(r'^\s*versionCode = ([0-9]+)\s*$', gradle, 'Gradle versionCode')))
    if host != android:
        raise ValueError(f'Android Bridge contract mismatch: host={host}, Gradle={android}')
    if (apk_name is None) != (apk_code is None):
        raise ValueError('Both APK version fields are required')
    if apk_name is not None and (apk_name, int(apk_code)) != host:
        raise ValueError(f'Android Bridge contract mismatch: host={host}, APK={(apk_name, apk_code)}')
    return host


def main():
    project = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-swift', type=Path, default=project/'Engines/Spider/JavaScriptSpiderSiteProvider.swift')
    parser.add_argument('--gradle', type=Path, default=project.parent.parent/'Helpers/AndroidDexBridge/app/build.gradle')
    parser.add_argument('--apk-version-name')
    parser.add_argument('--apk-version-code')
    args = parser.parse_args()
    try:
        version = validate(args.runtime_swift.read_text(), args.gradle.read_text(), args.apk_version_name, args.apk_version_code)
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f'Android Bridge contract passed: {version[0]} ({version[1]})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
