# Hanadi Timer

[العربية](README.ar.md)

A round LED desk timer for your Mac that floats above your other windows. Tap it to count up from 00:00, or pick 10, 20, 40 or 60 minutes. Take breaks without losing your work time, and see how long you worked today.

<p align="center"><img src="assets/screenshot.png" width="320" alt="Hanadi Timer counting down a 20-minute focus session"></p>

## Features

- **Count up or count down.** Tap the digits to count up; tap 10 / 20 / 40 / 60 for a focus countdown. Seconds always show (H:MM:SS past an hour).
- **Breaks that don't reset your work.** Break pauses your work timer; "Back to work" carries on where you stopped.
- **Today's log.** Right-click → Today shows every work stretch and break with times. A permanent history is kept on your Mac.
- **Knows when you're away.** Sleep, lock or 15 minutes without input pauses work at your last touch, then asks: resume, or count the time as a break.
- **Fresh every day.** At midnight the day closes and a new one starts.
- **Floats on top**, on every desktop. Three sizes, drag to move, menu bar icon with the live time, ⌃⌥T to show or hide.
- **Motivating sounds** and milestone cheers (every 15 minutes, halfway, last minute, every hour today).
- **Arabic and English**, following your Mac's language, or pick one in the right-click menu.
- **Optional Notion sync.** Each work stretch and break becomes a row in a Notion "Work log". Your Notion token stays in your Mac's Keychain.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode Command Line Tools (free; `xcode-select --install`)

No admin rights, accounts or passwords needed.

## Install with Claude

Paste this to Claude (Claude Code, or Claude with access to your Mac):

> Install Hanadi Timer from REPO_URL on my Mac, following its INSTALL-WITH-CLAUDE.md.

## Install by hand

```bash
git clone REPO_URL hanadi-timer
cd hanadi-timer
./build.sh
open ~/Applications/"Hanadi Timer.app"
```

The app is built into `~/Applications`. Find it later with Spotlight: **Hanadi Timer**.

## Notion (optional)

1. Create an internal connection in Notion and copy its API token (Notion: Settings → Connections → Develop or manage integrations, or notion.so/profile/integrations).
2. Right-click the timer → **Connect Notion…** → paste the token.
3. In Notion, open the page where you want the log → **•••** → **Connections** → add your connection. Copy the page link and paste it into the timer's second field → **Save**. A "Work log" database is created in that page. You can also paste the link of an existing Work log.

Paste the token only into the timer's window, never into a chat.

## Using it

| Do this | To |
|---|---|
| Tap the digits | Start counting up, pause, resume |
| Tap 10 / 20 / 40 / 60 | Start a focus countdown |
| Break / Back to work | Pause work for a break, then carry on |
| Drag the edge | Move it |
| Corner handle, pinch, or right-click → Size | Resize |
| Right-click | Today's log, language, Notion, stay on top, open at login, quit |
| ⌃⌥T or the menu bar icon | Show or hide |

## Files on your Mac

- Work history: `~/Library/Application Support/Hanadi Timer/work-log.jsonl` (one line per stretch)
- Settings: the app's preferences (`com.hanadialotaibi.timer`)
- Notion token: macOS Keychain item "Hanadi Timer Notion"

## Credits

Design and brand: Hanadi Alotaibi. Fonts: [Raleway](assets/fonts/Raleway/OFL.txt) and [JetBrains Mono](assets/fonts/JetBrainsMono/OFL.txt), both under the SIL Open Font License.
