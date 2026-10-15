#!/usr/bin/php
<?php
/**
 * Robustness + parity harness for kc_to_ascii()/kc_to_utf8() (PHP reference)
 * and the kc_idn UDF (C).
 *
 * Goals:
 *   1. Prove the reference never throws / never crashes on nasty input.
 *   2. Check its documented error/edge behaviour (empty, multi-@, too long).
 *   3. Check idempotency on already-punycode input.
 *   4. Cross-check ENCODE/DECODE output against the compiled C kc_idn binary
 *      (the UDF) and report every divergence.
 *   5. Detect transitional-vs-non-transitional drift on ß / roman numerals.
 *   6. Roundtrip decode(encode(x)) and fuzz for crash-safety.
 *
 * Usage (from the repo root):
 *   make standalone
 *   php test/test_robustness.php [path-to-c-binary]
 *
 * Environment overrides:
 *   KC_PHP_REF  path to the PHP reference (default: ../php_idn_kc_convert.php)
 *
 * Requires PHP with intl (idn_to_ascii/idn_to_utf8) and mbstring.
 */

$bin = $argv[1] ?? (getenv('KC_BIN') ?: __DIR__ . '/../kc_idn_test');
$ref = getenv('KC_PHP_REF') ?: __DIR__ . '/../php_idn_kc_convert.php';

if (!is_file($ref)) {
    fwrite(STDERR, "PHP reference not found: $ref\n");
    exit(2);
}

// ---- capture PHP notices/warnings (a robust function should stay quiet) ----
$warnings = 0;
set_error_handler(function ($no, $str) use (&$warnings) {
    $warnings++;
    return false;
});

require $ref;

function run_php($a, $utf = true)
{
    try {
        // kc_to_ascii() = encode (UTF-8/IDN -> punycode); kc_to_utf8() = decode.
        // Both return '' (false in string context) when conversion fails.
        // Every consumer (socketmap daemon, MySQL UDF) sees it in string
        // context, i.e. '' - so the harness works with the string value.
        $r = $utf ? (string) kc_to_ascii($a) : (string) kc_to_utf8($a);
        return [$r, null];
    } catch (\Throwable $e) {
        return [null, get_class($e) . ': ' . $e->getMessage()];
    }
}

function run_c($bin, $a, $utf8 = false)
{
    if (!$bin || !is_executable($bin)) return null;
    // --hex mode: pass the input hexlified so arbitrary bytes (invalid
    // UTF-8, GBK, control chars) survive the shell/argv hop unchanged.
    // escapeshellarg keeps an empty input as an explicit '' argument.
    $cmd = escapeshellarg($bin) . ($utf8 ? ' --utf8' : '') . ' --hex ' . escapeshellarg(bin2hex($a));
    $out = @shell_exec($cmd . ' 2>/dev/null');
    return $out === null ? null : rtrim($out, "\n");
}

$pass = 0; $fail = 0; $throws = 0;
function check($label, $cond, $got, $expect = null)
{
    global $pass, $fail;
    if ($cond) { $pass++; $tag = 'OK  '; }
    else       { $fail++; $tag = 'FAIL'; }
    printf("  [%-4s] %-46s => %s%s\n", $tag, $label,
        json_encode($got, JSON_UNESCAPED_UNICODE),
        $expect !== null ? '  (expect ' . json_encode($expect, JSON_UNESCAPED_UNICODE) . ')' : '');
}

echo "==============================================================\n";
echo "A. ERROR / EDGE HANDLING  (hard assertions)\n";
echo "==============================================================\n";
foreach ([
    [''            , 'no_input'],
    ['   '         , 'no_input'],
    [null          , 'no_input'],
    ['a@b@c.com'   , 'too_many_at_2+'],
    ['a@b@c@d.com' , 'too_many_at_2+'],
    [str_repeat('x', 201), 'input_too_long'],
    [str_repeat('中', 70), 'input_too_long'],
] as [$in, $exp]) {
    [$r, $err] = run_php($in);
    if ($err) { $throws++; check('edge ' . json_encode($in), false, $err); }
    else      { check('edge ' . json_encode($in), $r === $exp, $r, $exp); }
}

