#!/bin/bash
printf 'From: root@vche.net\nTo: nic@vche.net\nSubject: UDF-switch ASCII test\n\nASCII deliverability test after UDF deploy.\n' | sendmail -t
printf 'From: root@vche.net\nTo: 🤡@😍.uz\nSubject: UDF-switch IDN emoji test\n\nEmoji mailbox deliverability test after UDF deploy.\n' | sendmail -t
printf 'From: root@vche.net\nTo: test@vche.net\nSubject: UDF-switch catchall test\n\nCatch-all deliverability test after UDF deploy.\n' | sendmail -t
echo "=== queued? ==="
postqueue -p 2>/dev/null | head
sleep 2
echo "=== maillog (last 25, filtered) ==="
journalctl -u postfix --no-pager -n 30 2>/dev/null | grep -iE "saved|status=|queued|reject|error|🤡|uz|vche" | tail -25
