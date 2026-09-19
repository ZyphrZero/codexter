#!/bin/bash
# 在 Mac 上构建 Universal 包；仅使用本机临时签名，不冒充 Developer ID 公证分发。
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo '此脚本必须在 Mac 上运行' >&2; exit 1; }
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version="$(sed -nE 's/^version: *([0-9]+\.[0-9]+\.[0-9]+)(\+[0-9]+)? *$/\1/p' pubspec.yaml)"
[[ -n "$version" ]] || { echo 'pubspec.yaml 必须使用正式版本号，例如 1.0.7+8' >&2; exit 1; }
[[ -z "${RELEASE_VERSION:-}" || "$RELEASE_VERSION" == "$version" ]] || {
  echo '构建版本与发布版本不一致' >&2; exit 1;
}

xcodebuild -version
pod --version
flutter pub get --enforce-lockfile
# 固定 SDK 的 Release 默认构建 arm64 + x86_64；不传不存在的 --target-platform 参数。
args=(build macos --release --no-pub)
if [[ -n "${UPDATE_MANIFEST_URL:-}" ]]; then
  args+=("--dart-define=UPDATE_MANIFEST_URL=$UPDATE_MANIFEST_URL")
fi
flutter "${args[@]}"

app='build/macos/Build/Products/Release/Codexter.app'
[[ -f "$app/Contents/MacOS/Codexter" ]] || { echo '未找到 Mac 应用产物' >&2; exit 1; }
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$actual_version" == "$version" ]] || { echo '应用产物版本不匹配' >&2; exit 1; }

# 每个原生二进制都必须包含两种架构，避免只有主程序是 Universal 而插件缺架构。
while IFS= read -r -d '' binary; do
  if /usr/bin/file -b "$binary" | grep -q 'Mach-O'; then
    /usr/bin/lipo -verify_arch arm64 x86_64 "$binary"
  fi
done < <(find "$app" -type f -print0)
/usr/bin/codesign --verify --deep --strict "$app"

mkdir -p dist
archive="$PWD/dist/Codexter-$version-macos-universal.zip"
rm -f "$archive"
# ditto 保留 framework 符号链接及执行权限，不能在 Windows 上重新压缩 .app。
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
verify_dir=$(mktemp -d "${TMPDIR:-/tmp}/codexter-package.XXXXXX")
trap 'rm -rf "$verify_dir"' EXIT
/usr/bin/ditto -x -k "$archive" "$verify_dir"
/usr/bin/codesign --verify --deep --strict "$verify_dir/Codexter.app"
echo "已生成 $archive（未配置 Developer ID 签名或公证）"
