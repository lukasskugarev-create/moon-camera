import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'moon_calculator.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  MoonPosition? _moonPosition;
  Position? _devicePosition;
  double _deviceAzimuth = 0;
  double _devicePitch = 0;
  bool _isTakingPhoto = false;
  String _statusMessage = 'Inicializujem...';

  // Exposure & zoom
  double _exposureOffset = 0.0;
  double _minExposure = -4.0;
  double _maxExposure = 4.0;
  double _zoomLevel = 1.0;
  double _maxZoom = 8.0;
  bool _showControls = false;

  // Timer
  int _timerSeconds = 0;
  int _timerCountdown = 0;
  Timer? _countdownTimer;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _moonUpdateTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _initCamera();
    await _getLocation();
    _startCompass();
    _startMoonUpdates();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.location,
      Permission.photos,
    ].request();
  }

  void _startCompass() {
    FlutterCompass.events?.listen((event) {
      if (mounted && event.heading != null) {
        setState(() => _deviceAzimuth = event.heading!);
      }
    });
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) return;
      _controller = CameraController(
        _cameras!.first,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _controller!.initialize();
      await _controller!.setExposureMode(ExposureMode.auto);
      await _controller!.setFocusMode(FocusMode.auto);
      _minExposure = await _controller!.getMinExposureOffset();
      _maxExposure = await _controller!.getMaxExposureOffset();
      _maxZoom = await _controller!.getMaxZoomLevel();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _statusMessage = 'Chyba kamery: $e');
    }
  }

  Future<void> _getLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _statusMessage = 'GPS nie je zapnuté');
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _devicePosition = pos;
        _statusMessage = 'GPS OK';
      });
      _updateMoonPosition();
    } catch (e) {
      setState(() => _statusMessage = 'Chyba GPS: $e');
    }
  }

  void _startMoonUpdates() {
    _moonUpdateTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _updateMoonPosition();
    });
  }

  void _updateMoonPosition() {
    if (_devicePosition == null) return;
    final moon = MoonCalculator.calculate(
      _devicePosition!.latitude,
      _devicePosition!.longitude,
      DateTime.now(),
    );
    setState(() => _moonPosition = moon);
  }

  Offset? _getMoonScreenOffset() {
    if (_moonPosition == null) return null;
    double azDiff = _moonPosition!.azimuth - _deviceAzimuth;
    while (azDiff > 180) azDiff -= 360;
    while (azDiff < -180) azDiff += 360;
    double altDiff = _moonPosition!.altitude - _devicePitch;
    final double nx = azDiff / 30.0;
    final double ny = -altDiff / 22.5;
    return Offset(nx, ny);
  }

  bool _isMoonInFrame() {
    final offset = _getMoonScreenOffset();
    if (offset == null) return false;
    return offset.dx.abs() < 0.85 && offset.dy.abs() < 0.85;
  }

  Future<void> _setExposure(double value) async {
    if (_controller == null) return;
    setState(() => _exposureOffset = value);
    await _controller!.setExposureMode(ExposureMode.locked);
    await _controller!.setExposureOffset(value);
  }

  Future<void> _setZoom(double value) async {
    if (_controller == null) return;
    setState(() => _zoomLevel = value);
    await _controller!.setZoomLevel(value);
  }

  void _startTimerAndShoot() {
    if (_timerSeconds == 0) {
      _doTakePicture();
      return;
    }
    setState(() => _timerCountdown = _timerSeconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _timerCountdown--);
      if (_timerCountdown <= 0) {
        t.cancel();
        _doTakePicture();
      }
    });
  }

  Future<void> _doTakePicture() async {
    if (_controller == null || _isTakingPhoto) return;
    setState(() => _isTakingPhoto = true);
    try {
      if (_isMoonInFrame()) {
        final offset = _getMoonScreenOffset()!;
        final point = Offset((offset.dx + 1) / 2, (offset.dy + 1) / 2);
        await _controller!.setExposurePoint(point);
        await _controller!.setFocusPoint(point);
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final file = await _controller!.takePicture();
      setState(() => _isTakingPhoto = false);
      _showPhotoPreview(file.path);
    } catch (e) {
      setState(() => _isTakingPhoto = false);
    }
  }

  void _showPhotoPreview(String path) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              child: Image.file(File(path)),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.delete, color: Colors.red),
                    label: const Text('Zahodiť', style: TextStyle(color: Colors.red)),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Fotka uložená!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                    icon: const Icon(Icons.save, color: Colors.green),
                    label: const Text('Uložiť', style: TextStyle(color: Colors.green)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getMoonPhase() {
    final now = DateTime.now();
    final dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
    final cycle = (dayOfYear % 29.5);
    if (cycle < 1.5) return '🌑 Nov';
    if (cycle < 7.4) return '🌒 Dorast';
    if (cycle < 8.9) return '🌓 1. štvrtina';
    if (cycle < 14.8) return '🌔 Pribúda';
    if (cycle < 16.3) return '🌕 Spln';
    if (cycle < 22.1) return '🌖 Ubúda';
    if (cycle < 23.6) return '🌗 Posl. štvrtina';
    return '🌘 Ubúdajúci';
  }

  String _getMoonRiseTime() {
    if (_devicePosition == null) return '--:--';
    final now = DateTime.now();
    for (int h = 0; h < 24; h++) {
      final t1 = DateTime(now.year, now.month, now.day, h, 0);
      final t2 = DateTime(now.year, now.month, now.day, h + 1 < 24 ? h + 1 : 23, 59);
      final m1 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t1);
      final m2 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t2);
      if (m1.altitude <= 0 && m2.altitude > 0) {
        return '${h.toString().padLeft(2, '0')}:00';
      }
    }
    return '--:--';
  }

  String _getMoonSetTime() {
    if (_devicePosition == null) return '--:--';
    final now = DateTime.now();
    for (int h = 0; h < 24; h++) {
      final t1 = DateTime(now.year, now.month, now.day, h, 0);
      final t2 = DateTime(now.year, now.month, now.day, h + 1 < 24 ? h + 1 : 23, 59);
      final m1 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t1);
      final m2 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t2);
      if (m1.altitude > 0 && m2.altitude <= 0) {
        return '${h.toString().padLeft(2, '0')}:00';
      }
    }
    return '--:--';
  }

  @override
  void dispose() {
    _moonUpdateTimer?.cancel();
    _countdownTimer?.cancel();
    _pulseController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_controller != null && _controller!.value.isInitialized)
            CameraPreview(_controller!),
          _buildMoonOverlay(),
          _buildTopBar(),
          if (_showControls) _buildControlsPanel(),
          _buildBottomControls(),
          if (_timerCountdown > 0) _buildCountdown(),
        ],
      ),
    );
  }

  Widget _buildCountdown() {
    return Center(
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.6),
          border: Border.all(color: Colors.white, width: 3),
        ),
        child: Center(
          child: Text(
            '$_timerCountdown',
            style: const TextStyle(color: Colors.white, fontSize: 60, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildMoonOverlay() {
    if (_moonPosition == null) return const SizedBox();
    final inFrame = _isMoonInFrame();
    final offset = _getMoonScreenOffset();

    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final cx = w / 2;
      final cy = h / 2;

      if (inFrame && offset != null) {
        final moonX = cx + offset.dx * cx * 0.8;
        final moonY = cy + offset.dy * cy * 0.8;
        return AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (_, __) => CustomPaint(
            painter: MoonCirclePainter(center: Offset(moonX, moonY), radius: 60 * _pulseAnimation.value),
            child: const SizedBox.expand(),
          ),
        );
      } else if (offset != null) {
        final angle = atan2(offset.dy, offset.dx);
        return CustomPaint(
          painter: MoonArrowPainter(centerX: cx, centerY: cy, angle: angle, altitude: _moonPosition!.altitude),
          child: const SizedBox.expand(),
        );
      }
      return const SizedBox();
    });
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withOpacity(0.8), Colors.transparent],
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('🌙 MOON CAMERA',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  Row(
                    children: [
                      if (_moonPosition != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _moonPosition!.isAboveHorizon ? Colors.blue.withOpacity(0.3) : Colors.red.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _moonPosition!.isAboveHorizon ? Colors.blue : Colors.red),
                          ),
                          child: Text(
                            _moonPosition!.isAboveHorizon ? '↑ NAD' : '↓ POD',
                            style: TextStyle(
                              color: _moonPosition!.isAboveHorizon ? Colors.blue[200] : Colors.red[200],
                              fontSize: 10, fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() => _showControls = !_showControls),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: _showControls ? Colors.white.withOpacity(0.3) : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white38),
                          ),
                          child: const Icon(Icons.tune, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_moonPosition != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _infoChip('AZ', '${_moonPosition!.azimuth.toStringAsFixed(1)}°'),
                    const SizedBox(width: 6),
                    _infoChip('ALT', '${_moonPosition!.altitude.toStringAsFixed(1)}°'),
                    const SizedBox(width: 6),
                    _infoChip('DIST', '${(_moonPosition!.distance / 1000).toStringAsFixed(0)}k km'),
                  ],
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_getMoonPhase(), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  const SizedBox(width: 12),
                  Text('🌅 ${_getMoonRiseTime()}  🌇 ${_getMoonSetTime()}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: RichText(
        text: TextSpan(children: [
          TextSpan(text: '$label ', style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10)),
          TextSpan(text: value, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _buildControlsPanel() {
    return Positioned(
      top: 140, left: 16, right: 16,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.brightness_6, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text('Expozícia', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const Spacer(),
              Text(_exposureOffset.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
            Slider(
              value: _exposureOffset,
              min: _minExposure, max: _maxExposure, divisions: 16,
              activeColor: Colors.white, inactiveColor: Colors.white24,
              onChanged: _setExposure,
            ),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.zoom_in, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text('Zoom', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const Spacer(),
              Text('${_zoomLevel.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
            Slider(
              value: _zoomLevel,
              min: 1.0, max: _maxZoom,
              activeColor: Colors.white, inactiveColor: Colors.white24,
              onChanged: _setZoom,
            ),
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.timer, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text('Časovač', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const Spacer(),
              ...[0, 3, 5, 10].map((s) => GestureDetector(
                onTap: () => setState(() => _timerSeconds = s),
                child: Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _timerSeconds == s ? Colors.white : Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    s == 0 ? 'OFF' : '${s}s',
                    style: TextStyle(
                      color: _timerSeconds == s ? Colors.black : Colors.white,
                      fontSize: 11, fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final inFrame = _isMoonInFrame();
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 32),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: [Colors.black.withOpacity(0.8), Colors.transparent],
            ),
          ),
          child: Column(
            children: [
              Text(
                _timerCountdown > 0
                    ? '⏱️ Fotím za $_timerCountdown s...'
                    : inFrame
                        ? '🎯 Mesiac je v zábere! Sprav fotku!'
                        : _moonPosition != null
                            ? (_moonPosition!.isAboveHorizon ? '👆 Namiery telefón podľa šípky' : '😔 Mesiac je pod horizontom')
                            : _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: inFrame ? Colors.greenAccent : Colors.white70,
                  fontSize: 13,
                  fontWeight: inFrame ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_timerSeconds > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white12, borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text('⏱ ${_timerSeconds}s', style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  GestureDetector(
                    onTap: _timerCountdown > 0 ? null : _startTimerAndShoot,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isTakingPhoto || _timerCountdown > 0
                            ? Colors.white.withOpacity(0.3)
                            : inFrame ? Colors.white : Colors.white.withOpacity(0.4),
                        border: Border.all(color: inFrame ? Colors.white : Colors.white38, width: 3),
                        boxShadow: inFrame
                            ? [BoxShadow(color: Colors.white.withOpacity(0.4), blurRadius: 20, spreadRadius: 5)]
                            : null,
                      ),
                      child: _isTakingPhoto
                          ? const Center(child: CircularProgressIndicator(color: Colors.white))
                          : Icon(Icons.camera, size: 36, color: inFrame ? Colors.black : Colors.white54),
                    ),
                  ),
                  if (_zoomLevel > 1.0)
                    Container(
                      margin: const EdgeInsets.only(left: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white12, borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text('🔭 ${_zoomLevel.toStringAsFixed(1)}x',
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MoonCirclePainter extends CustomPainter {
  final Offset center;
  final double radius;
  MoonCirclePainter({required this.center, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(center, radius, Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15));
    canvas.drawCircle(center, radius, Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);

    final lp = Paint()..color = Colors.white.withOpacity(0.5)..strokeWidth = 1;
    canvas.drawLine(Offset(center.dx, center.dy - radius - 10), Offset(center.dx, center.dy - radius + 10), lp);
    canvas.drawLine(Offset(center.dx, center.dy + radius - 10), Offset(center.dx, center.dy + radius + 10), lp);
    canvas.drawLine(Offset(center.dx - radius - 10, center.dy), Offset(center.dx - radius + 10, center.dy), lp);
    canvas.drawLine(Offset(center.dx + radius - 10, center.dy), Offset(center.dx + radius + 10, center.dy), lp);
    canvas.drawCircle(center, 3, Paint()..color = Colors.white.withOpacity(0.6)..style = PaintingStyle.fill);

    final tp = TextPainter(
      text: TextSpan(text: '🌙 MESIAC',
        style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 4)])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + radius + 14));
  }

  @override
  bool shouldRepaint(MoonCirclePainter old) => old.center != center || old.radius != radius;
}

class MoonArrowPainter extends CustomPainter {
  final double centerX, centerY, angle, altitude;
  MoonArrowPainter({required this.centerX, required this.centerY, required this.angle, required this.altitude});

  @override
  void paint(Canvas canvas, Size size) {
    final ax = centerX + cos(angle) * 120.0;
    final ay = centerY + sin(angle) * 120.0;

    canvas.drawCircle(Offset(ax, ay), 36, Paint()..color = Colors.black.withOpacity(0.4));
    canvas.drawCircle(Offset(ax, ay), 36, Paint()
      ..color = Colors.white.withOpacity(0.6)..style = PaintingStyle.stroke..strokeWidth = 1.5);

    canvas.save();
    canvas.translate(ax, ay);
    canvas.rotate(angle);
    canvas.drawPath(
      Path()..moveTo(20, 0)..lineTo(-10, -10)..lineTo(-5, 0)..lineTo(-10, 10)..close(),
      Paint()..color = Colors.white..style = PaintingStyle.fill,
    );
    canvas.restore();

    final tp = TextPainter(
      text: const TextSpan(text: '🌙', style: TextStyle(fontSize: 16)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(ax - tp.width / 2, ay - tp.height / 2 - 20));

    final altTp = TextPainter(
      text: TextSpan(text: '${altitude.toStringAsFixed(0)}°',
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    altTp.paint(canvas, Offset(ax - altTp.width / 2, ay + 14));
  }

  @override
  bool shouldRepaint(MoonArrowPainter old) => true;
}