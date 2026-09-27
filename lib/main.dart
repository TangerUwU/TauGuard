// TauGuard 2.0 — помощник безопасности в горах Алматинской области.
// WIT Teens Hackathon, кейс «TauGuard: безопасность в горах».
//
// Что внутри (один файл):
//  • Маршруты рядом — OpenStreetMap Overpass API (без ключа), высоты — Open-Meteo Elevation.
//  • Погода в горах — Open-Meteo Forecast (без ключа): ветер, порывы, осадки, гроза,
//    нулевая изотерма. Последний прогноз кэшируется и доступен офлайн.
//  • Точка невозврата — правило Нейсмита + локальный расчёт заката (работает без сети).
//  • Разрешения: геолокация, контакты (выбор аварийного контакта), уведомления
//    (напоминание «пора разворачиваться»).
//  • SOS: звонок 112 (голос) и SMS личному контакту — строго раздельно.
//  • Офлайн-карточки первой помощи, профиль и последняя GPS-точка на устройстве.
//  • Демо-режим: тумблер в профиле или 3 тапа по логотипу.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as ln;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

// ═════════════════════════════════════════════════════════════
// Дизайн-токены: «ночь над хребтом». Контраст текста ≥ 4.5:1.
// ═════════════════════════════════════════════════════════════
const cBg = Color(0xFF0E1621);
const cSurface = Color(0xFF16212E);
const cSurfaceHi = Color(0xFF1F2D3D);
const cLine = Color(0xFF2A3B4F);
const cText = Color(0xFFEEF2F6);
const cMuted = Color(0xFF9FB0C3);
const cIce = Color(0xFF7DD3FC); // ледниковый голубой — основные действия
const cRed = Color(0xFFDC2626); // сигнальный красный — SOS
const cGreen = Color(0xFF34D399);
const cAmber = Color(0xFFFBBF24);
const cSun = Color(0xFFFCD34D);
const cInk = Color(0xFF0A1018); // тёмный текст на светлых плашках
const cErrText = Color(0xFFFCA5A5);

const almatyDefault = (lat: 43.2380, lon: 76.9450);

bool get isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await Notifier.init();
  final state = AppState(prefs)..load();
  unawaited(state.refreshPermissions());
  runApp(MountainSafeApp(state: state));
}

// ═════════════════════════════════════════════════════════════
// Утилиты
// ═════════════════════════════════════════════════════════════
typedef LL = ({double lat, double lon});

double _rad(double d) => d * math.pi / 180;
double _deg(double r) => r * 180 / math.pi;
double? _d(dynamic v) => v is num ? v.toDouble() : null;
int? _i(dynamic v) => v is num ? v.toInt() : null;
double? parseNum(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
String cleanPhone(String s) => s.replaceAll(RegExp(r'[^\d+]'), '');

double distKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

final _hm = DateFormat('HH:mm');
final _dm = DateFormat('dd.MM');
final _dmhm = DateFormat('dd.MM HH:mm');
const _weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
String dayName(DateTime d) => _weekdays[d.weekday - 1];

String fmtDur(Duration d) {
  final neg = d.isNegative;
  final a = d.abs();
  final h = a.inHours;
  final m = a.inMinutes % 60;
  final s = h > 0 ? '$h ч ${m.toString().padLeft(2, '0')} мин' : '$m мин';
  return neg ? '−$s' : s;
}

String fmtNum(double v, [int digits = 0]) => v.toStringAsFixed(digits);

// ═════════════════════════════════════════════════════════════
// Модели
// ═════════════════════════════════════════════════════════════
class GeoPoint {
  const GeoPoint({
    required this.lat,
    required this.lon,
    this.alt,
    this.accuracy,
    required this.time,
    required this.source,
  });

  final double lat;
  final double lon;
  final double? alt;
  final double? accuracy;
  final DateTime time;
  final String source;

  LL get ll => (lat: lat, lon: lon);
  String get latStr => '${lat.abs().toStringAsFixed(5)}° ${lat >= 0 ? 'N' : 'S'}';
  String get lonStr => '${lon.abs().toStringAsFixed(5)}° ${lon >= 0 ? 'E' : 'W'}';
  String get decimal => '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
  String get mapsUrl =>
      'https://maps.google.com/?q=${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
}

/// Маршрут, выбранный для расчёта (из OSM, демо или введённый вручную).
class RouteChoice {
  const RouteChoice({
    required this.name,
    required this.km,
    required this.gain,
    required this.start,
    this.top,
    this.topEle,
    this.startEle,
    this.source = 'Вручную',
  });

  final String name;
  final double km;
  final double gain;
  final LL start;
  final LL? top;
  final double? topEle;
  final double? startEle;
  final String source;

  Map<String, dynamic> toJson() => {
        'name': name,
        'km': km,
        'gain': gain,
        'sLat': start.lat,
        'sLon': start.lon,
        'tLat': top?.lat,
        'tLon': top?.lon,
        'tEle': topEle,
        'sEle': startEle,
        'src': source,
      };

  static RouteChoice? fromJson(Map<String, dynamic> j) {
    try {
      final tLat = _d(j['tLat']);
      final tLon = _d(j['tLon']);
      return RouteChoice(
        name: j['name'] as String,
        km: _d(j['km'])!,
        gain: _d(j['gain'])!,
        start: (lat: _d(j['sLat'])!, lon: _d(j['sLon'])!),
        top: tLat != null && tLon != null ? (lat: tLat, lon: tLon) : null,
        topEle: _d(j['tEle']),
        startEle: _d(j['sEle']),
        source: (j['src'] as String?) ?? 'Сохранённый',
      );
    } catch (_) {
      return null;
    }
  }
}

enum PermState { granted, notAsked, denied, unsupported }

enum Risk { green, yellow, red, unknown }

int sev(Risk r) => switch (r) {
      Risk.unknown => -1,
      Risk.green => 0,
      Risk.yellow => 1,
      Risk.red => 2,
    };

Risk worse(Risk a, Risk b) => sev(a) >= sev(b) ? a : b;

// ═════════════════════════════════════════════════════════════
// Погода: модели и анализ опасностей
// ═════════════════════════════════════════════════════════════
class HourWx {
  const HourWx({
    required this.time,
    this.temp,
    this.feels,
    this.precipProb,
    this.precip,
    this.code,
    this.gust,
    this.freezing,
  });
  final DateTime time;
  final double? temp, feels, precipProb, precip, gust, freezing;
  final int? code;
}

class DayWx {
  const DayWx({
    required this.date,
    this.code,
    this.tMax,
    this.tMin,
    this.precipProbMax,
    this.gustMax,
    this.uvMax,
    this.sunrise,
    this.sunset,
  });
  final DateTime date;
  final int? code;
  final double? tMax, tMin, precipProbMax, gustMax, uvMax;
  final DateTime? sunrise, sunset;
}

class WeatherData {
  WeatherData({
    required this.label,
    required this.lat,
    required this.lon,
    required this.fetchedAt,
    this.elevation,
    this.curTemp,
    this.curFeels,
    this.curWind,
    this.curGust,
    this.curPrecip,
    this.curCode,
    required this.hours,
    required this.days,
  });

  final String label;
  final double lat, lon;
  final DateTime fetchedAt;
  final double? elevation;
  final double? curTemp, curFeels, curWind, curGust, curPrecip;
  final int? curCode;
  final List<HourWx> hours;
  final List<DayWx> days;

  static WeatherData parse(
    Map<String, dynamic> j, {
    required String label,
    required double lat,
    required double lon,
    required DateTime fetchedAt,
  }) {
    List<dynamic> l(Map<String, dynamic>? m, String k) => (m?[k] as List?) ?? const [];
    DateTime? dt(dynamic v) => v is String ? DateTime.tryParse(v) : null;

    final cur = j['current'] as Map<String, dynamic>?;
    final h = j['hourly'] as Map<String, dynamic>?;
    final d = j['daily'] as Map<String, dynamic>?;

    final hTime = l(h, 'time');
    final hours = <HourWx>[];
    for (var i = 0; i < hTime.length; i++) {
      final t = dt(hTime[i]);
      if (t == null) continue;
      dynamic at(String k) {
        final list = l(h, k);
        return i < list.length ? list[i] : null;
      }

      hours.add(HourWx(
        time: t,
        temp: _d(at('temperature_2m')),
        feels: _d(at('apparent_temperature')),
        precipProb: _d(at('precipitation_probability')),
        precip: _d(at('precipitation')),
        code: _i(at('weather_code')),
        gust: _d(at('wind_gusts_10m')),
        freezing: _d(at('freezing_level_height')),
      ));
    }

    final dTime = l(d, 'time');
    final days = <DayWx>[];
    for (var i = 0; i < dTime.length; i++) {
      final t = dt(dTime[i]);
      if (t == null) continue;
      dynamic at(String k) {
        final list = l(d, k);
        return i < list.length ? list[i] : null;
      }

      days.add(DayWx(
        date: t,
        code: _i(at('weather_code')),
        tMax: _d(at('temperature_2m_max')),
        tMin: _d(at('temperature_2m_min')),
        precipProbMax: _d(at('precipitation_probability_max')),
        gustMax: _d(at('wind_gusts_10m_max')),
        uvMax: _d(at('uv_index_max')),
        sunrise: dt(at('sunrise')),
        sunset: dt(at('sunset')),
      ));
    }

    return WeatherData(
      label: label,
      lat: lat,
      lon: lon,
      fetchedAt: fetchedAt,
      elevation: _d(j['elevation']),
      curTemp: _d(cur?['temperature_2m']),
      curFeels: _d(cur?['apparent_temperature']),
      curWind: _d(cur?['wind_speed_10m']),
      curGust: _d(cur?['wind_gusts_10m']),
      curPrecip: _d(cur?['precipitation']),
      curCode: _i(cur?['weather_code']),
      hours: hours,
      days: days,
    );
  }

  bool get isStale => DateTime.now().difference(fetchedAt) > const Duration(hours: 3);
}

/// Описание и иконка по коду погоды WMO.
(String, IconData) wxInfo(int? code) {
  if (code == null) return ('Нет данных', Icons.help_outline);
  return switch (code) {
    0 => ('Ясно', Icons.wb_sunny),
    1 => ('Преимущественно ясно', Icons.wb_sunny_outlined),
    2 => ('Переменная облачность', Icons.cloud_queue),
    3 => ('Пасмурно', Icons.cloud),
    45 || 48 => ('Туман', Icons.foggy),
    51 || 53 || 55 => ('Морось', Icons.grain),
    56 || 57 => ('Ледяная морось', Icons.ac_unit),
    61 => ('Слабый дождь', Icons.umbrella),
    63 => ('Дождь', Icons.umbrella),
    65 => ('Сильный дождь', Icons.umbrella),
    66 || 67 => ('Ледяной дождь', Icons.ac_unit),
    71 => ('Слабый снег', Icons.ac_unit),
    73 => ('Снег', Icons.ac_unit),
    75 => ('Сильный снег', Icons.ac_unit),
    77 => ('Снежная крупа', Icons.ac_unit),
    80 || 81 => ('Ливень', Icons.umbrella),
    82 => ('Сильный ливень', Icons.umbrella),
    85 || 86 => ('Снегопад', Icons.ac_unit),
    95 => ('Гроза', Icons.thunderstorm),
    96 || 99 => ('Гроза с градом', Icons.thunderstorm),
    _ => ('Код $code', Icons.cloud),
  };
}

class WxFlag {
  const WxFlag(this.risk, this.icon, this.text);
  final Risk risk;
  final IconData icon;
  final String text;
}

/// Опасные явления в окне времени [from, to].
List<WxFlag> analyzeWeather(WeatherData w, DateTime from, DateTime to, {double? topEle}) {
  final hrs = w.hours
      .where((h) =>
          h.time.isAfter(from.subtract(const Duration(hours: 1))) &&
          h.time.isBefore(to.add(const Duration(minutes: 1))))
      .toList();
  if (hrs.isEmpty) return const [];

  double? maxOf(Iterable<double?> xs) {
    double? m;
    for (final x in xs) {
      if (x != null && (m == null || x > m)) m = x;
    }
    return m;
  }

  double? minOf(Iterable<double?> xs) {
    double? m;
    for (final x in xs) {
      if (x != null && (m == null || x < m)) m = x;
    }
    return m;
  }

  final gust = maxOf(hrs.map((h) => h.gust));
  final prob = maxOf(hrs.map((h) => h.precipProb));
  final feels = minOf(hrs.map((h) => h.feels));
  final freezing = minOf(hrs.map((h) => h.freezing));
  final codes = hrs.map((h) => h.code).whereType<int>().toList();

  final flags = <WxFlag>[];
  if (codes.any((c) => c >= 95)) {
    flags.add(const WxFlag(Risk.red, Icons.thunderstorm,
        'Гроза в прогнозе. Не выходите на гребни и вершины, спуститесь с открытых склонов.'));
  }
  if (gust != null && gust >= 20) {
    flags.add(WxFlag(Risk.red, Icons.air,
        'Порывы до ${fmtNum(gust)} м/с — на гребне может сбить с ног.'));
  } else if (gust != null && gust >= 12) {
    flags.add(WxFlag(Risk.yellow, Icons.air,
        'Порывы до ${fmtNum(gust)} м/с. Нужна ветрозащитная куртка.'));
  }
  if (prob != null && prob >= 60) {
    flags.add(WxFlag(Risk.yellow, Icons.umbrella,
        'Вероятность осадков до ${fmtNum(prob)}%. Тропа станет скользкой.'));
  }
  if (codes.any((c) => (c >= 71 && c <= 77) || c == 85 || c == 86)) {
    flags.add(const WxFlag(Risk.yellow, Icons.ac_unit, 'Возможен снег: следы и маркировка тропы пропадают.'));
  }
  if (codes.any((c) => c == 45 || c == 48)) {
    flags.add(const WxFlag(Risk.yellow, Icons.foggy, 'Туман: держитесь тропы, легко сбиться.'));
  }
  if (feels != null && feels <= -5) {
    flags.add(WxFlag(Risk.red, Icons.device_thermostat,
        'Ощущается как ${fmtNum(feels)}°C — высокий риск переохлаждения.'));
  } else if (feels != null && feels <= 3) {
    flags.add(WxFlag(Risk.yellow, Icons.device_thermostat,
        'Ощущается как ${fmtNum(feels)}°C. Возьмите тёплый слой и шапку.'));
  }
  if (freezing != null && topEle != null && freezing < topEle) {
    flags.add(WxFlag(Risk.yellow, Icons.landscape,
        'Нулевая изотерма ~${fmtNum(freezing)} м — ниже верхней точки (${fmtNum(topEle)} м). Возможен лёд.'));
  }
  if (flags.isEmpty) {
    flags.add(const WxFlag(Risk.green, Icons.check_circle_outline, 'Опасных явлений в прогнозе нет.'));
  }
  return flags;
}

// ═════════════════════════════════════════════════════════════
// Астрономия: локальный расчёт восхода и заката (алгоритм NOAA)
// ═════════════════════════════════════════════════════════════
class SunCalc {
  static double _norm(double v, double m) {
    final r = v % m;
    return r < 0 ? r + m : r;
  }

  static DateTime? _event(DateTime date, double lat, double lon, {required bool rising}) {
    final n = DateTime.utc(date.year, date.month, date.day)
            .difference(DateTime.utc(date.year, 1, 1))
            .inDays +
        1;
    final lngHour = lon / 15;
    final t = n + (((rising ? 6 : 18) - lngHour) / 24);
    final m = 0.9856 * t - 3.289;
    final l = _norm(m + 1.916 * math.sin(_rad(m)) + 0.020 * math.sin(_rad(2 * m)) + 282.634, 360);
    var ra = _norm(_deg(math.atan(0.91764 * math.tan(_rad(l)))), 360);
    final lQuad = (l / 90).floor() * 90;
    final raQuad = (ra / 90).floor() * 90;
    ra = (ra + (lQuad - raQuad)) / 15;
    final sinDec = 0.39782 * math.sin(_rad(l));
    final cosDec = math.cos(math.asin(sinDec));
    const zenith = 90.833;
    final cosH = (math.cos(_rad(zenith)) - sinDec * math.sin(_rad(lat))) /
        (cosDec * math.cos(_rad(lat)));
    if (cosH > 1 || cosH < -1) return null;
    var h = _deg(math.acos(cosH));
    if (rising) h = 360 - h;
    h /= 15;
    final localMean = h + ra - 0.06571 * t - 6.622;
    final ut = _norm(localMean - lngHour, 24);
    return DateTime.utc(date.year, date.month, date.day)
        .add(Duration(seconds: (ut * 3600).round()))
        .toLocal();
  }

  static DateTime? sunset(DateTime date, double lat, double lon) =>
      _event(date, lat, lon, rising: false);
  static DateTime? sunrise(DateTime date, double lat, double lon) =>
      _event(date, lat, lon, rising: true);
}

// ═════════════════════════════════════════════════════════════
// Правило Нейсмита и точка невозврата
// ═════════════════════════════════════════════════════════════
class HikePlan {
  HikePlan._({
    required this.tUp,
    required this.tBack,
    required this.total,
    required this.start,
    required this.turnaround,
    required this.finish,
    required this.sunset,
    required this.noReturn,
    required this.margin,
    required this.sunRisk,
    required this.wxFlags,
  });

  final Duration tUp, tBack, total;
  final DateTime start, turnaround, finish;
  final DateTime? sunset, noReturn;
  final Duration? margin;
  final Risk sunRisk;
  final List<WxFlag>? wxFlags; // null — прогноз не загружен или не для этого места

  Risk get risk {
    var r = sunRisk;
    for (final f in wxFlags ?? const <WxFlag>[]) {
      if (f.risk != Risk.green) r = worse(r, f.risk);
    }
    return r;
  }

  static Duration _h(double hours) => Duration(seconds: (hours * 3600).round());

  static HikePlan compute({
    required double km,
    required double gainM,
    required DateTime start,
    double? lat,
    double? lon,
    WeatherData? wx,
    double? topEle,
  }) {
    // T_туда = D/4 + H/600; T_возврат = T_туда × 1.5; T_итого = (T_туда + T_возврат) × 1.3
    final up = km / 4 + gainM / 600;
    final back = up * 1.5;
    final tUp = _h(up * 1.3);
    final tBack = _h(back * 1.3);
    final total = tUp + tBack;
    final finish = start.add(total);

    DateTime? sunset;
    if (lat != null && lon != null) sunset = SunCalc.sunset(start, lat, lon);

    DateTime? noReturn;
    Duration? margin;
    var risk = Risk.unknown;
    if (sunset != null) {
      noReturn = sunset.subtract(tBack);
      margin = sunset.difference(finish);
      if (margin.isNegative) {
        risk = Risk.red;
      } else if (margin < const Duration(hours: 2)) {
        risk = Risk.yellow;
      } else {
        risk = Risk.green;
      }
    }

    List<WxFlag>? flags;
    if (wx != null && lat != null && lon != null && distKm(wx.lat, wx.lon, lat, lon) < 30) {
      final f = analyzeWeather(wx, start, finish, topEle: topEle);
      if (f.isNotEmpty) flags = f;
    }

    return HikePlan._(
      tUp: tUp,
      tBack: tBack,
      total: total,
      start: start,
      turnaround: start.add(tUp),
      finish: finish,
      sunset: sunset,
      noReturn: noReturn,
      margin: margin,
      sunRisk: risk,
      wxFlags: flags,
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Сервисы: GPS, погода, OSM, уведомления, контакты
// ═════════════════════════════════════════════════════════════
class LocationResult {
  const LocationResult(this.point, this.message);
  final GeoPoint? point;
  final String? message;
}

Future<LocationResult> fetchLocation() async {
  try {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      return const LocationResult(
          null, 'Геолокация выключена. Включите её в настройках или введите координаты вручную.');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return const LocationResult(
          null, 'Нет разрешения на геолокацию. Выдайте его в «Профиле» или введите координаты вручную.');
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 25),
      ),
    );
    return LocationResult(
      GeoPoint(
        lat: p.latitude,
        lon: p.longitude,
        alt: kIsWeb ? null : p.altitude, // в браузере высота не измеряется
        accuracy: p.accuracy,
        time: DateTime.now(),
        source: 'GPS',
      ),
      null,
    );
  } catch (_) {
    if (!kIsWeb) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          return LocationResult(
            GeoPoint(
              lat: last.latitude,
              lon: last.longitude,
              alt: last.altitude,
              accuracy: last.accuracy,
              time: last.timestamp,
              source: 'Последняя известная',
            ),
            'Свежий GPS-фикс не получен. Показана последняя известная точка устройства.',
          );
        }
      } catch (_) {}
    }
    return const LocationResult(
        null, 'GPS не ответил. Выйдите на открытое место или введите координаты вручную.');
  }
}

