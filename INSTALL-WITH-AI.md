# Installing Hanadi Timer (instructions for an AI assistant)

You are an AI assistant that can run commands on the person's Mac (for example Claude Code, Gemini CLI or Codex), helping them install Hanadi Timer from this repository. The person may not be technical. Follow these steps in order.

## Ground rules

- **Answer in the person's language.** If they write in Arabic, reply in plain Modern Standard Arabic; otherwise match their language. Keep each message short: one step at a time.
- **No admin rights, no passwords.** Nothing here needs `sudo` or an administrator password. Never ask for a password, and never ask anyone to paste a token, key or password into the chat.
- **Keep it simple.** The install is: check the tools, clone, build, open, and ask one question. Don't bring up Notion or anything under "Optional extras" unless the person asks for it.
- Explain what each step does in one plain sentence before doing it.

If you can't run commands on their Mac (a chat-only assistant), say so and point them to the download route in the README instead.

## 1. Check the Mac

- macOS 15 or later: `sw_vers -productVersion`. If it is older, tell them the app needs macOS 15 (Sequoia) and stop.
- Swift tools: `xcode-select -p`.
  - If that prints a path, continue.
  - If it fails, run `xcode-select --install`. A macOS window opens asking to install the Command Line Tools. Tell them to click **Install**, agree, and wait (it can take 5–15 minutes). Wait for them to say it finished, then check `xcode-select -p` again.

## 2. Get the code and build

```bash
git clone https://github.com/Hanadi-designs/hanadi-timer ~/hanadi-timer
cd ~/hanadi-timer
./build.sh
```

`build.sh` compiles the app into `~/Applications/Hanadi Timer.app` (no admin rights needed). If `~/hanadi-timer` already exists, `cd` into it and run `git pull` instead of cloning.

## 3. Open it

```bash
open ~/Applications/"Hanadi Timer.app"
```

A round timer appears near the top-right of the screen, plus a timer icon in the menu bar.

## 4. Ask one question

Ask them, in their language: **"Just a timer, or do you also want to track your hours?"** (Arabic: «مؤقت فقط، أم تريد أيضًا تتبّع ساعاتك؟»)

The timer shows the same two buttons on its first launch. Tell them to click the one they chose:

- **Just a timer** (مؤقت فقط): count up, countdowns, breaks and sounds. Nothing is saved.
- **Track my hours** (تتبّع ساعاتي): the same, plus today's total, a log of every work stretch and break, and **Export my hours…** (right-click) to save a spreadsheet file for Numbers or Excel. Everything stays on their Mac; no account needed.

They can change it later: right-click → **Use as**.

## 5. Show them around (briefly)

- Tap the digits to start counting up; tap 10 / 20 / 40 / 60 for a countdown.
- **Break** pauses work; **Back to work** carries on.
- Right-click for size, language (System / English / العربية) and **Open at Login** (so it starts with the Mac).
- ⌃⌥T (Control + Option + T) shows or hides it. It can also be found in Spotlight as "Hanadi Timer".

That's the whole install.

## Updating later

```bash
cd ~/hanadi-timer && git pull && ./build.sh
```

Their settings and history are kept. If the timer was open, quit it first (right-click → Quit), then open it again after the build.

## Uninstalling

Quit the timer, then delete `~/Applications/Hanadi Timer.app`. With "Track my hours", their history stays in `~/Library/Application Support/Hanadi Timer/` unless they delete that folder too.

---

## Optional extras (only if the person asks)

### Sending hours to Notion

Needs **Track my hours**. The person does every step themselves; you guide.

1. Open https://app.notion.com/developers/connections → **Build** › **Internal connections** → **Create a new connection**.
2. Name it (for example "Hanadi Timer"), keep **API token** as the authentication method → **Create connection**.
3. On the **Configuration** tab, copy the token.
4. On the **Content access** tab → **Edit access** → pick the page where the log should live.
5. Right-click the timer → **Send to Notion (advanced)…** → paste the token into the first field. **The token goes only into this window, never into the chat.**
6. In Notion, open that page → **•••** (top right) → **Copy link**. Paste it into the timer's second field → **Save**. The timer creates a "Work log" database in the page and shows "Work log ready ✓". If they already have a Work log database, its link works too.
7. To test: take a break of at least a minute, then tap **Back to work**. A Break row appears in the Work log within a minute.

Optional: a **Timeline** view by Start/End, a **Calendar** view by Day, or a sum of Hours grouped by Day can be added in Notion by hand (or by you, if you have a Notion connector and they ask).

After an app update, macOS may show its own window asking whether Hanadi Timer can use the Notion token. That window is macOS asking the person for their Mac password; they type it there themselves and click **Always Allow**. Never ask for it in chat.

If the timer's menu says "Notion: give your connection access to the page", step 4 was missed or a different page was linked. "Key not accepted" means the token was copied wrong; they can paste it again in **Notion Settings…**.
