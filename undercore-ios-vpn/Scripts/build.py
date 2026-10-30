#!/usr/bin/env python3
"""Build only. Installation and real VPN activation are separate explicit steps."""
import argparse
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--sdk', choices=['iphoneos', 'iphonesimulator'], default='iphoneos')
parser.add_argument('--sign', action='store_true')
parser.add_argument('--provision', action='store_true')
parser.add_argument('--prepare', action='store_true')
parser.add_argument('--macos-source', type=Path, default=Path('/Users/rustam/Projects/wg/apps/macos'))
args = parser.parse_args()
if args.provision and not args.sign: parser.error('--provision requires --sign')
if args.sign and args.sdk != 'iphoneos': parser.error('Signing is only needed for the physical iPhone')
if args.prepare:
    subprocess.run(['python3', str(root / 'Scripts/prepare.py'), '--sdk', args.sdk, '--macos-source', str(args.macos_source)], check=True)
if not (root / '.build-deps/lib' / args.sdk / 'libwg-go.a').exists():
    parser.error('Prepare the pinned engine first with --prepare')
subprocess.run(['python3', str(root / 'Scripts/project.py')], check=True)
command = ['xcodebuild', '-project', str(root / 'UndercoreVPN.xcodeproj'), '-scheme', 'UndercoreVPN',
    '-configuration', 'Debug', '-destination', 'generic/platform=' + ('iOS' if args.sdk == 'iphoneos' else 'iOS Simulator'),
    '-derivedDataPath', str(root / ('DerivedData' if args.sdk == 'iphoneos' else 'DerivedData-Simulator')), 'ARCHS=arm64']
if not args.sign: command.append('CODE_SIGNING_ALLOWED=NO')
if args.provision: command.append('-allowProvisioningUpdates')
subprocess.run(command + ['build'], check=True)
print('Built Undercore VPN. No app installed and no VPN started.')
