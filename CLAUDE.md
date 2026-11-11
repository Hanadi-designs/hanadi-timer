# Hanadi Timer

If someone asked you to install, update or set up this timer, follow [INSTALL-WITH-AI.md](INSTALL-WITH-AI.md).

For code changes: Swift sources are `main.swift` (timer, dial, menus), `notion.swift` (Notion sync, Keychain, Connect window) and `strings.swift` (language). Text lives in `Resources/en.lproj` and `Resources/ar.lproj`; add every new string to both. Build with `./build.sh` (`APP_DIR=/tmp/x ./build.sh` to build elsewhere, `./build.sh release` for the download zip). Self-tests that touch no saved data: `--selftest`, `--awaytest`, `--featuretest`, `--snapshot <dir>` (set `TIMER_LANG=ar` for Arabic, `TIMER_USAGE=timer` for the just-a-timer mode).
