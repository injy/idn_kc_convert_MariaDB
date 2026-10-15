#!/usr/bin/php
<?php
/**
 * A/B comparison: PHP reference (kc_to_ascii / kc_to_utf8)  vs  compiled C kc_idn.
 *
 * The PHP reference implementation in this repo (php_idn_kc_convert.php) is the
 * semantic ground truth; the C UDF (kc_to_ascii + kc_to_utf8) must match it
 * byte-for-byte, otherwise a native `mysql:` lookup would resolve different
 * rows than the PHP daemon did.
 *
 * This script checks THREE things:
 *   A) kc_to_ascii : UTF-8/IDN  -> punycode   (PHP vs C)
 *   B) kc_to_utf8  : punycode    -> UTF-8/IDN  (PHP vs C)
 *   C) roundtrip   : kc_to_utf8(kc_to_ascii(x)) composed identically (PHP vs C)
 *
 * Usage:
 *   make standalone          # builds ./kc_idn_test
 *   php compare_idn.php      # runs the A/B/C suite
 *
 * Environment overrides:
 *   KC_BIN      path to the compiled C binary   (default: ./kc_idn_test)
 *   KC_PHP_REF  path to the PHP reference file  (default: ./php_idn_kc_convert.php)
 *
 * Requires the intl extension on the PHP side (idn_to_ascii/idn_to_utf8).
 */

$bin = getenv('KC_BIN') ?: __DIR__ . '/kc_idn_test';
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
    // --- valid addresses (UTF-8) -----------------------------------------
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
    // --- pure punycode decode inputs -------------------------------------
    'xn--fiq228c.xn--fiqs8s',
    'xn--mller-kva.de',
    'xn--e1t202ftnn@xn--ue4at70a.xn--fiqs8s',
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

/* Run the C binary. --utf8 selects the decode direction. --hex passes the
 * exact bytes so invalid UTF-8 / GBK survive the shell/argv hop unchanged.
 * escapeshellarg keeps an empty input as an explicit '' argument. */
function run_c($bin, $a, $utf8 = false)
{
    $cmd = escapeshellarg($bin) . ($utf8 ? ' --utf8' : '') . ' --hex ' . escapeshellarg(bin2hex($a));
    $out = @shell_exec($cmd . ' 2>/dev/null');
    return $out === null ? null : rtrim($out, "\n");
}

$passA = $passB = $passC = 0;
$failA = $failB = $failC = 0;

echo "=== A) kc_to_ascii : UTF-8/IDN -> punycode (PHP vs C) ===\n";
printf("%-6s | %-46s | %-46s | input\n", 'RESULT', 'php', 'c');
echo str_repeat('-', 138) . "\n";
foreach ($cases as $a) {
    $php = (string) kc_to_ascii($a);
    $c   = run_c($bin, $a, false);
    $ok  = ($php === $c);
    printf("%-6s | %-46s | %-46s | %s\n",
        $ok ? 'PASS' : 'FAIL', $php, (string)$c, $a === '' ? "''" : $a);
    $ok ? $passA++ : $failA++;
}

/* Decode-specific inputs.  kc_to_utf8() is the inverse of kc_to_ascii and is
 * meant for punycode / ACE input (what kc_to_ascii produced and what is stored
 * in the mailbox table).  We therefore test it with ACE, mixed and edge inputs.
 * NOTE: a single bare ASCII label longer than 63 bytes (e.g. 200 'x') is NOT a
 * valid email component and is never a stored username; libidn2 rejects it with
 * IDN2_TOO_BIG while ICU relaxes the limit in idn_to_utf8.  That pathological
 * case is exercised only in the encode direction (A) and robustness suite, not
 * here, where it would be a meaningless equality assertion. */
$decode_cases = [
    'xn--fiq228c@xn--fiq228c.xn--fiqs8s',
    'XN--FIQ228C@XN--FIQ228C.XN--FIQS8S',
    'xn--fiq228c.xn--fiqs8s',
    'xn--mller-kva.de',
    'xn--e1t202ftnn@xn--ue4at70a.xn--fiqs8s',
    'xn--i1a.xn--fiqs8s',                 // bogus ACE -> decode fails -> ''
    'mixed.中文@xn--fiq228c.xn--fiqs8s',
    'user@example.com',
    '@example.com',
    'foo@',
    '@',
    '',
    'a@b@c.com',
    'a@b@c@d.com',
    '中文@-bad-.com',                     // domain label invalid -> ''
    str_repeat('x', 201),                 // >200 bytes -> input_too_long
    str_repeat('中', 70),                 // >200 bytes -> input_too_long
    'a b@example.com',
    'a.<.>b@example.com',
    'clown@😍.uz',
    '🤡@😍.uz',
    '🤡',
];

echo "\n=== B) kc_to_utf8 : punycode -> UTF-8/IDN (PHP vs C) ===\n";
printf("%-6s | %-46s | %-46s | input\n", 'RESULT', 'php', 'c');
echo str_repeat('-', 138) . "\n";
foreach ($decode_cases as $a) {
    $php = (string) kc_to_utf8($a);
    $c   = run_c($bin, $a, true);
    $ok  = ($php === $c);
    printf("%-6s | %-46s | %-46s | %s\n",
        $ok ? 'PASS' : 'FAIL', $php, (string)$c, $a === '' ? "''" : $a);
    $ok ? $passB++ : $failB++;
}

echo "\n=== C) roundtrip : kc_to_utf8(kc_to_ascii(x)) composed identically ===\n";
printf("%-6s | %-46s | %-46s | input\n", 'RESULT', 'php', 'c');
echo str_repeat('-', 138) . "\n";
foreach ($cases as $a) {
    $php_rt = (string) kc_to_utf8(kc_to_ascii($a));
    $c_ascii = run_c($bin, $a, false);
    $c_rt   = run_c($bin, (string)$c_ascii, true);
    $ok = ($php_rt === $c_rt);
    printf("%-6s | %-46s | %-46s | %s\n",
        $ok ? 'PASS' : 'FAIL', $php_rt, (string)$c_rt, $a === '' ? "''" : $a);
    $ok ? $passC++ : $failC++;
}

echo str_repeat('-', 138) . "\n";
$nA = count($cases);
$nB = count($decode_cases);
$nC = count($cases);
printf("RESULT: A %d/%d, B %d/%d, C %d/%d  (total %d/%d)\n",
    $passA, $nA, $passB, $nB, $passC, $nC,
    $passA + $passB + $passC, $nA + $nB + $nC);
exit(($failA + $failB + $failC) ? 1 : 0);
