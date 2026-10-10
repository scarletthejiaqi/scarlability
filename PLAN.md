# Scarlability — Build Plan (v10: M5 and M6 built; all testing at the end, see TESTING.md)

A note-taking app for **iPad + Mac** that copies the *basic* parts of Notability:
1. Notability-style tools: pressure pen, highlighter, eraser, text, selection, shape snap
2. Images and PDFs: insert images, import and annotate PDFs, export to PDF
3. Notability-style organization (Dividers → Subjects → Notes)
4. Free sync between your MacBook and iPad through an **iCloud Drive folder**

**Rules:**
- Everything must be free. No paid Apple Developer account.
- Items marked **[?]** are still waiting on your answer (§9). I won't build them until you confirm.

---

## 1. Scope for v1

### 1.1 Tools (top toolbar, Notability-style) ✅
```
+--------------------------------------------------+
| < Library     Biology Lecture 3     Share  ...   |
|  Pen  Highlight  Eraser  Text  Select  Image     |
|        (o)(o)(o)    size:  .  o  O    Undo Redo  |
+--------------------------------------------------+
|                    page                          |
```
| Tool | Behavior |
|---|---|
| **Pen** | One pen style: **pressure-sensitive**, so the line gets thicker the harder you press. The pressure curve is tuned to feel like Notability. Color presets plus a custom color picker. Size presets plus a fine size slider. Smoothing so handwriting looks clean. |
| **Shape snap** | Draw a shape and hold still, and it snaps to a clean line, circle/ellipse, rectangle, triangle or polygon **[?]**. |
| **Highlighter** | Semi-transparent and always drawn *behind* pen ink. Draw and hold to snap to a straight line **[?]**. On PDFs there's a toggle: **freehand** (default) or **snap to the PDF's text lines**. |
| **Eraser** | Partial (pixel-style) eraser, whole-stroke eraser, and "erase highlighter only" **[?]**. Eraser sizes. |
| **Text** | Font, size, color. Bold/italic/underline. Bullet and numbered lists. Paste text from other apps. |
| **Select** | Two modes: **freeform loop** or **rectangle box**. Then move, resize, recolor, cut/copy/paste, duplicate, delete. Works on ink, text and images. |
| **Image** | Insert from Photos, Files/Finder, the camera, the document scanner, or paste. Move and resize. The camera and scanner are iPad-only. |
| **Canvas** | Apple Pencil writes and fingers scroll or pinch-zoom (palm rejection). "Draw with finger" toggle. Undo/redo. |
| **Pencil double-tap** | Does whatever you've set in **iPad Settings → Apple Pencil**. |
| **Pages** | **Continuous vertical scrolling.** Paper templates (blank, lined, grid, dotted), paper color and page size **[?]**. |

### 1.2 PDF ✅
- **Import:** open a PDF as a new note, **or** insert its pages into an existing note. Then write, highlight, type and add images on top. The original PDF is never changed.
- **Export** through the standard Share menu (AirDrop, Save to Files, Mail…):
  - the whole note, or only the pages you pick
  - with or without the paper lines/grid
  - several notes at once, either **combined into one PDF** or **one PDF per note**
- The exported PDF keeps text and imported PDF pages sharp (vector), not blurry screenshots.

### 1.3 Note organization (Notability-style library)
- **Dividers** are collapsible section headers in the sidebar. They group Subjects.
- **Subjects** have a name and a color, and hold notes. **Unfiled** catches notes with no subject.
- **Notes** show in a thumbnail grid or a list. Sort by date created, date modified or title. Search by title.
- Drag and drop: notes into subjects, subjects between dividers, reordering.
- Rename, delete, and **Recently Deleted** (restore) **[?]**.
- Multi-select notes, e.g. to export them together.