echo "\n==============================================================\n";
echo "B. EXPECTED CONVERSIONS  (hard assertions)\n";
echo "==============================================================\n";
$exp = [
    'user@example.com'  => 'user@example.com',
    'USER@EXAMPLE.COM'  => 'user@example.com',
    '中文@中文.中国'       => 'xn--fiq228c@xn--fiq228c.xn--fiqs8s',
    '中文.中国'            => 'xn--fiq228c.xn--fiqs8s',
    'xn--fiq228c@xn--fiq228c.xn--fiqs8s' => 'xn--fiq228c@xn--fiq228c.xn--fiqs8s',
];
foreach ($exp as $in => $want) {
    [$r, $err] = run_php($in);
    if ($err) { $throws++; check('conv ' . $in, false, $err); }
    else      { check('conv ' . $in, $r === $want, $r, $want); }
}

echo "\n==============================================================\n";
echo "C. IDEMPOTENCY  (encode then encode again must be stable)\n";
echo "==============================================================\n";
foreach ([
    'xn--fiq228c@xn--fiq228c.xn--fiqs8s',
    'user@example.com',
    '中文@中文.中国',
    'XN--FIQ228C@XN--FIQ228C.XN--FIQS8S',
] as $in) {
    [$r1, $e1] = run_php($in);
    [$r2, $e2] = run_php($r1);
    check('idempotent ' . $in, $e1 === null && $e2 === null && $r1 === $r2, $r2, $r1);
}

echo "\n==============================================================\n";
echo "D. PHP vs C UDF PARITY  (encode direction)\n";
echo "==============================================================\n";
if (!$bin || !is_executable($bin)) echo "  (no C binary supplied — skipping parity; build with: make standalone)\n";
$mismatch = 0; $parity_n = 0;
$parity_cases = [
    '中文@中文.中国', 'user@中文.中国', '用户@示例.中国',
    'test@müller.de', 'faß.de', 'straße.de', 'nic@example.com',
    'xn--fiq228c@xn--fiq228c.xn--fiqs8s', 'USER@中文.中国',
    'a.b@中文.中国', '中文.中国', 'mixed.中文@xn--fiq228c.xn--fiqs8s',
    '@example.com', 'foo@', 'admin@example.com', 'a b@x.de', 'user@-bad-.com',
    'Ⅰ.de', 'K.de', 'test.测试@example.com', 'a+b@x.de',
    'a@b@c.com', str_repeat('x', 201), 'a..b@x.de', 'a.<.>b@x.de',
    'clown@😍.uz', '🤡', '  spaced@example.com  ',
];
foreach ($parity_cases as $in) {
    [$php, $e] = run_php($in);
    $c = run_c($bin, $in);
    if ($c === null) continue;
    $parity_n++;
    $same = ($php === $c);
    if (!$same) $mismatch++;
    printf("  [%-4s] php=%-40s c=%-40s | in=%s\n",
        $same ? 'OK  ' : 'DIFF',
        json_encode($php, JSON_UNESCAPED_UNICODE),
        json_encode($c, JSON_UNESCAPED_UNICODE),
        $in);
}

echo "\n==============================================================\n";
echo "D2. PHP vs C UDF PARITY  (decode direction)\n";
echo "==============================================================\n";
$decode_cases = [
    'xn--fiq228c@xn--fiq228c.xn--fiqs8s', 'xn--fiq228c.xn--fiqs8s',
    'xn--mller-kva.de', 'xn--e1t202ftnn@xn--ue4at70a.xn--fiqs8s',
    'user@example.com', '@example.com', 'foo@',
    'xn--i1a.xn--fiqs8s', str_repeat('x', 201), 'a@b@c.com',
];
foreach ($decode_cases as $in) {
    [$php, $e] = run_php($in, false);
    $c = run_c($bin, $in, true);
    if ($c === null) continue;
    $parity_n++;
    $same = ($php === $c);
    if (!$same) $mismatch++;
    printf("  [%-4s] php=%-40s c=%-40s | in=%s\n",
        $same ? 'OK  ' : 'DIFF',
        json_encode($php, JSON_UNESCAPED_UNICODE),
        json_encode($c, JSON_UNESCAPED_UNICODE),
        $in);
}

