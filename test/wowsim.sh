#!/usr/bin/env bash
# Runs test/wowsim/*.lua inside wow-ui-sim (https://github.com/Osso/wow-ui-sim, WoW Forever build)
# against a copy of addon/, so nothing in your AddOns folder is touched.
# Usage: WOW_SIM=/path/to/wow-sim bash test/wowsim.sh
# Setup (simulator, Blizzard's Forever UI files): see test/README.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wow_sim="${WOW_SIM:?Set WOW_SIM to the wow-sim executable from a wow-ui-sim Forever release}"
addon_name="HEH" # the tests find the addon by this folder name

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/AddOns"
cp -R "$root/addon" "$staging/AddOns/$addon_name"
mkdir -p "$staging/AddOns/$addon_name/tests"
cp "$root/test/wowsim/"*.lua "$staging/AddOns/$addon_name/tests/"

"$wow_sim" --no-saved-vars --session-wtf-path "$staging/WTF" --addons-path "$staging/AddOns" run-tests "$addon_name"
