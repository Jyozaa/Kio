"""Report counts only; never print matching secret text. Source tests may name secrets."""
import json
import re
from pathlib import Path

roots = [Path('agent/src'), Path('apps/macos/Sources'), Path('docs/benchmarks'), Path('fixtures/trajectories')]
key_pattern = re.compile(r'AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9]{32,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
issues = []
checked = 0
for root in roots:
    for path in root.rglob('*'):
        if not path.is_file() or '__pycache__' in path.parts: continue
        checked += 1
        if path.suffix.lower() in {'.png','.jpg','.jpeg','.wav','.mp3','.m4a'}:
            issues.append('unexpected_media')
        if key_pattern.search(path.read_text(errors='ignore')):
            issues.append('possible_credential')
# Only opt-in structured recordings may exist; inspect formats without revealing contents.
trajectories = Path.home() / 'Library/Application Support/Kio/trajectories'
recordings = 0
if trajectories.exists():
    for path in trajectories.glob('*.json'):
        recordings += 1
        data = json.loads(path.read_text())
        def inspect(value):
            if isinstance(value,dict):
                for k,v in value.items():
                    if k in {'api_key','password','clipboard','audio','image','screenshot','element_token','payload'}: issues.append('private_recording_field')
                    inspect(v)
            elif isinstance(value,list):
                for v in value: inspect(v)
            elif isinstance(value,str) and key_pattern.search(value): issues.append('possible_recorded_credential')
        inspect(data)
print(json.dumps({'source_and_report_files':checked,'opt_in_trajectories_checked':recordings,'issues':issues}))
raise SystemExit(bool(issues))
