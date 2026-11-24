// ============================================================
//  NOISE GUARD - Smart Noise Pollution Monitoring & Mapping
//  ESP32 + GPS + Sound sensor  ->  Flutter app
//  The ESP32 joins a phone hotspot and serves live JSON at
//  http://<ESP32_IP>/data ; this app reads it every 2 seconds.
//  NOTE: values are RELATIVE noise indicators (uncalibrated
//  analog sensor). They are NOT dB and NOT official noise levels.
// ============================================================
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------- SETTINGS ----------------
const int kSaveIntervalSec = 15; // save one history point at most this often
const int kMaxHistory = 500;     // keep the newest N saved points
const double kZoneRadiusM = 25;  // radius of the "zone" circle around a real point

// ---------------- COLOURS (sky blue + yellow) ----------------
class C {
  static const skyTop = Color(0xFF9BDDFF);
  static const skyBottom = Color(0xFF49B1EE);
  static const navy = Color(0xFF0B2F5B);
  static const navyLight = Color(0xFF14427A);
  static const border = Color(0xFF1F5A9E);
  static const yellow = Color(0xFFFFD60A);
  static const white = Color(0xFFF4FAFF);
  static const muted = Color(0xFF9CC4E8);
  static const green = Color(0xFF2ECC71);
  static const red = Color(0xFFFF4D4D);
}

Color catColor(String c) {
  switch (c) {
    case 'HIGH':
      return C.red;
    case 'MODERATE':
      return C.yellow;
    default:
      return C.green;
  }
}

String fmtTime(DateTime t) => DateFormat('dd MMM yyyy, hh:mm:ss a').format(t);

// ============================================================
//  MODEL
// ============================================================
class NoiseReading {
  final String deviceId;
  final double? lat;
  final double? lng;
  final int rawVariation;
  final double relativeNoise;
  final String category;
  final DateTime time;
  final bool gpsValid;
  final int satellites;

  NoiseReading({
    required this.deviceId,
    required this.lat,
    required this.lng,
    required this.rawVariation,
    required this.relativeNoise,
    required this.category,
    required this.time,
    required this.gpsValid,
    required this.satellites,
  });

  bool get hasLocation => gpsValid && lat != null && lng != null;

