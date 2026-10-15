#!/bin/bash
for a in "nic@vche.net" "🤡@😍.uz" "♡@♡.hm" "test@vche.net" "user@中国.机构" "admin@ab.cd"; do
  echo "=== sendmail -bv $a ==="
  sendmail -bv "$a" 2>&1
done
