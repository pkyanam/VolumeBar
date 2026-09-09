#!/usr/bin/env python3
"""Upload signing credentials directly to encrypted GitHub environment secrets."""
import argparse
import base64
import getpass
import json
from pathlib import Path
import subprocess
import secrets
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', default='pkyanam/VolumeBar')
parser.add_argument('--p12', type=Path, required=True)
parser.add_argument('--p8', type=Path, required=True)
parser.add_argument('--key-id', required=True)
parser.add_argument('--issuer-id', required=True)
parser.add_argument('--team-id', required=True)
parser.add_argument('--password-file', type=Path, help='Optional protected local file; otherwise prompt securely')
args = parser.parse_args()
subprocess.run(['gh', 'repo', 'view', args.repo, '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], check=True)
password = args.password_file.read_text().strip() if args.password_file else getpass.getpass('P12 export password: ')
if not password or not args.p12.is_file() or not args.p8.is_file():
    raise SystemExit('Missing credential file or empty P12 password')
# Catch wrong passwords, missing private keys, and incompatible OpenSSL P12 exports
# before changing any GitHub configuration. The keychain is temporary and never made default.
with tempfile.TemporaryDirectory(prefix='volumebar-keycheck-') as folder:
    keychain = str(Path(folder) / 'check.keychain-db')
    keychain_password = secrets.token_hex(32)
    try:
        subprocess.run(['security', 'create-keychain', '-p', keychain_password, keychain], check=True, capture_output=True)
        imported = subprocess.run(['security', 'import', str(args.p12.resolve()), '-k', keychain, '-P', password, '-T', '/usr/bin/codesign'], capture_output=True)
        if imported.returncode:
            raise SystemExit('P12 cannot be imported by macOS Keychain. Check its password and the OpenSSL compatibility note in docs/signing.md.')
        identity = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning', keychain], text=True)
        if 'Developer ID Application:' not in identity:
            raise SystemExit('P12 must contain a valid Developer ID Application certificate and matching private key.')
    finally:
        subprocess.run(['security', 'delete-keychain', keychain], capture_output=True)
# Disable publishing while replacing the credential set. Enable only after all six uploads succeed.
subprocess.run(['gh', 'variable', 'set', 'SIGNING_ENABLED', '--repo', args.repo, '--body', 'false'], check=True)
policy = {'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}}
subprocess.run(['gh', 'api', '--method', 'PUT', f'repos/{args.repo}/environments/release', '--input', '-'], input=json.dumps(policy).encode(), stdout=subprocess.DEVNULL, check=True)
existing = json.loads(subprocess.check_output(['gh', 'api', f'repos/{args.repo}/environments/release/deployment-branch-policies']))
for name, kind in [('main', 'branch'), ('v*', 'tag')]:
    if not any(p['name'] == name and p.get('type', 'branch') == kind for p in existing['branch_policies']):
        subprocess.run(['gh', 'api', '--method', 'POST', f'repos/{args.repo}/environments/release/deployment-branch-policies', '--input', '-'], input=json.dumps({'name': name, 'type': kind}).encode(), stdout=subprocess.DEVNULL, check=True)
values = {
    'DEVELOPER_ID_P12_BASE64': base64.b64encode(args.p12.read_bytes()),
    'DEVELOPER_ID_P12_PASSWORD': password.encode(),
    'APPLE_API_KEY_P8': args.p8.read_bytes(),
    'APPLE_API_KEY_ID': args.key_id.encode(),
    'APPLE_API_ISSUER_ID': args.issuer_id.encode(),
    'APPLE_TEAM_ID': args.team_id.encode(),
}
for name, value in values.items():
    subprocess.run(['gh', 'secret', 'set', name, '--repo', args.repo, '--env', 'release'], input=value, check=True)
    print(f'Configured {name}')
subprocess.run(['gh', 'variable', 'set', 'SIGNING_ENABLED', '--repo', args.repo, '--body', 'true'], check=True)
print('Signing enabled. Dispatch ci.yml on main to verify notarization.')