  factory NoiseReading.fromEsp(Map<String, dynamic> j) {
    final ts = j['timestamp'] is String
        ? DateTime.tryParse(j['timestamp'] as String)
        : null;
    return NoiseReading(
      deviceId: (j['deviceId'] ?? 'unknown').toString(),
      lat: (j['latitude'] as num?)?.toDouble(),
      lng: (j['longitude'] as num?)?.toDouble(),
      rawVariation: (j['rawVariation'] as num?)?.toInt() ?? 0,
      relativeNoise: (j['relativeNoise'] as num?)?.toDouble() ?? 0,
      category: (j['noiseCategory'] ?? 'LOW').toString(),
      time: ts?.toLocal() ?? DateTime.now(), // GPS time, else phone time
      gpsValid: j['gpsValid'] == true,
      satellites: (j['satellites'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'lat': lat,
        'lng': lng,
        'raw': rawVariation,
        'rel': relativeNoise,
        'cat': category,
        'time': time.toIso8601String(),
        'gps': gpsValid,
        'sat': satellites,
      };

  factory NoiseReading.fromJson(Map<String, dynamic> j) => NoiseReading(
        deviceId: j['deviceId'] as String,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        rawVariation: (j['raw'] as num).toInt(),
        relativeNoise: (j['rel'] as num).toDouble(),
        category: j['cat'] as String,
        time: DateTime.parse(j['time'] as String),
        gpsValid: j['gps'] as bool,
        satellites: (j['sat'] as num).toInt(),
      );
}

// ============================================================
//  APP STATE (polls the ESP32, keeps history on the phone)
// ============================================================
class AppState extends ChangeNotifier {
  String ip = '';
  bool connected = false;
  String? error;
  NoiseReading? current;
  DateTime? lastUpdate;
  final List<NoiseReading> history = [];
  final List<NoiseReading> session = [];
  double? sessionMax;
  double? sessionMin;

  Timer? _timer;
  bool _busy = false;
  DateTime? _lastSaved;
  SharedPreferences? _prefs;

  int get locationCount => history
      .where((r) => r.hasLocation)
      .map((r) => '${r.lat!.toStringAsFixed(4)},${r.lng!.toStringAsFixed(4)}')
      .toSet()
      .length;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    ip = _prefs!.getString('ip') ?? '';
    for (final s in _prefs!.getStringList('history') ?? <String>[]) {
      try {
        history.add(NoiseReading.fromJson(
            Map<String, dynamic>.from(jsonDecode(s) as Map)));
      } catch (_) {}
    }
    if (ip.isNotEmpty) start();
  }

  Future<void> setIp(String value) async {
    ip = value.trim().replaceAll('http://', '').replaceAll('/', '');
    await _prefs?.setString('ip', ip);
    connected = false;
    error = null;
    if (ip.isEmpty) {
      _timer?.cancel();
    } else {
      start();
    }
    notifyListeners();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => fetchNow());
    fetchNow();
  }

  Future<void> fetchNow() async {
    if (ip.isEmpty || _busy) return;
    _busy = true;
    try {
      final res = await http
          .get(Uri.http(ip, '/data'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final r = NoiseReading.fromEsp(
          Map<String, dynamic>.from(jsonDecode(res.body) as Map));
      current = r;
      connected = true;
      error = null;
      lastUpdate = DateTime.now();
      session.add(r);
      if (session.length > 120) session.removeAt(0);
      sessionMax = sessionMax == null
          ? r.relativeNoise
          : math.max(sessionMax!, r.relativeNoise);
      sessionMin = sessionMin == null
          ? r.relativeNoise
          : math.min(sessionMin!, r.relativeNoise);
      await _maybeSave(r);
    } catch (_) {
      connected = false;
      error = 'Cannot reach ESP32 at $ip. Use the same hotspot/Wi-Fi and '
          'the IP shown on the OLED.';
    }
    _busy = false;
    notifyListeners();
  }

  Future<void> _maybeSave(NoiseReading r) async {
    if (!r.hasLocation) return; // only real GPS positions are stored
    final now = DateTime.now();
    if (_lastSaved != null &&
        now.difference(_lastSaved!).inSeconds < kSaveIntervalSec) {
      return;
    }
    _lastSaved = now;
    history.add(r);
    while (history.length > kMaxHistory) {
      history.removeAt(0);
    }
    await _persist();
  }

  Future<void> _persist() async {
    await _prefs?.setStringList(
        'history', history.map((e) => jsonEncode(e.toJson())).toList());
  }

  Future<void> clearHistory() async {
    history.clear();
    await _persist();
    notifyListeners();
  }
}

final AppState app = AppState();

// ============================================================
//  MAIN
// ============================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: C.skyBottom,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  await app.init();
  runApp(const NoiseApp());
}

class NoiseApp extends StatelessWidget {
  const NoiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noise Guard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: C.skyBottom,
        colorScheme: ColorScheme.fromSeed(
            seedColor: C.navy, primary: C.navy, secondary: C.yellow),
      ),
      home: const HomeScreen(),
    );
  }
}

// ============================================================
//  SHARED WIDGETS
// ============================================================
class SkyBackground extends StatelessWidget {
  final Widget child;
  const SkyBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [C.skyTop, C.skyBottom],
        ),
      ),
      child: child,
    );
  }
}

class NavyCard extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  const NavyCard({super.key, required this.child, this.borderColor = C.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.navy,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4))
        ],
      ),
      child: child,
    );
  }
}

Widget sectionLabel(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(t,
          style: const TextStyle(
              color: C.navy,
              fontSize: 12,
              letterSpacing: 4,
              fontWeight: FontWeight.w600)),
    );

class GlowButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;
  const GlowButton(
      {super.key,
      required this.label,
      required this.icon,
      required this.onTap,
      this.primary = true});

  @override
  Widget build(BuildContext context) {
    final Color fg = primary ? C.navy : C.yellow;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: primary ? C.yellow : C.navy,
            borderRadius: BorderRadius.circular(16),
            border: primary ? null : Border.all(color: C.yellow, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: (primary ? C.yellow : C.navy).withAlpha(110),
                  blurRadius: 16)
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 20),
              const SizedBox(width: 10),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 3)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget topBar(BuildContext context, String title, String sub,
    {bool back = true, Widget? trailing}) {
  return Container(
    width: double.infinity,
    padding: EdgeInsets.fromLTRB(
        back ? 6 : 20, MediaQuery.of(context).padding.top + 12, 16, 14),
    decoration: const BoxDecoration(
      color: C.navy,
      border: Border(bottom: BorderSide(color: C.yellow, width: 2)),
    ),
    child: Row(
      children: [
        if (back)
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios_new, color: C.yellow, size: 20),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: C.yellow,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 5)),
              const SizedBox(height: 4),
              Text(sub,
                  style: const TextStyle(
                      color: C.muted, fontSize: 11, letterSpacing: 2)),
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );
}