class WeatherApi {
  static Future<Map<String, dynamic>> forecast(double lat, double lon) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'current':
          'temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_gusts_10m,precipitation',
      'hourly':
          'temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_gusts_10m,freezing_level_height',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_gusts_10m_max,sunrise,sunset,uv_index_max',
      'wind_speed_unit': 'ms',
      'timezone': 'auto',
      'forecast_days': '3',
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Open-Meteo: HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Высоты точек по цифровой модели рельефа (до 100 точек за запрос).
  static Future<List<double?>> elevations(List<LL> pts) async {
    if (pts.isEmpty) return const [];
    final uri = Uri.https('api.open-meteo.com', '/v1/elevation', {
      'latitude': pts.map((p) => p.lat.toStringAsFixed(5)).join(','),
      'longitude': pts.map((p) => p.lon.toStringAsFixed(5)).join(','),
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Elevation: HTTP ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ((j['elevation'] as List?) ?? const []).map(_d).toList();
  }
}

class OsmRoute {
  OsmRoute({required this.id, required this.tags, this.center, this.distFromMe});
  final int id;
  final Map<String, String> tags;
  final LL? center;
  final double? distFromMe;

  String get name =>
      tags['name:ru'] ?? tags['name'] ?? tags['name:en'] ?? tags['name:kk'] ?? 'Маршрут без названия';
  bool get hasName => tags.containsKey('name') || tags.containsKey('name:ru');
  double? get distanceTag => parseNum((tags['distance'] ?? '').replaceAll(RegExp(r'[^\d.,]'), ''));
  double? get ascentTag => parseNum((tags['ascent'] ?? '').replaceAll(RegExp(r'[^\d.,]'), ''));
  String? get fromTo {
    final f = tags['from'];
    final t = tags['to'];
    if (f == null && t == null) return null;
    return '${f ?? '…'} → ${t ?? '…'}';
  }

  static OsmRoute? fromElement(Map<String, dynamic> e, LL me) {
    final id = _i(e['id']);
    if (id == null) return null;
    final rawTags = (e['tags'] as Map?) ?? const {};
    final tags = rawTags.map((k, v) => MapEntry(k.toString(), v.toString()));
    final c = e['center'] as Map?;
    LL? center;
    double? dist;
    if (c != null && _d(c['lat']) != null && _d(c['lon']) != null) {
      center = (lat: _d(c['lat'])!, lon: _d(c['lon'])!);
      dist = distKm(me.lat, me.lon, center.lat, center.lon);
    }
    return OsmRoute(id: id, tags: tags, center: center, distFromMe: dist);
  }
}

class RouteAnalysis {
  const RouteAnalysis({
    required this.ways,
    required this.lengthKm,
    this.low,
    this.high,
    this.minEle,
    this.maxEle,
  });
  final List<List<LL>> ways;
  final double lengthKm;
  final LL? low, high;
  final double? minEle, maxEle;
  double? get gain => (minEle != null && maxEle != null) ? maxEle! - minEle! : null;
}

class OverpassApi {
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static Future<Map<String, dynamic>> _query(String q) async {
    Object? lastErr;
    for (final e in _endpoints) {
      try {
        final r = await http
            .post(
              Uri.parse(e),
              headers: kIsWeb ? null : {'User-Agent': 'MountainSafe/2.0 (WIT Teens Hackathon)'},
              body: {'data': q},
            )
            .timeout(const Duration(seconds: 35));
        if (r.statusCode == 200) {
          return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        }
        lastErr = 'HTTP ${r.statusCode}';
      } catch (err) {
        lastErr = err;
      }
    }
    throw Exception('OpenStreetMap недоступен ($lastErr)');
  }

  /// Сырые элементы OSM (для кэша) — пешеходные маршруты в радиусе.
  static Future<List<dynamic>> nearbyRaw(LL me, int radiusM) async {
    final q = '[out:json][timeout:30];'
        '(relation["route"="hiking"](around:$radiusM,${me.lat},${me.lon});'
        'relation["route"="foot"](around:$radiusM,${me.lat},${me.lon}););'
        'out tags center;';
    final j = await _query(q);
    return (j['elements'] as List?) ?? const [];
  }

  static List<OsmRoute> parseRoutes(List<dynamic> raw, LL me) {
    final list = <OsmRoute>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        final r = OsmRoute.fromElement(e, me);
        if (r != null) list.add(r);
      }
    }
    list.sort((a, b) {
      if (a.hasName != b.hasName) return a.hasName ? -1 : 1;
      return (a.distFromMe ?? 1e9).compareTo(b.distFromMe ?? 1e9);
    });
    return list.take(80).toList();
  }

