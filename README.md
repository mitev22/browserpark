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

Without `--disable-backgrounding-occluded-windows`, Chrome can treat a parked window as covered and its pages go hidden, the same failure as minimising. We saw this in some test runs but not all, so don't rely on going without it. Start Chrome like this:

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

While the menu bar app runs, it also parks new windows from a parked browser, within about 3 seconds.

It doesn't fight Chrome for keyboard focus. An earlier version sent focus back whenever a parked Chrome took it, but it couldn't tell an agent from you swiping to the desktop or picking Chrome in Cmd-Tab, so it kept throwing people back into the app they'd just left. Use [the proxy](#stop-agents-taking-your-focus-the-proxy) to stop agents taking focus.

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
- **Dock and Cmd-Tab:** each browser gets its own identical Chrome icon. Picking a parked one makes it the active app, but its windows stay off-screen, so it looks like nothing happened. Use the menu to bring it back.
- **Keyboard focus:** a parked page reports `document.hasFocus()` as false, like any background window. Pages that only react when focused may behave differently, so bring the window back if something seems stuck.
- **Page titles:** the menu shows each browser's first tab title. It stays on your Mac.

## Stop agents taking your focus: the proxy

Chrome makes itself the active app whenever a tab is selected over CDP, which is what `agent-browser tab new` does. If your app is in full screen, macOS then switches you to the desktop's Space mid-sentence, and what you type goes to Chrome.

The proxy prevents it. Start it for a browser's debugging port, then connect your client to that port plus 10000:

```bash
nohup browserpark proxy --port 9222 >/dev/null 2>&1 &
```

```bash
agent-browser connect 19222 --session my-session
```

Your browser and its logins don't restart. Playwright's `connect_over_cdp("http://127.0.0.1:19222")` works the same way.

| Client asks for | What the proxy does |
|---|---|
| A new tab (`Target.createTarget`) | Opens it in its own background window, parked if the browser is parked. A background tab in a shared window wouldn't work, because its page reports itself as hidden. |
| Selecting a tab (`Target.activateTarget`, `Page.bringToFront`) | Answers without telling Chrome if the tab is already showing in its window. |
| Anything else | Passes it through unchanged. |

In our tests, with another app in front, agent-browser and Playwright opened, switched, clicked and closed tabs without Chrome taking focus once.

**Limits**

- **New tabs are separate windows.** Pages still work normally, but you'll see one parked window per tab instead of tabs in one window.
- **Tabs sharing a window still take focus.** Selecting a hidden tab in a shared window is the only way to make it visible, so the proxy passes it on. Shared windows come from tabs opened before the proxy, a client that connects to Chrome's own port instead of the proxy, and Chrome restoring a previous session into one window. Close those tabs and open them again through the proxy.
- **Links and pop-ups:** only CDP requests are rewritten. Tabs a page opens by itself aren't, so they can take focus. The menu bar app parks their windows afterwards.
- **Keeping it running:** nothing restarts the proxy if it stops, and clients connected through it lose their connection. Start it from your launch script, and restart it after updating browserpark.
- **Security:** it listens on 127.0.0.1 only, the same exposure as Chrome's own debugging port.

Without the proxy, prefer `open` in an existing tab. Using a maximised window instead of full screen should also avoid the jump to the desktop, though we haven't tested that.

## Not tested yet

- More than one display. The maths uses the combined desktop area, but it has only been run on a single laptop screen.
- Chromium builds other than Google Chrome.
- Other versions of macOS. It was tested on macOS 27 and should need at least macOS 14.4 to build.

## Tests

The tests drive a throwaway Chrome on port 9299 with a temporary profile. They need `agent-browser` and `node`, and they'll briefly take your focus and open windows. Run them more than once, because some focus problems only show up in some runs.

```bash
tests/test_park.sh
```

```bash
tests/test_proxy.sh
```

## License

MIT. browserpark is an independent project, not affiliated with Vercel, Google or Anthropic.
