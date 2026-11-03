import 'package:hydro_sense/data/models.dart';

final testNow = DateTime(2026, 11, 3, 15, 12);

DeviceView view(
  String id, {
  String? nickname,
  String? flowStatus = 'Normal Flow',
  double? flowRate = 8.0,
  bool online = true,
  DateTime? lastSeen,
  int? battery = 80,
  bool batteryFault = false,
  bool lowVoltageSleep = false,
  DateTime? statusChangedAt,
  DateTime? pausedUntil,
  double? lat = 16.04,
}) => DeviceView(
  Device(
    id: id,
    nickname: nickname ?? 'Line $id',
    flowStatus: flowStatus,
    flowRate: flowRate,
    lat: lat,
    lng: lat == null ? null : 120.33,
    statusChangedAt: statusChangedAt,
    pausedUntil: pausedUntil,
  ),
  Health(
    id: id,
    online: online,
    lastSeen: lastSeen ?? testNow.subtract(const Duration(seconds: 12)),
    batteryPercent: battery,
    batteryFault: batteryFault,
    lowVoltageSleep: lowVoltageSleep,
    chargingStatus: 'Steady',
    rssi: -61,
    firmware: '1.0.0',
  ),
);
