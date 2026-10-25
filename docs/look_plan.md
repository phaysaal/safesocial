# The look: colour and light that travel as numbers

*Plan, 25 October 2026. Nothing here is built yet.*

## What it is

A **look** is a small set of numbers that describe how a picture or a clip should be
shown: exposure, white balance, tint, warmth, contrast, highlights, shadows, saturation,
vibrance, a vignette, grain. It rides in the post's or message's payload beside the
media, and every viewer's phone applies it at draw time to the original pixels. The
original is never changed and never lost. Changing the look after posting is an edit of
a few numbers, the same path as editing the words: no new upload, instant everywhere,
reversible, and the viewer can always see the original.

What it is not: anything that changes a person. No smoothing, slimming, enlarging or
whitening, by decision (`teen_plan.md`, and the headshot that looks like someone else).
The one thing that touches skin is **true skin**: a white-balance and midtone correction
computed from the picture so that skin reads as it does in life, which phone cameras get
wrong unevenly across skin tones. It makes the picture more true, not the person more
standard.

## The model

`models/look.dart` (pure):

```dart
class Look {
  final double exposure;    // -2..2 stops
  final double temperature; // -1..1, blue..amber
  final double tint;        // -1..1, green..magenta
  final double contrast;    // -1..1
  final double highlights;  // -1..1
  final double shadows;     // -1..1
  final double saturation;  // -1..1
  final double vibrance;    // -1..1
  final double vignette;    //  0..1
  final double grain;       //  0..1
  final String? preset;     // the name it started from, for the UI only
}
```

- `Look.none` is all zeros. `toJson` writes only the non-zero fields, so a post with no
  look carries nothing. `tryParse` clamps every field to its range and drops anything
  that is not a number; a malformed look is no look.
- `Look.matrix()` builds the 4×5 colour matrix for exposure, temperature, tint,
  contrast and saturation, the part Flutter's `ColorFilter.matrix` applies in one pass
  with no measurable cost. Vibrance, highlights and shadows are approximated inside the
  matrix (vibrance as saturation weighted toward low-saturation pixels is not expressible
  in a matrix; it is applied as a second, lighter matrix, and that is good enough here
  and tested against a reference on a few pixels).
- Vignette and grain are not colour: a radial gradient overlay and a tiled noise image
  at low opacity, drawn over the picture.
- `Look.trueSkin(ImageStats)` estimates a temperature, tint and shadows lift from the
  picture's own statistics: a grey-world white balance clipped to a sane range, and a
  midtone lift when the histogram's middle is sunk. No face detection, no model, nothing
  leaves the phone. `ImageStats` is computed once on pick from a downscaled copy.
- Presets are looks with a name: *Office light*, *Window*, *Restaurant*, *Noon*,
  *Evening indoors*, *True skin*, *Mono*. They are numbers, not code.

Per media item: a post's `payload['look']` is a map from media index to look, so one
post with three pictures can carry one look for all or one each; a message's
`payload['look']` is one look. An album item carries its own.

## The wire

- **New posts and messages:** the look is in the payload at send time, sealed with the
  rest. Older clients ignore an unknown payload key and show the original: honest, and
  the reason the original must never be destroyed.
- **After posting:** `post_edit` gains an optional `look` field beside `content`; the
  receiver applies whichever fields are present and records the edit in the post's
  history as it does for words (the history keeps the previous look). The author only,
  as now. `chat_edit` the same for a message's photo. An album item's look changes
  through the album's own edit item.
- **Flashes:** the look is set before sending and not changed after, like the rest of a
  flash.
- Nothing about who viewed, and no pixels, travel for a look change: a few numbers.

## Rendering

`widgets/looked.dart`: `Looked(look: ..., child: ...)` wraps any image or video widget
with the colour filter and the two overlays; `Look.none` renders the child untouched
with no extra layer. It goes around `MediaThumb`, `MediaPreview`, the viewer's image and
`VideoPlayer`, and the protected viewer (a protected picture keeps its scan band; the
look is under it). The viewer has an **Original** toggle, held to compare like a
photographer's before-and-after, and a line "Look: Window light" so nobody is unsure what
they are seeing.

