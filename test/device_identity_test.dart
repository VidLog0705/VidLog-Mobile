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
}
