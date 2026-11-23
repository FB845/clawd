# Clawd — a Claude desktop pet for macOS

A tiny native macOS app: a pixel-art Clawd that lives on your screen, floating above your
other windows, and doubles as a live status buddy for Claude Code.

## Look and feel

- Clawd is drawn flat, after the official 2D Claude Code mascot, in units of one eye: an 8 x 6 body with
  square corners, 1 x 1 square eyes one unit in from each side, 2 x 2 arms, and four 1 x 2 legs. There is no
  outline or shading. To bring the old outline, shading, and highlights back, set `Clawd.shaded = true` in
  `Sources/Sprite.swift`.
- Motion is spring-driven: it squashes on landing, stretches when it jumps, swings when you carry it,
  leans into its walk, sways when dancing, and breathes when idle.
- Effects are particles that stay put in the world: dust puffs, hearts, floating Zs, music notes,
  sparkles, cookie crumbs, sweat drops, rain that splashes on its umbrella, and drifting snow.
- Claude Code status shows in a pixel thought bubble with animated icons; messages appear in a
  pixel speech bubble that types itself out.
- `build/preview.png` and `build/preview-dark.png` show every look on light and dark backgrounds.

## Build and run

```bash
./build.sh
open build/Clawd.app
```

Needs only the Xcode Command Line Tools (`swiftc`), no Xcode project, no dependencies.
The app has no Dock icon; a small Clawd appears in the menu bar with the controls.

## What it does on its own

- Wanders along the bottom of the screen, pauses, blinks, and watches your cursor.
- Sits on your windows: drop it on a window's top edge, or it jumps up on its own. It walks
  along the edge, rides the window when you move it, and hops down when it closes.
- Thinks now and then (spinning Claude asterisk) and falls asleep if you ignore it.
- Click it to pet it (blush + hearts). Click while asleep to wake it.
- Drag it anywhere and let go; it drops with gravity and bounces. Flick it to throw it.
- Right-click it, or use the menu bar icon, for Pet, Sleep/Wake, Come here, the
  "Sit on windows" and "Dance to music" toggles, and Quit.

## Token usage in the menu bar

The menu bar shows Clawd's icon with today's token count next to it. Click it for a usage panel at the
top of the menu:

- **Today:** tokens Claude took in or wrote, with the cache re-reads shown separately so the big
  re-used-context number doesn't drown out real usage. A breakdown shows input, output, cache writes,
  and cache reads.
- **Last 14 days** as a bar chart; hover a bar for that day's total. Totals for this week and 30 days.
- **Click the Today header** (or "Usage by project…" in the menu) for a details window: tokens by project for
  today, 7 days, or 30 days, with a share bar, per-project input/output/cache breakdown, models used, and
  every session by name with its subagent share. Clicking a project in Top Projects opens that project.
- **Top projects** and the **model mix** for the last 7 days.

Numbers come from Claude Code's session logs in `~/.claude/projects`, which both the desktop app and the
CLI write, including subagents. Each response appears in the logs more than once, so it is counted once
by its response id. Notes:

- It covers this Mac only, not claude.ai or other devices, and it isn't your plan's limit percentage.
- Claude Code deletes logs after 30 days by default (`cleanupPeriodDays`), so older history drops off.
- The log format is internal to Claude Code and could change in an update; unknown lines are skipped.
- Turn the number in the menu bar off with "Show today's tokens in menu bar".

## Toys, friends, pokes, and mood

- **Throw a ball** (menu, or `bin/clawd ball`): a ball drops at your cursor. Throw it around; when it comes
  to rest Clawd runs over and kicks it toward your cursor. A fast ball that hits Clawd bounces off and
  startles it.
- **Pick a ball** from the menu's Ball submenu, or with `bin/clawd ball baseball`. The choices are classic,
  baseball, basketball, soccer, and tennis. Each bounces and rolls a little differently: basketballs and
  tennis balls are bouncy, baseballs thud and stop quickly, soccer balls roll far. A big kick of a baseball
  sometimes earns a "Home run!". Switching while a ball is out swaps it in place, and the choice is remembered.
- **Drop a snack** (menu, or `bin/clawd snack`): a cookie drops at your cursor. Clawd waddles over and eats it
  in three bites, then celebrates.
- **Call a friend**: launches a second Clawd. The two notice each other and wave, and bump into each other when
  they walk into one another. Each friend has "Send this friend home" in its menu. Only the first Clawd
  listens to Claude Code and announces the weather.
- **Pokes**: click its eyes and it squints. Shake it back and forth while dragging and it lands dizzy.
  Hold it in the air for more than three seconds and it flails. Pet it six times in a row and it gets dizzy too.
- **Mood** is remembered between launches (shown in the menu). Petting, snacks, kicks, and friends raise it;
  eye pokes, hard throws, and shaking lower it, and it drops a little for each day you don't run Clawd.
  When happy it walks faster, jumps more, wanders over to your cursor, and floats hearts. When sulky it
  looks away from your cursor, sighs, walks slowly, and half-ignores petting until you win it back.

## How it reacts to your Mac

- Typing fast: it sits up and looks down at the keyboard.
- No input for 10 minutes: it dozes off. Touch the mouse or keyboard and it startles awake.
- Music or Spotify playing: it dances. It listens for the players' own play/pause announcements, so it
  never waits on a busy player, and it keeps dancing through the brief pause between tracks. A rare
  background check fills in the state at launch; macOS asks once for permission to peek at the player.
