# Installing Hanadi Timer (instructions for Claude)

You are helping someone install Hanadi Timer, a small Mac app built from this repository. The person may not be technical. Follow these steps in order.

## Ground rules

- **Answer in the person's language.** If they write in Arabic, reply in plain Modern Standard Arabic; otherwise match their language. Keep each message short: one step at a time.
- **No admin rights, no passwords.** Nothing here needs `sudo` or an administrator password. Never ask for a password, and never ask anyone to paste a token, key or password into the chat.
- Explain what each step does in one plain sentence before doing it.

## 1. Check the Mac

- macOS 15 or later: `sw_vers -productVersion`. If it is older, tell them the app needs macOS 15 (Sequoia) and stop.
- Swift tools: `xcode-select -p`.
  - If that prints a path, continue.
  - If it fails, run `xcode-select --install`. A macOS window opens asking to install the Command Line Tools. Tell them to click **Install**, agree, and wait (it can take 5–15 minutes). Wait for them to say it finished, then check `xcode-select -p` again.

## 2. Get the code and build

```bash
git clone REPO_URL ~/hanadi-timer
cd ~/hanadi-timer
./build.sh
```

`build.sh` compiles the app into `~/Applications/Hanadi Timer.app` (no admin rights needed). If `~/hanadi-timer` already exists, `cd` into it and run `git pull` instead of cloning.

## 3. Open it

```bash
open ~/Applications/"Hanadi Timer.app"
```

A round timer appears near the top-right of the screen, plus a timer icon in the menu bar. Tell them:

- Tap the digits to start counting up; tap 10 / 20 / 40 / 60 for a countdown.
- **Break** pauses work; **Back to work** carries on.
- Right-click the timer for today's log, language (System / English / العربية), size, and **Open at Login** (so it starts with the Mac).
- ⌃⌥T (Control + Option + T) shows or hides it. It can also be found in Spotlight as "Hanadi Timer".

## 4. Optional: send work hours to Notion

Only if they want it. They do every step themselves; you guide.

1. In Notion, create an internal connection and copy its API token: open notion.so/profile/integrations (Notion may label it **Connections**, e.g. app.notion.com/developers/connections) → **New** → name it (for example "Hanadi Timer") → choose their workspace → type **Internal** → save → copy the token.
2. Right-click the timer → **Connect Notion…** → paste the token into the first field. **The token goes only into this window, never into the chat.**
3. In Notion, open (or create) the page where the log should live → **•••** (top right) → **Connections** → add the connection from step 1.
4. Copy that page's link (**•••** → **Copy link**) and paste it into the timer's second field → **Save**. The timer creates a "Work log" database in the page and shows "Work log ready ✓". If they already have a Work log database, its link works too.
5. To test: take a break of at least a minute, then tap **Back to work**. A Break row appears in the Work log within a minute.

Optional extras they can add in Notion by hand (or you can, if you have a Notion connector and they ask): a **Timeline** view by Start/End, a **Calendar** view by Day, or a sum of Hours grouped by Day.

If the timer's menu says "Notion: share the page with your connection", step 3 was missed. "Key not accepted" means the token was copied wrong; they can paste it again in **Notion Settings…**.

## 5. Updating later

```bash
cd ~/hanadi-timer && git pull && ./build.sh
```

Their history and settings are kept. If the timer was running, quit it first (right-click → Quit), then open it again after the build.

## Uninstalling

Quit the timer, then delete `~/Applications/Hanadi Timer.app`. Their history stays in `~/Library/Application Support/Hanadi Timer/` unless they delete that folder too.
