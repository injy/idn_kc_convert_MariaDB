#!/usr/bin/php
<?php
/**
 * 转换域名或邮箱地址的IDN格式（语义参照实现 / reference implementation）
 *
 * 这是邮局生产函数 /etc/postfix/php/inc/php_idn_kc_convert.php 的副本，
 * 仅作一处修改：删除了 mb_detect_encoding()/mb_convert_encoding() 编码猜测
 * 分支（见下方 "与生产版的唯一差异"）。MariaDB UDF kc_punycode() 与本文件
 * 逐字节一致，compare_idn.php 即以本文件为基准做 A/B 对拍。
 *
 * @param string $input 输入字符串，可以是域名或邮箱地址
 * @param bool $is_utf 转换类型：true转换为ASCII(Punycode)，false转换为UTF-8
 * @return string 转换后的字符串，失败时返回错误信息
 *
 * 功能说明：
 * - 处理输入字符串：去除空格，检查长度，过滤特殊字符
 * - 支持邮箱地址格式(user@domain)和纯域名格式
 * - 使用PHP intl扩展进行IDN转换
 *
 * 返回值：
 * - 成功：转换后的字符串
 * - 失败：错误信息('no_input'/'too_many_at_2+'/'input_too_long')
 * - 首尾的@: 返回时会被删除
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
function idn_kc_convert($input = '', $is_utf = false)
{
    $input = trim($input);
    if ($input == '') {
        return 'no_input';
    }
    if (substr_count($input, '@') > 1) {
        return 'too_many_at_2+';
    }
    if (strlen($input) > 200) {
        return 'input_too_long';
    }

    // 过滤危险字符
    $input = preg_replace('/[<>"\';=&|\\?`{}()\[\]%*\/\s]/', '', $input);
    $input = preg_replace('/\.{2,}/', '.', $input);

    // 入参恒为 UTF-8 或 ASCII（Postfix/Dovecot 保证），不做编码猜测
    // （生产版此处为 mb_detect_encoding + mb_convert_encoding，已删除）

    $at = strpos($input, '@');
    if ($at > 0) {
        $user = substr($input, 0, $at);
        $user = $is_utf ? idn_to_ascii($user, INTL_IDNA_VARIANT_UTS46) : idn_to_utf8($user, INTL_IDNA_VARIANT_UTS46);
        $domain = substr($input, $at + 1);
    } elseif ($at === 0) {
        // 输入是 @xxx.com，只取 xxx.com
        $domain = substr($input, 1);
        $user = '';
    } else {
        $domain = $input;
        $user = '';
    }

    if ($domain == '') {
        return $user;
    }

    $domain = $is_utf ? idn_to_ascii($domain, INTL_IDNA_VARIANT_UTS46) : idn_to_utf8($domain, INTL_IDNA_VARIANT_UTS46);
    return $at ? ($user ? $user . '@' . $domain : '@' . $domain) : $domain;
}
