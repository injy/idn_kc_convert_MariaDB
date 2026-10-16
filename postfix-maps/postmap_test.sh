#!/bin/bash
# Full regression for the IDN UDF + native mysql: maps.
# Run on the server as root.

D=/etc/postfix/mysql

q() {  # q <map> <key> <expected>
    local out
    out=$(postmap -q "$2" "mysql:$D/$1" 2>&1)
    if [ "$out" = "$3" ]; then
        printf 'PASS  %-34s -> %s\n' "$2" "$out"
    else
        printf 'FAIL  %-34s -> got [%s]  want [%s]\n' "$2" "$out" "$3"
    fi
}

echo "--- virtual_mailbox_domains (form-agnostic, bare domain) ---"
q mysql_virtual_mailbox_domains.cf "中国.机构"  "xn--fiqs8s.xn--nqv7f"
q mysql_virtual_mailbox_domains.cf "的.中国"     "xn--hxy.xn--fiqs8s"
q mysql_virtual_mailbox_domains.cf "α.cc"        "xn--mxa.cc"
q mysql_virtual_mailbox_domains.cf "😍.uz"       "xn--r28h.uz"
q mysql_virtual_mailbox_domains.cf "vche.net"    "vche.net"
# not a hosted domain -> NOTFOUND
q mysql_virtual_mailbox_domains.cf "机构.中国"    ""

echo "--- virtual_alias_domains (identity rows MUST be excluded) ---"
q mysql_virtual_alias_domains.cf "ω.cc"        ""
q mysql_virtual_alias_domains.cf "xn--bya.cc"  ""
q mysql_virtual_alias_domains.cf "的.中国"      ""
q mysql_virtual_alias_domains.cf "xn--hxy.xn--fiqs8s" ""

echo "--- virtual_mailbox_maps ---"
q mysql_virtual_mailbox_maps.cf "nic@vche.net"                    "nic@vche.net"
q mysql_virtual_mailbox_maps.cf "xn--viq251j@xn--hxy.xn--fiqs8s"  "xn--viq251j@xn--hxy.xn--fiqs8s"
q mysql_virtual_mailbox_maps.cf "xn--9p9h@xn--r28h.uz"            "xn--9p9h@xn--r28h.uz"

echo "--- recipient_canonical (IDN -> ACE) ---"
q mysql_recipient_canonical.cf "🤡@😍.uz"      "xn--9p9h@xn--r28h.uz"
q mysql_recipient_canonical.cf "美丽@的.中国"   "xn--viq251j@xn--hxy.xn--fiqs8s"
q mysql_recipient_canonical.cf "中国.机构"      "xn--fiqs8s.xn--nqv7f"
q mysql_recipient_canonical.cf "nic@vche.net"   "nic@vche.net"

echo "--- virtual_alias_maps: 1对1转发 > 真实邮箱 > catch-all ---"
q mysql_virtual_alias_maps.cf "test@vche.net"      "injy@qq.com"   # 1 specific alias
q mysql_virtual_alias_maps.cf "nic@vche.net"       "nic@vche.net"  # 3 real mailbox -> address ITSELF (suppresses native @domain fallback)
q mysql_virtual_alias_maps.cf "xn--viq251j@xn--hxy.xn--fiqs8s" "xn--viq251j@xn--hxy.xn--fiqs8s"  # 3 IDN mailbox -> itself
q mysql_virtual_alias_maps.cf "xn--9p9h@xn--r28h.uz"           "xn--9p9h@xn--r28h.uz"            # 3 emoji mailbox -> itself
q mysql_virtual_alias_maps.cf "zztest999@vche.net" "injy@qq.com"   # 4 catch-all
q mysql_virtual_alias_maps.cf "@vche.net"          "injy@qq.com"   # native catch-all key (Postfix's own fallback query)
q mysql_virtual_alias_maps.cf "nobody@diy.gd"      ""              # no mailbox, no catch-all
