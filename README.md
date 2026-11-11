# Hanadi Timer

[العربية](README.ar.md)

A round LED desk timer for your Mac that floats above your other windows. Tap it to count up from 00:00, or pick 10, 20, 40 or 60 minutes. Take breaks without losing your work time.

<p align="center"><img src="assets/screenshot.png" width="320" alt="Hanadi Timer counting down a 20-minute focus session"></p>

## Two ways to use it

The first time it opens, the timer asks:

- **Just a timer.** Count up, countdowns, breaks and sounds. Nothing is saved.
- **Track my hours.** The same, plus a log of your day: today's total on the dial, every work stretch and break with its times, a history kept on your Mac, and **Export my hours…** as a spreadsheet file (CSV) for Numbers or Excel. No account needed.

You can switch any time: right-click the timer → **Use as**.

## Features

- **Count up or count down.** Tap the digits to count up; tap 10 / 20 / 40 / 60 for a focus countdown. Seconds always show (H:MM:SS past an hour).
- **Breaks that don't reset your work.** Break pauses your work timer; "Back to work" carries on where you stopped.
- **Knows when you're away.** Sleep, lock or 15 minutes without input pauses work at your last touch, then asks what to do with that time.
- **Floats on top**, on every desktop. Three sizes, drag to move, menu bar icon with the live time, ⌃⌥T to show or hide.
- **Motivating sounds** and milestone cheers (every 15 minutes, halfway, last minute).
- **Arabic and English**, following your Mac's language, or pick one in the right-click menu.

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

## Using it

| Do this | To |
|---|---|
| Tap the digits | Start counting up, pause, resume |
| Tap 10 / 20 / 40 / 60 | Start a focus countdown |
| Break / Back to work | Pause work for a break, then carry on |
| Drag the edge | Move it |
| Corner handle, pinch, or right-click → Size | Resize |
| Right-click | Use as, today's log, export, language, stay on top, open at login, quit |
| ⌃⌥T or the menu bar icon | Show or hide |

## Files on your Mac

- With **Track my hours**: history in `~/Library/Application Support/Hanadi Timer/work-log.jsonl` (one line per stretch)
- Settings: the app's preferences (`com.hanadialotaibi.timer`)

## Optional extras

### Send your hours to Notion (advanced)

Only with **Track my hours**, and only if you use Notion. Each work stretch and break becomes a row in a Notion "Work log".

1. Create an internal connection in Notion and copy its API token (Notion: Settings → Connections → Develop or manage integrations, or notion.so/profile/integrations).
2. Right-click the timer → **Send to Notion (advanced)…** → paste the token. It is kept in your Mac's Keychain only. Never paste it into a chat.
3. In Notion, open the page where you want the log → **•••** → **Connections** → add your connection. Copy the page link and paste it into the timer's second field → **Save**. A "Work log" database is created in that page (or paste the link of an existing Work log).

After you update the app, macOS may ask once whether Hanadi Timer can use its Notion token. Enter your Mac password and click **Always Allow**.

## Credits

Design and brand: Hanadi Alotaibi. Fonts: [Raleway](assets/fonts/Raleway/OFL.txt) and [JetBrains Mono](assets/fonts/JetBrainsMono/OFL.txt), both under the SIL Open Font License.
