#!/usr/bin/env python3
"""Compile exact production CoreAudio function bodies against fault-injected APIs.

No Bluetooth hardware is used. Real libdispatch and ASan/UBSan are used; CoreAudio
and mpv helpers are fakes. The extracted bodies are never edited by the harness.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def function(source, name):
    match = re.search(r"^static [^;\n]+\b" + name + r"\([^;]*?\)\s*\{", source, re.M)
    if not match:
        raise ValueError(name)
    start, depth = match.start(), 1
    end = match.end()
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--case", type=int, default=-1)
    args = parser.parse_args()
    source = args.source.read_text()
    names = ["reinit_device", "init", "init_audiounit", "cancel_and_release_idle_work",
             "uninit", "hotplug_cb", "hotplug_init", "hotplug_uninit",
             "register_hotplug_cb", "unregister_hotplug_cb"]
    bodies = [function(source, name) for name in names]
    declarations = "\n".join(body[:body.index("{")].strip() + ";" for body in bodies)
    template = Path(__file__).with_name("lifecycle.c.in").read_text()
    generated = template.replace("/* PRODUCTION_FUNCTIONS */", declarations + "\n" + "\n\n".join(bodies))
    args.output.mkdir(parents=True, exist_ok=True)
    c = args.output / "lifecycle.c"
    c.write_text(generated)
    binary = args.output / "lifecycle"
    command = ["xcrun", "clang", "-g", "-O1", "-fblocks", "-fsanitize=address,undefined",
               "-fno-omit-frame-pointer", "-framework", "CoreAudio", "-framework", "AudioUnit",
               str(c), "-o", str(binary)]
    subprocess.run(command, check=True)
    result = subprocess.run([str(binary), str(args.case)], capture_output=True, text=True)
    (args.output / "test.log").write_text(result.stdout + result.stderr)
    report = {"source_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
              "extracted_functions": names, "sanitizers": ["address", "undefined"],
              "case": args.case, "exit_code": result.returncode,
              "hardware": "NOT_TESTED"}
    (args.output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(result.stdout + result.stderr)
    raise SystemExit(result.returncode != 0)


if __name__ == "__main__":
    main()