  static Future<RouteAnalysis> analyze(int relationId) async {
    final j = await _query('[out:json][timeout:30];relation($relationId);out geom;');
    final els = (j['elements'] as List?) ?? const [];
    final ways = <List<LL>>[];
    for (final el in els) {
      final members = (el is Map ? el['members'] as List? : null) ?? const [];
      for (final m in members) {
        if (m is! Map || m['type'] != 'way') continue;
        final g = m['geometry'] as List?;
        if (g == null) continue;
        final pts = <LL>[];
        for (final p in g) {
          if (p is Map && _d(p['lat']) != null && _d(p['lon']) != null) {
            pts.add((lat: _d(p['lat'])!, lon: _d(p['lon'])!));
          }
        }
        if (pts.length >= 2) ways.add(pts);
      }
    }
    if (ways.isEmpty) throw Exception('У этого маршрута в OSM нет линии трека.');

    var len = 0.0;
    for (final w in ways) {
      for (var i = 1; i < w.length; i++) {
        len += distKm(w[i - 1].lat, w[i - 1].lon, w[i].lat, w[i].lon);
      }
    }

    final all = [for (final w in ways) ...w];
    final step = math.max(1, (all.length / 100).ceil());
    final samples = <LL>[for (var i = 0; i < all.length; i += step) all[i]].take(100).toList();

    List<double?> ele = const [];
    try {
      ele = await WeatherApi.elevations(samples);
    } catch (_) {}

    LL? low, high;
    double? minE, maxE;
    for (var i = 0; i < ele.length && i < samples.length; i++) {
      final e = ele[i];
      if (e == null) continue;
      if (minE == null || e < minE) {
        minE = e;
        low = samples[i];
      }
      if (maxE == null || e > maxE) {
        maxE = e;
        high = samples[i];
      }
    }
    return RouteAnalysis(ways: ways, lengthKm: len, low: low, high: high, minEle: minE, maxEle: maxE);
  }
}

class Notifier {
  static final _plugin = ln.FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static bool get supported => isMobile;

  static const _details = ln.NotificationDetails(
    android: ln.AndroidNotificationDetails(
      'turnaround',
      'Разворот и закат',
      channelDescription: 'Напоминания о точке невозврата на маршруте',
      importance: ln.Importance.max,
      priority: ln.Priority.high,
    ),
    iOS: ln.DarwinNotificationDetails(presentAlert: true, presentSound: true),
  );

  static Future<void> init() async {
    if (!supported) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(const ln.InitializationSettings(
        android: ln.AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: ln.DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ));
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  static Future<bool> request() async {
    if (!_ready) return false;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final a = _plugin.resolvePlatformSpecificImplementation<
            ln.AndroidFlutterLocalNotificationsPlugin>();
        return await a?.requestNotificationsPermission() ?? false;
      }
      final i =
          _plugin.resolvePlatformSpecificImplementation<ln.IOSFlutterLocalNotificationsPlugin>();
      return await i?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// null — система не сообщает статус (iOS до первого запроса).
  static Future<bool?> enabled() async {
    if (!_ready) return null;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final a = _plugin.resolvePlatformSpecificImplementation<
            ln.AndroidFlutterLocalNotificationsPlugin>();
        return await a?.areNotificationsEnabled();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _schedule(int id, String title, String body, DateTime when) =>
      _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(when, tz.UTC),
        _details,
        androidScheduleMode: ln.AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            ln.UILocalNotificationDateInterpretation.absoluteTime,
      );

  /// Ставит два напоминания: за 30 минут до точки невозврата и в момент разворота.
  static Future<List<DateTime>> scheduleTurnaround(DateTime noReturn, String route) async {
    if (!_ready) return const [];
    await cancelTurnaround();
    final now = DateTime.now();
    final out = <DateTime>[];
    final name = route.isEmpty ? 'маршруте' : 'маршруте «$route»';
    final warn = noReturn.subtract(const Duration(minutes: 30));
    if (warn.isAfter(now)) {
      await _schedule(101, 'Через 30 минут — разворот',
          'На $name разворачивайтесь не позже ${_hm.format(noReturn)}, чтобы спуститься до темноты.', warn);
      out.add(warn);
    }
    if (noReturn.isAfter(now)) {
      await _schedule(102, 'Пора разворачиваться',
          'Точка невозврата на $name. Дальше — спуск в темноте.', noReturn);
      out.add(noReturn);
    }
    return out;
  }

  static Future<void> cancelTurnaround() async {
    if (!_ready) return;
    await _plugin.cancel(101);
    await _plugin.cancel(102);
  }

  static Future<void> test() async {
    if (!_ready) return;
    await _plugin.show(1, 'TauGuard', 'Уведомления работают — напоминание о развороте придёт вовремя.', _details);
  }
}

class ContactsService {
  static bool get supported => isMobile;

  static Future<bool> request() async {
    if (!supported) return false;
    try {
      return await fc.FlutterContacts.requestPermission(readonly: true);
    } catch (_) {
      return false;
    }
  }

  static Future<List<(String, String)>> phones() async {
    final list = await fc.FlutterContacts.getContacts(withProperties: true);
    final out = <(String, String)>[];
    for (final c in list) {
      for (final p in c.phones) {
        if (p.number.trim().isNotEmpty) out.add((c.displayName, p.number));
      }
    }
    out.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    return out;
  }
}

// ═════════════════════════════════════════════════════════════
// Состояние приложения
// ═════════════════════════════════════════════════════════════
class AppState extends ChangeNotifier {
  AppState(this.prefs);
  final SharedPreferences prefs;

  String name = '';
  String contactPhone = '';
  String contactLabel = '';
  bool demoMode = false;
  bool onboarded = false;
  GeoPoint? lastPoint;
  RouteChoice? route;
  WeatherData? weather;
  bool wxLoading = false;
  String? wxError;
  List<DateTime> reminders = [];

  PermState permLocation = PermState.notAsked;
  PermState permContacts = PermState.notAsked;
  PermState permNotif = PermState.notAsked;

  static const demoName = 'Турист (демо)';
  static const demoPhone = '+77771234567';
  static const demoPhoneDisplay = '+7 777 123 45 67';
  static const demoLabel = 'Мама / Координатор';
  static final demoPoint = GeoPoint(lat: 43.2257, lon: 76.9089, time: DateTime.now(), source: 'Демо');
  static const demoRoute = RouteChoice(
    name: 'Кок-Жайлау',
    km: 5.5,
    gain: 350,
    start: (lat: 43.2257, lon: 76.9089),
    source: 'Демо',
  );

  String get effName => demoMode ? demoName : name;
  String get effPhone => demoMode ? demoPhone : contactPhone;
  String get effPhoneDisplay => demoMode ? demoPhoneDisplay : contactPhone;
  String get effLabel => demoMode ? demoLabel : contactLabel;
  GeoPoint? get effPoint => demoMode ? demoPoint : lastPoint;