Widget livePill() {
  return ListenableBuilder(
    listenable: app,
    builder: (_, __) {
      final on = app.connected;
      final c = on ? C.yellow : C.muted;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: c.withAlpha(30),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: c.withAlpha(160)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 9, color: c),
          const SizedBox(width: 8),
          Text(on ? 'LIVE' : 'OFFLINE',
              style: TextStyle(color: c, fontSize: 11, letterSpacing: 3)),
        ]),
      );
    },
  );
}

class RingPainter extends CustomPainter {
  final double value;
  final Color color;
  RingPainter(this.value, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 8;
    final bg = Paint()
      ..color = C.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, bg);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
        2 * math.pi * value.clamp(0.0, 1.0), false, fg);
  }

  @override
  bool shouldRepaint(covariant RingPainter old) =>
      old.value != value || old.color != color;
}

class RingGauge extends StatelessWidget {
  final double value; // 0..1
  final String text;
  final String unit;
  final String label;
  final Color color;
  const RingGauge(
      {super.key,
      required this.value,
      required this.text,
      required this.unit,
      required this.label,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 98,
          height: 98,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(size: const Size(98, 98), painter: RingPainter(value, color)),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text,
                      style: TextStyle(
                          color: color, fontSize: 22, fontWeight: FontWeight.bold)),
                  Text(unit,
                      style: const TextStyle(color: C.muted, fontSize: 10)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: TextStyle(color: color, fontSize: 11, letterSpacing: 3)),
      ],
    );
  }
}

