#!/bin/sh
set -eu
cd "$(dirname "$0")"
sdk_path=${ANDCINTOSH_SDK_PATH:-$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx --show-sdk-path)}
swift build --sdk "$sdk_path" -c debug --product Andcintosh
binary_dir=$(swift build --sdk "$sdk_path" -c debug --show-bin-path)
bundle_dir="$PWD/build/Andcintosh.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$binary_dir/Andcintosh" "$bundle_dir/Contents/MacOS/Andcintosh.new"
mv -f "$bundle_dir/Contents/MacOS/Andcintosh.new" "$bundle_dir/Contents/MacOS/Andcintosh"
cp App/Info.plist "$bundle_dir/Contents/Info.plist"
cp App/Resources/Andcintosh.icns "$bundle_dir/Contents/Resources/Andcintosh.icns"
codesign --force --sign - --identifier io.github.kaguramatsuri.Andcintosh "$bundle_dir"
printf '%s\n' "$bundle_dir"