  void load() {
    name = prefs.getString('name') ?? '';
    contactPhone = prefs.getString('contactPhone') ?? '';
    contactLabel = prefs.getString('contactLabel') ?? '';
    demoMode = prefs.getBool('demoMode') ?? false;
    onboarded = prefs.getBool('onboarded') ?? false;

    final lat = prefs.getDouble('lp_lat');
    final lon = prefs.getDouble('lp_lon');
    if (lat != null && lon != null) {
      lastPoint = GeoPoint(
        lat: lat,
        lon: lon,
        alt: prefs.getDouble('lp_alt'),
        accuracy: prefs.getDouble('lp_acc'),
        time: DateTime.fromMillisecondsSinceEpoch(prefs.getInt('lp_time') ?? 0),
        source: prefs.getString('lp_src') ?? 'Сохранённая',
      );
    }

    final r = prefs.getString('route');
    if (r != null) {
      try {
        route = RouteChoice.fromJson(jsonDecode(r) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (demoMode && route == null) route = demoRoute;

    final wx = prefs.getString('wx_cache');
    if (wx != null) {
      try {
        final j = jsonDecode(wx) as Map<String, dynamic>;
        weather = WeatherData.parse(
          j['data'] as Map<String, dynamic>,
          label: j['label'] as String? ?? 'Сохранённый прогноз',
          lat: _d(j['lat']) ?? 0,
          lon: _d(j['lon']) ?? 0,
          fetchedAt: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime(2000),
        );
      } catch (_) {}
    }

    reminders = (prefs.getStringList('reminders') ?? const [])
        .map(DateTime.tryParse)
        .whereType<DateTime>()
        .where((t) => t.isAfter(DateTime.now()))
        .toList();
  }

  Future<void> finishOnboarding() async {
    onboarded = true;
    await prefs.setBool('onboarded', true);
    notifyListeners();
  }

  Future<void> saveProfile(String n, String phone, String label) async {
    name = n.trim();
    contactPhone = phone.trim();
    contactLabel = label.trim();
    await prefs.setString('name', name);
    await prefs.setString('contactPhone', contactPhone);
    await prefs.setString('contactLabel', contactLabel);
    notifyListeners();
  }

  Future<void> setDemo(bool v) async {
    demoMode = v;
    await prefs.setBool('demoMode', v);
    await setRoute(v ? demoRoute : null);
  }

  Future<void> setRoute(RouteChoice? r) async {
    route = r;
    if (r == null) {
      await prefs.remove('route');
    } else {
      await prefs.setString('route', jsonEncode(r.toJson()));
    }
    notifyListeners();
  }

  Future<void> savePoint(GeoPoint p) async {
    lastPoint = p;
    await prefs.setDouble('lp_lat', p.lat);
    await prefs.setDouble('lp_lon', p.lon);
    p.alt != null ? await prefs.setDouble('lp_alt', p.alt!) : await prefs.remove('lp_alt');
    p.accuracy != null ? await prefs.setDouble('lp_acc', p.accuracy!) : await prefs.remove('lp_acc');
    await prefs.setInt('lp_time', p.time.millisecondsSinceEpoch);
    await prefs.setString('lp_src', p.source);
    notifyListeners();
  }

  Future<void> clearPoint() async {
    lastPoint = null;
    for (final k in ['lp_lat', 'lp_lon', 'lp_alt', 'lp_acc', 'lp_time', 'lp_src']) {
      await prefs.remove(k);
    }
    notifyListeners();
  }

  Future<void> fetchWeather(double lat, double lon, String label) async {
    wxLoading = true;
    wxError = null;
    notifyListeners();
    try {
      final j = await WeatherApi.forecast(lat, lon);
      final now = DateTime.now();
      weather = WeatherData.parse(j, label: label, lat: lat, lon: lon, fetchedAt: now);
      await prefs.setString(
        'wx_cache',
        jsonEncode({'label': label, 'lat': lat, 'lon': lon, 'at': now.toIso8601String(), 'data': j}),
      );
    } catch (_) {
      wxError = weather != null
          ? 'Нет связи с сервером погоды. Показан последний сохранённый прогноз.'
          : 'Нет связи с сервером погоды. Подключитесь к сети и нажмите «Обновить».';
    }
    wxLoading = false;
    notifyListeners();
  }

  Future<void> saveReminders(List<DateTime> list) async {
    reminders = list;
    await prefs.setStringList('reminders', list.map((e) => e.toIso8601String()).toList());
    notifyListeners();
  }

  // ── Разрешения ──
  Future<void> refreshPermissions() async {
    try {
      final p = await Geolocator.checkPermission();
      permLocation = switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => PermState.granted,
        LocationPermission.deniedForever => PermState.denied,
        _ => PermState.notAsked,
      };
    } catch (_) {
      permLocation = PermState.notAsked;
    }

    if (!ContactsService.supported) {
      permContacts = PermState.unsupported;
    } else {
      final v = prefs.getBool('perm_contacts');
      permContacts = v == null ? PermState.notAsked : (v ? PermState.granted : PermState.denied);
    }

    if (!Notifier.supported) {
      permNotif = PermState.unsupported;
    } else {
      final sys = await Notifier.enabled();
      final v = sys ?? prefs.getBool('perm_notif');
      permNotif = v == null ? PermState.notAsked : (v ? PermState.granted : PermState.denied);
    }
    notifyListeners();
  }

  Future<void> requestLocation() async {
    try {
      final p = await Geolocator.checkPermission();
      if (p == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
      } else {
        await Geolocator.requestPermission();
      }
    } catch (_) {}
    await refreshPermissions();
  }

  Future<void> requestContacts() async {
    if (!ContactsService.supported) return;
    if (permContacts == PermState.denied) {
      try {
        await Geolocator.openAppSettings(); // открывает настройки приложения
      } catch (_) {}
    }
    final ok = await ContactsService.request();
    await prefs.setBool('perm_contacts', ok);
    await refreshPermissions();
  }

  Future<void> requestNotifications() async {
    if (!Notifier.supported) return;
    if (permNotif == PermState.denied) {
      try {
        await Geolocator.openAppSettings();
      } catch (_) {}
    }
    final ok = await Notifier.request();
    await prefs.setBool('perm_notif', ok);
    await refreshPermissions();
  }
}

// ═════════════════════════════════════════════════════════════
// Приложение и оболочка
// ═════════════════════════════════════════════════════════════
class MountainSafeApp extends StatelessWidget {
  const MountainSafeApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: cIce, brightness: Brightness.dark).copyWith(
      primary: cIce,
      onPrimary: cInk,
      secondary: cAmber,
      onSecondary: cInk,
      error: cRed,
      onError: Colors.white,
      surface: cSurface,
      onSurface: cText,
      outline: cLine,
    );
    return MaterialApp(
      title: 'TauGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: cBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: cBg,
          foregroundColor: cText,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: cBg,
          labelStyle: const TextStyle(color: cMuted, fontSize: 16),
          floatingLabelStyle: const TextStyle(color: cIce),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: cLine),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 56),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 52),
            foregroundColor: cText,
            side: const BorderSide(color: cLine, width: 1.5),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: cIce,
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: cSurfaceHi,
          contentTextStyle: TextStyle(color: cText, fontSize: 15),
        ),
      ),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) =>
            state.onboarded ? HomeShell(state: state) : OnboardingPage(state: state),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});
  final AppState state;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  int _taps = 0;
  Timer? _tapTimer;

  AppState get s => widget.state;

  void _onLogoTap() {
    _taps++;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 900), () => _taps = 0);
    if (_taps >= 3) {
      _taps = 0;
      final next = !s.demoMode;
      s.setDemo(next);
      snack(context, next ? 'Демо-режим включён' : 'Демо-режим выключен');
    }
  }

  void _openSos() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SosPage(state: s)));
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    super.dispose();
  }

  Widget _nav(int i, IconData icon, IconData iconSel, String label) {
    final sel = _tab == i;
    return Expanded(
      child: Semantics(
        selected: sel,
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _tab = i),
          child: SizedBox(
            height: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: sel ? cSurfaceHi : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(sel ? iconSel : icon, color: sel ? cIce : cMuted, size: 26),
                ),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                      color: sel ? cText : cMuted,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onLogoTap,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RidgeMark(size: 30),
                    SizedBox(width: 10),
                    Text('TauGuard',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -0.3)),
                  ],
                ),
              ),
            ),
            bottom: s.demoMode
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(30),
                    child: Container(
                      height: 30,
                      width: double.infinity,
                      color: cAmber,
                      alignment: Alignment.center,
                      child: const Text('DEMO MODE — данные демонстрационные',
                          style: TextStyle(color: cInk, fontWeight: FontWeight.w800, fontSize: 14)),
                    ),
                  )
                : null,
          ),
          body: IndexedStack(
            index: _tab,
            children: [
              RouteTab(key: ValueKey('route-${s.demoMode}'), state: s),
              WeatherTab(state: s),
              const FirstAidTab(),
              ProfileTab(state: s),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
          floatingActionButton: Semantics(
            label: 'SOS: экстренная помощь',
            button: true,
            child: SizedBox(
              width: 76,
              height: 76,
              child: FloatingActionButton(
                heroTag: 'sos',
                onPressed: _openSos,
                backgroundColor: cRed,
                foregroundColor: Colors.white,
                elevation: 3,
                shape: const CircleBorder(side: BorderSide(color: cBg, width: 4)),
                child: const Icon(Icons.sos, size: 40),
              ),
            ),
          ),
          bottomNavigationBar: BottomAppBar(
            color: cSurface,
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            shape: const CircularNotchedRectangle(),
            notchMargin: 6,
            child: Row(
              children: [
                _nav(0, Icons.hiking_outlined, Icons.hiking, 'Маршрут'),
                _nav(1, Icons.cloud_outlined, Icons.cloud, 'Погода'),
                const SizedBox(width: 84),
                _nav(2, Icons.medical_services_outlined, Icons.medical_services, 'Помощь'),
                _nav(3, Icons.person_outline, Icons.person, 'Профиль'),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Общие виджеты
// ═════════════════════════════════════════════════════════════

/// Логотип: силуэт хребта.
class RidgeMark extends StatelessWidget {
  const RidgeMark({super.key, this.size = 28});
  final double size;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size * 0.8), painter: _RidgeMarkPainter());
}

class _RidgeMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final back = Path()
      ..moveTo(0, s.height)
      ..lineTo(s.width * 0.38, s.height * 0.12)
      ..lineTo(s.width * 0.62, s.height * 0.55)
      ..lineTo(s.width * 0.76, s.height * 0.35)
      ..lineTo(s.width, s.height)
      ..close();
    canvas.drawPath(back, Paint()..color = cIce);
    final snow = Path()
      ..moveTo(s.width * 0.27, s.height * 0.36)
      ..lineTo(s.width * 0.38, s.height * 0.12)
      ..lineTo(s.width * 0.49, s.height * 0.32)
      ..lineTo(s.width * 0.42, s.height * 0.28)
      ..lineTo(s.width * 0.36, s.height * 0.38)
      ..close();
    canvas.drawPath(snow, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: color ?? cSurface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cLine),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      );
}

class H1 extends StatelessWidget {
  const H1(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 26, fontWeight: FontWeight.w900, color: cText, height: 1.15, letterSpacing: -0.4)),
      );
}

class H2 extends StatelessWidget {
  const H2(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: cText)),
      );
}

class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: cMuted)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: cMuted, fontSize: 14.5, height: 1.4))),
          ],
        ),
      );
}

class KV extends StatelessWidget {
  const KV(this.k, this.v, {super.key, this.strong = false, this.color});
  final String k;
  final String v;
  final bool strong;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(k, style: const TextStyle(color: cMuted, fontSize: 16))),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                v,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: color ?? cText,
                  fontSize: strong ? 20 : 17,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.icon, this.color = cSurfaceHi, this.fg = cText});
  final String text;
  final IconData? icon;
  final Color color;
  final Color fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
          Text(text, style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
      );
}

Widget busyIcon(bool busy, IconData icon) => busy
    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
    : Icon(icon);

void snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

Future<GeoPoint?> manualCoordsDialog(BuildContext context, GeoPoint? initial) {
  final latC = TextEditingController(text: initial?.lat.toStringAsFixed(5) ?? '');
  final lonC = TextEditingController(text: initial?.lon.toStringAsFixed(5) ?? '');
  final altC = TextEditingController(text: initial?.alt?.round().toString() ?? '');
  String? error;
  return showDialog<GeoPoint>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        backgroundColor: cSurface,
        title: const Text('Координаты вручную'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: latC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Широта, например 43.12345'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: lonC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(labelText: 'Долгота, например 76.95000'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: altC,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Высота, м (необязательно)'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: const TextStyle(color: cErrText)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final lat = parseNum(latC.text);
              final lon = parseNum(lonC.text);
              if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
                setD(() => error = 'Широта от −90 до 90, долгота от −180 до 180.');
                return;
              }
              Navigator.pop(
                ctx,
                GeoPoint(lat: lat, lon: lon, alt: parseNum(altC.text), time: DateTime.now(), source: 'Вручную'),
              );
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ),
  );
}