The feed's post card shows the looked thumbnail; the origin score's sentence gains
"shown with a look" when one is set, and the score itself does not drop, because the
pixels are the camera's. An edit in the image editor still drops the score to the edited
band, as now, because those change the frame.

## The editor and the after-menu

- **Before sending**, in the image editor's filter step: the presets as tiles, then
  sliders for every field, **True skin** as one tap that fills the sliders from the
  estimate (the person sees the numbers and may move them), a *Same look for all* switch
  on a multi-picture post, and the original toggle. The pixel filters that exist today
  become presets of the look, so nothing is burned in any more; crop, straighten,
  rotate, drawing, text and stickers stay as frame edits.
- **After posting**, "Change the look" in the post menu for the author, and in a
  message's long-press menu for its sender: the same sliders over the picture as it is,
  Apply sends the edit. "Remove the look" sends an empty one.
- **Save to gallery** writes the picture as shown, with the look baked in, and says so;
  the original is one toggle away first.

## Status

L3 built on 25 October 2026: `ImageStats` from a 48-pixel copy (a file, or a blob's
inline thumbnail when that is all the phone holds), `Look.trueSkin` with its dead zones
and clips, the True skin chip in the editor and the after-sheets, and the look on every
video surface including flashes and the protected viewer. All three milestones are built;
album items remain.

L2 built on 25 October 2026: the look rides `post_edit` and `chat_edit` as numbers (null
removes), applied by the receiver without touching the words, the edit mark or the
signature; "Change the look" in the post menu and the photo's long-press menu; one set of
controls for the editor and the sheet. Album items are not yet covered. No history of
looks is kept: the original is always one hold away, and that is the reversibility.

L1 built on 25 October 2026: the model and matrix, `Looked`, looks at send time from the
editor's presets and sliders, the viewer's line and hold-for-original, the composer's
thumbnails. The origin sentence does not yet say "shown with a look"; the viewer's line
does. L2 and L3 are to come.

## Milestones

| # | Milestone | Size | What lands | Exit criterion |
|---|---|---|---|---|
| L1 | **The look, rendered** | 1.5 | `models/look.dart` with the matrix, parse and clamp; `Looked`; the viewer's original toggle and line; looks in post and message payloads at send time; the editor's sliders and presets replacing the burned-in filters; the origin sentence. | A photo posted with *Window* shows warmer on a second phone, its original one toggle away; an older build shows the original. Tests: the matrix against reference pixels, parse and clamp, zero look adds no layer, the origin sentence. |
| L2 | **Changed after posting** | 1 | `look` in `post_edit` and `chat_edit`, applied by the receiver and kept in history; "Change the look" and "Remove the look" in the post and message menus; album items. | A look changed on one phone changes on the other without a new upload, and the history shows the previous one. Tests: the edit round trip for posts and messages, author-only, history. |
| L3 | **True skin and video** | 1 | `ImageStats` on pick; `Look.trueSkin`; the preset tile; `Looked` around every video surface including flashes and the protected viewer. | Three photos of different skin tones under one kitchen bulb each get a true-skin look that reads right on the second phone, and a clip beside them takes the same warmth. Tests: grey-world estimate on synthetic frames, the clamp, a video widget wrapped. |

## Rules kept

- **Nothing changes a face.** The model has no field for it and the plan says why.
- **The original is never destroyed.** A look is numbers; the pixels are the camera's.
- **No pixels travel for a change.** A look edit is a few numbers on the existing edit
  path.
- **Nothing is computed from behaviour.** True skin reads the picture, not the person.
- **The viewer always knows.** A line names the look; a toggle shows the original.

## What is reused, not written

`post_edit` and `chat_edit` with their history; the image editor's step flow and its
pick-time downscale for `ImageStats`; `MediaThumb`, `MediaPreview`, the viewer and the
protected viewer as the single surfaces to wrap; the origin score's sentence; the album's
edit item; Flutter's `ColorFiltered` for the whole of the colour work.
