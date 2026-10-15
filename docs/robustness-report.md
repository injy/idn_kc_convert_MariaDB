# kc_idn 验证报告

验证时间：2026-10-15
验证对象：MariaDB UDF `kc_idn`（`kc_idn.c`，standalone 编译版，导出 `kc_to_ascii` 与
`kc_to_utf8` 两个函数）
基准：仓库内 PHP 参照实现 `php_idn_kc_convert.php`（= 邮局生产函数 `idn_kc_convert()`
去掉编码猜测分支后，拆为 `kc_to_ascii` / `kc_to_utf8` 两个显式方向函数的语义等价版）
环境：Debian 13.7 / gcc / libidn2 2.3.8 / PHP 8.4.25（intl、mbstring）

## 结论

**C UDF 与 PHP 参照实现在全部测试输入上逐字节一致**，且双方对恶意/畸形输入均不崩溃。
UDF 可安全替代 PHP 转换层用于 Postfix/Dovecot 原生 `mysql:` 查表。

| 测试 | 用例数 | 结果 |
|---|---|---|
| A/B 对拍（compare_idn.php：A 编码 41 / B 解码 22 / C 往返 41） | 104 | 104/104 PASS |
| 边界硬断言（A/B/C/F 段） | 22 | 22/22 PASS |
| PHP vs C 对拍（D 段） | 28 | 28/28，零差异 |
| 模糊测试（G 段） | 200 | 0 抛出 |
| GBK/编码专项（test_gbk.php） | 全部 | AGREE |
| `.so` UDF 分支编译 | — | 桩头 `-fsyntax-only -Wall -Wextra` 无警告 |

覆盖的输入类别：合法中文/混合地址、已 punycode 幂等（含大写 ACE）、大小写本地名、
ß/straße/罗马数字/凯尔文符号（transitional）、emoji（4 字节 UTF-8）、裸域名、
前导/尾随 `@`、空输入、多 `@`、超长输入（200/201 字节边界）、含空格/危险字符、
`a..b` 与 `a.<.>b`（过滤顺序）、非法域名标签、GBK 字节、随机字节。

## 关键设计决策（均有实测证据）

### 1. IDN2_TRANSITIONAL（对齐 PHP/ICU）

PHP 调用为 `idn_to_ascii($s, INTL_IDNA_VARIANT_UTS46)`，即 UTS46 **transitional** 处理：

```
faß.de     ref-call=fass.de       nontransitional=xn--fa-hia.de   *** 会分歧
straße.de  ref-call=strasse.de    nontransitional=xn--strae-oqa.de *** 会分歧
müller.de  ref-call=xn--mller-kva.de  （两种处理相同）
Ⅰ.de / K.de  ref-call=i.de / k.de   （罗马数字、凯尔文符号被 transitional 映射）
```

C 侧最初用 `IDN2_NONTRANSITIONAL`，实测 ß 类域名分歧后改为 `IDN2_TRANSITIONAL`。
用错标志的后果：所有含 ß 的邮箱在 `WHERE username=kc_punycode('%u')` 中查不到。

### 2. 入口严格 UTF-8 校验（对齐 ICU，纠正 libidn2 宽松解码）

libidn2 的 UTF-8 解码器是**宽松**的：遇到非法字节会跳过坏字节继续解。实测 GBK 字节
`d6 d0 b9 fa`（"中国"）会被解成 U+0409 并生成一个假 ACE 标签；ICU 的 `idn_to_ascii`
则是**严格失败**（返回 false → `''`）。

因此 `kc_puny_side()`（编码方向）与 `kc_utf8_side()`（解码方向）都先做严格
UTF-8 校验（拒绝过长编码、代理区、>U+10FFFF），非法输入直接按"转换失败"处理返回
`''`，与 PHP 完全一致。修复前用 `--hex` 直传 GBK 字节可复现分歧，修复后 GBK 输入
双方均返回 `''`（查不到 → 拒信，不崩溃、不损坏）。解码方向用 `idn2_to_unicode_8z8z`
（同样 `IDN2_TRANSITIONAL`），保证 `kc_to_utf8(kc_to_ascii(x)) == x`。

### 3. 过滤必须两遍且先剥离后折叠

PHP 原版是两个独立的 `preg_replace`：先删危险字符，再把连续 `.` 折叠成一个。
单遍同时做不等价：`a.<.>b` 必须得到 `a.b`（若在删除字符时重置"上一个字符是点"的状态，
会错误地得到 `a..b`）。C 侧 `kc_sanitise()` 严格按两遍实现。

### 4. 哨兵值与失败返回

PHP 的边界行为被逐一复刻：空输入 → `no_input`；多 `@` → `too_many_at_2+`；
>200 字节 → `input_too_long`；`idn_to_ascii` / `idn_to_utf8` 失败 → `false`
（字符串上下文为 `''`）。
这些值作为查表键都匹配不到任何行，与 PHP 版等效（拒信），但保持了行为一致，
便于两层并存期做 `postmap -q` 比对。

