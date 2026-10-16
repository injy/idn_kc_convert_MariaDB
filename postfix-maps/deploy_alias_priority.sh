#!/bin/bash
# 部署修正后的 virtual_alias_maps（真实邮箱优先于 catch-all）
set -e
M=/etc/postfix/mysql
cp /tmp/alias_new.cf $M/mysql_virtual_alias_maps.cf
sed -i "s/CHANGEME_DB_PASSWORD/${MAIL_DB_PASSWORD:-CHANGEME_DB_PASSWORD}/" $M/mysql_virtual_alias_maps.cf
chown root:postfix $M/mysql_virtual_alias_maps.cf
chmod 640 $M/mysql_virtual_alias_maps.cf
postfix check 2>&1 | grep -v smtpd_use_tls || true
postfix reload >/dev/null 2>&1
sleep 2
echo "=== 优先级矩阵（postmap 离线验证）==="
echo "--- [1] 1对1转发优先（specific alias）---"
echo -n "test@vche.net                    -> "; postmap -q "test@vche.net" mysql:$M/mysql_virtual_alias_maps.cf
echo "--- [2] 真实邮箱 > catch-all：应返回地址本身 ---"
echo -n "nic@vche.net                     -> "; postmap -q "nic@vche.net" mysql:$M/mysql_virtual_alias_maps.cf
echo -n "xn--viq251j@xn--hxy.xn--fiqs8s   -> "; postmap -q "xn--viq251j@xn--hxy.xn--fiqs8s" mysql:$M/mysql_virtual_alias_maps.cf
echo -n "xn--mxa@xn--mxa.cc               -> "; postmap -q "xn--mxa@xn--mxa.cc" mysql:$M/mysql_virtual_alias_maps.cf
echo "--- [3] 不存在的地址才进 catch-all ---"
echo -n "zztest999@vche.net               -> "; postmap -q "zztest999@vche.net" mysql:$M/mysql_virtual_alias_maps.cf
echo -n "nobody@diy.gd (无catch-all)      -> "; postmap -q "nobody@diy.gd" mysql:$M/mysql_virtual_alias_maps.cf
echo "--- [4] 原生 catch-all 键（Postfix 回退时直接查这个键）---"
echo -n "@vche.net                        -> "; postmap -q "@vche.net" mysql:$M/mysql_virtual_alias_maps.cf
echo "--- [5] 外部地址不受影响 ---"
echo -n "someone@gmail.com                -> "; postmap -q "someone@gmail.com" mysql:$M/mysql_virtual_alias_maps.cf; echo "   (空=正常)"
