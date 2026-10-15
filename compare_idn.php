#!/usr/bin/php
<?php
/**
 * A/B comparison: PHP idn_kc_convert()  vs  compiled C kc_punycode.
 *
 * The PHP reference implementation in this repo (php_idn_kc_convert.php)
 * is the semantic ground truth; the C UDF must match it byte-for-byte,
 * otherwise a native `mysql:` lookup with kc_punycode('%u') would resolve
 * different rows than the PHP daemon did.
 *
 * Usage:
 *   make standalone          # builds ./kc_punycode_test
 *   php compare_idn.php      # runs the A/B suite
 *
 * Environment overrides:
 *   KC_BIN      path to the compiled C binary   (default: ./kc_punycode_test)
 *   KC_PHP_REF  path to the PHP reference file  (default: ./php_idn_kc_convert.php)
 *
 * Requires the intl extension on the PHP side (idn_to_ascii/idn_to_utf8).
 */

$bin = getenv('KC_BIN') ?: __DIR__ . '/kc_punycode_test';
$ref = getenv('KC_PHP_REF') ?: __DIR__ . '/php_idn_kc_convert.php';

if (!is_executable($bin)) {
    fwrite(STDERR, "C binary not found or not executable: $bin\n  build it first:  make standalone\n");
    exit(2);
}
if (!is_file($ref)) {
    fwrite(STDERR, "PHP reference not found: $ref\n");
    exit(2);
}

require $ref;

$cases = [
    // --- valid addresses ------------------------------------------------
    '中文@中文.中国',
    'user@中文.中国',
    '用户@示例.中国',
    'test@müller.de',
    'admin@example.com',
    'nic@example.com',
    'USER@中文.中国',
    'a.b@中文.中国',
    'test.测试@example.com',
    'a+b@example.com',
    // --- already-punycode (must be idempotent) ---------------------------
    'xn--fiq228c@xn--fiq228c.xn--fiqs8s',
    'XN--FIQ228C@XN--FIQ228C.XN--FIQS8S',
    'mixed.中文@xn--fiq228c.xn--fiqs8s',
    // --- bare domains ----------------------------------------------------
    '中文.中国',
    'example.com',
    'faß.de',
    'straße.de',
    'müller.de',
    'Ⅰ.de',
    'K.de',
    // --- @ edge cases -----------------------------------------------------
    '@example.com',
    'foo@',
    '@',
    // --- sentinel / error paths ------------------------------------------
    '',
    'a@b@c.com',
    'a@b@c@d.com',
    str_repeat('x', 200),
    str_repeat('x', 201),
    str_repeat('中', 70),
    // --- sanitiser --------------------------------------------------------
    '  spaced@example.com  ',
    'a b@example.com',
    'a..b@example.com',
    'a.<.>b@example.com',
    // --- conversion failure ----------------------------------------------
    'user@-bad-.com',
    '中文@-bad-.com',
    // --- 4-byte UTF-8 (emoji) --------------------------------------------
    'clown@😍.uz',
    '🤡@😍.uz',
    '🤡',
];

$pass = 0;
$fail = 0;

printf("%-6s | %-44s | %-44s | input\n", 'RESULT', 'php', 'c');
echo str_repeat('-', 130) . "\n";

foreach ($cases as $a) {
    // NOTE: idn_kc_convert() returns the boolean false (not '') when
    // idn_to_ascii() fails on a bare domain.  Every consumer (socketmap
    // daemon, MySQL UDF) sees it in string context, i.e. '' - so compare
    // the string value, which is what a lookup actually uses.
    $php = (string) idn_kc_convert($a, true);
    // --hex mode: pass the input hexlified so arbitrary bytes (invalid
    // UTF-8, GBK, control chars) survive the shell/argv hop unchanged.
    // escapeshellarg keeps an empty input as an explicit '' argument.
    $c   = trim((string) shell_exec(escapeshellarg($bin) . ' --hex ' . escapeshellarg(bin2hex($a)) . ' 2>/dev/null'));
    $ok  = ($php === $c);
    printf("%-6s | %-44s | %-44s | %s\n",
        $ok ? 'PASS' : 'FAIL',
        $php,
        $c,
        $a === '' ? "''" : $a);
    $ok ? $pass++ : $fail++;
}

echo str_repeat('-', 130) . "\n";
printf("RESULT: %d pass, %d fail\n", $pass, $fail);
exit($fail ? 1 : 0);
