# GlucoGuard — UI rules

Instructions for whoever (or whatever) writes the next screen. This is not
general design advice; it is the specific system already implemented in
`source/glucoguardView.mc`. Follow it so every new screen matches the three
that exist.

Read this before touching any drawing code.

---

## 1. Device facts — measured, do not re-derive

These came from pixel-measuring simulator screenshots, not from docs. Trust
them over your own estimates.

| Fact | Value |
|---|---|
| Target product | `vivoactive6` only (see `manifest.xml`) |
| `dc.getWidth()` / `getHeight()` | **390 × 390**, round AMOLED |
| Max drawable radius | **195** from centre |
| `FONT_NUMBER_HOT` height | **96 px** |
| `FONT_NUMBER_MEDIUM` height | ~70 px |
| `FONT_SMALL` height | ~30 px |
| `FONT_XTINY` height | ~24 px |

**The bezel trap.** The watch renders roughly 20 px of *black bezel outside*
`getWidth()`. In a screenshot it is indistinguishable from the app's black
background, so the ring will always look like it stops short of the edge. It
does not — it stops at the edge of what you are allowed to draw. Do not "fix"
this by reducing padding further; `edgePad` is already 0.006·w (2 px) and the
ring's outer edge sits at radius 193 of a possible 195.

Because only one product is targeted, proportional maths (`w * 0.42`) and hard
pixels are equivalent today. Keep using proportions anyway — adding a second
product later should not require a redesign.

---

## 2. The layout law

**Never position an element relative to another element's font height.**

This broke the screen twice. Code like this is forbidden:

```monkeyc
// WRONG — a tall hero font pushes these outward into whatever is above/below
var countdownY = heroY - dc.getFontHeight(heroFont) / 2 - padding;
var labelY     = heroY + dc.getFontHeight(heroFont) / 2 + padding;
```

`FONT_NUMBER_HOT` turned out to be 96 px, which shoved the countdown into the
status label and the unit label into the button. Instead, every screen uses a
**content band** bounded by real measured edges, with rows laid out inside it:

```monkeyc
var bandTop    = drawHeader(dc, w, h, "STATUS", color) + (h * 0.024).toNumber();
var bandBottom = buttonRect(w, h)[1] - (h * 0.024).toNumber();
var gap        = (h * 0.024).toNumber();

// pick the biggest hero font whose stack still fits
var heroFont = fitHeroFont(dc, bandBottom - bandTop, [otherH1, otherH2], gap,
                           [Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
                            Graphics.FONT_NUMBER_MILD, Graphics.FONT_LARGE,
                            Graphics.FONT_MEDIUM]);

var rows = stackCenters(bandTop, bandBottom,
                        [otherH1, dc.getFontHeight(heroFont), otherH2], gap);
// rows[i] is the vertical CENTRE of row i — draw with TEXT_JUSTIFY_VCENTER
```

`drawHeader` returns its own bottom edge and `buttonRect` reports the button's
box without drawing it, so the band is derived from what is actually on screen.
Overlap becomes impossible by construction.

If a stack cannot fit even at the smallest hero font, **drop a row rather than
overlap** — the capturing screen drops the countdown digits, because the ring
already communicates remaining time.

---

## 3. Reuse these helpers — do not hand-roll

All already in `glucoguardView.mc`. Adding a screen means composing these, not
writing new `drawText` maths.

```monkeyc
drawCenteredText(dc, x, y, font, str, color)      // y is the CENTRE
drawTrack(dc, cx, cy, radius, penWidth)           // dim full ring
drawProgressArc(dc, cx, cy, radius, penWidth, progress /*0..1*/, color)
drawActionButton(dc, w, h, label, fillColor, labelColor)
buttonRect(w, h)                                  // [x, y, w, h], no drawing
drawHeader(dc, w, h, statusText, statusColor)     // returns header bottom y
stackCenters(bandTop, bandBottom, heights, gap)   // returns centre y per row
fitHeroFont(dc, bandHeight, otherHeights, gap, candidates)
drawTrendArrow(dc, x, y, size, direction /*-1,0,1*/, color)
drawTrendRow(dc, w, y, slope)                     // arrow + value, centred
drawHeart(dc, cx, centerY, size, color)           // centerY is optical centre
```

Every state function has the signature
`drawXState(dc, w, h, cx, cy, radius, penWidth)` and is dispatched from
`onUpdate`. Add new screens the same way.

---

## 4. Visual system

**Palette.** vivoactive6 is AMOLED, so use custom hex, not the 15 named
`Graphics.COLOR_*` constants. Colour carries meaning — never decorate with it.

