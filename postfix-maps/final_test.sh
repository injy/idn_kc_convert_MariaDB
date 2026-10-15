#!/bin/bash
# Final end-to-end test with the PHP daemon STOPPED.
# Must all be delivered locally via LMTP (no daemon, UDF + mysql: only).

STAMP=$(date +%s)
declare -A DIRS=(
  ["nic@diy.gd"]="diy.gd/nic"
  ["美丽@的.中国"]="xn--hxy.xn--fiqs8s/xn--viq251j"
  ["α@α.cc"]="xn--mxa.cc/xn--mxa"
  ["🤡@😍.uz"]="xn--r28h.uz/xn--9p9h"
)

count() { ls "/www/vmail/$1/new" 2>/dev/null | wc -l; }

for a in "${!DIRS[@]}"; do
    B["$a"]=$(count "${DIRS[$a]}")
done

echo "=== sending (daemon stopped) ==="
for a in "${!DIRS[@]}"; do
    printf 'From: root@gc.vche.net\nTo: %s\nSubject: final test %s\nDate: %s\n\nfinal %s\n' \
        "$a" "$STAMP" "$(date -R)" "$STAMP" | sendmail -t 2>&1
    echo "sent -> $a"
done

postqueue -f >/dev/null 2>&1
sleep 5

echo
echo "=== mail queue ==="; mailq | tail -1
echo
echo "=== DELTA per maildir ==="
for a in "${!DIRS[@]}"; do
    d=${DIRS[$a]}; b=${B[$a]}; af=$(count "$d")
    if [ "$af" -gt "$b" ]; then
        printf 'DELIVERED  %-22s %-32s +%s\n' "$a" "$d" "$((af-b))"
    else
        printf 'NO-CHANGE  %-22s %-32s (%s -> %s)\n' "$a" "$d" "$b" "$af"
    fi
done

echo
echo "=== LMTP status lines ==="
grep -iE "xn--|diy.gd" /var/log/postfix/postfix.log | grep "status=" | tail -6
