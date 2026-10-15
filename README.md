# idn_kc_convert_MariaDB

把邮箱地址或域名转成 punycode（ASCII）的 **MariaDB / MySQL 自定义函数（UDF）**，
与常见的 PHP `idn_kc_convert()` 语义**逐字节一致**。

它解决的是一个具体问题：邮局要支持 `中文@中文.中国` 这类 **IDN 邮箱**（本地名和域名都非 ASCII），
而 Postfix / Dovecot 的原生 `mysql:` 查表不会做 punycode 转换。传统做法是常驻一个 PHP
守护进程（socketmap）在 SQL 前转换地址——那是个单点。本 UDF 把转换下沉进数据库：

```sql
WHERE username = kc_punycode('%u')
```

Postfix、Dovecot 即可用原生 `mysql:` 表，**彻底去掉常驻进程**。

```sql
mysql> SELECT kc_punycode('中文@中文.中国');
+-----------------------------------+
| kc_punycode('中文@中文.中国')       |
+-----------------------------------+
| xn--fiq228c@xn--fiq228c.xn--fiqs8s |
+-----------------------------------+
```

## 构建

依赖：`libidn2`（必需）；编译 `.so` 另需 `libmariadb-dev`（Debian/Ubuntu：
`apt install libmariadb-dev`）。

```bash
make standalone    # 编译测试二进制 kc_punycode_test（只需 libidn2，不动数据库）
make udf           # 编译 kc_punycode.so（需 libmariadb-dev）
```

## 安装

```bash
cp kc_punycode.so $(mariadb_config --plugindir)
mysql -e "CREATE FUNCTION kc_punycode RETURNS STRING SONAME 'kc_punycode.so';"
```

`CREATE FUNCTION` 需要 root 权限，注册信息存于 `mysql.func` 表，MariaDB 重启后自动加载。
**注意：UDF 是运行在 mariadbd 进程内的 C 代码**——请自行审阅源码（单文件、约 300 行），
并确认插件目录权限；MariaDB 大版本升级后需用新版本头文件重新编译 `.so`。

## 使用

Postfix `mysql:` 映射（`/etc/postfix/mysql-virtual-mailbox-maps.cf`）：

```
query = SELECT 1 FROM mailbox WHERE local_part = kc_punycode('%u') AND domain = kc_punycode('%d') AND active = 1
```

Dovecot `auth-sql.conf.ext`：

```sql
password_query = SELECT username, password FROM mailbox WHERE username = kc_punycode('%u')
```

Dovecot 侧还需放行非 ASCII 用户名（`auth_username_chars = utf8`），Postfix 侧如需
UTF8 发件人则开 `smtputf8_enable = yes` 并补 `sender_canonical_maps`。

## 语义（与 PHP 参照实现完全一致）

按顺序：

1. `trim()`（PHP 默认字符集 `" \t\n\r\0\x0B"`）
2. 空输入 → 返回字符串 `no_input`
3. 输入含多于一个 `@` → 返回 `too_many_at_2+`
4. 输入超过 200 字节 → 返回 `input_too_long`
   （这三个哨兵值只是"查不到任何行"，与 PHP 原版行为一致——查表失败即拒信）
5. 过滤危险字符 `[<>"';=&|\?`{}()[]%*/\s]`，再把连续 `.` 折叠成一个
   （两个 preg_replace，**先过滤后折叠**）
6. 按**第一个** `@` 拆本地名/域名；前导 `@` 表示"只有域名"；尾随 `@`（域名为空）
   返回本地名部分
7. 本地名、域名**分别**做 `idn_to_ascii(..., UTS46)`；已 punycode / 纯 ASCII 输入
   原样返回（幂等）
8. `idn_to_ascii` 失败 → PHP 返回 `false`，字符串上下文中即 `''`

只实现 ASCII（punycode）方向；反向（`idn_to_utf8`）查表用不到，未实现。

### 与 PHP 生产版的唯一差异

PHP 原版在过滤后有一段 `mb_detect_encoding($s, ['UTF-8','GBK','ASCII'])` +
`mb_convert_encoding()` 的**编码猜测**，本 UDF **整段移除**，入参恒按 UTF-8 处理。原因：
Postfix/Dovecot 投递的地址只可能是 UTF-8（SMTPUTF8）或 ASCII，而该猜测实测有三类故障
（详见 `docs/robustness-report.md`）：把 4 字节 UTF-8（emoji）误判为 GBK 损坏字节、
把与 UTF-8 碰撞的 GBK 字节误判为 UTF-8 得到空结果、遇到未知编码直接抛未捕获的
`ValueError`。若你的上层确实可能提交 GBK，请在调用方先转 UTF-8。

## 验证

在 Debian 13 / PHP 8.4.25（intl）/ libidn2 2.3.8 上，以仓库内 PHP 参照实现
（`php_idn_kc_convert.php`）为基准：

| 测试 | 结果 |
|---|---|
| `compare_idn.php` A/B 对拍（38 例：合法地址/幂等/ß/emoji/哨兵值/非法域名/过滤顺序） | **38/38 逐字节一致** |
| `test/test_robustness.php`（边界硬断言 22 项 + 幂等 + 往返 + 模糊 200 例） | **22/22，0 抛出，0 警告外的问题** |
| `test/test_robustness.php` D 段对拍（28 例） | **28/28 零差异** |
| `test/test_gbk.php`（GBK/非法字节输入） | 全部 AGREE（均返回空、不崩溃） |
| `.so` UDF 接口分支 | 桩头文件 `-fsyntax-only` 通过（`-Wall -Wextra` 无警告） |

复现：

```bash
make standalone
php compare_idn.php
php test/test_robustness.php
php test/test_gbk.php
```

几个值得知道的设计决策（都有实测证据，见报告）：

- **必须用 `IDN2_TRANSITIONAL`**：PHP/ICU 的 transitional 处理把 `faß.de` 映射为
  `fass.de`，而非过渡处理会给 `xn--fa-hia.de`——用错标志会让所有含 ß 的邮箱查不到。
- **入口先做严格 UTF-8 校验**：libidn2 的解码器是宽松的，会把非法字节（如 GBK 的
  `d6 d0 b9 fa`）跳过坏字节后"解出"字符并生成假 ACE；ICU 则是严格失败。校验后两者一致。
- 测试二进制提供 `--hex <hex>` 模式：把输入按十六进制传入，避开 shell/argv 对原始
  字节的不稳定传递（在 PHP `shell_exec` 链路上实测观察到过 GBK 字节被破坏）。
  UDF 在 SQL 中由客户端库直接传字节，不经 shell，不受影响。

## 文件

```
kc_punycode.c            UDF 源码（单文件；#ifdef STANDALONE_TEST 内含测试 main）
Makefile                 standalone / udf / test / clean
php_idn_kc_convert.php   PHP 参照实现（语义基准，对拍用它）
compare_idn.php          A/B 对拍：C UDF vs PHP 参照
test/test_robustness.php 边界/幂等/往返/模糊 + 对拍
test/test_gbk.php        编码处理专项（GBK、非法字节、emoji）
docs/robustness-report.md 验证报告与设计决策
```

## License

MIT
