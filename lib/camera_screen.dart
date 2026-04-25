import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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
  double _deviceAzimuth = 0; // compass heading (placeholder)
  double _devicePitch = 0;   // tilt angle (placeholder)
  bool _isReady = false;
  bool _isTakingPhoto = false;
  String? _lastPhotoPath;
  String _statusMessage = 'Inicializujem...';

  late AnimationController _pulseController;
  late AnimationController _arrowController;
  late Animation<double> _pulseAnimation;

  Timer? _moonUpdateTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _arrowController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _initCamera();
    await _getLocation();
    _startMoonUpdates();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.location,
    ].request();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _statusMessage = 'Kamera nedostupná');
        return;
      }
      _controller = CameraController(
        _cameras!.first,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _controller!.initialize();
      // Set exposure mode for moon photography
      await _controller!.setExposureMode(ExposureMode.auto);
      await _controller!.setFocusMode(FocusMode.auto);

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
        _isReady = true;
        _statusMessage = 'GPS: ${pos.latitude.toStringAsFixed(3)}, ${pos.longitude.toStringAsFixed(3)}';
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
    setState(() {
      _moonPosition = moon;
    });
  }

  // Calculate where moon appears on screen relative to device orientation
  // Returns offset from center (-1 to 1 in each axis), null if behind
  Offset? _getMoonScreenOffset() {
    if (_moonPosition == null) return null;

    // Difference between moon azimuth and device heading
    double azDiff = _moonPosition!.azimuth - _deviceAzimuth;
    // Normalize to -180..180
    while (azDiff > 180) azDiff -= 360;
    while (azDiff < -180) azDiff += 360;

    // Altitude difference (device pitch vs moon altitude)
    double altDiff = _moonPosition!.altitude - _devicePitch;

    // If moon is way off screen (>45 degrees), just show arrow direction
    // FOV assumption: ~60 degrees horizontal, ~45 vertical
    final double hFov = 60.0;
    final double vFov = 45.0;

    final double nx = azDiff / (hFov / 2); // normalized -1..1
    final double ny = -altDiff / (vFov / 2); // inverted y

    return Offset(nx, ny);
  }

  bool _isMoonInFrame() {
    final offset = _getMoonScreenOffset();
    if (offset == null) return false;
    return offset.dx.abs() < 0.85 && offset.dy.abs() < 0.85;
  }

  Future<void> _lockExposureOnMoon() async {
    if (_controller == null || !_isMoonInFrame()) return;
    final size = MediaQuery.of(context).size;
    final offset = _getMoonScreenOffset()!;
    // Convert to camera point (0-1)
    final point = Offset(
      (offset.dx + 1) / 2,
      (offset.dy + 1) / 2,
    );
    await _controller!.setExposurePoint(point);
    await _controller!.setFocusPoint(point);
  }

  Future<void> _takePicture() async {
    if (_controller == null || _isTakingPhoto) return;
    setState(() => _isTakingPhoto = true);

    try {
      await _lockExposureOnMoon();
      await Future.delayed(const Duration(milliseconds: 500)); // stabilize
      final file = await _controller!.takePicture();
      setState(() {
        _lastPhotoPath = file.path;
        _isTakingPhoto = false;
      });
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
            Image.file(File(path)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Zahodiť', style: TextStyle(color: Colors.red)),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Fotka uložená!')),
                    );
                  },
                  child: const Text('Uložiť', style: TextStyle(color: Colors.green)),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _moonUpdateTimer?.cancel();
    _pulseController.dispose();
    _arrowController.dispose();
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
          // Camera preview
          if (_controller != null && _controller!.value.isInitialized)
            CameraPreview(_controller!),

          // Moon overlay
          _buildMoonOverlay(),

          // Top info bar
          _buildTopBar(),

          // Bottom controls
          _buildBottomControls(),
        ],
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
        // Draw circle around moon position
        final moonX = cx + offset.dx * cx * 0.8;
        final moonY = cy + offset.dy * cy * 0.8;

        return AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (_, __) => CustomPaint(
            painter: MoonCirclePainter(
              center: Offset(moonX, moonY),
              radius: 60 * _pulseAnimation.value,
            ),
            child: const SizedBox.expand(),
          ),
        );
      } else if (offset != null) {
        // Draw arrow pointing toward moon
        final angle = atan2(offset.dy, offset.dx);
        return CustomPaint(
          painter: MoonArrowPainter(
            centerX: cx,
            centerY: cy,
            angle: angle,
            altitude: _moonPosition!.altitude,
          ),
          child: const SizedBox.expand(),
        );
      }
      return const SizedBox();
    });
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withOpacity(0.7), Colors.transparent],
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '🌙 MOON CAMERA',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                  if (_moonPosition != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _moonPosition!.isAboveHorizon
                            ? Colors.blue.withOpacity(0.3)
                            : Colors.red.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _moonPosition!.isAboveHorizon
                              ? Colors.blue
                              : Colors.red,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        _moonPosition!.isAboveHorizon ? '↑ NAD HORIZONTOM' : '↓ POD HORIZONTOM',
                        style: TextStyle(
                          color: _moonPosition!.isAboveHorizon ? Colors.blue[200] : Colors.red[200],
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              if (_moonPosition != null) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _infoChip('AZ', '${_moonPosition!.azimuth.toStringAsFixed(1)}°'),
                    const SizedBox(width: 8),
                    _infoChip('ALT', '${_moonPosition!.altitude.toStringAsFixed(1)}°'),
                    const SizedBox(width: 8),
                    _infoChip('DIST', '${(_moonPosition!.distance / 1000).toStringAsFixed(0)}k km'),
                  ],
                ),
              ],
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
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final inFrame = _isMoonInFrame();

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 32),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withOpacity(0.8), Colors.transparent],
            ),
          ),
          child: Column(
            children: [
              // Status tip
              Text(
                inFrame
                    ? '🎯 Mesiac je v zábere! Sprav fotku!'
                    : _moonPosition != null
                        ? (_moonPosition!.isAboveHorizon
                            ? '👆 Namiery telefón podľa šípky'
                            : '😔 Mesiac je teraz pod horizontom')
                        : _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: inFrame ? Colors.greenAccent : Colors.white70,
                  fontSize: 13,
                  fontWeight: inFrame ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 20),
              // Shutter button
              GestureDetector(
                onTap: inFrame ? _takePicture : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isTakingPhoto
                        ? Colors.white.withOpacity(0.3)
                        : inFrame
                            ? Colors.white
                            : Colors.white.withOpacity(0.3),
                    border: Border.all(
                      color: inFrame ? Colors.white : Colors.white38,
                      width: 3,
                    ),
                    boxShadow: inFrame
                        ? [
                            BoxShadow(
                              color: Colors.white.withOpacity(0.3),
                              blurRadius: 20,
                              spreadRadius: 5,
                            )
                          ]
                        : null,
                  ),
                  child: _isTakingPhoto
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : Icon(
                          Icons.camera,
                          size: 36,
                          color: inFrame ? Colors.black : Colors.white38,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Painter for the moon circle overlay
class MoonCirclePainter extends CustomPainter {
  final Offset center;
  final double radius;

  MoonCirclePainter({required this.center, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    // Outer glow
    final glowPaint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
    canvas.drawCircle(center, radius, glowPaint);

    // Main circle
    final circlePaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(center, radius, circlePaint);

    // Crosshair lines
    final linePaint = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..strokeWidth = 1;

    // Top tick
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 10),
      Offset(center.dx, center.dy - radius + 10),
      linePaint,
    );
    // Bottom tick
    canvas.drawLine(
      Offset(center.dx, center.dy + radius - 10),
      Offset(center.dx, center.dy + radius + 10),
      linePaint,
    );
    // Left tick
    canvas.drawLine(
      Offset(center.dx - radius - 10, center.dy),
      Offset(center.dx - radius + 10, center.dy),
      linePaint,
    );
    // Right tick
    canvas.drawLine(
      Offset(center.dx + radius - 10, center.dy),
      Offset(center.dx + radius + 10, center.dy),
      linePaint,
    );

    // Center dot
    final dotPaint = Paint()
      ..color = Colors.white.withOpacity(0.6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3, dotPaint);

    // "MESIAC" label
    final tp = TextPainter(
      text: TextSpan(
        text: '🌙 MESIAC',
        style: TextStyle(
          color: Colors.white.withOpacity(0.9),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + radius + 14));
  }

  @override
  bool shouldRepaint(MoonCirclePainter old) =>
      old.center != center || old.radius != radius;
}

// Painter for the directional arrow
class MoonArrowPainter extends CustomPainter {
  final double centerX, centerY, angle, altitude;

  MoonArrowPainter({
    required this.centerX,
    required this.centerY,
    required this.angle,
    required this.altitude,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final arrowRadius = 120.0;
    final ax = centerX + cos(angle) * arrowRadius;
    final ay = centerY + sin(angle) * arrowRadius;

    // Arrow background circle
    final bgPaint = Paint()
      ..color = Colors.black.withOpacity(0.4)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(ax, ay), 36, bgPaint);

    final borderPaint = Paint()
      ..color = Colors.white.withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(Offset(ax, ay), 36, borderPaint);

    // Draw arrow
    canvas.save();
    canvas.translate(ax, ay);
    canvas.rotate(angle);

    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(20, 0)
      ..lineTo(-10, -10)
      ..lineTo(-5, 0)
      ..lineTo(-10, 10)
      ..close();
    canvas.drawPath(path, arrowPaint);
    canvas.restore();

    // Moon emoji
    final tp = TextPainter(
      text: const TextSpan(text: '🌙', style: TextStyle(fontSize: 16)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(ax - tp.width / 2, ay - tp.height / 2 - 20));

    // Altitude info
    final altTp = TextPainter(
      text: TextSpan(
        text: '${altitude.toStringAsFixed(0)}°',
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    altTp.paint(canvas, Offset(ax - altTp.width / 2, ay + 14));
  }

  @override
  bool shouldRepaint(MoonArrowPainter old) => true;
}
