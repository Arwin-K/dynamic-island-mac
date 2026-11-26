# Themes

A theme is one JSON file that controls how the island looks and moves. The files in this
folder are the built-in presets. They're bundled into the app.

Your own themes live in:

```
~/Library/Application Support/DynamicIsland4Mac/Themes/
```

The app watches that folder. Save a file in your text editor and the island updates right away.

## How a theme file is read

- **Every key is optional.** Any key you leave out uses the default listed below, so a
  theme can be as short as `{ "surface": { "kind": "solid" } }`.
- **Unknown keys are ignored**, so themes written for newer versions still load in older ones.
- **Invalid values fall back to the default**, for example a typo in a color or an unknown
  enum value. The rest of the theme still loads, and Settings → Appearance lists what was
  ignored.
- `id` defaults to the file name (without `.json`). If a theme in your folder has the same
  `id` as a built-in, it replaces that built-in. Settings → Appearance → *Reset to default*
  deletes your copy.
- Colors are hex strings: `"#RRGGBB"` or `"#RRGGBBAA"`. For example, `"#FFFFFF99"` is white
  at 60% opacity.

## Built-in presets

| File | Look |
|---|---|
| `stealth.json` | Pure black. Looks exactly like the hardware notch when collapsed. |
| `glass.json` | System material (blur) with a hairline border. Follows your macOS accent color. |
| `wallpaper-match.json` | Material surface. The accent is sampled from your desktop picture. |
| `graphite-minimal.json` | Solid graphite with a thin border, monochrome icons and calm motion. |
| `neon-terminal.json` | SF Mono, green on black, glowing border. No animation. |
| `pastel-rounded.json` | SF Rounded, soft gradient, big radii and bouncy springs. |

## Every key

### Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | file name | Stable identifier. Must be unique. |
| `name` | string | from `id` | Shown in Settings. |
| `author` | string | `""` | Credit. |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | `"system"` | Picks which color set is used (`colors.dark` or `colors.light`). `system` follows macOS. |

### `surface`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `kind` | `"black"` \| `"material"` \| `"solid"` \| `"gradient"` | `"black"` | `black` blends into the notch. `material` is system blur. `solid` uses `colors.*.surface`. `gradient` goes from `gradientStart` to `gradientEnd`. |
| `material` | `"ultraThin"` \| `"thin"` \| `"regular"` \| `"thick"` \| `"ultraThick"` | `"regular"` | Blur strength when `kind` is `material`. |
| `opacity` | 0–1 | `1` | Opacity of the background only. Text stays fully opaque. |
| `gradientAngle` | degrees | `90` | Direction of the gradient. `90` is top to bottom, `0` is left to right. |
| `border.width` | points | `0` | Border width. `0` turns the border off. |
| `border.opacity` | 0–1 | `1` | Multiplies the border color's own alpha. |
| `shadow.outerRadius` | points | `0` | Drop shadow blur. `0` turns it off. |
| `shadow.outerOpacity` | 0–1 | `0.45` | Drop shadow strength. |
| `shadow.innerRadius` | points | `0` | Inner glow or shadow along the edge. `0` turns it off. |
| `shadow.innerOpacity` | 0–1 | `0.35` | Inner shadow strength. |

When the island is collapsed on a display with a notch, it is always drawn pure black with
no border or shadow, so it stays invisible against the hardware.

### `colors`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `accentSource` | `"fixed"` \| `"system"` \| `"wallpaper"` \| `"albumArt"` | `"fixed"` | `fixed` uses `accent`. `system` follows the macOS accent color live. `wallpaper` samples your desktop picture, re-sampled on Space changes and wake. `albumArt` samples the artwork of what's playing. |
| `sampleStyle` | `"dominant"` \| `"vibrant"` | `"vibrant"` | How colors are sampled. `dominant` is the average color. `vibrant` is the most colorful one. |
| `dark` | color set | see below | Colors used in dark appearance. |
| `light` | color set | see below | Colors used in light appearance. |

A **color set** has these keys:

| Key | Dark default | Light default | Used for |
|---|---|---|---|
| `foreground` | `#FFFFFF` | `#1D1D1F` | Primary text and icons |
| `secondary` | `#FFFFFF99` | `#0000008C` | Subtitles, timers |
| `accent` | `#0A84FF` | `#007AFF` | Progress bars, highlights (when `accentSource` is `fixed`) |
| `surface` | `#000000` | `#F5F5F7` | Background for `solid`, and the tint over `material` |
| `gradientStart` | `#1C1C1E` | `#FFFFFF` | Gradient start |
| `gradientEnd` | `#000000` | `#E5E5EA` | Gradient end |
| `border` | `#FFFFFF2E` | `#0000001F` | Border |
| `shadow` | `#000000` | `#00000099` | Outer and inner shadow color |