// ═════════════════════════════════════════════════════════════
// Разрешения (онбординг и профиль)
// ═════════════════════════════════════════════════════════════
class PermissionTile extends StatelessWidget {
  const PermissionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.why,
    required this.state,
    required this.onRequest,
  });
  final IconData icon;
  final String title;
  final String why;
  final PermState state;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color, IconData sIcon) = switch (state) {
      PermState.granted => ('Разрешено', cGreen, Icons.check_circle),
      PermState.notAsked => ('Не выдано', cAmber, Icons.radio_button_unchecked),
      PermState.denied => ('Запрещено', cErrText, Icons.block),
      PermState.unsupported => ('Недоступно в этой версии', cMuted, Icons.remove_circle_outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: cSurfaceHi, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: cIce, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(why, style: const TextStyle(color: cMuted, fontSize: 14.5, height: 1.35)),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(sIcon, size: 18, color: color),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (state == PermState.notAsked || state == PermState.denied)
                    TextButton(
                      onPressed: onRequest,
                      child: Text(state == PermState.denied ? 'Настройки' : 'Разрешить'),
                    ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PermissionsBlock extends StatelessWidget {
  const PermissionsBlock({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => Column(children: [
        PermissionTile(
          icon: Icons.my_location,
          title: 'Геолокация',
          why: 'Координаты для SOS-сообщения, расчёта заката и поиска маршрутов рядом.',
          state: state.permLocation,
          onRequest: state.requestLocation,
        ),
        const Divider(color: cLine, height: 1),
        PermissionTile(
          icon: Icons.contacts_outlined,
          title: 'Контакты',
          why: 'Чтобы выбрать аварийный контакт из телефонной книги. Приложение только читает номер.',
          state: state.permContacts,
          onRequest: state.requestContacts,
        ),
        const Divider(color: cLine, height: 1),
        PermissionTile(
          icon: Icons.notifications_outlined,
          title: 'Уведомления',
          why: 'Напоминание «пора разворачиваться» придёт, даже если телефон в кармане.',
          state: state.permNotif,
          onRequest: state.requestNotifications,
        ),
      ]),
    );
  }
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
          children: [
            const RidgeMark(size: 56),
            const SizedBox(height: 20),
            const Text('Связь пропадёт за первым хребтом.\nПлан — нет.',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, height: 1.15, letterSpacing: -0.5)),
            const SizedBox(height: 12),
            const Text(
              'TauGuard считает, когда пора разворачиваться, помнит последний прогноз '
              'и готовит SOS без интернета. Три разрешения помогут ему сработать вовремя.',
              style: TextStyle(fontSize: 17, color: cMuted, height: 1.45),
            ),
            const SizedBox(height: 20),
            Panel(child: PermissionsBlock(state: state)),
            const SizedBox(height: 6),
            FilledButton(
              onPressed: state.finishOnboarding,
              child: const Text('Продолжить'),
            ),
            const Hint('Любое разрешение можно выдать или отозвать позже во вкладке «Профиль».'),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Вкладка «Маршрут»: световой день, план, точка невозврата
// ═════════════════════════════════════════════════════════════
class RouteTab extends StatefulWidget {
  const RouteTab({super.key, required this.state});
  final AppState state;
  @override
  State<RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends State<RouteTab> {
  final _name = TextEditingController();
  final _km = TextEditingController();
  final _gain = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  TimeOfDay _start = const TimeOfDay(hour: 8, minute: 0);
  int _dayOffset = 0;
  HikePlan? _plan;
  String? _error;
  bool _gpsBusy = false;
  LL? _heroPoint;
  RouteChoice? _chosen;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final r = s.route;
    if (r != null) {
      _fill(r);
      if (s.demoMode) _start = const TimeOfDay(hour: 9, minute: 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _calculate(silent: true);
      });
    } else if (s.effPoint != null) {
      _lat.text = s.effPoint!.lat.toStringAsFixed(5);
      _lon.text = s.effPoint!.lon.toStringAsFixed(5);
      _heroPoint = s.effPoint!.ll;
    }
  }

  void _fill(RouteChoice r) {
    _chosen = r;
    _name.text = r.name;
    _km.text = fmtNum(r.km, 1);
    _gain.text = fmtNum(r.gain);
    _lat.text = r.start.lat.toStringAsFixed(5);
    _lon.text = r.start.lon.toStringAsFixed(5);
    _heroPoint = r.start;
  }

  @override
  void dispose() {
    for (final c in [_name, _km, _gain, _lat, _lon]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _start,
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t != null) setState(() => _start = t);
  }

  Future<void> _fromGps() async {
    if (s.demoMode) {
      snack(context, 'В демо-режиме используются координаты маршрута Кок-Жайлау.');
      return;
    }
    setState(() => _gpsBusy = true);
    final r = await fetchLocation();
    if (!mounted) return;
    setState(() => _gpsBusy = false);
    if (r.point != null) {
      await s.savePoint(r.point!);
      _lat.text = r.point!.lat.toStringAsFixed(5);
      _lon.text = r.point!.lon.toStringAsFixed(5);
      setState(() => _heroPoint = r.point!.ll);
    }
    if (r.message != null && mounted) snack(context, r.message!);
  }

  Future<void> _findRoutes() async {
    final lat = parseNum(_lat.text);
    final lon = parseNum(_lon.text);
    final center = (lat != null && lon != null)
        ? (lat: lat, lon: lon)
        : (s.effPoint?.ll ?? almatyDefault);
    final choice = await Navigator.of(context).push<RouteChoice>(
      MaterialPageRoute(builder: (_) => RoutesSearchPage(state: s, center: center)),
    );
    if (choice == null || !mounted) return;
    await s.setRoute(choice);
    setState(() => _fill(choice));
    _calculate();
  }

  DateTime get _day {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day).add(Duration(days: _dayOffset));
  }

  void _calculate({bool silent = false}) {
    final km = parseNum(_km.text);
    final gain = parseNum(_gain.text);
    String? err;
    if (km == null || km <= 0 || km > 100) {
      err = 'Укажите расстояние в одну сторону: от 0.1 до 100 км.';
    } else if (gain == null || gain < 0 || gain > 5000) {
      err = 'Укажите набор высоты: от 0 до 5000 м.';
    }
    var lat = parseNum(_lat.text);
    var lon = parseNum(_lon.text);
    if (lat != null && lat.abs() > 90) lat = null;
    if (lon != null && lon.abs() > 180) lon = null;

    if (err != null) {
      setState(() {
        _error = silent ? null : err;
        _plan = null;
      });
      return;
    }
    final start = DateTime(_day.year, _day.month, _day.day, _start.hour, _start.minute);
    final plan = HikePlan.compute(
      km: km!,
      gainM: gain!,
      start: start,
      lat: lat,
      lon: lon,
      wx: s.weather,
      topEle: _chosen?.topEle,
    );

    if (lat != null && lon != null) {
      final updated = RouteChoice(
        name: _name.text.trim().isEmpty ? 'Мой маршрут' : _name.text.trim(),
        km: km,
        gain: gain,
        start: (lat: lat, lon: lon),
        top: _chosen?.top,
        topEle: _chosen?.topEle,
        startEle: _chosen?.startEle,
        source: _chosen?.source ?? 'Вручную',
      );
      _chosen = updated;
      if (!s.demoMode) s.setRoute(updated);
    }

    setState(() {
      _error = null;
      _plan = plan;
      if (lat != null && lon != null) _heroPoint = (lat: lat, lon: lon);
    });
  }

  Future<void> _remind() async {
    final p = _plan;
    if (p?.noReturn == null) return;
    if (!Notifier.supported) {
      snack(context, 'Напоминания работают в приложении для Android и iOS.');
      return;
    }
    if (s.permNotif != PermState.granted) await s.requestNotifications();
    if (!mounted) return;
    if (s.permNotif != PermState.granted) {
      snack(context, 'Без разрешения на уведомления напоминание не придёт.');
      return;
    }
    final times = await Notifier.scheduleTurnaround(p!.noReturn!, _name.text.trim());
    await s.saveReminders(times);
    if (!mounted) return;
    snack(
      context,
      times.isEmpty
          ? 'Точка невозврата уже прошла — разворачивайтесь сейчас.'
          : 'Напомню в ${times.map(_hm.format).join(' и ')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final dayLabels = ['Сегодня', 'Завтра', dayName(DateTime.now().add(const Duration(days: 2)))];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        DaylightHero(point: _heroPoint, day: _day, plan: _plan),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Expanded(child: H2('План выхода')),
                TextButton.icon(
                  onPressed: _findRoutes,
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('Маршруты рядом'),
                ),
              ]),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Название маршрута'),
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _km,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Туда, км'),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _gain,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Набор, м'),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              SegmentedButton<int>(
                segments: [
                  for (var i = 0; i < 3; i++) ButtonSegment(value: i, label: Text(dayLabels[i])),
                ],
                selected: {_dayOffset},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _dayOffset = v.first),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickTime,
                icon: const Icon(Icons.schedule),
                label: Text('Старт в ${_start.hour.toString().padLeft(2, '0')}:'
                    '${_start.minute.toString().padLeft(2, '0')}'),
              ),
              const SizedBox(height: 16),
              const Text('Точка старта', style: TextStyle(color: cMuted, fontSize: 15)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _lat,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Широта'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lon,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Долгота'),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _gpsBusy ? null : _fromGps,
                icon: busyIcon(_gpsBusy, Icons.my_location),
                label: Text(_gpsBusy ? 'Ищу спутники…' : 'Я на старте — взять GPS'),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _calculate,
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Рассчитать время и риск'),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: const TextStyle(color: cErrText, fontSize: 15)),
                ),
            ],
          ),
        ),
        if (_plan != null)
          PlanCard(
            plan: _plan!,
            reminders: s.reminders,
            onRemind: _plan!.noReturn != null ? _remind : null,
          ),
        const Hint(
          'Формула: туда = км/4 + м/600 ч; обратно = туда × 1.5; итого × 1.3 (запас 30%). '
          'Дети, снег, осыпи и усталость замедляют группу — закладывайте больше.',
        ),
        const Hint(
          'Закат считается на телефоне без интернета. В ущельях и на северных склонах '
          'темнеет раньше: солнце уходит за хребет.',
          icon: Icons.wb_twilight,
        ),
      ],
    );
  }
}

/// Световой день: дуга солнца от восхода до заката, текущее положение и отметки плана.
class DaylightHero extends StatefulWidget {
  const DaylightHero({super.key, required this.point, required this.day, this.plan});
  final LL? point;
  final DateTime day;
  final HikePlan? plan;
  @override
  State<DaylightHero> createState() => _DaylightHeroState();
}

class _DaylightHeroState extends State<DaylightHero> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.point ?? almatyDefault;
    final sunrise = SunCalc.sunrise(widget.day, p.lat, p.lon);
    final sunset = SunCalc.sunset(widget.day, p.lat, p.lon);
    final now = DateTime.now();
    final isToday = DateUtils.isSameDay(now, widget.day);

    String headline;
    String sub;
    if (sunrise == null || sunset == null) {
      headline = 'Закат не рассчитан';
      sub = 'Для этих координат солнце сегодня не заходит или не восходит.';
    } else if (!isToday) {
      headline = 'Закат ${_dm.format(sunset)} в ${_hm.format(sunset)}';
      sub = 'Светлого времени ${fmtDur(sunset.difference(sunrise))}';
    } else if (now.isBefore(sunrise)) {
      headline = 'Рассвет в ${_hm.format(sunrise)}';
      sub = 'Светлого времени сегодня ${fmtDur(sunset.difference(sunrise))}';
    } else if (now.isBefore(sunset)) {
      final left = sunset.difference(now);
      headline = 'До заката ${fmtDur(left)}';
      sub = left < const Duration(hours: 2)
          ? 'Меньше двух часов светлого времени — не начинайте новый подъём.'
          : 'Закат в ${_hm.format(sunset)}';
    } else {
      headline = 'Солнце село в ${_hm.format(sunset)}';
      sub = 'В темноте двигайтесь только по знакомой тропе, с фонарём.';
    }

    return Panel(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline,
              style: const TextStyle(
                  fontSize: 30, fontWeight: FontWeight.w900, height: 1.1, letterSpacing: -0.6)),
          const SizedBox(height: 6),
          Text(sub, style: const TextStyle(color: cMuted, fontSize: 15.5, height: 1.35)),
          if (sunrise != null && sunset != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 150,
              width: double.infinity,
              child: CustomPaint(
                painter: _DaylightPainter(
                  sunrise: sunrise,
                  sunset: sunset,
                  now: isToday ? now : null,
                  noReturn: widget.plan?.noReturn,
                  finish: widget.plan?.finish,
                ),
              ),
            ),
            Row(children: [
              Text('Рассвет ${_hm.format(sunrise)}', style: const TextStyle(color: cMuted, fontSize: 14)),
              const Spacer(),
              Text('Закат ${_hm.format(sunset)}',
                  style: const TextStyle(color: cSun, fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
            if (widget.plan?.noReturn != null) ...[
              const SizedBox(height: 10),
              const Wrap(spacing: 16, runSpacing: 6, children: [
                _Legend(color: cAmber, text: 'точка невозврата'),
                _Legend(color: cIce, text: 'финиш'),
              ]),
            ],
          ],
          if (widget.point == null)
            const Hint('Координаты не заданы — показано для Алматы. Возьмите GPS или выберите маршрут.',
                icon: Icons.location_off_outlined),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: cMuted, fontSize: 14)),
      ]);
}

class _DaylightPainter extends CustomPainter {
  _DaylightPainter({required this.sunrise, required this.sunset, this.now, this.noReturn, this.finish});
  final DateTime sunrise, sunset;
  final DateTime? now, noReturn, finish;

  double _f(DateTime t) {
    final total = sunset.difference(sunrise).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(sunrise).inSeconds / total).clamp(0.0, 1.0);
  }

  Offset _pos(double f, Offset c, double r) {
    final th = math.pi * (1 - f);
    return Offset(c.dx + r * math.cos(th), c.dy - r * math.sin(th));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final base = size.height - 16;
    final c = Offset(size.width / 2, base);
    final r = math.min(size.width / 2 - 14, base - 12);
    final rect = Rect.fromCircle(center: c, radius: r);

    final track = Paint()
      ..color = cLine
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, track);

    final n = now;
    final day = n != null && !n.isBefore(sunrise) && n.isBefore(sunset);
    final nowF = n == null ? 0.0 : (n.isBefore(sunrise) ? 0.0 : _f(n));
    if (nowF > 0) {
      canvas.drawArc(
        rect,
        math.pi,
        math.pi * nowF,
        false,
        Paint()
          ..color = cSun
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    void mark(DateTime? t, Color col) {
      if (t == null) return;
      final p = _pos(_f(t), c, r);
      canvas.drawCircle(p, 8, Paint()..color = cSurface);
      canvas.drawCircle(p, 6, Paint()..color = col);
    }

    mark(noReturn, cAmber);
    mark(finish, cIce);

    if (day) {
      final p = _pos(nowF, c, r);
      canvas.drawCircle(p, 18, Paint()..color = const Color(0x33FCD34D));
      canvas.drawCircle(p, 10, Paint()..color = cSun);
    }

    // Силуэт хребта: низкое солнце прячется за горы раньше астрономического заката.
    const ridge = <(double, double)>[
      (0.00, 8), (0.06, 16), (0.12, 9), (0.19, 24), (0.26, 13), (0.33, 19), (0.41, 7),
      (0.50, 11), (0.58, 5), (0.65, 17), (0.72, 28), (0.79, 15), (0.86, 21), (0.93, 10), (1.00, 14),
    ];
    final path = Path()..moveTo(0, size.height);
    for (final (x, h) in ridge) {
      path.lineTo(x * size.width, base + 6 - h);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = cSurfaceHi);
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      Paint()
        ..color = cLine
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _DaylightPainter old) => true;
}

class PlanCard extends StatelessWidget {
  const PlanCard({super.key, required this.plan, required this.reminders, this.onRemind});
  final HikePlan plan;
  final List<DateTime> reminders;
  final VoidCallback? onRemind;

