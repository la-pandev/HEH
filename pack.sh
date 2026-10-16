#!/usr/bin/env bash
# Zips the addon for release as build/HEH-v<major>.zip, with the files under a HEH/ folder.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
addon_dir="$root/addon"
addon_name="HEH" # WoW loads the addon by folder name; paths in the code depend on it

version="$(sed -n 's/^## Version: *\([0-9][0-9.]*\).*/\1/p' "$addon_dir/$addon_name.toc")"
if [[ -z "$version" ]]; then
    echo "No '## Version:' found in $addon_name.toc" >&2
    exit 1
fi
zip_path="$root/build/$addon_name-v${version%%.*}.zip"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$addon_dir" "$staging/$addon_name"

mkdir -p "$root/build"
rm -f "$zip_path"
(cd "$staging" && zip -qr "$zip_path" "$addon_name" -x '*.DS_Store' -x '*Thumbs.db')

echo "Built $zip_path ($addon_name $version)"
