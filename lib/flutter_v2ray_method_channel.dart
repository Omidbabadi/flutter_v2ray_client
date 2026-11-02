import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_v2ray_platform_interface.dart';
import 'model/v2ray_status.dart' show V2RayStatus;

/// An implementation of [FlutterV2rayPlatform] that uses method channels.
class MethodChannelFlutterV2ray extends FlutterV2rayPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_v2ray_client');

  /// The event channel used to receive status updates from the native platform.
  final eventChannel = const EventChannel('flutter_v2ray_client/status');

  StreamSubscription<dynamic>? _statusSubscription;

  @override
  Future<void> initializeV2Ray({
    required void Function(V2RayStatus status) onStatusChanged,
    required String notificationIconResourceType,
    required String notificationIconResourceName,
    required String providerBundleIdentifier,
    required String groupIdentifier,
  }) async {
    await _statusSubscription?.cancel();
    _statusSubscription = eventChannel
        .receiveBroadcastStream()
        .distinct()
        .cast<List<dynamic>>()
        .listen((event) {
      if (event.length >= 6) {
        onStatusChanged.call(V2RayStatus(
          duration: event[0].toString(),
          uploadSpeed: int.tryParse(event[1].toString()) ?? 0,
          downloadSpeed: int.tryParse(event[2].toString()) ?? 0,
          upload: int.tryParse(event[3].toString()) ?? 0,
          download: int.tryParse(event[4].toString()) ?? 0,
          state: event[5].toString(),
        ));
      }
    });
    await methodChannel.invokeMethod(
      'initializeV2Ray',
      {
        'notificationIconResourceType': notificationIconResourceType,
        'notificationIconResourceName': notificationIconResourceName,
        'providerBundleIdentifier': providerBundleIdentifier,
        'groupIdentifier': groupIdentifier,
      },
    );
  }

  @override
  Future<void> startV2Ray({
    required String remark,
    required String config,
    required String notificationDisconnectButtonName,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
  }) async {
    await methodChannel.invokeMethod('startV2Ray', {
      'remark': remark,
      'config': config,
      'blocked_apps': blockedApps,
      'bypass_subnets': bypassSubnets,
      'proxy_only': proxyOnly,
      'notificationDisconnectButtonName': notificationDisconnectButtonName,
    });
  }

  @override
  Future<void> stopV2Ray() async {
    await methodChannel.invokeMethod('stopV2Ray');
  }

  @override
  Future<int> getServerDelay({
    required String config,
    required String url,
  }) async {
    return await methodChannel.invokeMethod('getServerDelay', {
      'config': config,
      'url': url,
    });
  }

  @override
  Future<int> getConnectedServerDelay(String url) async {
    return await methodChannel
        .invokeMethod('getConnectedServerDelay', {'url': url});
  }

  @override
  Future<bool> requestPermission() async {
    return (await methodChannel.invokeMethod('requestPermission')) ?? false;
  }

  @override
  Future<String> getCoreVersion() async {
    return await methodChannel.invokeMethod('getCoreVersion');
  }

  @override
  Future<List<String>> getLogs() async {
    try {
      final result = await methodChannel.invokeMethod('getLogs');
      if (result is List) {
        return result.cast<String>();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  @override
  Future<bool> clearLogs() async {
    try {
      final result = await methodChannel.invokeMethod('clearLogs');
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
