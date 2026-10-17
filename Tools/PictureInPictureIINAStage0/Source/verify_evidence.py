"""Check runtime facts; these checks cannot approve real PiP pixels or sound."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("runtime", type=Path)
args = parser.parse_args()
data = json.loads(args.runtime.read_text())
assert data["capabilities"]["requiredAPICompatible"]
assert data["mpvClientsCreated"] == data["loadCommands"] == 1
assert data["renderContextsCreated"] == 1
assert data["renderContextsDestroyed"] == 0
assert data["sameOpenGLContext"]
assert data["starts"] >= 3 and data["stops"] >= 2
assert not any(event["state"] == "failed" for event in data["events"])
samples = data["samples"]
pip = [s for s in samples if s["state"] == "pip" and not s["paused"]]
assert len(pip) >= 5
assert pip[-1]["frames"] - pip[0]["frames"] > 30
assert all(not s["surfaceInMain"] for s in pip)
paused = next(e for e in data["events"] if e["event"] == "paused")
returned = next(e for e in data["events"] if e["event"] == "pip-did-close" and e["uptime"] > paused["uptime"])
# The pause request is asynchronous. Compare settled, actually paused samples,
# not the cached position at the instant the request was queued.
settled = [s for s in samples if s["paused"] and
           paused["uptime"] + 1 < s["uptime"] < returned["uptime"]]
assert len(settled) >= 5
positions = [float(s["position"]) for s in settled] + [float(returned["position"])]
assert max(positions) - min(positions) < 1 / 30
result = {
    "verified": ["single-player", "single-render-context", "playing-in-pip",
                 "return-to-inline", "paused-entry-and-return"],
    "audioOutput": data["audioOutput"],
    "realSoundVerified": False,
    "nativePiPVisualVerified": False,
    "nativeControlsVerified": False,
    "productionAdmission": "pending-human-visual-and-real-audio-gates",
}
print(json.dumps(result, ensure_ascii=False, indent=2))
