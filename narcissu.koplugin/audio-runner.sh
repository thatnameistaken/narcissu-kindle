#!/bin/sh
# Run only this plugin's stream under the Kindle's stock libraries.
# Args: gst old file rate channels loop prefix parent minimum_seconds
unset LD_LIBRARY_PATH LD_PRELOAD GST_PLUGIN_PATH GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_SCANNER
gst=$1
old=$2
file=$3
rate=$4
channels=$5
loop=$6
prefix=$7
parent=$8
minimum=$9
child=
watcher=
finish() {
    code=$1
    trap '' TERM INT HUP
    if [ -n "$watcher" ]; then kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null; fi
    if [ -n "$child" ]; then
        kill "$child" 2>/dev/null
        ( sleep 3; kill -9 "$child" 2>/dev/null ) &
        killer=$!
        wait "$child" 2>/dev/null
        kill "$killer" 2>/dev/null
        wait "$killer" 2>/dev/null
    fi
    printf '%s\n' "$code" > "$prefix.done.tmp"
    mv "$prefix.done.tmp" "$prefix.done"
    exit "$code"
}
trap 'finish 143' TERM INT HUP
printf '%s\n' "$$" > "$prefix.pid"
if [ -e "$prefix.cancel" ]; then finish 143; fi
if [ "$old" = 1 ]; then
    caps="audio/x-raw-int,endianness=1234,signed=true,width=16,depth=16,rate=$rate,channels=$channels"
else
    caps="audio/x-raw,format=S16LE,layout=interleaved,rate=$rate,channels=$channels"
fi
iteration=0
while :; do
    if [ -e "$prefix.cancel" ] || ! kill -0 "$parent" 2>/dev/null; then finish 143; fi
    started=$(date +%s)
    # GST parse-launch strings have their own quoting rules, separate from sh.
    # Escape only backslashes and quotes in the location property.
    escaped=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')
    "$gst" -q filesrc "location=\"$escaped\"" ! "$caps" ! queue ! mixersink stream-type=Music sync=true > "$prefix.log" 2>&1 &
    child=$!
    if [ -e "$prefix.cancel" ]; then finish 143; fi
    # A crashed KOReader must not leave a detached music loop behind.
    (
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done
        if ! kill -0 "$parent" 2>/dev/null; then kill -TERM "$$" 2>/dev/null; fi
    ) &
    watcher=$!
    wait "$child"
    code=$?
    child=
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    watcher=
    if [ "$code" != 0 ]; then finish "$code"; fi
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -lt "$minimum" ]; then
        printf '\nAudio pipeline ended before the clip could finish (%ss).\n' "$elapsed" >> "$prefix.log"
        finish 70
    fi
    iteration=$((iteration + 1))
    printf '%s\n' "$iteration" > "$prefix.loops"
    if [ "$loop" != 1 ]; then finish 0; fi
done
