# browserpark

Keep your AI agent's Chrome windows off your Mac's desktop, without breaking the pages inside them.

If you drive a real, visible Chrome with an agent ([agent-browser](https://github.com/vercel-labs/agent-browser), Playwright over CDP, your own scripts), its windows sit on top of your work and take your keyboard focus. browserpark moves them just off the screen, keeps them running normally, and gives you a menu bar icon to bring any of them back.

## Why not just hide or minimise them?

Because that breaks pages. A hidden or minimised window tells the page it isn't visible, so rendering stops, and apps that wait to be visible can stop loading. We hit this with Outlook on the web, where the folders appeared but the message list stayed empty.

Results from a real Chrome, with the flags that normally stop background throttling turned on:

| Method | `document.visibilityState` | `requestAnimationFrame` |
|---|---|---|
| Hide (Cmd-H) | `hidden` | stalled |
| Minimise | `hidden` | stalled |
| **browserpark** | `visible` | runs |

Screenshots, clicks and opening pages keep working while a window is parked, and the page stays the same size. **This depends on the Chrome flags below.** macOS won't let a window leave the screen completely, so a corner of about 40×40 points stays visible at the bottom left.

## Install

You need a Mac with Google Chrome and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/mitev22/browserpark.git
```

```bash
cd browserpark && ./install.sh
```

This builds `~/.local/bin/browserpark` and starts the menu bar icon, now and at each login. It asks for no special permissions, because it only uses Chrome's local debugging port and standard macOS app calls.

To remove it:

```bash
./install.sh --uninstall
```

## Start Chrome with these flags

Without `--disable-backgrounding-occluded-windows`, Chrome marks a parked window as covered and its pages go hidden after a few seconds, the same failure as minimising. Start Chrome like this:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --user-data-dir="$HOME/.chrome-agent" \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --disable-background-timer-throttling
```

The menu and `browserpark status` warn you about any browser missing the first flag.

## Use

Click the menu bar icon (two overlapping windows). It lists every visible Chrome running with `--remote-debugging-port`, no setup needed. Click one to park it or bring it back, or use **Park all**.

From the terminal:

```bash
browserpark status
```

```bash
browserpark park all
```

```bash
browserpark show my-profile
```

```bash
browserpark toggle --port 9222
```

While the menu bar app runs, it also:

- **Returns your focus:** if a parked Chrome grabs focus, such as when an agent opens a tab, focus goes back to the app you were using, usually within about 60 ms. That's a repair, not a prevention: keystrokes in that gap can be lost, and if your app is in full screen the screen flickers to the desktop for about 150 ms, because macOS switches Spaces when Chrome takes focus. See [Known limitation](#known-limitation-opening-tabs-takes-focus).
- **Parks new windows:** a new window from a parked browser gets parked within about 3 seconds.

### Park automatically at launch

Add one line after Chrome's debugging port is up in your launch script:

```bash
browserpark park --port 9222
```

The window shows briefly first, because Chrome ignored `--window-position` for an off-screen spot in our testing.

### Names and start commands (optional)

Browsers are named after their `--user-data-dir` folder. To set your own names, and to start a browser from the menu when it isn't running, create `~/.config/browserpark/config.json`:

```json
[
  { "name": "work", "port": 9225, "start": "~/bin/start-work-chrome.sh" }
]
```

`start` runs as a bash command, so only put commands you trust there.

## Good to know

- **Logins:** you can't see a parked window, so bring it back before logging in or doing MFA.
- **Dock and Cmd-Tab:** clicking a parked Chrome's Dock icon or Cmd-Tabbing to it appears to do nothing, because focus bounces straight back. Use the menu.
- **Showing from a script:** `browserpark show` works while the menu app runs, because it moves the window before taking focus.
- **Keyboard focus:** a parked page reports `document.hasFocus()` as false, like any background window. Pages that only react when focused may behave differently, so bring the window back if something seems stuck.
- **Page titles:** the menu shows each browser's first tab title. It stays on your Mac.

## Known limitation: opening tabs takes focus

Chrome activates itself when a tab is selected over CDP (`Target.activateTarget`), which is what `agent-browser tab new` does. browserpark can't block that from outside Chrome. Navigating in the current tab, clicking, screenshots and `eval` don't take focus, so prefer `open` in an existing tab where you can. Using a maximised window instead of full screen avoids the Space switch, but not the brief loss of focus.

## Not tested yet

- More than one display. The maths uses the combined desktop area, but it has only been run on a single laptop screen.
- Chromium builds other than Google Chrome.
- Other versions of macOS. It was tested on macOS 27 and should need at least macOS 14.4 to build.

## Tests

The tests drive a throwaway Chrome on port 9299 with a temporary profile. They need `agent-browser` and `node`, and they'll briefly take your focus and open windows.

```bash
tests/test_park.sh
```

## License

MIT. browserpark is an independent project, not affiliated with Vercel, Google or Anthropic.
