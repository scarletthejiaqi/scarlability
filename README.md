# Scarlability

A free, open-source note-taking app for **iPad and Mac**, made as an alternative to the basic parts of Notability.
Handwrite with Apple Pencil pressure, highlight and annotate PDFs, keep notes in colored folders, and sync
between your iPad and your Mac through your own **iCloud Drive**.

> Scarlability is an independent hobby project. It isn't affiliated with, endorsed by or connected to
> Notability or Ginger Labs. "Notability" is a trademark of its owner and is used here only to describe
> what this app is similar to.

## Free to use

- **No price, no subscription, no ads, no sign-up.**
- **No paid Apple Developer account.** A free Apple ID is enough to build and run it.
- **No servers.** Your notes are plain files in your own iCloud Drive (Apple gives everyone 5 GB free).
- **Open source** under the [MIT License](LICENSE): use it, change it and share it.

## Features

### Pen
- **Pressure-sensitive:** the line gets thicker the harder you press with Apple Pencil. Smoothing keeps handwriting clean.
- **Fountain pen:** stronger thin-to-bold contrast (**Pen ▾ → Fountain Pen**).
- 7 colors plus your own custom color (spectrum and eyedropper), and 3 sizes, each with a fine slider.
- **Pen Feel** settings for smoothing, pressure and how close the ink follows the tip, with a strip to try them out.
- **Shape snap:** draw a line, circle, oval, rectangle, triangle or polygon and hold still for half a second. It turns
  into a clean shape. Keep holding and move to turn or resize it; lines lock exactly flat or upright.
- **Palm rejection:** the Pencil writes, fingers scroll and zoom. Finger drawing can be turned on.
- Apple Pencil double-tap does whatever you set in **iPad Settings → Apple Pencil**.

### Highlighter
- Bright fluorescent colors (yellow, green, blue, pink, orange, plus a custom one), always **behind** your writing.
  Overlapping highlights stay one even color.
- Flat chisel tip. Draw and hold to snap to a straight line.
- **Snap to Text** on PDFs: highlights exactly the PDF text you drag across.

### Eraser
- **Whole Stroke**, **Partial** (rubs out just the part you touch) or **Highlighter only**. 3 sizes.

### Lasso (select)
- Freeform loop or rectangle box. Move, resize and rotate what you selected.
- Delete, Copy, Paste, Cut, Duplicate, Color, Thickness and Copy as Image.
- Works on handwriting, text boxes and pictures.

### Text
- Tap anywhere on the page to start a text box. 6 fonts, sizes, colors, **bold** / *italic* / underline,
  bullet and numbered lists, and pasting text from other apps.

### Pictures and scans
- Insert from Photos, Files, the camera or the clipboard. Move, resize, rotate and crop.
- Scan paper documents straight into new pages (iPad).

### PDFs
- Import a PDF as a new note, add its pages to a note you already have, or send a PDF from another app's Share menu.
- PDF pages stay sharp when you zoom. Write, highlight, type and add pictures on top; the original PDF is never changed.
- **Export as PDF:** all pages, the current page, or a range like `1-3, 5`; with or without the paper lines;
  several notes as one PDF or one PDF per note. Share through AirDrop, Files, Mail and more.

### Pages and paper
- Pages scroll continuously, and writing can cross from one page to the next. There's always a blank page at the end.
- Paper: Blank or Lined (adjustable line spacing), in White, Cream, Gray or Dark, for the whole note or one page.
- Zoom locks when the page fills the screen width and when the whole page fits.
- **Page panel:** thumbnails of every page, search through typed text and PDF text, bookmarks, a big grid view,
  and per-page Add, Cut, Copy, Paste, Duplicate, Clear and Delete. Select several pages to act on them together.

### Library
- Folders with colors, and folder groups that fold open and closed.
- **All Notes**, **Recents**, **Favorites** and **Unfiled** tabs. Search by title. Sort by date modified, date created or title.
- Drag notes onto folders. Select several notes to favorite, move, delete or export them together.
- **Recently Deleted** keeps deleted notes for 30 days.
- The Files app and Finder show the same structure: a folder per folder, one item per note.