  @override
  Widget build(BuildContext context) {
    final risk = plan.risk;
    final (Color bg, Color fg, String title) = switch (risk) {
      Risk.green => (cGreen, cInk, 'Можно идти'),
      Risk.yellow => (cAmber, cInk, 'Идти с осторожностью'),
      Risk.red => (cRed, Colors.white, 'Маршрут опасен'),
      Risk.unknown => (cSurfaceHi, cText, 'Риск не оценён'),
    };

    final sunText = switch (plan.sunRisk) {
      Risk.green => 'До заката после финиша остаётся больше 2 часов.',
      Risk.yellow => 'Запас до заката меньше 2 часов: любая задержка — и спуск в сумерках.',
      Risk.red => 'Возврат после заката. Выйдите раньше или выберите короткий вариант.',
      Risk.unknown => 'Нет координат старта — закат не рассчитан.',
    };

    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: bg,
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: fg, fontSize: 24, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(sunText, style: TextStyle(color: fg, fontSize: 16, height: 1.35)),
            ]),
          ),
          if (plan.noReturn != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Разворачивайтесь не позже',
                        style: TextStyle(color: cMuted, fontSize: 15)),
                    Text(_hm.format(plan.noReturn!),
                        style: const TextStyle(
                          color: cAmber,
                          fontSize: 52,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                          fontFeatures: [FontFeature.tabularFigures()],
                        )),
                  ]),
                ),
                if (onRemind != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: FilledButton.tonalIcon(
                      onPressed: onRemind,
                      icon: Icon(reminders.isEmpty
                          ? Icons.notification_add_outlined
                          : Icons.notifications_active),
                      label: Text(reminders.isEmpty ? 'Напомнить' : 'Обновить'),
                    ),
                  ),
              ]),
            ),
          if (reminders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Hint('Напоминания: ${reminders.map(_hm.format).join(', ')}',
                  icon: Icons.notifications_active_outlined),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
            child: Column(children: [
              KV('Путь туда (с запасом)', fmtDur(plan.tUp)),
              KV('Путь обратно (с запасом)', fmtDur(plan.tBack)),
              KV('Итого в пути', fmtDur(plan.total), strong: true),
              const Divider(color: cLine, height: 20),
              KV('Старт', _hm.format(plan.start)),
              KV('Плановый разворот', _hm.format(plan.turnaround)),
              KV('Финиш', _hm.format(plan.finish), strong: true),
              KV('Закат', plan.sunset != null ? _hm.format(plan.sunset!) : '?'),
              if (plan.margin != null)
                KV('Запас до заката', fmtDur(plan.margin!),
                    strong: true, color: plan.margin!.isNegative ? cErrText : null),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Divider(color: cLine, height: 12),
              const SizedBox(height: 6),
              const Text('Погода на время похода',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              if (plan.wxFlags == null)
                const Hint(
                  'Прогноз для этого места не загружен. Откройте вкладку «Погода», пока есть сеть, '
                  'и пересчитайте план.',
                  icon: Icons.cloud_off,
                )
              else
                for (final f in plan.wxFlags!) WxFlagRow(flag: f),
            ]),
          ),
        ],
      ),
    );
  }
}

class WxFlagRow extends StatelessWidget {
  const WxFlagRow({super.key, required this.flag});
  final WxFlag flag;
  @override
  Widget build(BuildContext context) {
    final color = switch (flag.risk) {
      Risk.red => cErrText,
      Risk.yellow => cAmber,
      Risk.green => cGreen,
      Risk.unknown => cMuted,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(flag.icon, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Text(flag.text, style: const TextStyle(fontSize: 16, height: 1.35))),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Поиск маршрутов (OpenStreetMap)
// ═════════════════════════════════════════════════════════════
class RoutesSearchPage extends StatefulWidget {
  const RoutesSearchPage({super.key, required this.state, required this.center});
  final AppState state;
  final LL center;
  @override
  State<RoutesSearchPage> createState() => _RoutesSearchPageState();
}

class _RoutesSearchPageState extends State<RoutesSearchPage> {
  int _radiusKm = 25;
  bool _loading = false;
  String? _error;
  List<OsmRoute> _routes = [];
  DateTime? _cachedAt;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _loadCache();
    _search();
  }

  void _loadCache() {
    final raw = s.prefs.getString('routes_cache');
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _routes = OverpassApi.parseRoutes(j['elements'] as List, widget.center);
      _cachedAt = DateTime.tryParse(j['at'] as String? ?? '');
    } catch (_) {}
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await OverpassApi.nearbyRaw(widget.center, _radiusKm * 1000);
      final now = DateTime.now();
      await s.prefs.setString('routes_cache', jsonEncode({'at': now.toIso8601String(), 'elements': raw}));
      if (!mounted) return;
      setState(() {
        _routes = OverpassApi.parseRoutes(raw, widget.center);
        _cachedAt = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _routes.isEmpty
          ? 'Нет связи с OpenStreetMap. Подключитесь к сети или введите маршрут вручную.'
          : 'Нет связи с OpenStreetMap. Показан сохранённый список.');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(OsmRoute r) async {
    final choice = await Navigator.of(context).push<RouteChoice>(
      MaterialPageRoute(builder: (_) => RouteDetailPage(route: r)),
    );
    if (choice != null && mounted) Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Маршруты рядом', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(
            'Пешеходные маршруты из OpenStreetMap в радиусе $_radiusKm км от '
            '${widget.center.lat.toStringAsFixed(3)}, ${widget.center.lon.toStringAsFixed(3)}',
            style: const TextStyle(color: cMuted, fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 10, label: Text('10 км')),
              ButtonSegment(value: 25, label: Text('25 км')),
              ButtonSegment(value: 50, label: Text('50 км')),
            ],
            selected: {_radiusKm},
            showSelectedIcon: false,
            onSelectionChanged: (v) {
              setState(() => _radiusKm = v.first);
              _search();
            },
          ),
          const SizedBox(height: 14),
          if (s.demoMode)
            _RouteTile(
              title: 'Кок-Жайлау (демо)',
              lines: const ['5.5 км туда', 'набор 350 м'],
              onTap: () => Navigator.of(context).pop(AppState.demoRoute),
              accent: true,
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null) Hint(_error!, icon: Icons.wifi_off),
          if (_cachedAt != null && !_loading)
            Hint('Сохранённый список от ${_dmhm.format(_cachedAt!)}', icon: Icons.history),
          if (!_loading && _error == null && _routes.isEmpty)
            const Hint('В этом радиусе маршрутов в OSM нет. Увеличьте радиус.'),
          const SizedBox(height: 8),
          for (final r in _routes)
            _RouteTile(
              title: r.name,
              lines: [
                if (r.distFromMe != null) '${fmtNum(r.distFromMe!, 1)} км от точки',
                if (r.distanceTag != null) 'длина ${fmtNum(r.distanceTag!, 1)} км',
                if (r.ascentTag != null) 'набор ${fmtNum(r.ascentTag!)} м',
                if (r.fromTo != null) r.fromTo!,
              ],
              onTap: () => _open(r),
            ),
          const Hint('Данные © участники OpenStreetMap (ODbL). Проверяйте актуальность тропы на месте.',
              icon: Icons.copyright),
        ],
      ),
    );
  }
}

class _RouteTile extends StatelessWidget {
  const _RouteTile({required this.title, required this.lines, required this.onTap, this.accent = false});
  final String title;
  final List<String> lines;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: accent ? const Color(0xFF2B2A1A) : cSurface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent ? cAmber : cLine),
            ),
            child: Row(children: [
              Icon(Icons.alt_route, color: accent ? cAmber : cIce, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  if (lines.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(lines.join('  ·  '), style: const TextStyle(color: cMuted, fontSize: 14.5)),
                  ],
                ]),
              ),
              const Icon(Icons.chevron_right, color: cMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

class RouteDetailPage extends StatefulWidget {
  const RouteDetailPage({super.key, required this.route});
  final OsmRoute route;
  @override
  State<RouteDetailPage> createState() => _RouteDetailPageState();
}

class _RouteDetailPageState extends State<RouteDetailPage> {
  late Future<RouteAnalysis> _future;

  @override
  void initState() {
    super.initState();
    _future = OverpassApi.analyze(widget.route.id);
  }

  RouteChoice _choice(RouteAnalysis a) {
    final r = widget.route;
    final km = r.distanceTag ?? a.lengthKm;
    final gain = r.ascentTag ?? a.gain ?? 0;
    final start = a.low ?? a.ways.first.first;
    return RouteChoice(
      name: r.name,
      km: double.parse(km.toStringAsFixed(1)),
      gain: gain.roundToDouble(),
      start: start,
      top: a.high,
      topEle: a.maxEle,
      startEle: a.minEle,
      source: 'OpenStreetMap',
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    return Scaffold(
      appBar: AppBar(title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w800))),
      body: FutureBuilder<RouteAnalysis>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Загружаю трек и высоты…', style: TextStyle(color: cMuted, fontSize: 16)),
              ]),
            );
          }
          if (snap.hasError || !snap.hasData) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              Hint('Не удалось загрузить трек: ${snap.error ?? 'нет данных'}', icon: Icons.error_outline),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _future = OverpassApi.analyze(r.id)),
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ]);
          }
          final a = snap.data!;
          final c = _choice(a);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Panel(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  height: 220,
                  child: CustomPaint(painter: _TrackPainter(a), size: Size.infinite),
                ),
              ),
              Panel(
                child: Column(children: [
                  KV('Длина трека', '${fmtNum(c.km, 1)} км', strong: true),
                  KV('Набор высоты', '${fmtNum(c.gain)} м', strong: true),
                  if (a.minEle != null) KV('Нижняя точка', '~${fmtNum(a.minEle!)} м'),
                  if (a.maxEle != null) KV('Верхняя точка', '~${fmtNum(a.maxEle!)} м'),
                  KV('Старт', '${c.start.lat.toStringAsFixed(4)}, ${c.start.lon.toStringAsFixed(4)}'),
                  if (r.fromTo != null) KV('Направление', r.fromTo!),
                ]),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(c),
                icon: const Icon(Icons.check),
                label: const Text('Рассчитать этот маршрут'),
              ),
              Hint(
                r.distanceTag != null
                    ? 'Длина взята из данных маршрута в OSM.'
                    : 'Длина — сумма всех участков в OSM. Если маршрут кольцевой или с вариантами, '
                        'поправьте расстояние «туда» вручную.',
              ),
              Hint(
                r.ascentTag != null
                    ? 'Набор высоты взят из данных маршрута в OSM.'
                    : 'Набор оценён как разница высот верхней и нижней точек трека (рельеф Open-Meteo). '
                        'Реальный набор с подъёмами-спусками обычно больше.',
                icon: Icons.terrain,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter(this.a);
  final RouteAnalysis a;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final w in a.ways) ...w];
    if (pts.isEmpty) return;
    var minLat = pts.first.lat, maxLat = pts.first.lat, minLon = pts.first.lon, maxLon = pts.first.lon;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    final k = math.cos(_rad((minLat + maxLat) / 2));
    final w = math.max((maxLon - minLon) * k, 1e-6);
    final h = math.max(maxLat - minLat, 1e-6);
    const pad = 18.0;
    final scale = math.min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h);
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - h * scale) / 2;
    Offset map(LL p) => Offset(ox + (p.lon - minLon) * k * scale, oy + (maxLat - p.lat) * scale);

    final line = Paint()
      ..color = cIce
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    for (final way in a.ways) {
      final path = Path()..moveTo(map(way.first).dx, map(way.first).dy);
      for (final p in way.skip(1)) {
        final o = map(p);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, line);
    }
    if (a.low != null) {
      final o = map(a.low!);
      canvas.drawCircle(o, 9, Paint()..color = cSurface);
      canvas.drawCircle(o, 7, Paint()..color = cGreen);
    }
    if (a.high != null) {
      final o = map(a.high!);
      final tri = Path()
        ..moveTo(o.dx, o.dy - 11)
        ..lineTo(o.dx - 10, o.dy + 7)
        ..lineTo(o.dx + 10, o.dy + 7)
        ..close();
      canvas.drawPath(tri, Paint()..color = cAmber);
    }
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) => old.a != a;
}

// ═════════════════════════════════════════════════════════════
// Вкладка «Погода» (Open-Meteo, кэш офлайн)
// ═════════════════════════════════════════════════════════════
class WeatherTab extends StatefulWidget {
  const WeatherTab({super.key, required this.state});
  final AppState state;
  @override
  State<WeatherTab> createState() => _WeatherTabState();
}

