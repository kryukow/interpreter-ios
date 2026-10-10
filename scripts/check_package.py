"""Check publication contents and configuration. Does not replace an Xcode build."""
from pathlib import Path
import re
import yaml

root = Path(__file__).resolve().parents[1]
files = list(root.rglob('*'))
for path in files:
    if not path.is_file():
        continue
    assert path.suffix.lower() not in {'.p12', '.mobileprovision', '.ipa', '.pem', '.key'}, path
    if path.suffix.lower() == '.png':
        assert path.relative_to(root).as_posix() == 'App/Assets.xcassets/AppIcon.appiconset/AppIcon.png', path
        assert path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), path
        continue
    text = path.read_text(encoding='utf-8')
    secret_pattern = r'\bsk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|' + '-----BEGIN ' + r'.*PRIVATE' + ' KEY-----'
    assert not re.search(secret_pattern, text), path
project = yaml.safe_load((root / 'project.yml').read_text(encoding='utf-8'))
assert project['targets']['Interpreter']['sources'] == ['App']
assert project['targets']['Interpreter']['settings']['base']['INFOPLIST_KEY_NSSpeechRecognitionUsageDescription']
workflow = yaml.safe_load((root / '.github/workflows/build-ios.yml').read_text(encoding='utf-8'))
assert workflow['jobs']['build']['runs-on'] == 'macos-latest'
assert workflow['permissions'] == {'contents': 'read'}
for path in (root / 'App').glob('*.swift'):
    text = path.read_text(encoding='utf-8')
    assert 'wss://api.openai.com' not in text, path
    assert 'SecureAPIKey' not in text, path
    assert 'kSecAttrAccessGroup' not in text, path
print('PASS: publication file allowlist, credential patterns, YAML, speech permissions, no paid audio channel or shared Page Helper credentials')