- Battery at 20% or less on battery power: droopy eyes, slow walk, a low-battery icon.
  Plugging in makes it happy.
- Between 11pm and 6am it wears a nightcap and sleeps more.
- Copy something: it briefly holds up a little clipboard. It never reads the contents.

## Time, season, and weather

- **Morning (6–10am)**: yawns now and then and holds a coffee mug. **Late night (11pm–6am)**: nightcap.
  **Dec 20–26**: Santa hat.
- **Season**: a flower in spring, sunglasses on clear warm summer days, a leaf in autumn, a beanie when it
  snows or feels below -3°C. Seasons flip for the southern hemisphere.
- **Weather**: scarf at 8°C or below and shivering at 2°C or below; sweat drop at 28°C and panting at 33°C;
  umbrella and rain streaks when it rains; snowflakes when it snows; squinting in fog; startled jumps in
  thunderstorms. It announces the weather in a speech bubble when it first checks and whenever conditions change.
- Weather comes from Open-Meteo (free, no key) every 15 minutes. The city is guessed once from your network
  address via ipapi.co; use **Set location…** in the menu to pick any city instead (leave it empty to go back
  to automatic). Temperatures show in °F when your Mac is set to US units, °C otherwise.

## Claude Code companion

`bin/install-hooks.py` adds hooks to `~/.claude/settings.json` (already done on this machine;
run it with `--remove` to take them out). Claude Code then tells Clawd what it is doing:

| Claude Code            | Clawd                                   |
|------------------------|-----------------------------------------|
| You send a prompt      | thinks with Claude Code's · ✢ ✳ ✶ ✻ ✽ spinner |
| Runs a shell command   | swings a hammer                         |
| Edits or writes a file | holds a pencil                          |
| Reads or searches      | holds a magnifying glass                |
| Fetches the web        | holds a globe                           |
| Spawns a subagent      | holds a tiny Clawd                      |
| Needs your permission  | hops up with an Allow / Deny card        |
| Finishes a turn        | happy hop with a green check            |

### Approving permission requests from Clawd

When Claude Code asks for permission, Clawd hops up and shows a card above its head: the tool, the exact
command, file, or URL, the project, and how many requests are waiting. Click **Allow** or **Deny**.

- Claude Code's own prompt still appears too. In the desktop app both are live and whichever you answer
  first wins; Clawd drops its card when you answer in Claude Code instead.
- If you ignore the card for 2 minutes, or Clawd isn't running, Claude Code simply asks the normal way.
  Change the wait with the `CLAWD_APPROVAL_TIMEOUT` environment variable (seconds).
- Only a real mouse click on the card can approve. There is no socket message or `clawd` command that
  approves, so scripts can't approve on your behalf. The buttons also ignore clicks for half a second
  after the card appears, so a click meant for something else can't land on Allow.
- Settings deny rules still win: an Allow from Clawd can't override a rule that blocks a tool.
- Claude's questions (AskUserQuestion) and plan reviews (ExitPlanMode) never get Allow or Deny buttons,
  because they need your real answer. Clawd just tells you one is waiting and leaves it to Claude Code.

You can talk to it yourself from any script:

```bash
bin/clawd notify "Build finished"     # speech bubble + hop
bin/clawd say "hi"
bin/clawd thinking | done | attention | clear
bin/clawd tool bash                   # bash | edit | read | web | agent
bin/clawd pet | sleep | wake
```

Messages go over the Unix socket `/tmp/clawd.sock`; received events are logged to
`~/Library/Logs/Clawd.log`. If Clawd isn't running the client silently does nothing.

## Layout

- `Sources/Sprite.swift` builds every frame procedurally from a `PetLook` (gaze, blink, gait, squash, bubble, nightcap, hop).
- `Sources/PetController.swift` is the behaviour state machine, physics, perching, sensors, companion overlay, and input.
- `Sources/Surfaces.swift` finds the visible top edges of on-screen windows to stand on.
- `Sources/Sensors.swift` reads keyboard/mouse idle time, battery, and time of day; `MusicWatcher` there
  follows the music player.
- `Sources/Weather.swift` is the season calendar plus the Open-Meteo and location lookups.
- `Sources/Toy.swift` is the ball and the snack: tiny physics windows you can drag and throw.
- `Sources/Peers.swift` lets running Clawds share positions through `/tmp/clawd-peers`.
- `Sources/UsageStore.swift` reads token usage from the session logs; `Sources/UsageView.swift` is the menu panel.
- `Sources/ApprovalPanel.swift` is the Allow / Deny card for Claude Code permission requests.
- `Sources/ControlSocket.swift` is the Unix-socket server; `bin/clawd` is the client.
- `Sources/PetView.swift` renders Clawd. The sprite, shadow, and thought bubble are Core Animation layers
  moved by springs on the GPU; particles and speech are painted into two overlay layers only while they animate.
  The window spans the screen's width and ignores the mouse except over Clawd, so it never blocks clicks.
- `Sources/Particles.swift` holds the particle glyphs and the spring; `Sources/Icons.swift` the bubble icons and toys.
- `Sources/IconRenderer.swift` renders the menu-bar icon, the .icns, and `build/preview.png`.
