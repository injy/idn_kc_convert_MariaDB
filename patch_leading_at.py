#!/usr/bin/env python3
"""Patch kc_idn.c so kc_to_ascii()/kc_to_utf8() PRESERVE a leading '@'.

Why
---
The Postfix virtual_alias_maps query applies kc_to_ascii() to the
`alias.address` column.  Catch-all rows are stored as '@domain'
(e.g. '@vche.net') and are matched with

    kc_to_ascii(address) = CONCAT('@', SUBSTRING_INDEX(kc_to_ascii('%s'),'@',-1))

The original code DROPPED a leading '@': the `at == tmp` branch left
at_gt0 == 0 and emitted only the converted domain, so the left side became
'vche.net' while the right side was '@vche.net'.  The catch-all therefore
never matched, silently breaking catch-all forwarding.

Preserving a leading '@' is also semantically right: a leading '@' means
"domain only" (a catch-all key), so its converted form must keep it.  It
also keeps the match form-agnostic for IDN catch-alls stored as UTF-8
('@\u673a\u6784.\u4e2d\u56fd' -> '@xn--...').

The two core functions differ (kc_ascii_core uses user_enc/domain_enc,
kc_utf8_core uses user_dec/domain_dec), so they are patched separately.
"""

import sys

P = "/root/kc_idn_build/kc_idn.c"
ADD = "    int leading_at = (tmp[0] == '@') ? 1 : 0;   /* keep a leading '@' */"

# ---- kc_ascii_core ------------------------------------------------------
A1_OLD = (
    "    int at_gt0 = 0;                    /* strpos() returned > 0 */\n"
    "\n"
    "    user_enc[0] = '\\0';\n"
    "    domain_enc[0] = '\\0';"
)
A1_NEW = (
    "    int at_gt0 = 0;                    /* strpos() returned > 0 */\n"
    + ADD + "\n"
    "\n"
    "    user_enc[0] = '\\0';\n"
    "    domain_enc[0] = '\\0';"
)
A2_OLD = (
    "        snprintf(out, outlen, \"%s\", domain_enc);\n"
    "    }\n"
    "    return 0;"
)
A2_NEW = (
    "        snprintf(out, outlen, \"%s%s\", leading_at ? \"@\" : \"\", domain_enc);\n"
    "    }\n"
    "    return 0;"
)

# ---- kc_utf8_core -------------------------------------------------------
B1_OLD = (
    "    int at_gt0 = 0;\n"
    "\n"
    "    user_dec[0] = '\\0';\n"
    "    domain_dec[0] = '\\0';"
)
B1_NEW = (
    "    int at_gt0 = 0;\n"
    + ADD + "\n"
    "\n"
    "    user_dec[0] = '\\0';\n"
    "    domain_dec[0] = '\\0';"
)
B2_OLD = (
    "        snprintf(out, outlen, \"%s\", domain_dec);\n"
    "    }\n"
    "    return 0;"
)
B2_NEW = (
    "        snprintf(out, outlen, \"%s%s\", leading_at ? \"@\" : \"\", domain_dec);\n"
    "    }\n"
    "    return 0;"
)

s = open(P, encoding="utf-8").read()

for name, old, new in (
    ("A1(ascii decl)", A1_OLD, A1_NEW),
    ("A2(ascii out)", A2_OLD, A2_NEW),
    ("B1(utf8 decl)", B1_OLD, B1_NEW),
    ("B2(utf8 out)", B2_OLD, B2_NEW),
):
    n = s.count(old)
    if n != 1:
        sys.exit("anchor %s matched %d times (expected exactly 1)" % (name, n))
    s = s.replace(old, new)

open(P, "w", encoding="utf-8").write(s)
print("patched OK: leading '@' preserved in kc_ascii_core + kc_utf8_core")
