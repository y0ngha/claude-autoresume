# claude-autoresume

Automatically continues Claude Code sessions that stalled on the **5‑hour usage
limit** — resuming each session **in place, right after it resets**, even while
you're asleep — plus a live **session‑manager dashboard**.

*(한국어 README: [README.md](README.md))*

- Each Claude session runs in its own window of a `tmux` session (`claude`).
- A `launchd` daemon periodically scans every window. When it sees a limit
  message, it waits until the stated **resets** time, then types "continue" into
  that window so the session picks up **in place**, keeping its context.
- Because it operates at the **terminal layer**, each window can use a different
  launch command / profile — it doesn't care.
- `csm` gives you a real‑time dashboard to watch and control all sessions.

> Platform: **macOS** (uses `launchd` + BSD `date`). UI language defaults to
> **English** (`CAR_LANG=ko` switches to Korean); all limit/usage detection matches
> Claude's **English** on‑screen text.

---

## Requirements (3rd‑party)

| Tool | Why | Install |
|---|---|---|
| **tmux** | Runs each Claude session in a detachable background window the daemon can read/type into | `brew install tmux` (the installer does this for you) |
| **Claude Code CLI** | The thing being kept alive | already installed |
| bash / launchd / osascript | Daemon, startup registration, macOS notifications | built into macOS |

No other dependencies. Nothing is sent anywhere — it only reads your local
terminal and types into it.

---

## Quick start

```sh
bash ~/Project/claude-autoresume/install.sh   # checks tmux, registers daemon, wires shell funcs
source ~/.zshrc                               # (or just open a new terminal)

cbg job1                                       # start a session
csm                                            # open the dashboard
```

What `install.sh` does: ① ensures tmux (via brew) ② marks scripts executable
③ registers & starts the `launchd` daemon ④ adds the shell functions to `~/.zshrc`.

> This README uses `~/Project/claude-autoresume` in examples. **If you cloned it
> elsewhere**, just change the path in the commands — the scripts resolve their own
> location (no hardcoded paths), so the tool works from any folder.

---

## Everyday commands

```sh
cbg <window> [command] [args...]   # run claude in a new window; args after the command pass through
cba [window]                       # attach; with no arg, lists windows and lets you pick. Detach: Ctrl-b then d
csm                                # ★ the session-manager dashboard
cbls                               # list windows
cbpeek <window>                    # peek at the bottom 30 lines of a window
cbk <window>                       # kill one window
cbkill                             # kill everything
```

Examples:
```sh
cbg job1                              # default `claude`
cbg job2 claude --continue            # extra args pass straight through
cbg job3 claude-work --resume         # `claude-work` = your own profile launcher (a shell function)
```
> The 2nd arg is the command to run; everything after it is forwarded verbatim
> (quote anything with spaces). The working directory is wherever you ran `cbg`.

### Minimal tmux knowledge
- **Detach**: `Ctrl-b`, release, then `d` — the session keeps running in the background.
- **Switch window**: `Ctrl-b` then a number, or `w` for a list.
- You rarely need raw tmux — `cbg` / `cba` / `csm` / `cbk` cover the common cases.

---

## The dashboard (csm)

![csm dashboard](imgs/run.png)

```
 ⌘ Claude Session Manager   16:09:40   ● auto-resume ON
  [a]attach [n]new [k]kill [p]auto-toggle [t]alerts [l]lang [r]refresh [q]quit · refresh 10s

  job1            PERSONAL  🟢 working     · active 2s ago · 5h 76% · 7d 8%
  job2            WORK      🟡 limit-wait  · resets 3:30pm (12m left)  · active 5m ago
  job3            BOTH      🔵 background  · active 8m ago  ⏸excluded

  3 sessions  ·  🟢 working 1  🔵 background 1  🟡 limit-wait 1  ⛔ blocked 0  ⚪ idle 0
```

**States** (row and summary use identical wording)
- 🟢 **working** — the agent is *actually generating* (screen shows `esc to interrupt`).
  Simple screen changes — typing a prompt, `/status`, the clock ticking — are **not** counted as working.
- 🔵 **background** — main view is static but a background shell/agent/workflow is running.
- 🟡 **limit-wait** — 5h session limit. Once the resets time passes, the daemon continues it (shows the countdown).
- ⛔ **blocked** — org/weekly limit, etc. Auto-resume is pointless → notify only, needs manual attention.
- ⚪ **idle** — genuinely stopped, waiting for your input (finished, or asking a question).

**Columns**: window · profile · state · usage left · last activity · last auto-inject · `⏸excluded`.

**Keys**: `a` attach (pick a window) · `n` new session · `k` kill · `p` per-window
auto-resume toggle · `t` **per-state alerts** · `l` **language toggle (en↔ko, applied to
the daemon too)** · `r` refresh · `q` quit. Pass an interval (`csm 5`); `csm --once` prints
one frame. **Every interactive prompt cancels with `esc` (or empty input)** and returns to
the dashboard. The dashboard uses the **alternate screen buffer** (no scrollback buildup;
your original screen is restored on quit).

