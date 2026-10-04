#!/usr/bin/env bash
#
# Print the SDK path the build scripts should use, or nothing to use the default.
#
# Why this exists: the macOS 27 SDK turned SwiftUI's `@State` into a macro backed
# by the `SwiftUIMacros` host plugin, which ships only with Xcode. On a machine
# with Command Line Tools alone the default SDK therefore fails with:
#
#   external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
#
# The macOS 26 SDK still declares `@State` as a plain property wrapper and needs
# no plugin, so it builds fine. When the plugin is unavailable we pick the newest
# installed SDK that does not require it. With Xcode installed this prints
# nothing and the default SDK is used unchanged.
#
# Override by exporting CODEX_KEEPER_SDK=/path/to/MacOSX<version>.sdk
set -euo pipefail

if [[ -n "${CODEX_KEEPER_SDK:-}" ]]; then
  printf '%s\n' "$CODEX_KEEPER_SDK"
  exit 0
fi

developer_dir="$(xcode-select -p 2>/dev/null || true)"
[[ -n "$developer_dir" ]] || exit 0

# The plugin is present -> the default SDK works, so leave it alone.
for plugin in \
  "$developer_dir/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
  "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"; do
  [[ -f "$plugin" ]] && exit 0
done

for candidate in $(ls -d "$developer_dir"/SDKs/MacOSX*.sdk 2>/dev/null | sort -rV); do
  interface="$candidate/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
  [[ -f "$interface" ]] || continue
  if ! grep -q 'macro State()' "$interface"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

exit 0