class _WeatherTabState extends State<WeatherTab> {
  String _where = 'start';
  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    if (s.route == null) _where = 'me';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final w = s.weather;
      if (w == null || w.isStale) _refresh(silent: true);
    });
  }

  (LL, String)? _target() {
    final r = s.route;
    switch (_where) {
      case 'top':
        if (r?.top != null) {
          return (r!.top!, '${r.name}: верхняя точка${r.topEle != null ? ' ~${fmtNum(r.topEle!)} м' : ''}');
        }
      case 'start':
        if (r != null) return (r.start, '${r.name}: старт');
    }
    final p = s.effPoint;
    if (p != null) return (p.ll, s.demoMode ? 'Демо-точка' : 'Моё местоположение');
    return null;
  }

  Future<void> _refresh({bool silent = false}) async {
    var t = _target();
    if (t == null && _where == 'me' && !s.demoMode) {
      final r = await fetchLocation();
      if (r.point != null) {
        await s.savePoint(r.point!);
        t = _target();
      } else if (!silent && mounted) {
        snack(context, r.message ?? 'Не удалось определить местоположение.');
      }
    }
    if (t == null) {
      if (!silent && mounted) snack(context, 'Выберите маршрут или возьмите GPS на вкладке «Маршрут».');
      return;
    }
    await s.fetchWeather(t.$1.lat, t.$1.lon, t.$2);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final w = s.weather;
        final r = s.route;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              const H1('Погода в горах'),
              SegmentedButton<String>(
                segments: [
                  const ButtonSegment(value: 'me', label: Text('Я'), icon: Icon(Icons.my_location)),
                  ButtonSegment(value: 'start', label: const Text('Старт'), enabled: r != null),
                  ButtonSegment(value: 'top', label: const Text('Вершина'), enabled: r?.top != null),
                ],
                selected: {_where},
                showSelectedIcon: false,
                onSelectionChanged: (v) {
                  setState(() => _where = v.first);
                  _refresh();
                },
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text(
                    w == null
                        ? 'Прогноз ещё не загружен'
                        : '${w.label}\nОбновлено ${_dmhm.format(w.fetchedAt)}${w.isStale ? ' — устарел' : ''}',
                    style: TextStyle(color: w?.isStale == true ? cAmber : cMuted, fontSize: 14.5, height: 1.4),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: s.wxLoading ? null : _refresh,
                  icon: busyIcon(s.wxLoading, Icons.refresh),
                  label: const Text('Обновить'),
                ),
              ]),
              if (s.wxError != null) Hint(s.wxError!, icon: Icons.wifi_off),
              const SizedBox(height: 12),
              if (w != null) ...[
                _CurrentWx(w: w),
                _TodayFlags(w: w, topEle: _where == 'top' ? r?.topEle : null),
                const H2('По часам'),
                _HourlyStrip(w: w),
                const SizedBox(height: 14),
                const H2('Три дня'),
                for (final d in w.days) _DayRow(d: d),
              ],
              const Hint(
                'Прогноз загружается, пока есть сеть, и сохраняется на телефоне. В горах погода '
                'меняется быстрее модели: следите за небом и разворачивайтесь при первых признаках грозы.',
              ),
              const Hint('Данные: Open-Meteo.com (CC BY 4.0).', icon: Icons.copyright),
            ],
          ),
        );
      },
    );
  }
}

class _CurrentWx extends StatelessWidget {
  const _CurrentWx({required this.w});
  final WeatherData w;
  @override
  Widget build(BuildContext context) {
    final (desc, icon) = wxInfo(w.curCode);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(w.curTemp != null ? '${fmtNum(w.curTemp!)}°' : '?°',
                  style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w900, height: 1)),
              const SizedBox(height: 4),
              Text(desc, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              if (w.curFeels != null)
                Text('Ощущается как ${fmtNum(w.curFeels!)}°',
                    style: const TextStyle(color: cMuted, fontSize: 15.5)),
            ]),
          ),
          Icon(icon, size: 64, color: cIce),
        ]),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (w.curWind != null) Pill('Ветер ${fmtNum(w.curWind!)} м/с', icon: Icons.air),
          if (w.curGust != null) Pill('Порывы ${fmtNum(w.curGust!)} м/с', icon: Icons.storm),
          if (w.curPrecip != null) Pill('Осадки ${fmtNum(w.curPrecip!, 1)} мм', icon: Icons.water_drop_outlined),
          if (w.elevation != null) Pill('Высота модели ${fmtNum(w.elevation!)} м', icon: Icons.terrain),
        ]),
      ]),
    );
  }
}

class _TodayFlags extends StatelessWidget {
  const _TodayFlags({required this.w, this.topEle});
  final WeatherData w;
  final double? topEle;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = w.days.where((d) => DateUtils.isSameDay(d.date, now)).firstOrNull;
    final end = today?.sunset ?? now.add(const Duration(hours: 8));
    final to = end.isAfter(now) ? end : now.add(const Duration(hours: 8));
    final flags = analyzeWeather(w, now, to, topEle: topEle);
    if (flags.isEmpty) return const SizedBox.shrink();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(end.isAfter(now) ? 'До заката сегодня' : 'Ближайшие 8 часов',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        for (final f in flags) WxFlagRow(flag: f),
      ]),
    );
  }
}

