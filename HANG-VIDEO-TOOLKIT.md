# Reading a kernel hang off a phone video

When a machine hangs or panics on real hardware, often the only record is a
phone video of the screen — no serial console, no surviving log.  These four
small tools turn such a video into readable text and, for kernel messages, the
exact emitting `file:line`.  They were written while debugging page-clustering
(PGCL) boots on a laptop, but nothing in them is PGCL-specific.

## The pipeline

1. **`mtp-pull.sh`** — get the video off the phone.
   Wraps `gio`/gvfs MTP with per-file validation (`ffprobe`) and auto-retry, so
   a flaky USB-C link that drops mid-copy (dmesg `error -71`) self-heals instead
   of leaving a truncated, unplayable file.  Finds the newest clip for you.
   ```
   ./mtp-pull.sh --list            # see newest videos
   ./mtp-pull.sh -n 1 -d ./vids    # pull the newest into ./vids
   ```

2. **`framestack.py`** — recover legible text from the frozen screen.
   A hang freezes the framebuffer, so the clip is dozens-to-hundreds of noisy
   photographs of one identical image.  Register them (ORB homography) to the
   sharpest frame and stack: sensor noise and hand-shake average out, glyphs
   reinforce.  Astrophotography for a console.  (Only works on a *static* screen
   — a hang/panic — not scrolling text or a blank screen.)
   ```
   ./framestack.py vids/boot.mp4 --start 147 --dur 11 -o hang
   #   -> hang_reference.png  hang_mean.png  hang_sharp.png
   ```

3. **`kmsg-vocab.py`** — build the closed candidate set.
   Kernel log lines are literal `printk`/decompressor/EFI-stub format strings in
   the source.  Extract them (with `file:line`) from whatever tree built the
   kernel under test:
   ```
   ./kmsg-vocab.py -r /path/to/linux -o vocab.tsv \
       /path/to/linux/arch/x86/boot /path/to/linux/init/main.c ...
   ```

4. **`kmsg-match.py`** — snap a noisy OCR read to the right source line.
   Strips `printf` specifiers, scores partial reads by best-substring overlap:
   ```
   ./kmsg-match.py -v vocab.tsv "Decmpressing Linx..."
   #   1.00  decompress  arch/x86/boot/compressed/misc.c:514  Decompressing Linux...
   ```

Stacking does the image cleanup; closed-set matching kills the residual glyph
ambiguity (`0`↔`8`, `e`↔`c`).  Together they read a UUID or a panic line that no
single frame could.

## Requirements
`gio` (glib2), `ffmpeg`/`ffprobe`, Python 3 with `opencv-python` + `numpy`.

## Why these are here
The PGCL code may go nowhere upstream, but debugging byproducts can still help
someone.  Base MTP tools (gio, libmtp, jmtpfs) give *access*; what was missing
was resilient pulling over a failing link and the hang-to-source-line reading
loop above.  If you improve them, that's the spirit — carry it on.
