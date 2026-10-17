"""Validate the recorded experiment, not product PiP acceptance."""
from pathlib import Path
import argparse,json

parser=argparse.ArgumentParser()
parser.add_argument('evidence', type=Path)
args=parser.parse_args()
for name in ['samplebuffer-live-attempt.json','samplebuffer-vod-attempt.json']:
    d=json.loads((args.evidence/name).read_text())
    assert d['sampleLayerReady'] and d['frames'] > 0 and d['layerStatus'] == 1, name
    assert not d['possible'] and not d['active'], name
    assert d['timeRangeDelegateCalls'] == 0 and d['pausedDelegateCalls'] == 0, name
    assert any(e['event']=='start-timeout' and e['mode']==d['mode'] for e in d['events']), name
d=json.loads((args.evidence/'avplayer-active-control.json').read_text())
assert d['possible'] and d['active'] and d['playerLayerReady']
assert any(e['event']=='did-start' and e['mode']=='avplayer-control' for e in d['events'])
print('Recorded evidence is consistent. Stage 0 sample-buffer PiP gate: FAILED. No mpv or visual-acceptance pass inferred.')
