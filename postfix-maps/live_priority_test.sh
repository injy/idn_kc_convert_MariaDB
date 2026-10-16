#!/bin/bash
# 真实投递验证：nic@vche.net 必须落本地 maildir；不存在地址必须进 catch-all
BEFORE=$(ls /www/vmail/vche.net/nic/new 2>/dev/null | wc -l)
echo "nic maildir before: $BEFORE"
printf "From: root@gc.vche.net\nTo: nic@vche.net\nSubject: priority-fix local test\n\nLocal delivery check.\n" | sendmail -t
printf "From: root@gc.vche.net\nTo: zztest998@vche.net\nSubject: priority-fix catchall test\n\nCatch-all check.\n" | sendmail -t
sleep 3
postqueue -f 2>&1
sleep 3
echo "=== nic@vche.net delivery trace ==="
grep "to=<nic@vche.net>" /var/log/postfix/postfix.log | tail -3
echo "=== zztest998@vche.net delivery trace (catch-all) ==="
grep "zztest998@vche.net" /var/log/postfix/postfix.log | grep -E "to=<|orig_to" | tail -3
AFTER=$(ls /www/vmail/vche.net/nic/new 2>/dev/null | wc -l)
echo "nic maildir after: $AFTER  (delta: $((AFTER-BEFORE)))"
echo "=== queue ==="
mailq | tail -1
