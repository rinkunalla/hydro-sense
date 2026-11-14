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
  DateTime? abnormalSince,
  double? lat = 16.04,
  bool registered = true,
}) => DeviceView(
  Device(
    id: id,
    nickname: nickname ?? 'Line $id',
    flowStatus: flowStatus,
    flowRate: flowRate,
    lat: lat,
    lng: lat == null ? null : 120.33,
    statusChangedAt: statusChangedAt,
    abnormalSince: abnormalSince,
  ),
  Health(
    id: id,
    online: online,
    lastSeen: registered
        ? (lastSeen ?? testNow.subtract(const Duration(seconds: 12)))
        : null,
    registeredAt: registered ? testNow.subtract(const Duration(days: 3)) : null,
    batteryPercent: battery,
    batteryFault: batteryFault,
    lowVoltageSleep: lowVoltageSleep,
    chargingStatus: 'Steady',
    rssi: -61,
    firmware: '1.0.0',
  ),
);
