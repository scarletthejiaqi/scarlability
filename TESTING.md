# Scarlability — What to Test

Everything to try on your iPad, grouped by part. Do it all at the end.
Tick a box when it works. If it doesn't, write what happened next to it (a screenshot helps a lot).

---

## 0. One-time setup (already done once)
1. Plug the iPad into the Mac and unlock it.
2. In Xcode, choose your iPad at the top center and press **⌘R**.
3. If the iPad says "Untrusted Developer": **Settings → General → VPN & Device Management →** your Apple ID **→ Trust**, then ⌘R again.
4. Every 7 days the app stops opening. Plug in the iPad and press ⌘R again; your notes are kept.

## 1. First launch and saving (M1)
- [ ] The first screen asks where to keep notes. Pick **iCloud Drive**.
- [ ] **Files app → iCloud Drive → Scarlability** contains **"Test Note"** as **one item**, not a folder full of files.
- [ ] Write something, swipe the app closed, and reopen it. The writing is still there.

## 2. Pen (M1)
- [ ] **Smooth:** write slowly, then fast. It's one smooth curve, not small straight pieces joined together.
- [ ] **No flash:** when you lift the Pencil, the line doesn't change (no bold "highlight" that then gets thinner).
- [ ] **Pressure:** light writing is thinner, pressing hard is thicker.
- [ ] **Lag:** when you write fast, the ink stays close to the Pencil tip.
- [ ] **Palm:** rest your hand on the screen while writing. The page doesn't move and no marks appear.
- [ ] **Zoomed in:** zoom in and write. The ink is sharp.

## 3. Toolbar (M1)
- [ ] **Colors:** tap black, blue, red. Tap the **selected** color again and the color picker opens. Try the eyedropper (吸管) in it.
- [ ] **Extra color:** tap the rainbow **+**, pick a color, and it becomes the 4th color.
- [ ] **Sizes:** tap a size dot. Tap the **selected** dot again and a thickness slider appears.
- [ ] **⋯ → Pressure sensitivity:** move the slider, then write. You can feel the difference.
- [ ] **⋯ → Draw with finger:** one finger writes, two fingers scroll. Turn it back off afterwards.
- [ ] **Undo/redo buttons** (arrows at top right) work.

## 4. Pages and zoom (M1)
- [ ] There's always a blank page at the end. Writing on it adds another.
- [ ] **Pages connect:** write across the line between two pages. The writing continues onto the next page.
- [ ] Undoing a stroke that crossed two pages removes all of it at once.
- [ ] **Zoom lock (锁定):** pinch slowly. The page **sticks** when its width fills the screen, and again when the whole page fits. Keep pinching and it moves on.
- [ ] **Two-finger tap** undoes. **Three-finger tap** redoes.
- [ ] Rotate to landscape. Nothing looks broken.

## 5. Highlighter (M2)
- [ ] Tap **Highlighter** and highlight across some writing. The yellow stays **behind** the writing.
- [ ] Highlight the same spot twice, or cross two highlights. The color stays **even** (no darker spots once you lift).
- [ ] It's a flat chisel tip: highlighting sideways gives a tall band, and going up and down is thinner.
- [ ] Draw a highlight and **hold** the Pencil still at the end. It snaps to a **straight line**.
- [ ] Colors: yellow plus the rainbow **+**. Tap the selected color again for the picker and eyedropper (取色笔).
- [ ] The 3 sizes work, and tapping the selected size again shows its slider.

## 6. Eraser (M2)
- [ ] **Whole Stroke** (the default): touching a line removes all of it.
- [ ] **Partial**: rubs out just the part you touch, so a line can be cut in two.
- [ ] **Highlighter only**: erases highlights and leaves the writing.
- [ ] A gray circle shows where and how big the eraser is. The 3 sizes work.
- [ ] One eraser swipe undoes in **one** step.
- [ ] You stay on the eraser after lifting the Pencil.

## 7. Select (M2)
- [ ] **Freeform**: draw a loop around some writing. It gets a dashed box and a menu pops up **above** it (not covering it).
- [ ] **Box**: drag a rectangle to select.
- [ ] **Move**: drag inside the box, with the Pencil or a finger.
- [ ] **Resize**: drag the bottom-right circle. **Rotate**: drag the circle above the box.
- [ ] Menu items: **Cut, Copy, Paste, Duplicate, Color, Thickness (Thinner/Thicker), Copy as Image, Delete**.
- [ ] **Copy as Image**, then paste into Messages or Notes. A picture of the selection appears.
- [ ] Copy, then tap an empty spot with the Select tool. A **Paste** menu appears there.
- [ ] Tap outside the selection to deselect it. Undo puts moved or deleted ink back.
- [ ] Select writing that crosses two pages, then move it. It stays together.

## 8. Shapes (M2)
- [ ] With the pen, draw a rough line, circle, oval, rectangle, triangle or other polygon and **hold still about half a second**. It snaps to a clean shape.
- [ ] Normal handwriting never snaps by accident.

## 9. Paper (M2)
- [ ] Tap the **paper icon** (top right, next to ⋯). Switch between **Blank** and **Lined**, and try the **Narrow / Medium / Wide** line spacing.
- [ ] Try the colors **White, Cream, Gray, Dark**. On Dark paper, black ink shows as **white**.
- [ ] **Whole Note** changes every page, and new pages get it too. **This Page** changes only the page in the middle of the screen.

## 10. Apple Pencil double-tap (M2)
- [ ] Double-tapping the Pencil does what **iPad Settings → Apple Pencil → Double-tap** is set to (switch to the eraser and back, switch to the previous tool, or show the color picker).

## 11. Questions to answer while testing
1. **Pressure feel:** too subtle, too strong, or right compared to Notability?
2. **Smoothing:** too much (letters look rounded), too little (still bumpy), or right?
3. **Pen sizes:** thin 1.4 / medium 2.2 / thick 3.4. Do they match what you use?
4. **Colors:** are black, blue, red the right defaults?
5. **Lined paper:** 8 mm spacing, light blue lines, no red margin line. Should it look different?
6. **Zoom range:** 50%–500%. Enough?
7. **Zoom lock:** too sticky, not sticky enough, or right? (You have to pinch about 7% past it.)
8. **Undo taps:** did any get missed, or fire by accident while writing?
9. **Color picker:** is Apple's standard picker OK, or do you want a round color wheel?
10. **Settings:** is the **⋯** button a good place for pressure, finger drawing and the folder?

**From M2** (I picked a default for each):
11. **Highlighter opacity** is 38%. On Dark paper highlights look dim. More or less see-through?
12. **Highlighter while drawing:** where a new highlight crosses an old one, it looks darker until you lift, then evens out. Bothersome?
13. **Highlighter tip:** going up and down is 30% as thick as going sideways. Want a round tip instead, or a different ratio?
14. **Sizes:** highlighter 10 / 16 / 24 and eraser 4 / 9 / 18. Right?
15. **Selecting:** a line counts as selected when at least half of it is inside your loop. Too strict or too loose?
16. **Shape snap:** hold still about 0.5 s within about 3 points. Too easy or too hard to trigger?
17. **Duplicate** puts the copy a little down and to the right. OK?

---

*New sections are added here as each part is built (next: M3, the library).*
