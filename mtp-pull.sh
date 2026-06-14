#!/usr/bin/env bash
# mtp-pull.sh - resiliently pull the newest media off an MTP phone over a flaky
# USB link.
#
# Base MTP access already exists (gio/gvfs, libmtp's mtp-files/mtp-getfile,
# jmtpfs, simple-mtpfs).  What none of them handle well is the case that bit us
# repeatedly while pulling kernel-hang boot videos off a Pixel with a loose
# USB-C socket: the link drops mid-copy (dmesg "error -71"/-EPROTO), leaving a
# truncated file (e.g. an MP4 missing its trailing moov atom, so unplayable).
# This wraps gio + cp with per-file validation and auto-retry, and finds the
# newest matching files for you, so "grab the boot video I just recorded" is one
# command even when the cable is failing.
#
# Validation: video files are checked with ffprobe (must have a readable
# duration -> moov present); other files just need to be non-empty.  A file that
# fails validation is re-pulled, up to --retries times.
#
# The phone's storage directory name is localized ("Internal shared storage" /
# "Interner gemeinsamer Speicher" / ...), so we locate DCIM/Camera by case-
# insensitive path match rather than hardcoding it.
#
# Examples:
#   mtp-pull.sh --list                 # list newest 10 videos, copy nothing
#   mtp-pull.sh                        # pull the single newest video to .
#   mtp-pull.sh -n 2 -d ./vids         # newest 2 videos into ./vids
#   mtp-pull.sh --since '2026-06-14 13:00' -d ./vids
#   mtp-pull.sh --match 'PXL_2026*'    # newest matching this glob
#   mtp-pull.sh --images -n 5          # newest 5 photos instead of videos
#
# Deps: gio (glib2), coreutils; ffprobe (ffmpeg) recommended for video validate.
set -u

N=1; DEST="."; SUBDIR=""; SINCE=""; MATCH=""; RETRIES=5; TIMEOUT=360
EXTS="mp4 mov mkv webm ts m4v"; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2;;
    -d|--dest) DEST="$2"; shift 2;;
    -s|--subdir) SUBDIR="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --match) MATCH="$2"; shift 2;;
    --images) EXTS="jpg jpeg png heic dng webp"; shift;;
    --ext) EXTS="$2"; shift 2;;
    --retries) RETRIES="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --list) LIST=1; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

uid=$(id -u)

find_root() {
  local r
  for r in /run/user/"$uid"/gvfs/mtp:host=*; do [ -d "$r" ] && { echo "$r"; return; }; done
  local vol; vol=$(timeout 15 gio mount -li 2>/dev/null | grep -oE 'mtp://[^[:space:]/]*/' | head -1)
  [ -n "$vol" ] && timeout 25 gio mount "$vol" >/dev/null 2>&1
  for r in /run/user/"$uid"/gvfs/mtp:host=*; do [ -d "$r" ] && { echo "$r"; return; }; done
}

ROOT=$(find_root)
[ -z "${ROOT:-}" ] && { echo "no MTP device mounted (is the phone unlocked & in File-transfer mode?)" >&2; exit 1; }

if [ -n "$SUBDIR" ]; then
  SRC=$(find "$ROOT" -maxdepth 4 -type d -ipath "*/$SUBDIR" 2>/dev/null | head -1)
else
  SRC=$(find "$ROOT" -maxdepth 4 -type d -ipath '*/DCIM/Camera' 2>/dev/null | head -1)
fi
[ -z "${SRC:-}" ] && { echo "could not find source dir under $ROOT" >&2; exit 1; }

# build find predicate for extensions / match
pred=( -type f )
if [ -n "$MATCH" ]; then
  pred+=( -name "$MATCH" )
else
  pred+=( '(' ); first=1
  for e in $EXTS; do [ $first = 1 ] || pred+=( -o ); pred+=( -iname "*.$e" ); first=0; done
  pred+=( ')' )
fi
[ -n "$SINCE" ] && pred+=( -newermt "$SINCE" )

mapfile -t ROWS < <(find "$SRC" -maxdepth 1 "${pred[@]}" -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -rn)
[ "${#ROWS[@]}" -eq 0 ] && { echo "no matching files in $SRC" >&2; exit 1; }

if [ "$LIST" = 1 ]; then
  lim=$N; [ "$lim" -lt 10 ] && lim=10
  printf '%s\n' "${ROWS[@]:0:$lim}" | awk -F'\t' '{printf "%10.1fMB  %s\n",$2/1048576,$3}'
  exit 0
fi

validate() {
  local f="$1"; [ -s "$f" ] || return 1
  case "${f,,}" in
    *.mp4|*.mov|*.mkv|*.webm|*.ts|*.m4v)
      command -v ffprobe >/dev/null 2>&1 || return 0
      ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" >/dev/null 2>&1;;
    *) return 0;;
  esac
}

mkdir -p "$DEST"; rc=0; got=0
for row in "${ROWS[@]}"; do
  [ "$got" -ge "$N" ] && break
  src=$(cut -f3- <<<"$row"); base=$(basename "$src"); dst="$DEST/$base"
  if [ -f "$dst" ] && validate "$dst"; then echo "[$base] already present & valid"; got=$((got+1)); continue; fi
  ok=0
  for a in $(seq 1 "$RETRIES"); do
    echo "[$base] attempt $a $(date +%H:%M:%S)"
    timeout "$TIMEOUT" cp "$src" "$dst" 2>/dev/null
    if validate "$dst"; then echo "[$base] OK $(stat -c %s "$dst") bytes"; ok=1; break; fi
    echo "[$base] incomplete/invalid, retrying"; sleep 2
  done
  if [ "$ok" = 1 ]; then got=$((got+1)); else echo "[$base] FAILED after $RETRIES tries" >&2; rc=1; fi
done
echo "pulled $got/$N to $DEST"
exit $rc