### 1.4 Sync (iCloud Drive folder, free) ✅
- Notes are saved in `iCloud Drive/Scarlability`, one item per note (see §4), and iCloud Drive copies them between devices.
- **Setup:** the first time you open the app on each device, it asks you to pick that folder.
- **Timing:** Apple decides when to sync, usually seconds to a few minutes. The app re-checks the folder while it's open.
- **Edits on both devices:** each device writes only its own files, and the app combines them, so writing on both devices never loses work.
- Notes count against your iCloud storage (5 GB free).

### 1.5 Not in v1
Audio recording, handwriting search, handwriting-to-text, sharing and collaboration, iPhone and Vision Pro versions, fixed-width and dashed pen styles.

---

## 2. Key technical decisions ✅

| Decision | Choice | Why |
|---|---|---|
| **Drawing engine** | **Custom ink engine** (Swift + Core Graphics, Metal later if needed) | Full control of the pressure curve, so it feels like Notability. It also supports highlighter-behind-ink and "erase highlighter only", and runs natively on Mac. |
| **Text** | Apple's built-in rich-text system (TextKit) inside movable text boxes | Gives fonts, styles, lists and copy/paste properly |
| **PDF** | Apple's PDFKit for reading, finding PDF text for snap highlighting, and writing exports | Built in and free |
| **Images / scanning** | Apple's photo picker, camera and document scanner (VisionKit) | Built in and free |
| **Storage + sync** | Plain files in the iCloud Drive folder, per-device files with merge logic | Free. No database or paid iCloud features needed. |
| **App structure** | One SwiftUI app for **iPadOS + native macOS only**. Platform-specific canvas input views (UIKit/AppKit) feed a shared engine. | Same features on both devices |
| **Look** | Notability-like layout and behavior, with our own icons and artwork | Avoids copying their assets |

### Pressure by device
| Input | Pressure? |
|---|---|
| Your Apple Pencil 2nd gen on iPad Air 5 | ✅ Full pressure + tilt + double-tap, ~240 updates per second (no squeeze or hover on this hardware) |
| Mac Force Touch trackpad | Limited |
| Mac mouse | ❌ Fixed width |

---

## 3. Architecture

```
scarlability/
├── App/            App entry, app-wide state, settings, first-run folder picker
├── Library/        Sidebar (Dividers/Subjects), note grid/list, search, drag & drop, multi-select
├── Editor/         Note screen, top toolbar, tool option popovers, continuous page view
├── Ink/            ← shared, platform-independent, unit-tested
│   ├── Stroke.swift           points (x, y, pressure, tilt, time), tool, color, width
│   ├── PressureCurve.swift    pressure → line thickness, tuned to match Notability
│   ├── StrokeBuilder.swift    smoothing + variable-width outline
│   ├── InkRenderer.swift      draws strokes; caches finished ink, renders live stroke on top
│   ├── HitTesting.swift       eraser (partial/whole), freeform + rectangle selection
│   ├── ShapeRecognizer.swift  draw-and-hold → line/ellipse/rect/triangle/polygon
│   └── UndoStack.swift
├── Canvas/
│   ├── CanvasView+iOS.swift   UIView: Pencil touches (coalesced + predicted), gestures, double-tap
│   └── CanvasView+macOS.swift NSView: mouse/trackpad
├── Items/          Text boxes (TextKit), images, selection handles
├── PDF/            Import, PDF page backgrounds, text-snap highlighting, export
└── Storage/        Folder access (saved bookmark), coordinated file reading/writing,
                    folder watching, encoders/decoders, merge logic
```

---

## 4. Folder layout ✅ (changed after your first test)

