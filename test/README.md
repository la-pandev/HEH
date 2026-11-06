# Testing with wow-ui-sim

[wow-ui-sim](https://github.com/Osso/wow-ui-sim) runs addons headlessly against Blizzard's real UI code. The tests in `test/wowsim/` load HEH into its WoW Forever build and check it against Forever's actual chat frames, event payloads and APIs.

They cover one player: events are fired in by hand and the clock is simulated. How several players' clients interact (echoes, triggers, lag, dropped messages) is covered by the offline simulation instead:

```sh
lua5.1 test/sim.lua        # -v prints each test's chat timeline
```

Tested with wow-ui-sim v0.1.40 and Blizzard's Forever UI 1.60.1.70790.

## 1. Get the simulator

Download the **Forever** package for your platform from the [releases page](https://github.com/Osso/wow-ui-sim/releases). Forever package names contain `forever`; the ones without it are Retail.

```sh
curl -LO https://github.com/Osso/wow-ui-sim/releases/download/v0.1.40/wow-ui-sim-v0.1.40-forever-linux-x86_64.tar.gz
tar -xzf wow-ui-sim-v0.1.40-forever-linux-x86_64.tar.gz
```

**Linux:** the build needs ICU 78. If `ldd wow-sim | grep 'not found'` lists `libicui18n.so.78` or `libicuuc.so.78` and you can't install `libicu78`, unpack Ubuntu's package without installing it:

```sh
curl -LO http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu78_78.2-2ubuntu1_amd64.deb
dpkg-deb -x libicu78_78.2-2ubuntu1_amd64.deb icu78
export LD_LIBRARY_PATH="$PWD/icu78/usr/lib/x86_64-linux-gnu"
```

## 2. Give it Blizzard's Forever UI files

wow-sim loads Blizzard's UI from a cache. If the cache is empty, it fills it on first start. Either way works:

### A. From your WoW Forever install

Set `WOW_INSTALL_PATH` to the install root: the folder that contains `Data`, not the game folder that holds `Wow.exe`. wow-sim extracts the UI from `Data` into its cache. See wow-ui-sim's README, under "WoW install location".

This route hasn't been tried for HEH yet.

### B. From the wow-ui-source mirror (no install needed)

[Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) mirrors Blizzard's UI code. Its `forever` branch has one commit per build, titled like `1.60.1 (70790)`.

1. Find your game's build: in game, `/run print(GetBuildInfo())`.
2. Copy the matching commit's files into the cache:

```sh
commit=eac30af597e5aaa43a60f6675ef5fdcea100375f   # 1.60.1 (70790)
curl -L -o ui.tar.gz "https://codeload.github.com/Gethe/wow-ui-source/tar.gz/$commit"
tar -xzf ui.tar.gz

cache="${XDG_CACHE_HOME:-$HOME/.cache}/wow-ui-sim/blizzard-ui/wowforever/AddOns"
mkdir -p "$cache"
cp -R "wow-ui-source-$commit/Interface/AddOns/." "$cache/"
touch "$cache/.wow-ui-sim-blizzard-ui-complete"   # tells wow-sim the cache is ready
```

On Windows the cache is under `%LOCALAPPDATA%`, and on macOS under `~/Library/Caches`, each followed by `wow-ui-sim/blizzard-ui/wowforever/AddOns`.

Things to know about this route:
- It is a workaround. wow-sim's own sync checks every file against Blizzard's content keys. This copy isn't checked; wow-sim only looks for the marker file (as of v0.1.40).
- Also set `WOW_SIM_CASC=0` when you run the tests. It stops wow-sim from loading game art, which needs an install; the tests don't need art.

## 3. Run the tests

```sh
WOW_SIM=/path/to/wow-ui-sim-v0.1.40-forever-linux-x86_64/wow-sim bash test/wowsim.sh
```

`wowsim.sh` copies `addon/` and `test/wowsim/*.lua` into a temporary folder and runs this:

```
wow-sim --no-saved-vars --session-wtf-path <tmp>/WTF --addons-path <tmp>/AddOns run-tests HEH
```

Your WoW folder and its AddOns are never touched. On Windows without bash, do the same by hand: make an `AddOns/HEH` folder containing `addon/` plus a `tests/` folder holding `test/wowsim/*.lua`, then run `wow-sim.exe` with the same options.

## Reading the output

Most of the output is startup logging. The result is at the end:

```
  ✓ heh_test.lua (13 tests)
13 tests, 13 passed, 0 failed
```

A failing test prints its file and line, for example `heh_test.lua:117: expected Player-1-00000001:GUILD, got Player-1-00000001`. The script exits non-zero when a test fails.

Expected noise:
- **`attempt to call field 'IsChatLineCensored' (a nil value)`** in `ChatFrameOverrides.lua`. wow-ui-sim doesn't implement this Forever API, and Blizzard's chat display code calls it when a test fires a chat message. Tests only fail on errors from `FunnyEcho.lua`.
- **ALSA errors** when there's no sound device.
- **`GetBuildInfo()` reports 1.60.1.70707** (the build wow-ui-sim is pinned to), even when the UI files come from a later build.

## Writing tests

Tests live in `test/wowsim/` and use wow-ui-sim's `test(name, fn)` and `assert*` functions. See "Writing Tests" in its README. `heh_test.lua` has helpers for the rest:

| Helper | What it does |
|---|---|
| `Fresh()` | Moves the clock past any open chorus and clears what was captured. Call it first in every test: the addon loads once per run, so its state carries over between tests. |
| `Chat(event, text, sender, guid)` | Fires a `CHAT_MSG_*` event with Forever's full payload. |
| `Trigger(text)` | Fires an incoming HEH trigger (`CHAT_MSG_ADDON`). |
| `PressKey()` | Sends a keypress to HEH's key frame, if it's shown. |
| `Echoes()`, `Cats(frame)` | Count the echoes sent and the cats shown so far. |
| `NoErrors()` | Fails if `FunnyEcho.lua` raised a Lua error. |
| `A_Admin.AdvanceTime(seconds)` | Moves the simulated clock, which drives `GetTime()` and `C_Timer`. |

Things the simulator does differently from the game:
- **Outgoing chat isn't delivered.** `SendChatMessage` writes the raw text to `ChatFrame1`, which is how `Echoes()` counts. Trigger sends are caught with `hooksecurefunc` on `C_ChatInfo.SendAddonMessage`. To have your own echo "come back", fire it with `Chat("CHAT_MSG_GUILD", "HEH", "Me", UnitGUID("player"))`.
- **Restrictions aren't enforced, and lockdown can't be switched on.** The lockdown test replaces `C_ChatInfo.InChatMessagingLockdown` for its duration.
- **Chat payloads need argument 18 (`discordInfo`) with `userID = 0`.** Otherwise Blizzard's chat code goes down its Discord branch and errors.
- **The manual clock is turned on once, at the top of `heh_test.lua`.** wow-sim allows that only once per run.
- **`print` output doesn't reach the console.** To look at a value, put it in an assertion or `error()` message.