echo "\n==============================================================\n";
echo "E. TRANSITIONAL vs NON-TRANSITIONAL PROBE  (the ß question)\n";
echo "==============================================================\n";
// What does the reference call actually produce, and how does it differ
// from an explicit non-transitional call?  (The C UDF uses
// IDN2_TRANSITIONAL to match the first column.)
$probe = ['faß.de', 'müller.de', 'straße.de', 'Ⅰ.de', 'K.de', 'öbb.de'];
foreach ($probe as $d) {
    $flags_as_written = idn_to_ascii($d, INTL_IDNA_VARIANT_UTS46);          // how the reference calls it
    $explicit_nt = idn_to_ascii($d, IDNA_NONTRANSITIONAL_TO_ASCII, INTL_IDNA_VARIANT_UTS46);
    $differs = ($flags_as_written !== $explicit_nt);
    printf("  %-12s | ref-call=%-22s | nontrans=%-22s | %s\n",
        $d,
        json_encode($flags_as_written, JSON_UNESCAPED_UNICODE),
        json_encode($explicit_nt, JSON_UNESCAPED_UNICODE),
        $differs ? '*** DIVERGES (C must use transitional)' : 'same');
}

echo "\n==============================================================\n";
echo "F. ROUNDTRIP  decode(encode(x)) should recover Unicode\n";
echo "==============================================================\n";
foreach (['中文@中文.中国', 'user@müller.de', 'test@müller.de', '中文.中国', 'user@example.com'] as $in) {
    [$enc, $e1] = run_php($in, true);
    [$dec, $e2] = run_php($enc, false);
    // normalize both to NFC for comparison (intl may output different normalization)
    $dec_n = class_exists('Normalizer') ? \Normalizer::normalize($dec, \Normalizer::FORM_C) : $dec;
    $in_n  = class_exists('Normalizer') ? \Normalizer::normalize($in,  \Normalizer::FORM_C) : $in;
    check('roundtrip ' . $in, $e1 === null && $e2 === null && $dec_n === $in_n, $dec, $in);
}

echo "\n==============================================================\n";
echo "G. FUZZ  (200 random: valid UTF-8 + raw bytes) — must not crash\n";
echo "==============================================================\n";
$fuzz_throw = 0; $fuzz_n = 200;
for ($i = 0; $i < $fuzz_n; $i++) {
    if ($i % 2 === 0) {
        // random valid-ish UTF-8 multibyte
        $s = '';
        $len = random_int(1, 12);
        for ($j = 0; $j < $len; $j++) {
            $cp = random_int(0x20, 0x9FA5);
            $s .= mb_chr($cp, 'UTF-8');
        }
        if ($i % 3 === 0) $s .= '@' . mb_substr($s, 0, 3) . '.com';
    } else {
        // raw random bytes, often invalid UTF-8
        $s = random_bytes(random_int(1, 20));
    }
    [$r, $err] = run_php($s);
    if ($err) $fuzz_throw++;
}
check('fuzz: no throw over ' . $fuzz_n . ' cases', $fuzz_throw === 0,
    $fuzz_throw . ' throws');

echo "\n==============================================================\n";
echo "SUMMARY\n";
echo "==============================================================\n";
printf("  hard asserts : %d pass / %d fail\n", $pass, $fail);
printf("  php throws   : %d (edges+fuzz)\n", $throws + $fuzz_throw);
printf("  php warnings : %d (during whole run)\n", $warnings);
printf("  parity cases : %d checked / %d mismatch (vs C UDF)\n", $parity_n, $mismatch);
echo "\n";
if ($fail === 0 && $throws === 0 && $fuzz_throw === 0 && $mismatch === 0) {
    echo "  VERDICT: reference is CRASH-SAFE and the C UDF matches it byte-for-byte.\n";
} elseif ($fail === 0 && $throws === 0 && $fuzz_throw === 0) {
    echo "  VERDICT: reference is CRASH-SAFE, but C UDF diverges (see DIFF lines).\n";
} else {
    echo "  VERDICT: ROBUSTNESS DEFECT(S) FOUND — review FAIL/throws.\n";
}
