#!/bin/sh
# Read-only diagnostics. No radio, firmware, or filesystem changes.
printf 'Narcissu Kindle diagnostics\n'
uname -a
if [ -f /etc/prettyversion.txt ]; then cat /etc/prettyversion.txt; fi
printf '\nGStreamer libraries\n'
for d in /usr/lib /lib /usr/lib/arm-linux-gnueabihf /lib/arm-linux-gnueabihf; do
    for f in "$d"/libgstreamer*.so* "$d"/libglib-2.0.so* "$d"/libgobject-2.0.so*; do
        [ ! -e "$f" ] || ls -l "$f"
    done
done
printf '\nBluetooth state (if supported)\n'
lipc-get-prop com.lab126.btfd BTstate 2>/dev/null
lipc-get-prop com.lab126.btfd BTconnectedDevName 2>/dev/null
printf '\nStock player executables\n'
for player in /usr/bin/gst-launch-0.10 /usr/bin/gst-launch-1.0 /usr/bin/gst-launch; do
    if [ -x "$player" ]; then
        printf '%s\n' "$player"
        LD_LIBRARY_PATH= LD_PRELOAD= "$player" --version 2>/dev/null
    fi
done
printf '\nAudio output and focus (if supported)\n'
lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null
lipc-get-prop com.lab126.audiomgrd getFocus 2>/dev/null
printf '\nGStreamer output and volume elements\n'
for inspector in gst-inspect-1.0 gst-inspect-0.10 gst-inspect; do
    if command -v "$inspector" >/dev/null 2>&1; then
        "$inspector" mixersink
        "$inspector" volume
        break
    fi
done
