#!/usr/bin/php
<?php
/**
 * Encoding-handling probe: what happens when the input is GBK (or any
 * non-UTF-8) instead of the UTF-8 that Postfix/Dovecot actually deliver?
 *
 * Design decision under test: idn_kc_convert() and the C UDF do NO encoding
 * guessing - the input is assumed to be UTF-8 (which is what the mail path
 * guarantees).  Consequences, all intentional:
 *
 *   - genuine UTF-8 (incl. 4-byte emoji) converts correctly;
 *   - GBK / arbitrary bytes are simply NOT valid UTF-8, so idn_to_ascii()
 *     fails and the result is an empty string -> the SQL lookup finds
 *     nothing -> the message is rejected.  No crash, no silent corruption;
 *   - the production PHP original used to *guess* the encoding here
 *     (mb_detect_encoding + mb_convert_encoding), which corrupted emoji and
 *     mangled GBK bytes that collide with UTF-8.  That guess was removed.
 *
 * Usage (from the repo root):
 *   make standalone
 *   php test/test_gbk.php
 *
 * Environment overrides:
 *   KC_PHP_REF  path to the PHP reference (default: ../php_idn_kc_convert.php)
 *   KC_BIN      path to the C binary       (default: ../kc_punycode_test)
 */

$ref = getenv('KC_PHP_REF') ?: __DIR__ . '/../php_idn_kc_convert.php';
$bin = getenv('KC_BIN') ?: __DIR__ . '/../kc_punycode_test';

if (!is_file($ref)) {
    fwrite(STDERR, "PHP reference not found: $ref\n");
    exit(2);
}
require $ref;

function run_c($bin, $a)
{
    if (!$bin || !is_executable($bin)) return '(no binary)';
    // --hex mode: pass the input hexlified so arbitrary bytes (GBK,
    // invalid UTF-8) survive the shell/argv hop unchanged.
    // escapeshellarg keeps an empty input as an explicit '' argument.
    $out = @shell_exec(escapeshellarg($bin) . ' --hex ' . escapeshellarg(bin2hex($a)) . ' 2>/dev/null');
    return $out === null ? '(crash)' : rtrim($out, "\n");
}

echo "=== A. genuine GBK bytes that are NOT valid UTF-8 ===\n";
$clean = [
  '中文' => mb_convert_encoding('中文','GBK','UTF-8'),
  '中国' => mb_convert_encoding('中国','GBK','UTF-8'),
  '邮箱中文' => mb_convert_encoding('邮箱中文','GBK','UTF-8'),
];
foreach($clean as $label=>$gbk){
  // string coercion: idn_kc_convert() returns bool false on failure, which
  // is '' in every real consumer (socketmap daemon, MySQL UDF)
  $php = (string) @idn_kc_convert($gbk, true);
  $c   = run_c($bin, $gbk);
  printf("  %-10s gbk=%s\n", $label, bin2hex($gbk));
  printf("             php=%-24s c=%-24s %s\n",
    json_encode($php), json_encode($c), ($php === $c ? 'AGREE' : 'DIVERGE'));
}

echo "=== B. genuine GBK that is ALSO valid UTF-8 (collision) ===\n";
$found = 0;
for($fb = 0xC2; $fb <= 0xDF; $fb++){
  for($sb = 0x80; $sb <= 0xBF; $sb++){
    $b = chr($fb).chr($sb);
    $det = mb_detect_encoding($b, ['UTF-8','GBK','ASCII'], true);
    if($det === 'UTF-8'){
      $asGbk = @mb_convert_encoding($b,'UTF-8','GBK');
      if($asGbk !== false && $asGbk !== $b){
        $php = (string) @idn_kc_convert($b, true);
        $c   = run_c($bin, $b);
        printf("  gbk=%s(%s) php=%-20s c=%-20s %s\n",
           bin2hex($b), $asGbk, json_encode($php), json_encode($c),
           ($php === $c ? 'AGREE' : 'DIVERGE'));
        if(++$found >= 4) break 2;
      }
    }
  }
}
if($found === 0) echo "  (none found in 2-byte scan)\n";

echo "=== C. what Postfix actually delivers (UTF-8/SMTPUTF8) ===\n";
foreach(['中文@中文.中国','müller@example.de','clown@😍.uz','🤡@😍.uz'] as $u){
  $php = (string) @idn_kc_convert($u, true);
  $c   = run_c($bin, $u);
  printf("  %-24s php=%-40s c=%-40s %s\n", $u, $php, $c, ($php === $c ? 'AGREE' : 'DIVERGE'));
}

echo "=== D. GBK input must not throw (the production version threw ValueError) ===\n";
$gbk_chinese = mb_convert_encoding('中文','GBK','UTF-8');
try {
  $r = (string) idn_kc_convert($gbk_chinese, true);
  printf("  php: no throw, result=%s\n", json_encode($r));
} catch (\Throwable $e) {
  printf("  php: THROWS %s: %s\n", get_class($e), $e->getMessage());
}
