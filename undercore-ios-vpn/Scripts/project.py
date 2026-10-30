#!/usr/bin/env python3
"""Separate app, shared UIKit/Core sources. Never modifies the original Xcode project."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
original = root.parent / 'undercore-ios'
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(original / 'Undercore.xcodeproj/project.pbxproj')]))
objects = project['objects']
def obj(label, isa, **fields):
    key = hashlib.sha256(('ios-vpn:' + label).encode()).hexdigest()[:24].upper()
    objects[key] = dict(isa=isa, **fields)
    return key
def file(path, kind): return obj(path, 'PBXFileReference', path=path, lastKnownFileType=kind, sourceTree='<group>')
app_id = next(k for k, v in objects.items() if v['isa'] == 'PBXNativeTarget')
app = objects[app_id]
app['name'] = app['productName'] = 'UndercoreVPN'
objects[app['productReference']]['path'] = 'UndercoreVPN.app'
main = objects[project['rootObject']]
children = objects[main['mainGroup']]['children']
for v in list(objects.values()):
    if v['isa'] == 'PBXGroup' and v.get('path') == 'Undercore': v['path'] = '../undercore-ios/Undercore'
    if v['isa'] == 'XCLocalSwiftPackageReference' and v.get('relativePath') == 'Core': v['relativePath'] = '../undercore-ios/Core'
for config_id in objects[app['buildConfigurationList']]['buildConfigurations']:
    config = objects[config_id]
    config['buildSettings'].update(PRODUCT_BUNDLE_IDENTIFIER='ru.undercore.ios.vpn', PRODUCT_MODULE_NAME='UndercoreVPN',
        INFOPLIST_FILE='Config/App-Info.plist', INFOPLIST_KEY_CFBundleDisplayName='Undercore VPN',
        CODE_SIGN_ENTITLEMENTS='Config/App.entitlements',
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) UNDERCORE_VPN')
for path in sorted((root / 'App').glob('*.swift')):
    ref = file(str(path.relative_to(root)), 'sourcecode.swift'); children.append(ref)
    sources = next(objects[k] for k in app['buildPhases'] if objects[k]['isa'] == 'PBXSourcesBuildPhase')
    sources['files'].append(obj('build:' + str(path.name), 'PBXBuildFile', fileRef=ref))
core = obj('core', 'XCLocalSwiftPackageReference', relativePath='VPNCore')
awg = obj('awg', 'XCLocalSwiftPackageReference', relativePath='.build-deps/AWGKit')
main['packageReferences'] += [core, awg]
def dependency(target, package, product):
    dep = obj(target['name'] + product, 'XCSwiftPackageProductDependency', package=package, productName=product)
    target['packageProductDependencies'].append(dep)
    phase = next(objects[k] for k in target['buildPhases'] if objects[k]['isa'] == 'PBXFrameworksBuildPhase')
    phase['files'].append(obj('link:' + dep, 'PBXBuildFile', productRef=dep))
dependency(app, core, 'UndercoreVPNCore')
sources = obj('tunnel-sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
frameworks = obj('tunnel-frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
for path in sorted((root / 'Tunnel').glob('*.swift')):
    ref = file(str(path.relative_to(root)), 'sourcecode.swift'); children.append(ref)
    objects[sources]['files'].append(obj('tunnel-source-build:' + path.name, 'PBXBuildFile', fileRef=ref))
configs = []
for mode in ['Debug', 'Release']:
    configs.append(obj('tunnel-config:' + mode, 'XCBuildConfiguration', name=mode, buildSettings={
        'PRODUCT_NAME': 'UndercoreVPNTunnel', 'PRODUCT_MODULE_NAME': 'UndercoreVPNTunnel',
        'PRODUCT_BUNDLE_IDENTIFIER': 'ru.undercore.ios.vpn.tunnel', 'CODE_SIGN_STYLE': 'Automatic',
        'DEVELOPMENT_TEAM': '5XU62DD2N8', 'CODE_SIGN_ENTITLEMENTS': 'Config/Tunnel.entitlements',
        'INFOPLIST_FILE': 'Config/Tunnel-Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
        'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'SDKROOT': 'iphoneos', 'TARGETED_DEVICE_FAMILY': '1,2',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SWIFT_VERSION': '5.0',
        'SKIP_INSTALL': 'YES', 'APPLICATION_EXTENSION_API_ONLY': 'YES',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O',
        'LIBRARY_SEARCH_PATHS': ['$(inherited)', '$(PROJECT_DIR)/.build-deps/lib/$(PLATFORM_NAME)'],
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    }))
config_list = obj('tunnel-configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
product = obj('tunnel-product', 'PBXFileReference', explicitFileType='wrapper.app-extension', path='UndercoreVPNTunnel.appex', sourceTree='BUILT_PRODUCTS_DIR')
objects[main['productRefGroup']]['children'].append(product)
tunnel_id = obj('tunnel-target', 'PBXNativeTarget', name='UndercoreVPNTunnel', productName='UndercoreVPNTunnel', productReference=product,
    productType='com.apple.product-type.app-extension', buildConfigurationList=config_list, buildPhases=[sources, frameworks], buildRules=[], dependencies=[], packageProductDependencies=[])
main['targets'].append(tunnel_id)
dependency(objects[tunnel_id], core, 'UndercoreVPNCore')
dependency(objects[tunnel_id], awg, 'WireGuardKit')
proxy = obj('proxy', 'PBXContainerItemProxy', containerPortal=project['rootObject'], proxyType=1, remoteGlobalIDString=tunnel_id, remoteInfo='UndercoreVPNTunnel')
app['dependencies'].append(obj('tunnel-dependency', 'PBXTargetDependency', target=tunnel_id, targetProxy=proxy))
embed = obj('embed', 'PBXBuildFile', fileRef=product, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})
app['buildPhases'].append(obj('embed-phase', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, files=[embed], name='Embed App Extensions', runOnlyForDeploymentPostprocessing=0))
ref = file('Config/ThirdPartyNotices.txt', 'text'); children.append(ref)
phase = next(objects[k] for k in app['buildPhases'] if objects[k]['isa'] == 'PBXResourcesBuildPhase')
phase['files'].append(obj('notices-build', 'PBXBuildFile', fileRef=ref))
def render(v):
    if isinstance(v, dict): return '{\n' + '\n'.join(json.dumps(k) + ' = ' + render(x) + ';' for k, x in v.items()) + '\n}'
    if isinstance(v, list): return '(' + ', '.join(map(render, v)) + ')'
    if isinstance(v, int): return str(v)
    return json.dumps(v, ensure_ascii=False)
folder = root / 'UndercoreVPN.xcodeproj'; folder.mkdir(exist_ok=True)
(folder / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + render(project) + '\n')
schemes = folder / 'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
scheme = (original / 'Undercore.xcodeproj/xcshareddata/xcschemes/Undercore.xcscheme').read_text().replace('Undercore.app', 'UndercoreVPN.app').replace('BlueprintName="Undercore"', 'BlueprintName="UndercoreVPN"').replace('container:Undercore.xcodeproj', 'container:UndercoreVPN.xcodeproj')
(schemes / 'UndercoreVPN.xcscheme').write_text(scheme)
info = plistlib.loads((original / 'Undercore/Info.plist').read_bytes())
info['CFBundleDisplayName'] = 'Undercore VPN'
info['CFBundleVersion'] = '4'
info['CFBundleURLTypes'][0]['CFBundleURLName'] = 'ru.undercore.ios.vpn'
info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] = ['undercore-vpn']
(root / 'Config/App-Info.plist').write_bytes(plistlib.dumps(info))
info = { 'CFBundleDevelopmentRegion':'ru', 'CFBundleDisplayName':'Undercore VPN Tunnel',
    'CFBundleExecutable':'$(EXECUTABLE_NAME)', 'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleInfoDictionaryVersion':'6.0', 'CFBundleName':'$(PRODUCT_NAME)', 'CFBundlePackageType':'XPC!',
    'CFBundleShortVersionString':'0.1', 'CFBundleVersion':'4',
    'NSExtension': {'NSExtensionPointIdentifier':'com.apple.networkextension.packet-tunnel',
                    'NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).PacketTunnelProvider'} }
(root / 'Config/Tunnel-Info.plist').write_bytes(plistlib.dumps(info))
for name in ['App', 'Tunnel']:
    entitlements = {'com.apple.developer.networking.networkextension': ['packet-tunnel-provider']}
    if name == 'App': entitlements['aps-environment'] = '$(APS_ENVIRONMENT)'
    (root / ('Config/' + name + '.entitlements')).write_bytes(plistlib.dumps(entitlements))
print('Generated separate Undercore VPN project with shared app sources')
