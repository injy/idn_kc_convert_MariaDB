#!/usr/bin/php
<?php
/**
 * 转换域名或邮箱地址的 IDN 格式（语义参照实现 / reference implementation）
 *
 * 这是邮局生产函数 /etc/postfix/php/inc/php_idn_kc_convert.php 的副本，仅做
 * 两处改动，使其与 MariaDB UDF kc_idn 逐字节一致：
 *   1. 删除了 mb_detect_encoding()/mb_convert_encoding() 编码猜测分支
 *      （见下方"与生产版的唯一差异"）。
 *   2. 拆成两个显式方向函数 kc_to_ascii() / kc_to_utf8()，分别对应 UDF 的
 *      两个入口，便于 A/B 对拍。
 *
 * 用法（与 UDF 一一对应）：
 *   kc_to_ascii($input)  - UTF-8/IDN  -> punycode（与 UDF kc_to_ascii 一致）
 *   kc_to_utf8($input)   - punycode   -> UTF-8/IDN（与 UDF kc_to_utf8 一致）
 *
 * 语义（与 C 端完全相同）：
 *   - trim() 默认字符集
 *   - 空输入 -> 'no_input'
 *   - 多于一个 '@' -> 'too_many_at_2+'
 *   - 长度 > 200 字节 -> 'input_too_long'
 *   - 过滤危险字符后折叠连续 '.'（先过滤后折叠）
 *   - 按第一个 '@' 拆本地名/域名，两侧分别做 idn_to_ascii / idn_to_utf8
 *   - 转换失败 -> false -> 字符串上下文为 ''
 *
 * 与生产版的唯一差异：
 *   生产版在过滤危险字符后、拆分@之前，有一段
 *       $encoding = mb_detect_encoding($input, ['UTF-8', 'GBK', 'ASCII'], true);
 *       if ($encoding !== 'UTF-8') { $input = mb_convert_encoding($input, 'UTF-8', $encoding); }
 *   该编码猜测会把 4 字节 UTF-8（如 emoji）误判为 GBK 而损坏字节，也会把
 *   与 UTF-8 碰撞的 GBK 字节误判为 UTF-8 而得到空结果。Postfix/Dovecot
 *   投递的地址恒为 UTF-8(SMTPUTF8) 或 ASCII，本就不需要猜测，故整段删除。
 *   （详见 docs/robustness-report.md）
 */

/** 共享前处理：trim -> 空/多@/超长哨兵 -> 过滤+折叠。返回哨兵或清洗后的串。 */
function kc_prepare_php($input)
{
    $input = trim((string)$input);
    if ($input === '') {
        return ['sentinel' => 'no_input'];
    }
    if (substr_count($input, '@') > 1) {
        return ['sentinel' => 'too_many_at_2+'];
    }
    if (strlen($input) > 200) {
        return ['sentinel' => 'input_too_long'];
    }
    // 过滤危险字符，再折叠连续 '.'
    $input = preg_replace('/[<>"\';=&|\\?`{}()\[\]%*\/\s]/', '', $input);
    $input = preg_replace('/\.{2,}/', '.', $input);
    return ['s' => $input];
}

/** 单侧转 ASCII（对齐 C kc_puny_side）。 */
function kc_side_ascii($s)
{
    if ($s === '') {
        return '';
    }
    $r = @idn_to_ascii($s, INTL_IDNA_VARIANT_UTS46);
    return $r === false ? '' : (string)$r;
}

/** 单侧转 UTF-8（对齐 C kc_utf8_side）。 */
function kc_side_utf8($s)
{
    if ($s === '') {
        return '';
    }
    $r = @idn_to_utf8($s, INTL_IDNA_VARIANT_UTS46);
    return $r === false ? '' : (string)$r;
}

/**
 * UTF-8/IDN -> punycode（ASCII）。
 */
function kc_to_ascii($input = '')
{
    $p = kc_prepare_php($input);
    if (isset($p['sentinel'])) {
        return $p['sentinel'];
    }
    $s = $p['s'];

    $at = strpos($s, '@');
    if ($at > 0) {
        $user = substr($s, 0, $at);
        $user = kc_side_ascii($user);
        $domain = substr($s, $at + 1);
    } elseif ($at === 0) {
        // 输入是 @xxx.com，只取 xxx.com
        $domain = substr($s, 1);
        $user = '';
    } else {
        $domain = $s;
        $user = '';
    }

    if ($domain === '') {
        return $user;
    }
    $domain = kc_side_ascii($domain);
    return $at ? ($user ? $user . '@' . $domain : '@' . $domain) : $domain;
}

/**
 * punycode（ASCII/ACE）-> UTF-8/IDN。
 */
function kc_to_utf8($input = '')
{
    $p = kc_prepare_php($input);
    if (isset($p['sentinel'])) {
        return $p['sentinel'];
    }
    $s = $p['s'];

    $at = strpos($s, '@');
    if ($at > 0) {
        $user = substr($s, 0, $at);
        $user = kc_side_utf8($user);
        $domain = substr($s, $at + 1);
    } elseif ($at === 0) {
        $domain = substr($s, 1);
        $user = '';
    } else {
        $domain = $s;
        $user = '';
    }

    if ($domain === '') {
        return $user;
    }
    $domain = kc_side_utf8($domain);
    return $at ? ($user ? $user . '@' . $domain : '@' . $domain) : $domain;
}
