#!/bin/bash
# Show the headers of the newest message in the emoji mailbox (🤡@😍.uz).
D=/www/vmail/xn--r28h.uz/xn--9p9h/new
N=$(ls -t "$D" 2>/dev/null | head -1)
if [ -z "$N" ]; then
    echo "no message found in $D"
    exit 1
fi
echo "file: $N"
echo "--- headers ---"
grep -aiE '^(From|To|Subject|Date):' "$D/$N"
echo "--- body ---"
sed -n '/^$/,$p' "$D/$N" | head -3
