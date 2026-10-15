#!/bin/bash
# Local-delivery test: mailboxes at domains with NO catch-all (@domain) row.
# These must be delivered LOCALLY via LMTP into the punycode-organised maildir,
# proving the IDN UDF + mysql: mailbox_maps path works end to end.

STAMP=$(date +%s)
SUBJ="IDN local delivery $STAMP"

count() { ls "/www/vmail/$1/new" 2>/dev/null | wc -l; }

declare -A BEFORE
for d in "diy.gd/nic" "xn--mxa.cc/xn--mxa" "xn--hxy.xn--fiqs8s/xn--viq251j"; do
    BEFORE[$d]=$(count "$d")
done

echo "=== sending (UTF-8 / IDN forms) ==="
send() {
    printf 'From: root@gc.vche.net\nTo: %s\nSubject: %s\nDate: %s\n\nIDN local delivery test %s\n' \
        "$1" "$SUBJ" "$(date -R)" "$STAMP" | sendmail -t 2>&1
}
send "nic@diy.gd"        && echo "sent -> nic@diy.gd       (ASCII, no catch-all)"
send "α@α.cc"            && echo "sent -> α@α.cc           (Greek IDN)"
send "美丽@的.中国"       && echo "sent -> 美丽@的.中国 (Chinese IDN)"

postqueue -f >/dev/null 2>&1
sleep 4

echo
echo "=== mail queue ==="
mailq | tail -1

echo
echo "=== DELTA per maildir (before -> after) ==="
for d in "diy.gd/nic" "xn--mxa.cc/xn--mxa" "xn--hxy.xn--fiqs8s/xn--viq251j"; do
    a=$(count "$d")
    b=${BEFORE[$d]}
    if [ "$a" -gt "$b" ]; then
        printf 'DELIVERED  %-35s %s -> %s  (+%s)\n' "$d" "$b" "$a" "$((a-b))"
    else
        printf 'NO-CHANGE  %-35s %s -> %s\n' "$d" "$b" "$a"
    fi
done

echo
echo "=== postfix delivery lines for these addresses ==="
grep -iE "diy\.gd|xn--mxa|xn--hxy|xn--viq251j" /var/log/postfix/postfix.log | grep -iE "status=" | tail -6