| Constant | Hex | Means |
|---|---|---|
| `C_BG` | `0x000000` | background, and text on bright fills |
| `C_TRACK` | `0x353A42` | ring with nothing in it |
| `C_MUTED` | `0x8B919C` | labels, units, secondary values |
| `C_TEXT` | `0xFFFFFF` | the hero value |
| `C_READY` | `0x4DA3FF` | idle / not started |
| `C_LIVE` | `0x1E9BE9` | work in progress |
| `C_DONE` | `0x21C97A` | finished, good |
| `C_DANGER` | `0xE03131` | cancel, stop, elevated risk |
| `C_RISING` | `0xF5A524` | trending up / warning |
| `C_FALLING` | `0x4DA3FF` | trending down |

**The ring is the state indicator.** Every screen draws it. Dim track = idle;
partial coloured arc = in progress; solid coloured circle = complete. A user
should identify the screen's state from the ring alone, before reading a word.
Progress fills **clockwise from 12 o'clock**.

**One hero per screen.** Exactly one value gets the number font and `C_TEXT`.
Everything else is `C_MUTED` and small. If two things look equally important,
the screen is wrong. Current heroes: heart glyph (ready), live HR (capturing),
average HR (complete).

**Three type sizes maximum**: one number font for the hero, `FONT_SMALL` for a
secondary value, `FONT_XTINY` for labels and metadata. Never wrap a line —
abbreviate instead.

**Show, don't spell out.** A quantity gets a shape: an arc for progress, a
coloured triangle for trend, a badge for a category. Numbers accompany the
shape; they do not replace it.

**Buttons are colour-coded by consequence** — `C_READY`/`C_DONE` fill with
`C_BG` text for go actions, `C_DANGER` fill with `C_TEXT` for stop actions.
Pill shape, radius = height / 2.

---

## 5. Monkey C facts worth not re-learning

- **Arc angles**: 0° is 3 o'clock, **90° is 12 o'clock**, and angles increase
  *counter-clockwise*. To sweep clockwise from the top, count the end angle
  down from 90 and add 360 when it goes negative. Constants are
  `Graphics.ARC_CLOCKWISE` / `ARC_COUNTER_CLOCKWISE`.
- **`WatchUi.View` has no `getWidth()` / `getHeight()`** — those are `Dc`
  methods. The original `onTap` called them and was silently broken. The view
  caches the button box it drew in `buttonBounds`; the delegate calls
  `hitTestPrimaryAction(x, y)`. Keep that pattern for any new hit target.
- **`Toybox.Time` must be imported explicitly** even though other Toybox
  modules are.
- **Guard optional Dc methods**: `if (dc has :setAntiAlias) { ... }`.
- Verify API names against
  `developer.garmin.com/connect-iq/api-docs/` before using them. Monkey C is
  low-training-data and plausible-looking method names are often wrong.
- Sensor reads return `null` constantly. Null-check every one, and make every
  screen render correctly with no data (`"--"` placeholders).

---

## 6. How to verify a screen

The simulator is the only truth. Do not eyeball a screenshot — **measure it.**

1. Build, run, screenshot the state.
2. Load the PNG in Python/PIL. Find a known-size element (the button is
   `0.40·w × 0.125·h`) to establish scale and the screen origin.
3. Scan for each palette colour and print the bounding boxes. Fused bands mean
   overlapping text. Ring radius and pen width confirm which build is running.
4. Compare against a small script that reproduces the layout maths.

That method found both real bugs here: the first, that `FONT_NUMBER_HOT` was
96 px rather than the assumed ~70; the second, that a "fix" was never on disk
at all — the ring's measured radius and track colour matched the *old*
constants exactly. **Palette values double as build fingerprints; change one
and you can prove which version is running.**

Always state what is testable in the simulator versus what needs the physical
watch. The simulator feeds constant fake HR, so trend arrows sit flat and HRV
is meaningless there.

---

## 7. Known gaps

- **The risk score has no home.** `drawDoneState` shows average HR as its hero
  because nothing reachable from the view computes a score yet. When one
  exists it becomes the hero — a coloured badge or full ring, green / amber /
  red — and average HR drops to the secondary row. A marked comment sits at the
  insertion point.
- `validSampleCount()` is implemented but never drawn; it was written for a
  capture-quality readout that did not survive the layout budget.
- "NOT A MEDICAL DEVICE" appears only on the ready screen. It arguably belongs
  on the results screen too, which has no room at present.

Every screen presenting a health figure must keep that disclaimer reachable.
This is not a diagnostic or medical device.