class _HourlyStrip extends StatelessWidget {
  const _HourlyStrip({required this.w});
  final WeatherData w;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().subtract(const Duration(minutes: 59));
    final hrs = w.hours.where((h) => h.time.isAfter(now)).take(24).toList();
    if (hrs.isEmpty) return const Hint('Почасовой прогноз устарел — обновите при появлении сети.');
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: hrs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final h = hrs[i];
          final (_, icon) = wxInfo(h.code);
          final storm = (h.code ?? 0) >= 95;
          final windy = (h.gust ?? 0) >= 12;
          return Container(
            width: 78,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: cSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: storm ? cErrText : cLine, width: storm ? 2 : 1),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(_hm.format(h.time), style: const TextStyle(color: cMuted, fontSize: 14)),
              Icon(icon, color: storm ? cErrText : cIce, size: 28),
              Text(h.temp != null ? '${fmtNum(h.temp!)}°' : '?',
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              Text(h.gust != null ? '${fmtNum(h.gust!)} м/с' : '—',
                  style: TextStyle(fontSize: 13, color: windy ? cAmber : cMuted, fontWeight: FontWeight.w600)),
              Text(h.precipProb != null ? '${fmtNum(h.precipProb!)}%' : '—',
                  style: const TextStyle(fontSize: 13, color: cMuted)),
            ]),
          );
        },
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.d});
  final DayWx d;
  @override
  Widget build(BuildContext context) {
    final (desc, icon) = wxInfo(d.code);
    final today = DateUtils.isSameDay(d.date, DateTime.now());
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        SizedBox(
          width: 64,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(today ? 'Сегодня' : dayName(d.date), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            Text(_dm.format(d.date), style: const TextStyle(color: cMuted, fontSize: 13.5)),
          ]),
        ),
        Icon(icon, color: (d.code ?? 0) >= 95 ? cErrText : cIce, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(desc, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
            Text(
              [
                if (d.gustMax != null) 'порывы ${fmtNum(d.gustMax!)} м/с',
                if (d.precipProbMax != null) 'осадки ${fmtNum(d.precipProbMax!)}%',
                if (d.uvMax != null) 'УФ ${fmtNum(d.uvMax!)}',
              ].join(' · '),
              style: const TextStyle(color: cMuted, fontSize: 13.5),
            ),
          ]),
        ),
        Text(
          '${d.tMax != null ? fmtNum(d.tMax!) : '?'}° / ${d.tMin != null ? fmtNum(d.tMin!) : '?'}°',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════
// SOS
// ═════════════════════════════════════════════════════════════
const kStatuses = <(String, IconData)>[
  ('Потерял тропу', Icons.explore_off),
  ('Травма', Icons.personal_injury),
  ('Переохлаждение', Icons.ac_unit),
  ('Горная болезнь', Icons.landscape),
  ('Другое', Icons.help_outline),
];

class SosPage extends StatefulWidget {
  const SosPage({super.key, required this.state});
  final AppState state;
  @override
  State<SosPage> createState() => _SosPageState();
}

class _SosPageState extends State<SosPage> {
  int _status = 0;
  bool _busy = false;
  String? _gpsMsg;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    // Сразу пытаемся обновить координаты — они нужнее всего.
    if (!s.demoMode) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (s.demoMode) {
      snack(context, 'В демо-режиме показаны демонстрационные координаты.');
      return;
    }
    setState(() {
      _busy = true;
      _gpsMsg = null;
    });
    final r = await fetchLocation();
    if (!mounted) return;
    if (r.point != null) await s.savePoint(r.point!);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _gpsMsg = r.message;
    });
  }

  Future<void> _manual() async {
    final p = await manualCoordsDialog(context, s.lastPoint);
    if (p != null) {
      await s.savePoint(p);
      if (mounted) setState(() => _gpsMsg = null);
    }
  }

  String _message() {
    final p = s.effPoint;
    final b = StringBuffer('SOS! Нужна помощь в горах.\n');
    if (s.effName.isNotEmpty) b.writeln('Имя: ${s.effName}');
    b.writeln('Ситуация: ${kStatuses[_status].$1}');
    final r = s.route;
    if (r != null) b.writeln('Маршрут: ${r.name}');
    if (p != null) {
      b.writeln('Координаты: ${p.decimal}');
      if (p.alt != null) b.writeln('Высота: ~${p.alt!.round()} м');
      if (p.accuracy != null) b.writeln('Точность: ±${p.accuracy!.round()} м');
      b.writeln('Фикс: ${_dmhm.format(p.time)} (${p.source})');
      b.writeln(p.mapsUrl);
    } else {
      b.writeln('Координаты: неизвестны');
    }
    b.write('Если не отвечаю — позвони 112 и передай эти данные.');
    return b.toString();
  }

  Future<void> _call112() async {
    if (s.demoMode) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cSurface,
          title: const Text('Демо-режим'),
          content: const Text(
            'В демо-режиме звонок в 112 не выполняется, чтобы не создавать ложный вызов. '
            'В обычном режиме откроется номеронабиратель с номером 112.',
            style: TextStyle(fontSize: 16, height: 1.4),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно'))],
        ),
      );
      return;
    }
    try {
      final ok = await launchUrl(Uri(scheme: 'tel', path: '112'));
      if (!ok && mounted) snack(context, 'Не удалось открыть звонилку. Наберите 112 вручную.');
    } catch (_) {
      if (mounted) snack(context, 'Не удалось открыть звонилку. Наберите 112 вручную.');
    }
  }

  Future<void> _sms() async {
    final phone = cleanPhone(s.effPhone);
    if (phone.isEmpty) {
      final picked = await pickContact(context, s);
      if (picked == null || !mounted) return;
      await s.saveProfile(s.name, picked.$2, picked.$1);
      if (!mounted) return;
      return _sms();
    }
    final msg = _message();
    if (s.demoMode) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: cSurface,
          title: Text('Демо: SMS для ${s.effLabel}'),
          content: SingleChildScrollView(
            child: Text('Кому: ${s.effPhoneDisplay}\n\n$msg', style: const TextStyle(fontSize: 15, height: 1.4)),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть (не отправлено)')),
          ],
        ),
      );
      return;
    }
    try {
      final ok = await launchUrl(Uri.parse('sms:$phone?body=${Uri.encodeComponent(msg)}'));
      if (!ok && mounted) snack(context, 'SMS-приложение не открылось. Скопируйте текст кнопкой ниже.');
    } catch (_) {
      if (mounted) snack(context, 'SMS-приложение не открылось. Скопируйте текст кнопкой ниже.');
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _message()));
    if (mounted) snack(context, 'Текст SOS скопирован');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final p = s.effPoint;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Экстренная помощь', style: TextStyle(fontWeight: FontWeight.w900)),
            bottom: s.demoMode
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(26),
                    child: Container(
                      height: 26,
                      width: double.infinity,
                      color: cAmber,
                      alignment: Alignment.center,
                      child: const Text('DEMO MODE',
                          style: TextStyle(color: cInk, fontWeight: FontWeight.w800)),
                    ),
                  )
                : null,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              SizedBox(
                height: 96,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: cRed,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  onPressed: _call112,
                  icon: const Icon(Icons.call, size: 38),
                  label: const Text('Позвонить 112'),
                ),
              ),
              const Hint(
                'Звонок идёт спасателям 112. SMS отправляется вашему личному контакту — '
                '112 в Казахстане принимает только голосовые вызовы.',
                icon: Icons.record_voice_over,
              ),
              const SizedBox(height: 18),

              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Ваши координаты', style: TextStyle(color: cMuted, fontSize: 15)),
                  const SizedBox(height: 6),
                  if (p != null) ...[
                    SelectableText(p.latStr,
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                    SelectableText(p.lonStr,
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                    const SizedBox(height: 8),
                    KV('Высота', p.alt != null ? '~${p.alt!.round()} м' : '?'),
                    KV('Точность', p.accuracy != null ? '±${p.accuracy!.round()} м' : '?'),
                    KV('Источник', p.source),
                    KV('Время фикса', _dmhm.format(p.time)),
                  ] else
                    const Text('?  Координаты ещё не получены',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  if (_gpsMsg != null) Hint(_gpsMsg!, icon: Icons.gps_off),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _refresh,
                        icon: busyIcon(_busy, Icons.gps_fixed),
                        label: Text(_busy ? 'Поиск…' : 'Обновить GPS'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _manual,
                        icon: const Icon(Icons.edit_location_alt),
                        label: const Text('Вручную'),
                      ),
                    ),
                  ]),
                ]),
              ),

              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const H2('Что случилось?'),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (var i = 0; i < kStatuses.length; i++)
                      ChoiceChip(
                        avatar: Icon(kStatuses[i].$2, size: 20),
                        label: Text(kStatuses[i].$1, style: const TextStyle(fontSize: 16)),
                        selected: _status == i,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _status = i),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      ),
                  ]),
                  const SizedBox(height: 18),
                  Text(
                    s.effPhone.isEmpty
                        ? 'Аварийный контакт не задан'
                        : '${s.effLabel.isEmpty ? 'Контакт' : s.effLabel}: ${s.effPhoneDisplay}',
                    style: const TextStyle(fontSize: 16, color: cMuted),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _sms,
                    icon: const Icon(Icons.sms),
                    label: Text(s.effPhone.isEmpty ? 'Выбрать контакт и отправить SMS' : 'SMS контакту с координатами'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy),
                    label: const Text('Скопировать текст SOS'),
                  ),
                  const Hint(
                    'SMS уходит без мобильного интернета — достаточно одной полоски сети. '
                    'Нет сети — поднимитесь выше на открытое место и повторите.',
                  ),
                ]),
              ),
              const Hint(
                'Три свистка, три вспышки фонаря или три крика подряд — международный сигнал бедствия.',
                icon: Icons.campaign_outlined,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Выбор контакта из телефонной книги
// ═════════════════════════════════════════════════════════════
Future<(String, String)?> pickContact(BuildContext context, AppState s) async {
  if (!ContactsService.supported) {
    snack(context, 'Выбор из контактов доступен в приложении для Android и iOS. Введите номер в «Профиле».');
    return null;
  }
  if (s.permContacts != PermState.granted) await s.requestContacts();
  if (!context.mounted) return null;
  if (s.permContacts != PermState.granted) {
    snack(context, 'Нет доступа к контактам. Введите номер вручную в «Профиле».');
    return null;
  }
  return Navigator.of(context).push<(String, String)>(
    MaterialPageRoute(builder: (_) => const ContactPickerPage()),
  );
}

class ContactPickerPage extends StatefulWidget {
  const ContactPickerPage({super.key});
  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  late final Future<List<(String, String)>> _future = ContactsService.phones();
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Аварийный контакт', style: TextStyle(fontWeight: FontWeight.w800))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Поиск по имени или номеру', prefixIcon: Icon(Icons.search)),
            onChanged: (v) => setState(() => _q = v.toLowerCase()),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<(String, String)>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Hint('Не удалось прочитать контакты. Проверьте разрешение в «Профиле».'),
                );
              }
              final list = (snap.data ?? const [])
                  .where((c) => _q.isEmpty || c.$1.toLowerCase().contains(_q) || c.$2.contains(_q))
                  .toList();
              if (list.isEmpty) {
                return const Padding(padding: EdgeInsets.all(16), child: Hint('Ничего не найдено.'));
              }
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(color: cLine, height: 1),
                itemBuilder: (context, i) {
                  final c = list[i];
                  return ListTile(
                    minVerticalPadding: 12,
                    leading: CircleAvatar(
                      backgroundColor: cSurfaceHi,
                      child: Text(c.$1.isEmpty ? '?' : c.$1.characters.first.toUpperCase(),
                          style: const TextStyle(color: cIce, fontWeight: FontWeight.w800)),
                    ),
                    title: Text(c.$1, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    subtitle: Text(c.$2, style: const TextStyle(color: cMuted, fontSize: 15)),
                    onTap: () => Navigator.of(context).pop(c),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Вкладка «Помощь»: первая помощь офлайн
// ═════════════════════════════════════════════════════════════
class AidTopic {
  const AidTopic(this.icon, this.title, this.steps, this.danger);
  final IconData icon;
  final String title;
  final List<String> steps;
  final String danger;
}

const kAid = <AidTopic>[
  AidTopic(Icons.explore_off, 'Потерял тропу', [
    'Остановись. Не беги и не ищи путь наугад — паника уводит дальше.',
    'Нажми SOS: зафиксируй координаты и отправь их контакту, пока есть заряд.',
    'Не спускайся в незнакомые ущелья и по руслам ручьёв: там обрывы, водопады и нет связи.',
    'Возвращайся только к месту, где точно был на тропе. Не уверен — оставайся на месте.',
    'Жди на открытом, заметном месте. Утепляйся заранее, в темноте подавай сигналы фонарём.',
  ], 'Темнеет, есть пострадавший или не получается согреться — звоните 112.'),
  AidTopic(Icons.ac_unit, 'Переохлаждение', [
    'Укройся от ветра и осадков. Изолируй человека от земли: коврик, рюкзак, ветки.',
    'Сними мокрую одежду, надень сухую, шапку и перчатки. Спасательное одеяло — поверх.',
    'Если человек в сознании и может глотать — тёплое сладкое питьё. Никакого алкоголя.',
    'Не растирай руки и ноги снегом или силой. Двигай пострадавшего бережно.',
    'Грей корпус, а не конечности: тёплые бутылки к груди, подмышкам, паху.',
  ], 'Дрожь прекратилась, речь спутанная, сонливость — это тяжёлая стадия, звоните 112.'),
  AidTopic(Icons.healing, 'Травмы и вывихи', [
    'Убедись, что на месте нет камнепада. При подозрении на травму шеи или спины не двигай человека.',
    'Сильное кровотечение: плотно прижми рану тканью и наложи давящую повязку.',
    'Не вправляй вывих и перелом. Зафиксируй конечность в том положении, в каком она есть.',
    'Шина из палок, коврика или одежды должна захватывать два соседних сустава.',
    'Холод на место травмы через ткань на 15–20 минут. Держи пострадавшего в тепле.',
  ], 'Кровь не останавливается, человек не может идти или теряет сознание — звоните 112.'),
  AidTopic(Icons.landscape, 'Горная болезнь', [
    'Признаки: головная боль вместе с тошнотой, слабостью, головокружением. Не поднимайся выше.',
    'Если в покое не проходит или усиливается — спускайся минимум на 500 м.',
    'Пей воду небольшими порциями, без алкоголя. Не оставляй человека одного.',
    'Спускайтесь вместе, даже ночью, если состояние ухудшается.',
    'Шаткая походка, спутанность, одышка в покое, кашель с пенистой мокротой — немедленный спуск.',
  ], 'Любой признак из шага 5 — звоните 112 и начинайте спуск.'),
];

class FirstAidTab extends StatelessWidget {
  const FirstAidTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        const H1('Первая помощь без интернета'),
        for (final t in kAid)
          Panel(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                iconColor: cIce,
                collapsedIconColor: cMuted,
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: cSurfaceHi, borderRadius: BorderRadius.circular(12)),
                  child: Icon(t.icon, color: cIce),
                ),
                title: Text(t.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                children: [
                  for (var i = 0; i < t.steps.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: cIce, shape: BoxShape.circle),
                          child: Text('${i + 1}',
                              style: const TextStyle(color: cInk, fontWeight: FontWeight.w900, fontSize: 15)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(t.steps[i], style: const TextStyle(fontSize: 17, height: 1.42)),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: cRed, borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      const Icon(Icons.call, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(t.danger,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700, height: 1.35)),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        const Hint(
          'Это памятка, а не замена курсам первой помощи. Пройдите обучение до сезона, '
          'носите аптечку, фонарь, свисток и спасательное одеяло.',
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════
// Вкладка «Профиль»
// ═════════════════════════════════════════════════════════════
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key, required this.state});
  final AppState state;
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _label;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: s.name);
    _phone = TextEditingController(text: s.contactPhone);
    _label = TextEditingController(text: s.contactLabel);
    s.addListener(_sync);
  }

  /// Если контакт выбрали на экране SOS — подтягиваем его в пустые поля профиля.
  void _sync() {
    if (_phone.text.isEmpty && s.contactPhone.isNotEmpty) _phone.text = s.contactPhone;
    if (_label.text.isEmpty && s.contactLabel.isNotEmpty) _label.text = s.contactLabel;
  }

  @override
  void dispose() {
    s.removeListener(_sync);
    _name.dispose();
    _phone.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final c = await pickContact(context, s);
    if (c == null) return;
    setState(() {
      _label.text = c.$1;
      _phone.text = c.$2;
    });
    await _save();
  }

  Future<void> _save() async {
    final phone = cleanPhone(_phone.text);
    if (_phone.text.trim().isNotEmpty && phone.replaceAll('+', '').length < 10) {
      snack(context, 'Номер слишком короткий. Формат: +7 777 123 45 67');
      return;
    }
    await s.saveProfile(_name.text, _phone.text, _label.text);
    if (mounted) snack(context, 'Профиль сохранён на телефоне');
  }

  Future<void> _cancelReminders() async {
    await Notifier.cancelTurnaround();
    await s.saveReminders([]);
    if (mounted) snack(context, 'Напоминания отменены');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final p = s.lastPoint;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            const H1('Профиль'),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Ваше имя'),
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 18),
                const H2('Аварийный контакт'),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Телефон'),
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _label,
                  decoration: const InputDecoration(labelText: 'Кто это: мама, гид, координатор'),
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.contacts_outlined),
                  label: const Text('Выбрать из контактов'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Сохранить профиль'),
                ),
                if (s.demoMode)
                  const Hint('Включён демо-режим: SOS использует демонстрационный контакт.',
                      icon: Icons.slideshow),
              ]),
            ),

            const H2('Разрешения'),
            Panel(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: PermissionsBlock(state: s)),

            const H2('Напоминания'),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  s.reminders.isEmpty
                      ? 'Нет запланированных напоминаний. Поставьте их в карточке плана.'
                      : 'Запланировано: ${s.reminders.map(_dmhm.format).join(', ')}',
                  style: const TextStyle(fontSize: 16, height: 1.4),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: Notifier.supported && s.permNotif == PermState.granted
                          ? () async {
                              await Notifier.test();
                              if (context.mounted) snack(context, 'Тестовое уведомление отправлено');
                            }
                          : null,
                      child: const Text('Проверить'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: s.reminders.isEmpty ? null : _cancelReminders,
                      child: const Text('Отменить все'),
                    ),
                  ),
                ]),
              ]),
            ),

            Panel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                value: s.demoMode,
                onChanged: (v) => s.setDemo(v),
                title: const Text('Демо-режим для презентации',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                subtitle: const Text(
                  'Маршрут Кок-Жайлау, демо-координаты и контакт. Звонок и SMS не отправляются. '
                  'Включается и тройным тапом по логотипу.',
                  style: TextStyle(color: cMuted, height: 1.35),
                ),
              ),
            ),

            const H2('Последняя GPS-точка'),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (p == null)
                  const Text('Пока нет. Точка сохраняется при каждом успешном GPS-фиксе.',
                      style: TextStyle(color: cMuted, fontSize: 16))
                else ...[
                  KV('Координаты', p.decimal),
                  KV('Высота', p.alt != null ? '~${p.alt!.round()} м' : '?'),
                  KV('Источник', p.source),
                  KV('Когда', _dmhm.format(p.time)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: s.clearPoint,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Удалить точку'),
                  ),
                ],
              ]),
            ),
            const Hint(
              'Профиль, точка и кэш прогноза хранятся только на этом телефоне. '
              'В сеть уходят лишь координаты для запросов погоды и маршрутов.',
              icon: Icons.lock_outline,
            ),
            const Hint('Погода и рельеф: Open-Meteo.com. Маршруты: © участники OpenStreetMap.',
                icon: Icons.copyright),
          ],
        );
      },
    );
  }
}
