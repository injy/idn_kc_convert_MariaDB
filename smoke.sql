CREATE FUNCTION IF NOT EXISTS kc_to_ascii RETURNS STRING SONAME "kc_idn.so";
CREATE FUNCTION IF NOT EXISTS kc_to_utf8  RETURNS STRING SONAME "kc_idn.so";

SELECT "--- registered ---" AS step;
SELECT name, dl, type FROM mysql.func WHERE name IN ("kc_to_ascii","kc_to_utf8");

SELECT "--- examples ---" AS step;
SELECT kc_to_ascii("中文@中文.中国") AS ascii_zh;
SELECT kc_to_utf8("xn--fiq228c@xn--fiq228c.xn--fiqs8s") AS utf8_zh;

SELECT "--- roundtrip ---" AS step;
SELECT kc_to_utf8(kc_to_ascii("中文@中文.中国")) AS rt;

SELECT "--- ascii passthrough + edge ---" AS step;
SELECT kc_to_ascii("user@example.com") AS ascii_mail;
SELECT kc_to_ascii("") AS empty_in;
SELECT kc_to_ascii("a@b@c") AS two_at;
SELECT kc_to_ascii("x@example.com<script>") AS danger;
SELECT kc_to_utf8("user@example.com") AS utf8_ascii_in;
