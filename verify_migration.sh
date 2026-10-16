#!/bin/bash
DST=/data/vmail
echo "=== [A] 是否还有 /www/vmail 残留引用（应为空）==="
grep -rn "/www/vmail" /etc 2>/dev/null | head -10
echo "(以上为空=干净)"
echo; echo "=== [B] Dovecot 在新路径看到各邮箱（含历史邮件）==="
for u in nic@vche.net xn--viq251j@xn--hxy.xn--fiqs8s xn--9p9h@xn--r28h.uz xn--mxa@xn--mxa.cc; do
  printf "%-32s " "$u"
  doveadm mailbox status -u "$u" messages INBOX 2>&1 | head -1
done
echo; echo "=== [C] quota 读取 ==="
doveadm quota get -u nic@vche.net 2>&1 | head -4
echo; echo "=== [D] 迁移后 emoji IDN 实时投递 ==="
B=$(ls $DST/xn--r28h.uz/xn--9p9h/new 2>/dev/null | wc -l)
printf "From: root@gc.vche.net\nTo: 🤡@😍.uz\nSubject: post-migration emoji\n\nEmoji check after migration.\n" | sendmail -t
sleep 3; postqueue -f >/dev/null 2>&1; sleep 2
A=$(ls $DST/xn--r28h.uz/xn--9p9h/new 2>/dev/null | wc -l)
echo "🤡@😍.uz new/ delta: $((A-B))"
grep "to=<xn--9p9h@xn--r28h.uz>" /var/log/postfix/postfix.log | tail -1
echo; echo "=== [E] 服务与队列 ==="
echo "postfix=$(systemctl is-active postfix) dovecot=$(systemctl is-active dovecot) phpdaemon=$(systemctl is-active php_postfix_maps)"
mailq | tail -1
echo; echo "=== [F] 磁盘 ==="
df -h /data / | tail -2
