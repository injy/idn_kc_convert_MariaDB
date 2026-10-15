# kc_punycode build file
#
# Two targets:
#   make standalone   -> kc_punycode_test  (needs only libidn2, no MariaDB headers)
#   make udf          -> kc_punycode.so    (needs libmariadb-dev: apt install libmariadb-dev)
#
# Typical workflow:
#   # 1) verify conversion matches the PHP reference (safe, no DB change)
#   make standalone
#   php compare_idn.php          # A/B parity: C UDF vs PHP reference
#   php test/test_robustness.php # edge/idempotency/fuzz + parity
#   php test/test_gbk.php        # encoding-handling probe (GBK etc.)
#
#   # 2) build + install the real UDF (requires libmariadb-dev)
#   make udf
#   cp kc_punycode.so $(mariadb_config --plugindir)
#   mysql -e "CREATE FUNCTION kc_punycode RETURNS STRING SONAME 'kc_punycode.so';"

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LIBS    ?= -lidn2

all: standalone

standalone: kc_punycode.c
	$(CC) $(CFLAGS) -DSTANDALONE_TEST -o kc_punycode_test kc_punycode.c $(LIBS)

udf: kc_punycode.c
	$(CC) $(CFLAGS) -fPIC -shared -o kc_punycode.so kc_punycode.c $(LIBS) \
		$$(mariadb_config --include 2>/dev/null || mysql_config --include 2>/dev/null)

test: standalone
	php compare_idn.php
	php test/test_robustness.php
	php test/test_gbk.php

clean:
	rm -f kc_punycode_test kc_punycode.so

.PHONY: all standalone udf test clean