注意一个 PHP 细节：无 `@` 的裸域名转换失败时，PHP 返回的是**布尔 `false`** 而非 `''`；
测试脚本统一按字符串比对（socketmap/MySQL 消费的都是字符串上下文）。

### 5. 移除编码猜测（与 PHP 生产版的唯一有意偏差）

生产 PHP 版有一段：

```php
$encoding = mb_detect_encoding($input, ['UTF-8', 'GBK', 'ASCII'], true);
if ($encoding !== 'UTF-8') { $input = mb_convert_encoding($input, 'UTF-8', $encoding); }
```

实测三类故障：

1. **emoji 被误判为 GBK**：`mb_detect_encoding('🤡', [...], true)` 对部分 4 字节
   UTF-8 返回 CP936 → 破坏性转码 → 错误 punycode，且同一字符裸输入与 `@` 形式结果不同
   （函数非确定）。
2. **与 UTF-8 碰撞的 GBK 被误判为 UTF-8**：真实 GBK 字符（`聙`=c280、`聛`=c281、
   `聜`=c282、`聝`=c283 …）字节同时也是合法 2 字节 UTF-8，因候选列表 UTF-8 在前而
   误判 → 原样喂给 `idn_to_ascii` → 空结果（丢信）。
3. **仅删除 GBK 候选反而会崩**：真实 GBK 输入检测返回 false →
   `mb_convert_encoding($s, 'UTF-8', false)` 抛未捕获的 `ValueError`。

由于 Postfix/Dovecot 投递的地址恒为 UTF-8 或 ASCII，UDF 直接假定 UTF-8，三类故障
一并消除。在邮局生产库的全部 IDN 邮箱上端到端回放（Unicode 入参 → 转换 → 查库），
修正后全部命中库中存储的 punycode 行。

### 6. 解码方向（kc_to_utf8）用 toASCII→toUnicode 两步实现

`kc_to_utf8` 要逐字节对齐 PHP 的 `idn_to_utf8(..., UTS46)`。实测 libidn2 的
`idn2_to_unicode_8z8z` **只解码 ACE 标签、对未编码（非 ACE）输入原样返回**
（`faß.de`→`faß.de`、`K.de`→`K.de`），而 ICU 的 `idn_to_utf8` 会对**每个标签**做
完整 UTS46 映射（ß→ss、Ⅰ→i、大写→小写）。直接调 `idn2_to_unicode_8z8z` 会让解码
方向与 PHP 在 8 类非 punycode 输入上分歧。

修复：解码侧先 `idn2_to_ascii_8z`（应用 UTS46 映射）→ 再 `idn2_to_unicode_8z8z`
（解码 ACE）。这一步等价复刻 `idn_to_utf8` 对 ACE 与非 ACE 输入的行为，同时
保证 `kc_to_utf8(kc_to_ascii(x)) == x`。

注意一个边界：单个裸 ASCII 标签长度 > 63 字节（如 200 个 `x`）不是合法邮件组件、
也绝不会是库里存的用户名；libidn2 以 `IDN2_TOO_BIG` 拒绝，ICU 在 `idn_to_utf8` 中
放宽了该限制。该病态输入只在编码方向与健壮性套件覆盖（转换失败→`''`），解码方向
的对拍用例刻意排除它（详见 compare_idn.php 注释），避免无意义的等值断言。

## 测试链路的两个坑（已绕过，供复用者注意）

1. **PHP `shell_exec` → shell → argv 传原始字节不可靠**：实测 GBK 字节在该链路上会被
   破坏（同一输入得到 `no_input` 或假 ACE 等不稳定结果）。因此测试二进制提供
   `--hex <hexlified-input>` 模式，测试脚本一律以十六进制传参，保证字节精确。
   UDF 在 SQL 中由 MySQL 客户端库直接传字节，不经 shell，无此问题。
2. **空输入的 `--hex` 参数会消失**：`bin2hex('')` 为空串，shell 命令里 `--hex` 后面
   没有实参。测试脚本对 hex 参数加 `escapeshellarg()`，空输入显式传 `''`。

## 未覆盖 / 后续

- `.so` 仅在桩头文件下通过语法检查；真实 `libmariadb-dev` 编译与 `CREATE FUNCTION`
  注册需在目标数据库环境执行（属生产变更，另行授权后进行）。
- 输入含内嵌 NUL 字节时 C 侧会在 NUL 处截断（PHP 字符串二进制安全）。邮件地址
  不可能含 NUL（Postfix 拒绝），不影响使用。
- 反向函数 `kc_to_utf8`（punycode → UTF-8）已实现并与 PHP `idn_to_utf8` 对拍一致；
  用途是出库展示 / 回信路由（把库里存的 punycode 用户名还原成可读 IDN），
  以及保证 `kc_to_utf8(kc_to_ascii(x)) == x` 的往返一致性。