**The [n] profile menu is dynamic**: it combines `NEW_SESSION_MENU` from
`config.sh` (default: just `claude`) with any `~/.claude-*` config directories it
auto-detects. If you use profile launchers (shell functions), add them to
`NEW_SESSION_MENU`.

---

## How auto-resume works (limit buckets)

| On-screen text (example) | Bucket | Daemon action |
|---|---|---|
| `You've used 97% of your session limit` | early warning | **ignore** |
| `You've hit your session limit · resets 1:40pm` | 5h session limit (text) | **wait for resets, then inject "continue"** |
| Choice menu (`Stop and wait for limit to reset` + `Enter to confirm`) | 5h session limit (menu) | **auto-select option 1 "Stop and wait"** → then inject after reset |
| `You've hit your org's monthly spend limit …` | billing/weekly | **do not inject + notify** |

- It distinguishes `used NN%` (warning) from `hit … limit` (blocked), and only
  reads the **bottom few lines**, so old text scrolled up after a resume isn't misread.
- It parses the resets time and **waits until then**; if parsing fails it falls
  back to periodic retries.
- A **choice menu** can't be dismissed by typed text, so the daemon selects
  "Stop and wait for limit to reset" (option 1) with arrow keys + Enter. It only acts
  on an **active** menu (the confirm prompt `Enter to confirm` is present, so leftover
  text after selection isn't re-triggered); after selecting, once the reset passes it
  falls through to the normal text path and injects "continue".

---

## Notifications & background awareness

- **Per-state transition alerts**: when a window settles into a new state, you get one
  macOS notification, gated by `NOTIFY_WORKING` / `NOTIFY_BACKGROUND` / `NOTIFY_LIMIT` /
  `NOTIFY_BLOCKED` / `NOTIFY_IDLE` (`config.sh`). Defaults: 🟡 limit / ⛔ blocked / ⚪ idle
  on; 🟢 working / 🔵 background off. Toggle any of them live with **`t` in csm**
  (see [Per-state alerts](#per-state-alerts-csm-t)).
- **Background awareness**: a window running a background shell/agent/workflow (or a
  sub-agent still streaming tokens) is classified 🔵 **background**, not ⚪ idle — so a
  running background job never fires a false "finished" (idle) alert.
- A transition must be **stable for 2 consecutive scans** before it notifies (anti-flap).
  Notifications use `osascript` (native macOS banners); defensive guards ensure a failed
  screen capture or an unnamed window can never fire a bogus notification.

---

## Per-window auto-resume on/off (default ON)

To exclude specific windows (manage them yourself):
- In csm press `p` → enter the window name → toggle. Excluded windows show `⏸excluded`.
- Or list window names, one per line, in `disabled.list`.

---

## Configuration (`config.sh`)

| Key | Default | Meaning |
|---|---|---|
| `CONTINUE_PROMPT` | i18n (en/ko) | text injected to resume; default follows `CAR_LANG`, override via `CAR_CONTINUE_PROMPT` |
| `RESUME_REGEX` | … | (A) limit text that triggers auto-resume |
| `BLOCKED_NOAUTO_REGEX` | … | (B) text that only notifies (no inject) |
| `IGNORE_REGEX` | `used NN% of` | early-warning text to ignore |
| `WORKING_REGEX` | `esc to interrupt` | detects 🟢 working (only shown while generating) |
| `BACKGROUND_REGEX` | … | detects 🔵 background (shell/agent/workflow/sub-agent token counter) |
| `LIMIT_MENU_OPT` / `LIMIT_MENU_ACTIVE` | `stop and wait…` / `enter to confirm…` | detects the active limit choice menu |
| `NEW_SESSION_MENU` | `("claude")` | csm [n] new-session menu candidates |
| `NOTIFY_WORKING` / `_BACKGROUND` | 0 / 0 | notify on → 🟢 working / 🔵 background |
| `NOTIFY_LIMIT` / `_BLOCKED` / `_IDLE` | 1 / 1 / 1 | notify on → 🟡 limit-wait / ⛔ blocked / ⚪ idle |
| `INTERVAL` | 60 | scan period (seconds) |
| `MIN_RESEND_GAP` | 540 | min seconds between re-injects/re-alerts per window |
| `RESET_BUFFER` | 30 | inject this many seconds after the resets time |
| `CAPTURE_LINES` | 15 | how many bottom lines to judge from |

Apply changes: `launchctl kickstart -k gui/$(id -u)/com.claude-autoresume`

### Per-state alerts (csm `t`)
A one-shot macOS notification when a window **transitions** into a state. By default
only 🟡 limit-wait, ⛔ blocked, and ⚪ idle are on (🟢 working / 🔵 background are noisy,
off). Toggle instantly with **`t` in csm** — saved to `notify.conf`, shared with the
daemon. A transition must be stable for 2 consecutive scans before it fires (anti-flap).

### Environment variables (optional)
- `CAR_LANG` — UI language: `en` (default) or `ko`. Applies to dashboard, prompts,
  notifications, logs, and the injected resume text. Easiest way to switch is the
  **`l` key in csm** (toggles instantly, saved to the `lang` file which the daemon
  shares). Precedence: env `CAR_LANG` > `lang` file > `en`.
- `CAR_SESSION` — tmux session name to watch (default `claude`)
- `CAR_LABEL` — launchd label (default `com.claude-autoresume`)
- `CAR_CONTINUE_PROMPT` — the resume text
- `TMUX_TMPDIR` — tmux socket location (default `/tmp`; keep it to share with the daemon)

---

## Startup registration (launchd daemon)

`install.sh` writes `~/Library/LaunchAgents/com.claude-autoresume.plist` with
`RunAtLoad` + `KeepAlive`, so the daemon **starts at login and restarts if it dies**.

```sh
launchctl list | grep com.claude-autoresume                                   # status
tail -f ~/Project/claude-autoresume/autoresume.log                            # logs
launchctl kickstart -k gui/$(id -u)/com.claude-autoresume                     # apply config (restart)
launchctl bootout   gui/$(id -u)/com.claude-autoresume                        # stop
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-autoresume.plist  # start
```

---

## Files

- `config.sh` — settings + shared helpers (detection/parsing). **Edit here.**
- `i18n.sh` — UI string tables (en/ko). Add/edit wording here.
- `autoresume.sh` — the watcher daemon (`bash autoresume.sh --once` to test one pass)
- `session-manager.sh` — the dashboard (csm)
- `shell-functions.zsh` — cbg/cba/csm etc.
- `install.sh` / `uninstall.sh`
- `disabled.list` — excluded windows (runtime, optional)
- `lang` — UI language setting (toggled by csm `l`, runtime)
- `notify.conf` — per-state alert on/off (toggled by csm `t`, runtime)
- `autoresume.log`, `state/`, `.sm/` — logs · state · cache (runtime)

> **Public-repo safety**: `.gitignore` excludes runtime/personal traces — `state/`,
> `.sm/` (pane pid & profile cache), `disabled.list` (window names), `lang` (language
> setting), `notify.conf` (alert settings), `*.log` (window names & activity). No
> usernames, emails, absolute paths, or personal profile names are hardcoded — profiles,
> paths, and the tmux location are all detected dynamically at runtime.

---

## (Optional) `.zshrc` setup

**Wire up the shell functions** — `install.sh` adds this line automatically. To do
it by hand, add it to `~/.zshrc`. This one line provides every function —
`cbg` / `cba` (with the window picker) / `csm` (with the `l` language toggle):
```sh
source ~/Project/claude-autoresume/shell-functions.zsh
```
> If you have an older setup where `cbg`/`cba`/… were **pasted directly** into
> `~/.zshrc`, delete that block and replace it with the `source` line above (no
> hardcoded paths, and you get the latest features).

**Profile launchers (optional)** — if you run Claude with multiple accounts/configs,
define a launcher function per profile; then `cbg <window> <function>` uses it and
the `[n]` menu can too:
```sh
claude-work()     { CLAUDE_CUSTOM_PROFILE=WORK     command claude --dangerously-skip-permissions "$@"; }
claude-personal() { CLAUDE_CUSTOM_PROFILE=PERSONAL CLAUDE_CONFIG_DIR=~/.claude-personal command claude --dangerously-skip-permissions "$@"; }
```
> The `source` line and the profile launchers are **independent** (it all works with
> plain `claude` too). csm's profile badge reads the running process's
> `CLAUDE_CUSTOM_PROFILE`, else the `CLAUDE_CONFIG_DIR` folder name
> (`.claude-personal` → `personal`), else `default`.

## (Optional) statusline setup — for the usage-left display

The "5h 76% · 7d 8%" **usage left** figures are parsed from Claude's bottom
statusline. The **default statusline doesn't include them — a custom statusline is
required**. Without one this column is simply omitted, so it's fine to skip. Make
your custom statusline emit strings like `5h N% left / 7d N% left` and csm picks
them up automatically. If your wording differs, adjust `USAGE_REGEX_SHORT/LONG` in
`config.sh`.

---

## Tuning the weekly-limit text

Once you know your account's exact weekly-limit wording, add its keywords to
`BLOCKED_NOAUTO_REGEX` in `config.sh` (currently guessed as `weekly limit|7-day limit`):
```sh
cbpeek <window>   # read the actual limit message → update config.sh → kickstart -k
```

## Uninstall

```sh
bash ~/Project/claude-autoresume/uninstall.sh          # remove daemon/plist
bash ~/Project/claude-autoresume/uninstall.sh --purge  # also delete the folder
# + remove the `source …/shell-functions.zsh` line from ~/.zshrc
```
