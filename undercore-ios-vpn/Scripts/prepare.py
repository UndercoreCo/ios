#!/usr/bin/env python3
"""Build the pinned AmneziaWG bridge for iPhone, without changing the Mac build."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--macos-source', type=Path, default=Path('/Users/rustam/Projects/wg/apps/macos'))
parser.add_argument('--sdk', choices=['iphoneos', 'iphonesimulator'], default='iphoneos')
args = parser.parse_args()
lock = json.loads((root / 'dependency-lock.json').read_text())
deps = root / '.build-deps'
deps.mkdir(exist_ok=True)
upstream = args.macos_source / '.build-deps/amneziawg-apple'
if subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip() != lock['appleRevision']:
    raise SystemExit('Unexpected AWG source revision')
if subprocess.check_output(['git', '-C', str(upstream), 'status', '--porcelain'], text=True).strip():
    raise SystemExit('AWG source has unverified changes')
package = deps / 'AWGKit'
for name in ['WireGuardKit', 'WireGuardKitC']:
    shutil.copytree(upstream / 'Sources' / name, package / 'Sources' / name, dirs_exist_ok=True)
bridge = package / 'Sources/WireGuardKitGo'
bridge.mkdir(parents=True, exist_ok=True)
for name in ['wireguard.h', 'module.modulemap', 'dummy.c']:
    shutil.copyfile(upstream / 'Sources/WireGuardKitGo' / name, bridge / name)
text = (upstream / 'Sources/Shared/Model/TunnelConfiguration+WgQuickConfig.swift').read_text()
text = text.replace('    convenience init(fromWgQuickConfig', '    public convenience init(fromWgQuickConfig')
(package / 'Sources/WireGuardKit/TunnelConfiguration+WgQuickConfig.swift').write_text(text)
shutil.copyfile(upstream / 'Sources/Shared/Model/String+ArrayConversion.swift', package / 'Sources/WireGuardKit/String+ArrayConversion.swift')
models = package / 'Sources/WireGuardConfiguration'
models.mkdir(parents=True, exist_ok=True)
for path in (package / 'Sources/WireGuardKit').glob('*.swift'):
    if path.name not in {'WireGuardAdapter.swift', 'PacketTunnelSettingsGenerator.swift', 'DNSResolver.swift'}:
        shutil.copyfile(path, models / path.name)
(package / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AWGKit", platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "WireGuardKit", targets: ["WireGuardKit"]), .library(name: "WireGuardConfiguration", targets: ["WireGuardConfiguration"])],
    targets: [
        .target(name: "WireGuardConfiguration", dependencies: ["WireGuardKitC"]),
        .target(name: "WireGuardKit", dependencies: ["WireGuardKitC", "WireGuardKitGo"]),
        .target(name: "WireGuardKitC", publicHeadersPath: "."),
        .target(name: "WireGuardKitGo", publicHeadersPath: ".", linkerSettings: [.linkedLibrary("wg-go"), .linkedLibrary("resolv")])
    ])
''')
shutil.copyfile(upstream / 'COPYING', package / 'LICENSE')
engine = deps / 'engine'
engine.mkdir(exist_ok=True)
for name in ['api-apple.go', 'Makefile', 'goruntime-boottime-over-monotonic.diff']:
    shutil.copyfile(upstream / 'Sources/WireGuardKitGo' / name, engine / name)
for name in ['go.mod', 'go.sum']:
    shutil.copyfile(root / 'Config' / name, engine / name)
go = args.macos_source / '.build-deps/go/bin/go'
if 'go' + lock['goVersion'] + ' ' not in subprocess.check_output([str(go), 'version'], text=True):
    raise SystemExit('Unexpected Go toolchain version')
env = {**os.environ, 'PATH': str(go.parent) + os.pathsep + os.environ['PATH'],
       'GOTOOLCHAIN': 'local', 'GOPATH': str(deps / 'go-cache'),
       'GOCACHE': str(deps / 'go-build-cache'), 'GOFLAGS': '-mod=readonly'}
# Reuse downloaded modules read-only as a local module proxy when present.
cache = args.macos_source / '.build-deps/go-cache/pkg/mod/cache/download'
if cache.exists(): env['GOPROXY'] = cache.as_uri() + ',https://proxy.golang.org'
subprocess.run([str(go), 'mod', 'download'], cwd=engine, env=env, check=True)
subprocess.run([str(go), 'mod', 'verify'], cwd=engine, env=env, check=True)
sdk = subprocess.check_output(['xcrun', '--sdk', args.sdk, '--show-sdk-path'], text=True).strip()
clang = subprocess.check_output(['xcrun', '--sdk', args.sdk, '--find', 'clang'], text=True).strip()
minimum = 'miphoneos-version-min' if args.sdk == 'iphoneos' else 'mios-simulator-version-min'
subprocess.run(['make', 'ARCHS=arm64', 'PLATFORM_NAME=' + args.sdk,
    'GOOS_' + args.sdk + '=ios', 'SDKROOT=' + sdk, 'CC=' + clang,
    'DESTDIR=' + str(deps / 'lib' / args.sdk),
    'BUILDDIR=' + str(deps / ('build-' + args.sdk)),
    'DEPLOYMENT_TARGET_CLANG_FLAG_NAME=' + minimum,
    'DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONEOS_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET=16.0'],
    cwd=engine, env=env, check=True)
notices = ['AmneziaWG Apple adapter\n' + (upstream / 'COPYING').read_text(),
           'Go runtime\n' + (go.parents[1] / 'LICENSE').read_text()]
for path in sorted((deps / 'go-cache/pkg/mod').glob('**/LICENSE')):
    if '/cache/' not in str(path): notices.append(str(path.parent.name) + '\n' + path.read_text())
(root / 'Config/ThirdPartyNotices.txt').write_text('\n\n--------------------\n\n'.join(notices))
print('Prepared iOS AmneziaWG:', args.sdk)