### `typography`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `family` | string | `"system"` | `"system"` (SF Pro), `"system-rounded"` (SF Rounded), `"system-mono"` (SF Mono), `"system-serif"` (New York), or the family name of any installed font, for example `"JetBrains Mono"`. |
| `titleSize` | points | `13` | Titles (track name, project name) |
| `bodySize` | points | `12` | Body text |
| `captionSize` | points | `10.5` | Small text and timers |
| `titleWeight` | weight | `"semibold"` | One of `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `bodyWeight` | weight | `"regular"` | |
| `monospacedDigits` | bool | `true` | Fixed-width digits for timers, so they don't jitter. |

### `geometry`

| Key | Default | Meaning |
|---|---|---|
| `compactSideWidth` | `68` | Width added on each side of the notch in the compact state |
| `expandedWidth` | `400` | Width of the expanded panel |
| `expandedHeight` | `120` | Height of the expanded panel, measured below the notch |
| `alertWidth` | `360` | Width of alerts |
| `alertHeight` | `56` | Height of alerts, measured below the notch |
| `collapsedBottomRadius` | `9` | Bottom corner radius when collapsed (match your notch) |
| `collapsedSideOutset` | `8` | When collapsed, how far the island reaches past each side of the notch (0 = exactly the notch, invisible) |
| `collapsedBottomOutset` | `4` | When collapsed, how far the island reaches below the notch |
| `compactBottomRadius` | `12` | Bottom corner radius in the compact state |
| `expandedBottomRadius` | `28` | Bottom corner radius when expanded or alerting |
| `topCurveDepth` | `6` | Depth of the small inward curves where the island meets the top of the screen |
| `padding` | `14` | Inner padding |
| `verticalOffset` | `0` | Moves the island down from the top. Above `0`, the island floats below the notch as a rounded shape. |
| `pillWidth` | `190` | Width of the floating pill on displays without a notch |
| `pillHeight` | `30` | Height of the floating pill |

### `motion`

| Key | Default | Meaning |
|---|---|---|
| `preset` | `"snappy"` | `snappy`, `bouncy` (iOS-like), `smooth`, `instant` (no animation), or `custom` |
| `response` | `0.38` | Spring response in seconds (only for `custom`) |
| `damping` | `0.8` | Spring damping, where `1` means no bounce (only for `custom`) |
| `hoverDelay` | `0.12` | Seconds the pointer must rest on the island before it opens |
| `autoCollapseDelay` | `0.35` | Seconds after the pointer leaves before the island closes |
| `alertDuration` | `3.5` | Seconds an alert stays up |

With **Reduce Motion** turned on in macOS, all springs become short fades.

### `icons`

| Key | Default | Meaning |
|---|---|---|
| `weight` | `"medium"` | SF Symbols weight (same names as font weights) |
| `rendering` | `"hierarchical"` | `monochrome`, `hierarchical`, `palette` or `multicolor` |

### `feedback`

| Key | Default | Meaning |
|---|---|---|
| `haptics` | `true` | Trackpad haptic on alerts. You only feel it while a finger rests on a Force Touch trackpad. |
| `sounds` | see below | Map from event id to `{ "enabled": bool, "sound": "<name>" }` |

Sound names are the files in `/System/Library/Sounds` without the extension: `Basso`,
`Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`,
`Sosumi`, `Submarine`, `Tink`.

Event ids: `agent.permission` (on by default, `Funk`), `agent.idle`, `agent.done`,
`agent.failed`, `media.trackChanged`, `battery.low`, `battery.charging`, `calendar.soon`, `hud`.

### `providers`

Per-agent-provider overrides, keyed by provider id (`claude-code`, `codex`, or any provider you add):

```json
"providers": {
  "claude-code": { "accent": "#D97757", "symbol": "sparkle" },
  "codex": { "accent": "#10A37F" }
}
```

| Key | Meaning |
|---|---|
| `accent` | Color of that provider's status dot and highlights |
| `symbol` | An SF Symbol name to use instead of the provider's default icon |

## Sharing a theme

Use Settings → Appearance → *Export…* to save a theme as a file, or *Import…* to load one.
To add a theme to the built-ins for everyone, see "Submit your theme" in `CONTRIBUTING.md`.
