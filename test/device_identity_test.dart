import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/device_identity.dart';

/// 本机身份（需求方 2026-09-22：本机名可改、电脑端用它区分机位）。
///
/// 这一份配置的特殊之处在于**它写坏一次的代价不是丢一条数据，是换一台设备** ——
/// 设备标识一变，电脑端就把这台手机认成一台新机位，历史录像的来源也跟着变了。
/// 所以这里测的重点是「**标识不随名字变**」和「**改名要落盘**」。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-identity-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String path() => '${temp.path}/device.json';

  test('第一次打开：生成标识，名字是默认的「未命名机位」', () async {
    final identity = await DeviceIdentity.load(path());

    expect(identity.deviceId, isNotEmpty);
    expect(identity.deviceName, defaultDeviceName);
    expect(identity.hostAddress, isEmpty);
    expect(File(path()).existsSync(), isTrue, reason: '必须当场落盘，不然下次又是一个新标识');
  });

  test('★ 重新打开：标识不变', () async {
    final first = await DeviceIdentity.load(path());
    final second = await DeviceIdentity.load(path());

    expect(second.deviceId, first.deviceId);
  });

  test('★ 改名不换标识 —— 标识写进每条录像的 sourceDeviceId', () async {
    final identity = await DeviceIdentity.load(path());
    final originalId = identity.deviceId;

    await identity.rename('3号打包台');
    final reloaded = await DeviceIdentity.load(path());

    expect(reloaded.deviceName, '3号打包台');
    expect(reloaded.deviceId, originalId);
  });

  test('名字改成空白 → 退回默认名，不能变成空', () async {
    final identity = await DeviceIdentity.load(path());

    await identity.rename('   ');
    expect(identity.deviceName, defaultDeviceName);

    await identity.rename(' 4号机 ');
    expect(identity.deviceName, '4号机', reason: '前后空白要修掉');
  });

  test('电脑端地址与名字一起落盘', () async {
    final identity = await DeviceIdentity.load(path());

    await identity.setHost(address: ' 192.168.1.10 ', name: ' 打包间电脑 ');
    final reloaded = await DeviceIdentity.load(path());

    expect(reloaded.hostAddress, '192.168.1.10');
    expect(reloaded.hostName, '打包间电脑');
  });

  // 这条记的是一个**会真丢东西**的分支：读不出 id 就只能重新生成，
  // 电脑端会把这台手机认成新机位。它不该发生（写走的是原子写），
  // 真发生了要能自己站起来，而不是卡在启动失败上。
  test('文件被写坏 → 重新生成一份，不抛异常（代价见文件头说明）', () async {
    File(path()).writeAsStringSync('{ 这不是 JSON');

    final identity = await DeviceIdentity.load(path());

    expect(identity.deviceId, isNotEmpty);
    expect(identity.deviceName, defaultDeviceName);
  });

  test('文件里是空对象 → 补齐默认值', () async {
    File(path()).writeAsStringSync(jsonEncode(<String, Object?>{}));

    final identity = await DeviceIdentity.load(path());

    expect(identity.deviceId, isNotEmpty);
    expect(identity.deviceName, defaultDeviceName);
  });

  // ══════════════════════════════════════════════════════════════════
  // 机位名的宽度上限（需求方 2026-09-23）
  //
  //   原话：「机位名只允许12个字符内，一个汉字两个字符，一个字母1个字符，
  //   可以12个字母或者6个汉字」。
  //
  // ⚠️ 这组的核心是**「字符」在这句话里指的是显示宽度，不是 `length`**。
  // 下面每一条都同时钉住「数得对」和「`length` 数是错的」——
  // 谁要是把实现改回 `text.length`，红的不会是一条，是一片。
  // ══════════════════════════════════════════════════════════════════

  group('机位名上限 12 格（汉字算 2）', () {
    test('★ 12 个字母正好用完，6 个汉字也一样', () {
      expect(deviceNameWidth('abcdefghijkl'), 12, reason: '12 个字母 = 12 格，正好');
      expect(deviceNameWidth('三号仓打包台'), 12, reason: '6 个汉字 = 12 格，正好');

      // 这一条是「为什么不能用 length」的证明：
      expect('三号仓打包台'.length, 6, reason: 'length 数出来是 6 —— 照它做上限就是把 12 格放宽成 12 个汉字');
    });

    test('多一格就超', () {
      expect(deviceNameWidth('abcdefghijklm'), 13);
      expect(deviceNameWidth('三号仓打包台东'), 14, reason: '7 个汉字');
    });

    test('混排按格数相加：3 个汉字 + 6 个字母 = 12', () {
      expect(deviceNameWidth('三号仓abcdef'), 12);
      expect(deviceNameWidth('三号仓abcdefg'), 13);
    });

    test('★ 截断：12 个字母留 12，13 个字母砍掉尾巴', () {
      expect(clampDeviceName('abcdefghijkl'), 'abcdefghijkl');
      expect(clampDeviceName('abcdefghijklm'), 'abcdefghijkl');
    });

    test('★ 截断：6 个汉字留住，第 7 个进不来', () {
      expect(clampDeviceName('三号仓打包台'), '三号仓打包台');
      expect(
        clampDeviceName('三号仓打包台东'),
        '三号仓打包台',
        reason: '第 7 个汉字只剩 0 格，整字砍掉（不是砍一半 —— 半个汉字不在数据里）',
      );
    });

    // 代理对：`substring` 砍在中间会留下一个孤零零的半字符，
    // 那种字符串既显示不出来、也已经不是原来那个字了。
    test('★ 截断不劈开 emoji（代理对只在字符边界上切）', () {
      final one = clampDeviceName('a📦📦📦📦📦📦'); // 1 + 6×2 = 13 → 砍一个

      expect(one, 'a📦📦📦📦📦');
      expect(one.runes.length, 6, reason: '5 个 emoji 各占一个 rune，没有被劈成两半');
      expect(deviceNameWidth(one), 11);
    });

    test('默认名本身不超上限 —— 改默认值的人得知道有这道闸', () {
      expect(
        deviceNameWidth(defaultDeviceName) <= maxDeviceNameWidth,
        isTrue,
        reason: '默认名要是超过 12 格，第一次打开 App 就已经违规了',
      );
    });

    test('★ rename 也截 —— 上限是字段的属性，不只是那个输入框的', () async {
      final identity = await DeviceIdentity.load(path());

      await identity.rename('三号仓打包台东');
      expect(identity.deviceName, '三号仓打包台');

      final reloaded = await DeviceIdentity.load(path());
      expect(reloaded.deviceName, '三号仓打包台', reason: '落盘的也得是截过的');
    });

    test('rename 先修空白再截 —— 前后空格不吃额度', () async {
      final identity = await DeviceIdentity.load(path());

      await identity.rename('   abcdefghijkl   ');
      expect(identity.deviceName, 'abcdefghijkl', reason: '空白修掉后正好 12 格，一个字都不该少');

      await identity.rename('   abcdefghijklm   ');
      expect(identity.deviceName, 'abcdefghijkl');
    });

    // 手改过 device.json / 旧版本存下的长名字 —— 不在这儿掐掉的话，
    // 它会一路带到电脑端的设备表里。
    test('device.json 里手塞一个超长名字 → 读出来就是截过的', () async {
      File(path()).writeAsStringSync(jsonEncode(<String, Object?>{
        'deviceId': 'dev-keep-me',
        'deviceName': '一二三四五六七八九十',
      }));

      final identity = await DeviceIdentity.load(path());

      expect(identity.deviceName, '一二三四五六');
      expect(identity.deviceId, 'dev-keep-me', reason: '只截名字，标识一个字都不许动');
    });
  });
}