The Files app (and Finder) mirrors the app. Each note is **one item named after the note**: a `.scarnote` package, which is a folder that Files shows as a single file.
```
iCloud Drive/Scarlability/          ← made inside the place you pick
├── Spring 2026/                    ← Divider            (M3)
│   └── Biology/                    ← Subject            (M3)
│       └── Lecture 1.scarnote      ← a note
└── Test Note.scarnote              ← an Unfiled note    (M1)
    ├── Note.json                   { title, created, modified, default paper/size }
    ├── PDFs/, Images/              imported files       (M4/M5)
    └── Pages/<pageID>/
        ├── Page.json               { sortKey, size, paper }
        ├── <iPad-deviceID>.ink     what the iPad wrote/erased on this page
        └── <Mac-deviceID>.ink      what the Mac wrote/erased on this page
```
**How merging works:**
- Every object has a unique ID.
- **Strokes** never change after they're created. A merged page has every device's strokes, minus anything any device erased.
- **Text boxes and images** can be edited. If both devices changed the same one, the newest change wins.
- **Pages** each have their own sort key, so adding pages on both devices at once never loses a page.
- **Library files** (renaming a subject, etc.): the newest change wins.

---

## 5. Milestones (you test at the end of each one)

| # | Milestone | You'll be able to… |
|---|---|---|
| ~~M0~~ | *Folded into M1 at your request.* | |
| **M1** ✅ built | Setup (iPad + Mac only, read-write folder access, shared engine package + tests) plus the ink core on iPad: pressure pen + pressure curve, 3 colors + extra color, 3 sizes with sliders, top toolbar, Pencil-only + finger scroll/zoom, undo/redo (buttons + 2/3-finger taps), continuous pages with an automatic blank last page, saving to the iCloud folder | Write on your iPad and compare the feel with Notability. **We'll spend the most time here tuning pressure and smoothing.** |
| **M2** ✅ built | Highlighter (flat chisel, behind ink, even color, yellow + extra color), eraser (whole stroke by default, partial, highlighter only), select (freeform + box; floating menu with Cut/Copy/Paste/Duplicate/Color/Thickness/Copy as Image/Delete; move, resize, rotate), shape snap (hold 0.5 s), Pencil double-tap, paper (Blank/Lined with 3 spacings; White/Cream/Gray/Dark; whole note or this page) | Use every drawing tool |
| **M3** ✅ built | Library: sidebar (All Notes, Unfiled, Dividers ▸ Subjects with 8 colors, Recently Deleted for 30 days), thumbnail grid, sort, title search, rename/move/duplicate/delete, drag onto a subject, multi-select Move/Delete, rename by tapping the title; folders in Files mirror it | Organize notes like in Notability |
| **M4** ✅ built | Text boxes (tap to place, grow as you type, width handle, 6 fonts, sizes, colors, B/I/U, bullet and numbered lists, paste); images (Photos, Files, camera, paste; move, resize, rotate, crop); scanned documents become new pages; text and images sit under ink; tap or lasso to select them | Type and add pictures |
| **M4.5** ✅ built | Notability look: library with Search, Notes (count), Folders (colored dots; folder groups fold open) and Recently Deleted; All Notes / Recents / Favorites / Unfiled tabs; cards with folder tags; ★ Favorites; + New. Note screen: page fills the screen edge to edge (zoom lock with no gray edge), floating toolbar (tools, 7 colors, 3 sizes, finger drawing), page number with ⌃/⌄, page panel with thumbnails, add and delete pages. Also: smoother, lag-free writing and the Delete-first selection bar | Use an app that looks and feels like Notability |
| **M5** ✅ built | PDF: import (new note, into a note, or "Open in" from other apps), vector PDF pages, annotate, Snap to Text highlighter, export (all / this page / range; with or without paper; several notes as one PDF or one each) | Annotate lecture slides and export them |
| **M6** ✅ built | Mac app (Mac Catalyst, like Notability's Mac app): same library + editor, mouse/trackpad drawing, two-finger scroll, trackpad pinch zoom, menu bar (File/Edit/Tools) and keyboard shortcuts (⌘N, ⇧⌘I, ⌘Z, ⌘C/⌘X/⌘V, ⌘A, ⌫, ⌘D, ⌘1–5, ⌘=/⌘-/⌘0), runs on macOS 15 | Use the app on your MacBook |
| **M7** | Two-device sync: per-device files, merging, folder watching, handling files that aren't downloaded yet | Write on iPad and see it on your Mac shortly after |
| **M8** | Polish: performance with 100+ page notes, faster thumbnails, settings screen, app icon | Daily-drive it |

---

## 6. How I'll verify my work
- **Unit tests** for the parts that are easy to get subtly wrong: pressure curve and stroke geometry, eraser/selection hit testing, shape recognition, encoding, merge rules, and PDF export page selection.
- **Build checks** for both iPad and Mac after every change (with `xcodebuild`).
- **You test on real devices.** The Simulator can't reproduce Apple Pencil pressure or feel.

## 7. What you'll need (all free)
- A free Apple ID signed in to Xcode.
- iCloud Drive turned on, with the same Apple ID on both your Mac and iPad.
- Re-run the iPad app from Xcode every 7 days (free-signing limit). ✅ You said that's OK.

## 8. Current project state
- Targets **iPad + Mac only**. iPadOS 26.2 minimum, macOS 15.8 minimum, Xcode 26.3.
- The Mac app can read *and write* the folder you pick.
- `Packages/ScarlabilityKit` holds the platform-independent engine: ink model, pressure curve, smoothing, stroke shapes, paper, page tiles, `.ink` file format, merge rule, folder storage. Its tests run with `swift test`.
- The app (`scarlability/`) has the iPad editor (toolbar, canvas, Pencil input). The Mac shows a "coming in M6" screen.

---

## 9. Questions

**Answered ✅**
- Paid account: no, everything free.
- Sync: iCloud Drive folder; "eventually" is fine.
- Ink engine: custom.
- 7-day iPad re-run: OK.
- Devices: iPad + Mac only.
- Pen: the pressure pen only.
- Shape snap: yes, in v1.
- Select: freeform loop and rectangle box.
- Text: font/size/color, bold/italic/underline, lists.
- Images: Photos, Files, camera, scanner, paste.
- PDF import: as a new note or into an existing note.
- PDF highlighting: freehand, with a snap-to-text toggle.
- PDF export: whole note, picked pages, optional paper lines, many notes as one PDF or separate PDFs.
- Toolbar: across the top.
- Pages: continuous vertical scroll.
- Pencil double-tap: follows the iPad setting.

- iPad: iPad Air 5 on iPadOS 26.7.1, with Apple Pencil 2nd gen.

- Git: one branch per milestone, merged into main after you approve.
- M0 folded into M1.
- M1 colors: 3 presets plus an extra slot. Tap the selected color again to open the picker (spectrum + eyedropper).
- M1 sizes: 3 presets. Tap the selected size again to get its thickness slider.
- M1 pressure: tuned, plus a sensitivity slider in Settings. Undo: 2-finger tap undoes, 3-finger tap redoes.
- M1 paper: A4, white lined. New pages are added automatically. M1 opens straight into one test note.

- After the first iPad test: lines must be smooth, not "small straight lines" (new smoothing). Pages connect, and writing continues onto the next page. Zoom locks at "page width fills the screen" and "whole page fits". Undo/redo fixed. One item per note in Files, with folders mirroring Dividers/Subjects. Old test files deleted.

**Questions from building M1 (I picked a default for each; tell me what to change)**
1. **Pressure feel:** at the default sensitivity, the line goes from about 0.65× (light) to 1.35× (firm) of the pen size. Is that too subtle or too strong compared to Notability?
2. **Smoothing:** shaky lines are smoothed slightly, so very sharp corners get a little rounded. Does writing feel laggy, too wobbly, or about right?
3. **Default pen sizes:** thin 1.4, medium 2.2, thick 3.4. Do they match what you use in Notability?
4. **Default colors:** black, blue, red. Any other shades?
5. **Lined paper:** 8 mm line spacing, light blue lines, 20 mm top margin, no red margin line. Should it look different?
6. **Zoom range:** 50% to 500% of "page fills the width". OK?
7. **Toolbar in M1:** only the Pen tool is shown. Highlighter, eraser and the rest appear when they're built (M2+), not as greyed-out buttons. OK?
8. **Settings location:** the "⋯" button in the title row holds the pressure slider, "Draw with finger", and the notes folder. OK?
9. **Undo taps vs. palm:** two/three-finger taps are ignored for 0.6 s after the Pencil was used, and for big (palm-sized) touches, so a resting palm doesn't undo. Tell me if undo taps get missed or fire by accident.
10. **Color picker:** it's Apple's standard picker (spectrum / grid / sliders + eyedropper). Do you want a round color wheel instead?
11. **Zoom lock strength:** you have to pinch about 7% past a lock to leave it. Too sticky, or not sticky enough?
12. **Smoothing strength:** is the new smoothing too much (letters look rounded) or too little (still bumpy)?

- M2: decided up front: see `TESTING.md` §5–10 for what was built, and §11 for the questions I picked defaults for.
- M3: sidebar (All Notes, Unfiled, Dividers ▸ Subjects, Recently Deleted) plus notes on the right; new notes named "Note Oct 9, 2026 4:30 PM"; thumbnail grid; Recently Deleted keeps notes 30 days.

**Asked when we reach that milestone**
- M1: which preset colors and sizes, and how many of each? Pressure sensitivity slider in Settings, or one fixed Notability-like feel?
- M2: confirm the eraser modes, highlighter straight-line snap, which shapes snap, paper templates/sizes, and the default paper.
- M3: how long Recently Deleted keeps notes, and how new notes are named by default.
- M4: does tapping with the text tool create a text box where you tap (Notability-style), or does text flow from the top of the page?
- M5: when combining many notes into one PDF, what order, and should there be a title page per note?
- M6: on the Mac, do you mostly draw with the trackpad/mouse, or mostly view, organize and type?
- M8: dark mode?

---

## 10. How to test M1 on your iPad

**One-time setup**
1. Connect the iPad to your Mac with a cable. Unlock it and tap **Trust This Computer**.
2. Open `scarlability.xcodeproj` in Xcode. In the bar at the top, choose your iPad as the run destination.
3. Under **Signing & Capabilities** for the `scarlability` target, make sure **Team** is your Apple ID (Personal Team). If Xcode says the bundle ID is unavailable, change it to something unique, e.g. `com.scarletthe.scarlability`.
4. On the iPad, go to **Settings → Privacy & Security → Developer Mode** and turn it on. The iPad restarts. The option only appears after the iPad has been connected to Xcode once.
5. Press **Run (⌘R)** in Xcode. If the iPad says "Untrusted Developer", go to **Settings → General → VPN & Device Management**, tap your Apple ID, and tap **Trust**. Then press Run again.
6. In the app, tap **Choose Folder…**, go to **iCloud Drive**, create a new folder named **Scarlability**, and open it.

**What to try (rebuilt version)**
- [ ] **Smoothness:** write slowly and quickly. Is the line one smooth curve now, instead of small straight pieces?
- [ ] **No flash:** watch the line as you lift the Pencil. It should not change at all.
- [ ] **Across pages:** write across the line between two pages. The writing should continue onto the next page.
- [ ] **Zoom lock:** pinch slowly. The page should stick when its width fills the screen and when the whole page fits, then move on if you keep pinching.
- [ ] **Undo/redo:** two-finger tap undoes, three-finger tap redoes, and the arrow buttons work too.
- [ ] **Files app → iCloud Drive → Scarlability:** "Test Note" should be **one item**, not folders.
- [ ] Still working from last time: pressure, colors and picker, sizes and slider, palm resting, Draw with finger, new blank page at the end, writing is still there after closing and reopening the app.

Then answer the questions in §9. I'll tune the pen, and once you approve M1, I'll merge it into `main` and start M2.
