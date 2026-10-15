# kc_idn build file
#
# Two targets:
#   make standalone   -> kc_idn_test  (needs only libidn2, no MariaDB headers)
#   make udf          -> kc_idn.so    (needs libmariadb-dev: apt install libmariadb-dev)
#
# The .so registers TWO UDFs: kc_to_ascii() and kc_to_utf8().
#
# Typical workflow:
#   # 1) verify conversion matches the PHP reference (safe, no DB change)
#   make standalone
#   php compare_idn.php          # A/B parity: ascii + utf8 + roundtrip
#   php test/test_robustness.php # edge/idempotency/fuzz + parity (both dirs)
#   php test/test_gbk.php        # encoding-handling probe (GBK etc.)
#
#   # 2) build + install the real UDF (requires libmariadb-dev)
#   make udf
#   cp kc_idn.so $(mariadb_config --plugindir)
#   mysql -e "CREATE FUNCTION kc_to_ascii RETURNS STRING SONAME 'kc_idn.so';"
#   mysql -e "CREATE FUNCTION kc_to_utf8  RETURNS STRING SONAME 'kc_idn.so';"

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LIBS    ?= -lidn2

all: standalone

standalone: kc_idn.c
	$(CC) $(CFLAGS) -DSTANDALONE_TEST -o kc_idn_test kc_idn.c $(LIBS)

udf: kc_idn.c
	$(CC) $(CFLAGS) -fPIC -shared -o kc_idn.so kc_idn.c $(LIBS) \
		$$(mariadb_config --include 2>/dev/null || mysql_config --include 2>/dev/null)

test: standalone
	php compare_idn.php
	php test/test_robustness.php
	php test/test_gbk.php

clean:
	rm -f kc_idn_test kc_idn.so

.PHONY: all standalone udf test clean
