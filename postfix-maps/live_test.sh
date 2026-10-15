#!/bin/bash
# Live end-to-end delivery test after the IDN UDF + mysql: switch.
# Verifies that mail actually lands in the punycode-organised maildir.

STAMP=$(date +%s)
SUBJ="IDN-UDF live test $STAMP"

send() {  # send <recipient>
    printf 'From: root@gc.vche.net\nTo: %s\nSubject: %s\nDate: %s\n\nLive IDN UDF delivery test %s\n' \
        "$1" "$SUBJ" "$(date -R)" "$STAMP" | sendmail -t 2>&1
}

echo "=== sending 3 test messages ==="
send "nic@vche.net"          && echo "sent -> nic@vche.net        (ASCII, real mailbox)"
send "服务@中国.机构"         && echo "sent -> 服务@中国.机构  (UTF-8 IDN, real mailbox)"
send "ω@ω.cc"                && echo "sent -> ω@ω.cc           (UTF-8, alias-domain rewrite path)"

postqueue -f >/dev/null 2>&1
sleep 4

echo
echo "=== mail queue (should be empty) ==="
mailq | tail -2

echo
echo "=== did they land in the punycode maildirs? ==="
for d in "vche.net/nic" "xn--fiqs8s.xn--nqv7f/xn--zfr188b" "xn--bya.cc/xn--bya"; do
    n=$(ls /www/vmail/$d/new 2>/dev/null | wc -l)
    printf '%-40s new/ files: %s\n' "$d" "$n"
done

echo
echo "=== recent delivery log for this stamp ==="
grep -i "$STAMP" /var/log/postfix/postfix.log | grep -iE "to=<|status=" | tail -6