Widget kv(String k, String v, {Color vColor = C.white}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: C.muted, fontSize: 13)),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right,
                style: TextStyle(
                    color: vColor, fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

// ============================================================
//  HOME SCREEN
// ============================================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _ip;

  @override
  void initState() {
    super.initState();
    _ip = TextEditingController(text: app.ip);
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  void _go(Widget w) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SkyBackground(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final r = app.current;
            final cat = r?.category ?? '--';
            final cc = r == null ? C.muted : catColor(r.category);
            return Column(
              children: [
                topBar(
                  context,
                  'NOISE GUARD',
                  app.ip.isEmpty
                      ? 'ENTER ESP32 IP BELOW'
                      : '${app.ip} · ${app.connected ? 'CONNECTED' : 'NOT CONNECTED'}',
                  back: false,
                  trailing: livePill(),
                ),
                Expanded(
                  child: SafeArea(
                    top: false,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                      children: [
                        sectionLabel('ESP32 CONNECTION'),
                        NavyCard(
                          child: Column(
                            children: [
                              TextField(
                                controller: _ip,
                                keyboardType: TextInputType.url,
                                style: const TextStyle(color: C.white),
                                decoration: InputDecoration(
                                  labelText: 'ESP32 IP address (shown on OLED)',
                                  labelStyle: const TextStyle(color: C.muted),
                                  hintText: 'e.g. 192.168.43.25',
                                  hintStyle: const TextStyle(color: C.border),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(color: C.border),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide:
                                        const BorderSide(color: C.yellow, width: 1.5),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              GlowButton(
                                label: 'CONNECT',
                                icon: Icons.wifi,
                                onTap: () {
                                  FocusScope.of(context).unfocus();
                                  app.setIp(_ip.text);
                                },
                              ),
                              if (app.error != null && app.ip.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(app.error!,
                                    style: const TextStyle(
                                        color: C.red, fontSize: 12, height: 1.4)),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        sectionLabel('LIVE READINGS'),
                        NavyCard(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              RingGauge(
                                value: (r?.relativeNoise ?? 0) / 100,
                                text: r == null
                                    ? '--'
                                    : r.relativeNoise.toStringAsFixed(1),
                                unit: 'rel',
                                label: 'NOISE',
                                color: cc == C.muted ? C.yellow : cc,
                              ),
                              RingGauge(
                                value: (r?.rawVariation ?? 0) / 4095,
                                text: r == null ? '--' : '${r.rawVariation}',
                                unit: 'raw',
                                label: 'RAW',
                                color: C.yellow,
                              ),
                              RingGauge(
                                value: (r?.satellites ?? 0) / 12,
                                text: r == null ? '--' : '${r.satellites}',
                                unit: 'sats',
                                label: 'GPS',
                                color: C.muted,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        NavyCard(
                          borderColor: cc,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('NOISE CATEGORY (RELATIVE)',
                                  style: TextStyle(
                                      color: C.muted, fontSize: 11, letterSpacing: 3)),
                              const SizedBox(height: 8),
                              Text(cat,
                                  style: TextStyle(
                                      color: cc,
                                      fontSize: 30,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 4)),
                              const SizedBox(height: 6),
                              const Text(
                                'Relative indicator from an uncalibrated analog sensor. Not dB.',
                                style: TextStyle(
                                    color: C.muted, fontSize: 11, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        NavyCard(
                          child: Column(
                            children: [
                              kv('GPS STATUS',
                                  r == null
                                      ? '--'
                                      : (r.gpsValid ? 'FIX' : 'NO FIX'),
                                  vColor: r != null && r.gpsValid
                                      ? C.green
                                      : C.yellow),
                              kv('LATITUDE',
                                  r?.lat == null ? '--' : r!.lat!.toStringAsFixed(6)),
                              kv('LONGITUDE',
                                  r?.lng == null ? '--' : r!.lng!.toStringAsFixed(6)),
                              kv('LAST UPDATED',
                                  app.lastUpdate == null
                                      ? '--'
                                      : DateFormat('hh:mm:ss a')
                                          .format(app.lastUpdate!)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        GlowButton(
                            label: 'OPEN MAP',
                            icon: Icons.map,
                            onTap: () => _go(const MapScreen())),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                            child: GlowButton(
                                label: 'HISTORY',
                                icon: Icons.history,
                                primary: false,
                                onTap: () => _go(const HistoryScreen())),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GlowButton(
                                label: 'DASHBOARD',
                                icon: Icons.insights,
                                primary: false,
                                onTap: () => _go(const DashboardScreen())),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ============================================================
//  MAP SCREEN (OpenStreetMap via flutter_map)
// ============================================================
class MapScreen extends StatefulWidget {
  final NoiseReading? focus;
  const MapScreen({super.key, this.focus});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mc = MapController();
  NoiseReading? _selected;
  bool _zones = false;

  LatLng? _bestPoint() {
    final f = widget.focus;
    if (f != null && f.hasLocation) return LatLng(f.lat!, f.lng!);
    final c = app.current;
    if (c != null && c.hasLocation) return LatLng(c.lat!, c.lng!);
    for (int i = app.history.length - 1; i >= 0; i--) {
      final h = app.history[i];
      if (h.hasLocation) return LatLng(h.lat!, h.lng!);
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.focus;
  }

  @override
  Widget build(BuildContext context) {
    final start = _bestPoint();
    return Scaffold(
      body: Column(
        children: [
          topBar(context, 'NOISE MAP', 'MONITORING POINTS', trailing: livePill()),
          Expanded(
            child: ListenableBuilder(
              listenable: app,
              builder: (context, _) {
                final live = app.current;
                final markers = <Marker>[
                  for (final r in app.history.where((e) => e.hasLocation))
                    Marker(
                      point: LatLng(r.lat!, r.lng!),
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: () => setState(() => _selected = r),
                        child: Icon(Icons.location_on,
                            size: 40,
                            color: catColor(r.category),
                            shadows: const [
                              Shadow(color: Colors.black54, blurRadius: 6)
                            ]),
                      ),
                    ),
                  if (live != null && live.hasLocation)
                    Marker(
                      point: LatLng(live.lat!, live.lng!),
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => setState(() => _selected = live),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: C.navy,
                            border: Border.all(color: C.yellow, width: 3),
                          ),
                          child: const Icon(Icons.sensors,
                              color: C.yellow, size: 20),
                        ),
                      ),
                    ),
                ];
                final circles = <CircleMarker>[
                  if (_zones)
                    for (final r in app.history.where((e) => e.hasLocation))
                      CircleMarker(
                        point: LatLng(r.lat!, r.lng!),
                        radius: kZoneRadiusM,
                        useRadiusInMeter: true,
                        color: catColor(r.category).withAlpha(70),
                        borderColor: catColor(r.category),
                        borderStrokeWidth: 1.5,
                      ),
                ];

                return Stack(
                  children: [
                    FlutterMap(
                      mapController: _mc,
                      options: MapOptions(
                        initialCenter: start ?? const LatLng(20.5937, 78.9629),
                        initialZoom: start == null ? 4.5 : 17,
                        onTap: (_, __) => setState(() => _selected = null),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName:
                              'com.example.noise_monitoring_app',
                        ),
                        CircleLayer(circles: circles),
                        MarkerLayer(markers: markers),
                      ],
                    ),
                    // legend
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: C.navy.withAlpha(235),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: C.border),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('RELATIVE NOISE',
                                style: TextStyle(
                                    color: C.muted,
                                    fontSize: 10,
                                    letterSpacing: 2)),
                            SizedBox(height: 6),
                            _LegendRow(C.green, 'LOW'),
                            _LegendRow(C.yellow, 'MODERATE'),
                            _LegendRow(C.red, 'HIGH'),
                          ],
                        ),
                      ),
                    ),
                    // buttons
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Column(
                        children: [
                          _MapBtn(Icons.refresh, () {
                            app.fetchNow();
                            setState(() {});
                          }),
                          const SizedBox(height: 10),
                          _MapBtn(Icons.my_location, () {
                            final c = app.current;
                            if (c != null && c.hasLocation) {
                              _mc.move(LatLng(c.lat!, c.lng!), 17);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('No GPS fix from the ESP32 yet.')));
                            }
                          }),
                          const SizedBox(height: 10),
                          _MapBtn(Icons.blur_circular, () {
                            setState(() => _zones = !_zones);
                          }, active: _zones),
                        ],
                      ),
                    ),
                    const Positioned(
                      left: 6,
                      bottom: 4,
                      child: Text('© OpenStreetMap contributors',
                          style: TextStyle(color: Colors.black87, fontSize: 10)),
                    ),
                    if (_selected != null)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 24,
                        child: _PointCard(
                            r: _selected!,
                            onClose: () => setState(() => _selected = null)),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final Color color;
  final String text;
  const _LegendRow(this.color, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(Icons.location_on, color: color, size: 18),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(color: C.white, fontSize: 12, letterSpacing: 1)),
        ]),
      );
}

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  const _MapBtn(this.icon, this.onTap, {this.active = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: active ? C.yellow : C.navy,
            shape: BoxShape.circle,
            border: Border.all(color: C.yellow, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
          ),
          child: Icon(icon, color: active ? C.navy : C.yellow, size: 22),
        ),
      );
}

class _PointCard extends StatelessWidget {
  final NoiseReading r;
  final VoidCallback onClose;
  const _PointCard({required this.r, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final cc = catColor(r.category);
    return NavyCard(
      borderColor: cc,
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.location_on, color: cc),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('NOISE MONITORING POINT',
                    style: TextStyle(
                        color: C.yellow,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2)),
              ),
              GestureDetector(
                  onTap: onClose,
                  child: const Icon(Icons.close, color: C.muted, size: 20)),
            ],
          ),
          const Divider(color: C.border, height: 18),
          kv('Latitude', r.lat?.toStringAsFixed(6) ?? '--'),
          kv('Longitude', r.lng?.toStringAsFixed(6) ?? '--'),
          kv('Reading',
              '${r.relativeNoise.toStringAsFixed(1)} rel  (raw ${r.rawVariation})'),
          kv('Category', r.category, vColor: cc),
          kv('Time', fmtTime(r.time)),
        ],
      ),
    );
  }
}

// ============================================================
//  HISTORY SCREEN
// ============================================================
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.navy,
        title: const Text('Clear history?', style: TextStyle(color: C.yellow)),
        content: const Text('All saved measurement points will be deleted.',
            style: TextStyle(color: C.white)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('CANCEL')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('DELETE', style: TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok == true) app.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SkyBackground(
        child: Column(
          children: [
            topBar(
              context,
              'HISTORY',
              'SAVED MEASUREMENT POINTS',
              trailing: IconButton(
                onPressed: () => _confirmClear(context),
                icon: const Icon(Icons.delete_outline, color: C.yellow),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: app,
                builder: (context, _) {
                  final items = app.history.reversed.toList();
                  if (items.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(30),
                        child: Text(
                          'No saved points yet.\nPoints are saved only when the ESP32 has a valid GPS fix.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: C.navy, height: 1.5),
                        ),
                      ),
                    );
                  }
                  return SafeArea(
                    top: false,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final r = items[i];
                        final cc = catColor(r.category);
                        return GestureDetector(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => MapScreen(focus: r))),
                          child: NavyCard(
                            borderColor: cc.withAlpha(150),
                            child: Row(
                              children: [
                                Icon(Icons.location_on, color: cc, size: 30),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          '${r.relativeNoise.toStringAsFixed(1)} rel · ${r.category}',
                                          style: TextStyle(
                                              color: cc,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15)),
                                      const SizedBox(height: 4),
                                      Text(
                                          '${r.lat!.toStringAsFixed(5)}, ${r.lng!.toStringAsFixed(5)}',
                                          style: const TextStyle(
                                              color: C.white, fontSize: 12)),
                                      const SizedBox(height: 2),
                                      Text(fmtTime(r.time),
                                          style: const TextStyle(
                                              color: C.muted, fontSize: 11)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.map, color: C.yellow, size: 20),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
//  DASHBOARD SCREEN
// ============================================================
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  Widget _stat(String label, String value, Color color) {
    return Expanded(
      child: NavyCard(
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: C.muted, fontSize: 10, letterSpacing: 2)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SkyBackground(
        child: Column(
          children: [
            topBar(context, 'DASHBOARD', 'SESSION SUMMARY', trailing: livePill()),
            Expanded(
              child: ListenableBuilder(
                listenable: app,
                builder: (context, _) {
                  final cur = app.current;
                  final spots = <FlSpot>[
                    for (int i = 0; i < app.session.length; i++)
                      FlSpot(i.toDouble(), app.session[i].relativeNoise),
                  ];
                  String f(double? v) => v == null ? '--' : v.toStringAsFixed(1);
                  return SafeArea(
                    top: false,
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Row(children: [
                          _stat('CURRENT', f(cur?.relativeNoise), C.yellow),
                          const SizedBox(width: 12),
                          _stat('SESSION MAX', f(app.sessionMax), C.red),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          _stat('SESSION MIN', f(app.sessionMin), C.green),
                          const SizedBox(width: 12),
                          _stat('LOCATIONS', '${app.locationCount}', C.white),
                        ]),
                        const SizedBox(height: 20),
                        sectionLabel('RELATIVE NOISE OVER TIME'),
                        NavyCard(
                          child: SizedBox(
                            height: 240,
                            child: spots.length < 2
                                ? const Center(
                                    child: Text('Waiting for live data...',
                                        style: TextStyle(color: C.muted)))
                                : LineChart(
                                    LineChartData(
                                      minY: 0,
                                      maxY: 100,
                                      minX: 0,
                                      maxX: (spots.length - 1).toDouble(),
                                      borderData: FlBorderData(show: false),
                                      gridData: const FlGridData(
                                        show: true,
                                        drawVerticalLine: false,
                                        horizontalInterval: 25,
                                      ),
                                      titlesData: FlTitlesData(
                                        topTitles: const AxisTitles(
                                            sideTitles:
                                                SideTitles(showTitles: false)),
                                        rightTitles: const AxisTitles(
                                            sideTitles:
                                                SideTitles(showTitles: false)),
                                        bottomTitles: const AxisTitles(
                                            sideTitles:
                                                SideTitles(showTitles: false)),
                                        leftTitles: AxisTitles(
                                          sideTitles: SideTitles(
                                            showTitles: true,
                                            reservedSize: 36,
                                            interval: 25,
                                            getTitlesWidget: (v, meta) => Text(
                                                v.toInt().toString(),
                                                style: const TextStyle(
                                                    color: C.muted, fontSize: 10)),
                                          ),
                                        ),
                                      ),
                                      lineBarsData: [
                                        LineChartBarData(
                                          spots: spots,
                                          isCurved: true,
                                          color: C.yellow,
                                          barWidth: 3,
                                          dotData: const FlDotData(show: false),
                                          belowBarData: BarAreaData(
                                              show: true,
                                              color: C.yellow.withAlpha(40)),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        NavyCard(
                          child: Column(children: [
                            kv('SAVED POINTS', '${app.history.length}'),
                            kv('SESSION SAMPLES', '${app.session.length}'),
                          ]),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Values are relative indicators from an uncalibrated analog '
                          'sensor, not calibrated dB(A) and not official noise levels.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: C.navy, fontSize: 11, height: 1.5),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
