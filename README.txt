Undercore for iOS

Two related targets are preserved together because the VPN target references its sibling:
- undercore-ios/: account application and shared Core package.
- undercore-ios-vpn/: experimental VPN extension and connection application.

Keep these directories side by side. Open undercore-ios/Undercore.xcodeproj or undercore-ios-vpn/UndercoreVPN.xcodeproj.

The VPN preparation script uses pinned AmneziaWG sources prepared by the macOS project. Clone UndercoreCo/macos separately, prepare its dependencies, and pass its absolute path through --macos-source to undercore-ios-vpn/Scripts/build.py. See --help for SDK/signing options. Developer signing credentials and provisioned binaries are not included. This is an experimental source snapshot, not an App Store release.