### Mac app
- The same library and editor on your Mac (Mac Catalyst).
- Draw with the mouse or trackpad (fixed width, since there's no pressure), scroll with two fingers, pinch to zoom.
- Menu bar and [keyboard shortcuts](#keyboard-shortcuts), which also work on an iPad with a keyboard.

## iCloud sync

Scarlability syncs your iPad and Mac through an ordinary folder in **iCloud Drive**. It doesn't use Apple's paid
developer services (CloudKit), so it works with a free Apple ID.

- Your notes live in **iCloud Drive → Scarlability**. Each note is one `.scarnote` item (a package folder that Files
  and Finder show as a single file).
- iCloud Drive moves the files between your devices. Apple decides when: usually within seconds, sometimes a minute or two.
- **Changes appear on their own.** An open note picks up the other device's writing, erasing, text, pictures and pages.
  The library refreshes by itself, and renamed, moved or deleted notes follow on the other device.
- **Writing on both devices at once never loses work.** Each device saves its own files and the app merges them.
  For text boxes, pictures and renames, the newest change wins.
- **Works offline.** Changes sync once you're back online.
- Notes count against your iCloud storage.

To sync, both devices need to be signed in to the **same Apple ID** with **iCloud Drive turned on**, and the app
must use the same folder on each device (see [Install](#install), step 6).

## Requirements

- An iPad with **iPadOS 26.2** or later. An Apple Pencil is recommended, since pressure needs one.
- Optional: a Mac with **macOS 15** or later, to use the Mac app.
- A Mac with **Xcode 26.3** or later, to build the app.
- A free Apple ID.

## Install

The app isn't on the App Store. You build it yourself with Xcode, which is free.

1. Download the code:
   ```sh
   git clone https://github.com/scarletthejiaqi/scarlability.git
   ```
2. Open `scarlability.xcodeproj` in Xcode.
3. Click the **scarlability** target → **Signing & Capabilities**. Set **Team** to your own Apple ID (Personal Team;
   add your Apple ID under **Xcode → Settings → Accounts** if it isn't there). Change **Bundle Identifier** to
   something unique, like `com.yourname.scarlability`.
4. **iPad:**
   1. Connect the iPad to your Mac with a cable, unlock it and tap **Trust This Computer**.
   2. Choose your iPad at the top center of Xcode and press **⌘R**.
   3. The first time, turn on **iPad Settings → Privacy & Security → Developer Mode** (the iPad restarts).
   4. If the iPad says "Untrusted Developer", go to **Settings → General → VPN & Device Management**, tap your
      Apple ID and tap **Trust**. Then press **⌘R** again.
5. **Mac:** choose **My Mac (Mac Catalyst)** at the top center of Xcode and press **⌘R**.
6. **First launch, on each device:** tap **Choose Folder…** and pick **iCloud Drive**. The app keeps your notes in a
   folder named **Scarlability** there. Pick the same place on every device so they sync.

> **Free Apple ID limit:** apps signed with a free Apple ID stop opening on the iPad after 7 days. Plug the iPad in
> and press **⌘R** in Xcode again; your notes are kept. If the Mac app ever stops opening, do the same on the Mac.

## How to use

### Library
- **+ New** (top right) → **Note**, **Folder** or **Import PDF…**. New notes go into the folder you're viewing.
- **+** next to **Folders** in the sidebar makes a folder or a folder group.
- Tap a note to open it. Long-press (right-click on Mac) a note or folder for its menu: Rename, Favorite, Move,
  Duplicate, Export, Delete.
- **⋯** (top right) → **Select Notes** to work on several notes, or **Sort by**.

### In a note
- **Toolbar** (top): pen, highlighter, eraser, **Aa** text, lasso, **⊕** insert (pictures, camera, scan, PDF),
  **✋** finger drawing. The current tool's colors and sizes are underneath.
- Tap the **selected** color again for the color picker. Tap the **selected** size again for its thickness slider.
- **Top right:** undo, redo, **⋯** (Rename Note, Paper, Export as PDF, Settings) and the pages button, which opens
  the page panel.
- **Tap the note's name** to rename it. The page number is at the bottom right; **⌃** and **⌄** jump between pages.

### Gestures
| Gesture | What it does |
|---|---|
| Apple Pencil | Writes with the current tool |
| One finger | Scrolls (writes when ✋ finger drawing is on; then two fingers scroll) |
| Pinch | Zooms |
| Two-finger tap | Undo |
| Three-finger tap | Redo |
| Draw, then hold still | Snaps to a clean shape (or a straight highlighter line) |
| Long-press a note or folder | Opens its menu |

### Keyboard shortcuts
On the Mac, and on an iPad with a keyboard (hold **⌘** to see them).

| Keys | Action |
|---|---|
| ⌘N | New note |
| ⇧⌘I | Import PDF |
| ⌘[ | Back to the library |
| ⌘1 – ⌘5 | Pen, Highlighter, Eraser, Text, Lasso |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘X / ⌘C / ⌘V | Cut / Copy / Paste |
| ⌘A | Select all |
| ⌘D | Duplicate the selection |
| ⌫ | Delete the selection |
| Esc | Deselect |
| ⌘= / ⌘- / ⌘0 | Zoom in / Zoom out / Page width |

## Not built yet

Audio recording, searching handwriting, turning handwriting into text, page templates, sharing and collaboration,
an iPhone version, and an app icon.

## For developers

- `scarlability/`: the app, one target for iPad and Mac Catalyst (SwiftUI with UIKit for the canvas).
  `App/` startup and settings, `Library/` the notes library, `Editor/` the note screen and toolbar, `Canvas/` Pencil
  input and drawing.
- `Packages/ScarlabilityKit/`: the platform-independent engine: ink model, pressure curve, smoothing, shape snap,
  hit testing, PDF, the note file format and the sync merge. Run its tests with:
  ```sh
  cd Packages/ScarlabilityKit && swift test
  ```

## License

[MIT](LICENSE) © 2026 Scarlett He
