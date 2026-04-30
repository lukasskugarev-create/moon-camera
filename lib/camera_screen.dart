import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
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
  int _selectedCameraIndex = 0;
  bool _isSwitchingCamera = false;
  MoonPosition? _moonPosition;
  Position? _devicePosition;
  double _deviceAzimuth = 0;
  double _devicePitch = 0;
  bool _isTakingPhoto = false;
  String _statusMessage = 'Inicializujem...';

  double _exposureOffset = 0.0;
  double _minExposure = -4.0;
  double _maxExposure = 4.0;
  double _zoomLevel = 1.0;
  double _maxZoom = 8.0;
  bool _showControls = false;
  bool _nightMode = false;

  int _timerSeconds = 0;
  int _timerCountdown = 0;
  Timer? _countdownTimer;

  // Tap-to-lock
  Offset? _lockedMoonPosition; // screen position where user tapped
  bool get _isLocked => _lockedMoonPosition != null;

  StreamSubscription? _accelerometerSubscription;

  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late AnimationController _lockAnimController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _rotateAnimation;
  late Animation<double> _lockAnimation;
  Timer? _moonUpdateTimer;

  List<String> get _lensLabels {
    if (_cameras == null) return [];
    switch (_cameras!.length) {
      case 1: return ['1x'];
      case 2: return ['1x', '2x'];
      case 3: return ['0.5x', '1x', '2x'];
      case 4: return ['0.5x', '1x', '2x', '3x'];
      default: return List.generate(_cameras!.length, (i) => '${i + 1}x');
    }
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _pulseController = AnimationController(duration: const Duration(seconds: 2), vsync: this)..repeat(reverse: true);
    _rotateController = AnimationController(duration: const Duration(seconds: 20), vsync: this)..repeat();
    _lockAnimController = AnimationController(duration: const Duration(milliseconds: 400), vsync: this);
    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _rotateAnimation = Tween<double>(begin: 0, end: 2 * pi).animate(_rotateController);
    _lockAnimation = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _lockAnimController, curve: Curves.elasticOut));
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _initCamera();
    await _getLocation();
    _startCompass();
    _startAccelerometer();
    _startMoonUpdates();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.location, Permission.photos].request();
  }

  void _startCompass() {
    FlutterCompass.events?.listen((event) {
      if (mounted && event.heading != null) {
        setState(() => _deviceAzimuth = event.heading!);
      }
    });
  }

  void _startAccelerometer() {
    _accelerometerSubscription = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!mounted) return;
      final pitch = atan2(-event.z, sqrt(event.x * event.x + event.y * event.y)) * 180 / pi;
      setState(() => _devicePitch = pitch);
    });
  }

  Future<void> _initCamera({int index = 0}) async {
    try {
      final allCameras = await availableCameras();
      final backCameras = allCameras.where((c) => c.lensDirection == CameraLensDirection.back).toList();
      if (backCameras.isEmpty) return;
      _cameras = backCameras;

      final safeIndex = index.clamp(0, _cameras!.length - 1);
      final oldController = _controller;
      _controller = null;
      if (mounted) setState(() {});
      await oldController?.dispose();

      final newController = CameraController(_cameras![safeIndex], ResolutionPreset.max, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await newController.initialize();
      await newController.setExposureMode(ExposureMode.auto);
      await newController.setFocusMode(FocusMode.auto);

      final minExp = await newController.getMinExposureOffset();
      final maxExp = await newController.getMaxExposureOffset();
      final maxZoom = await newController.getMaxZoomLevel();

      if (mounted) {
        setState(() {
          _controller = newController;
          _selectedCameraIndex = safeIndex;
          _minExposure = minExp;
          _maxExposure = maxExp;
          _maxZoom = maxZoom.clamp(1.0, 10.0);
          _zoomLevel = 1.0;
          _exposureOffset = 0.0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Chyba kamery: $e');
    }
  }

  Future<void> _switchCamera(int index) async {
    if (_cameras == null || index >= _cameras!.length) return;
    if (index == _selectedCameraIndex || _isSwitchingCamera) return;
    setState(() { _isSwitchingCamera = true; _lockedMoonPosition = null; });
    await _initCamera(index: index);
    if (mounted) setState(() => _isSwitchingCamera = false);
  }

  Future<void> _getLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) { setState(() => _statusMessage = 'GPS nie je zapnuté'); return; }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() { _devicePosition = pos; _statusMessage = 'GPS OK'; });
      _updateMoonPosition();
    } catch (e) {
      setState(() => _statusMessage = 'Chyba GPS: $e');
    }
  }

  void _startMoonUpdates() {
    _moonUpdateTimer = Timer.periodic(const Duration(seconds: 10), (_) => _updateMoonPosition());
  }

  void _updateMoonPosition() {
    if (_devicePosition == null) return;
    final moon = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, DateTime.now());
    setState(() => _moonPosition = moon);
  }

  void _onTapScreen(TapUpDetails details) {
    if (_isLocked) return; // already locked, ignore
    final pos = details.localPosition;
    setState(() => _lockedMoonPosition = pos);
    _lockAnimController.forward(from: 0);
    HapticFeedback.mediumImpact();

    // Auto-set exposure on tapped position
    if (_controller != null) {
      final size = context.size;
      if (size != null) {
        final point = Offset(pos.dx / size.width, pos.dy / size.height);
        _controller!.setExposurePoint(point);
        _controller!.setFocusPoint(point);
      }
    }
  }

  void _unlockMoon() {
    setState(() => _lockedMoonPosition = null);
    _lockAnimController.reverse();
    HapticFeedback.lightImpact();
  }

  Offset? _getMoonScreenOffset() {
    if (_moonPosition == null) return null;
    double azDiff = _moonPosition!.azimuth - _deviceAzimuth;
    while (azDiff > 180) azDiff -= 360;
    while (azDiff < -180) azDiff += 360;
    double altDiff = _moonPosition!.altitude - _devicePitch;
    return Offset(azDiff / 30.0, -altDiff / 22.5);
  }

  bool _isMoonInFrame() {
    if (_isLocked) return true; // if locked, always "in frame"
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
    if (_timerSeconds == 0) { _doTakePicture(); return; }
    setState(() => _timerCountdown = _timerSeconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _timerCountdown--);
      if (_timerCountdown <= 0) { t.cancel(); _doTakePicture(); }
    });
  }

  Future<void> _doTakePicture() async {
    if (_controller == null || _isTakingPhoto) return;
    setState(() => _isTakingPhoto = true);
    try {
      final file = await _controller!.takePicture();
      setState(() => _isTakingPhoto = false);
      _showPhotoPreview(file.path);
    } catch (e) {
      setState(() => _isTakingPhoto = false);
    }
  }

  Future<void> _saveToGallery(String path) async {
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final result = await ImageGallerySaver.saveImage(bytes, quality: 100, name: 'moon_${DateTime.now().millisecondsSinceEpoch}');
      if (mounted) {
        final success = result['isSuccess'] == true;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(success ? '✅ Fotka uložená do galérie!' : '❌ Nepodarilo sa uložiť'),
          backgroundColor: success ? Colors.green : Colors.red,
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ Chyba: $e'), backgroundColor: Colors.red));
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
            ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(12)), child: Image.file(File(path))),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.delete, color: Colors.red), label: const Text('Zahodiť', style: TextStyle(color: Colors.red))),
                  TextButton.icon(
                    onPressed: () { Navigator.pop(ctx); _saveToGallery(path); },
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
    final cycle = (now.difference(DateTime(now.year, 1, 1)).inDays % 29.5);
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
      if (m1.altitude <= 0 && m2.altitude > 0) return '${h.toString().padLeft(2, '0')}:00';
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
      if (m1.altitude > 0 && m2.altitude <= 0) return '${h.toString().padLeft(2, '0')}:00';
    }
    return '--:--';
  }

  Color get _uiColor => _nightMode ? Colors.red.shade400 : Colors.white;
  Color get _uiColorDim => _nightMode ? Colors.red.shade700 : Colors.white70;
  Color get _bgColor => _nightMode ? Colors.red.shade900.withOpacity(0.15) : Colors.white.withOpacity(0.1);

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _moonUpdateTimer?.cancel();
    _countdownTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _pulseController.dispose();
    _rotateController.dispose();
    _lockAnimController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: _isLocked ? null : _onTapScreen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller != null && _controller!.value.isInitialized)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller!.value.previewSize!.height,
                    height: _controller!.value.previewSize!.width,
                    child: CameraPreview(_controller!),
                  ),
                ),
              ),
            if (_isSwitchingCamera)
              Container(color: Colors.black.withOpacity(0.6), child: Center(child: CircularProgressIndicator(color: _uiColor))),
            if (_nightMode) Container(color: Colors.red.withOpacity(0.08)),
            _buildMoonOverlay(),
            _buildTopBar(),
            _buildSkyMap(),
            _buildLensSwitcher(),
            _buildLockIndicator(),
            if (_showControls) _buildControlsPanel(),
            _buildBottomControls(),
            if (_timerCountdown > 0) _buildCountdown(),
          ],
        ),
      ),
    );
  }

  // Lock indicator — shown when moon is locked
  Widget _buildLockIndicator() {
    if (!_isLocked) return const SizedBox();
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 100),
          child: Center(
            child: GestureDetector(
              onTap: _unlockMoon,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.amber, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock, color: Colors.amber, size: 14),
                    const SizedBox(width: 6),
                    const Text('Mesiac zamknutý — ťukni pre odomknutie', style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLensSwitcher() {
    if (_cameras == null || _cameras!.length <= 1) return const SizedBox();
    final labels = _lensLabels;
    return Positioned(
      bottom: 30, left: 16,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_cameras!.length, (i) {
              final isSelected = i == _selectedCameraIndex;
              return GestureDetector(
                onTap: _isSwitchingCamera ? null : () => _switchCamera(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? _uiColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(labels[i], style: TextStyle(color: isSelected ? Colors.black : _uiColor, fontSize: 13, fontWeight: FontWeight.bold)),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildCountdown() {
    return Center(
      child: Container(
        width: 120, height: 120,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withOpacity(0.6), border: Border.all(color: _uiColor, width: 3)),
        child: Center(child: Text('$_timerCountdown', style: TextStyle(color: _uiColor, fontSize: 60, fontWeight: FontWeight.bold))),
      ),
    );
  }

  Widget _buildSkyMap() {
    if (_moonPosition == null) return const SizedBox();
    return Positioned(
      right: 16, bottom: 140,
      child: Container(
        width: 110, height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.65),
          border: Border.all(color: _nightMode ? Colors.red.shade900 : Colors.white24, width: 1.5),
        ),
        child: CustomPaint(
          painter: SkyMapPainter(moonAzimuth: _moonPosition!.azimuth, moonAltitude: _moonPosition!.altitude, deviceAzimuth: _deviceAzimuth, nightMode: _nightMode),
        ),
      ),
    );
  }

  Widget _buildMoonOverlay() {
    if (_moonPosition == null) return const SizedBox();

    return LayoutBuilder(builder: (context, constraints) {
      final cx = constraints.maxWidth / 2;
      final cy = constraints.maxHeight / 2;

      // If locked — use tapped position
      if (_isLocked && _lockedMoonPosition != null) {
        return AnimatedBuilder(
          animation: Listenable.merge([_pulseAnimation, _rotateAnimation, _lockAnimation]),
          builder: (_, __) => CustomPaint(
            painter: MoonCirclePainter(
              center: _lockedMoonPosition!,
              radius: 60 * _pulseAnimation.value,
              rotation: _rotateAnimation.value,
              nightMode: _nightMode,
              isLocked: true,
              lockProgress: _lockAnimation.value,
            ),
            child: const SizedBox.expand(),
          ),
        );
      }

      // Not locked — use astronomical position
      final offset = _getMoonScreenOffset();
      if (offset == null) return const SizedBox();

      final inFrame = offset.dx.abs() < 0.85 && offset.dy.abs() < 0.85;

      if (inFrame) {
        final moonX = cx + offset.dx * cx * 0.8;
        final moonY = cy + offset.dy * cy * 0.8;
        return AnimatedBuilder(
          animation: Listenable.merge([_pulseAnimation, _rotateAnimation]),
          builder: (_, __) => CustomPaint(
            painter: MoonCirclePainter(
              center: Offset(moonX, moonY),
              radius: 60 * _pulseAnimation.value,
              rotation: _rotateAnimation.value,
              nightMode: _nightMode,
            ),
            child: const SizedBox.expand(),
          ),
        );
      } else {
        final angle = atan2(offset.dy, offset.dx);
        return CustomPaint(
          painter: MoonArrowPainter(centerX: cx, centerY: cy, angle: angle, altitude: _moonPosition!.altitude, nightMode: _nightMode),
          child: const SizedBox.expand(),
        );
      }
    });
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('🌙 MOON CAMERA', style: TextStyle(color: _uiColor, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  Row(children: [
                    if (_moonPosition != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _moonPosition!.isAboveHorizon ? (_nightMode ? Colors.red.shade900.withOpacity(0.3) : Colors.blue.withOpacity(0.3)) : Colors.red.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _moonPosition!.isAboveHorizon ? (_nightMode ? Colors.red.shade700 : Colors.blue) : Colors.red),
                        ),
                        child: Text(_moonPosition!.isAboveHorizon ? '↑ NAD' : '↓ POD', style: TextStyle(color: _uiColorDim, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => setState(() => _nightMode = !_nightMode),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _nightMode ? Colors.red.shade900.withOpacity(0.4) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _nightMode ? Colors.red.shade700 : Colors.white38),
                        ),
                        child: Icon(Icons.bedtime, color: _nightMode ? Colors.red.shade300 : Colors.white, size: 18),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => setState(() => _showControls = !_showControls),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _showControls ? _uiColor.withOpacity(0.3) : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _nightMode ? Colors.red.shade700 : Colors.white38),
                        ),
                        child: Icon(Icons.tune, color: _uiColor, size: 18),
                      ),
                    ),
                  ]),
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
                    _infoChip('TILT', '${_devicePitch.toStringAsFixed(1)}°'),
                  ],
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_getMoonPhase(), style: TextStyle(color: _uiColorDim, fontSize: 11)),
                  const SizedBox(width: 12),
                  Text('🌅 ${_getMoonRiseTime()}  🌇 ${_getMoonSetTime()}', style: TextStyle(color: _uiColorDim, fontSize: 11)),
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
      decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: _uiColor.withOpacity(0.2))),
      child: RichText(
        text: TextSpan(children: [
          TextSpan(text: '$label ', style: TextStyle(color: _uiColorDim, fontSize: 10)),
          TextSpan(text: value, style: TextStyle(color: _uiColor, fontSize: 11, fontWeight: FontWeight.bold)),
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
          color: _nightMode ? Colors.red.shade900.withOpacity(0.85) : Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _nightMode ? Colors.red.shade800 : Colors.white12),
        ),
        child: Column(
          children: [
            Row(children: [Icon(Icons.brightness_6, color: _uiColorDim, size: 18), const SizedBox(width: 8), Text('Expozícia', style: TextStyle(color: _uiColorDim, fontSize: 12)), const Spacer(), Text(_exposureOffset.toStringAsFixed(1), style: TextStyle(color: _uiColor, fontSize: 12))]),
            SliderTheme(
              data: SliderThemeData(activeTrackColor: _uiColor, inactiveTrackColor: _uiColor.withOpacity(0.2), thumbColor: _uiColor),
              child: Slider(value: _exposureOffset, min: _minExposure, max: _maxExposure, divisions: 16, onChanged: _setExposure),
            ),
            Row(children: [Icon(Icons.zoom_in, color: _uiColorDim, size: 18), const SizedBox(width: 8), Text('Zoom', style: TextStyle(color: _uiColorDim, fontSize: 12)), const Spacer(), Text('${_zoomLevel.toStringAsFixed(1)}x', style: TextStyle(color: _uiColor, fontSize: 12))]),
            SliderTheme(
              data: SliderThemeData(activeTrackColor: _uiColor, inactiveTrackColor: _uiColor.withOpacity(0.2), thumbColor: _uiColor),
              child: Slider(value: _zoomLevel, min: 1.0, max: _maxZoom, onChanged: _setZoom),
            ),
            Row(children: [
              Icon(Icons.timer, color: _uiColorDim, size: 18), const SizedBox(width: 8),
              Text('Časovač', style: TextStyle(color: _uiColorDim, fontSize: 12)), const Spacer(),
              ...[0, 3, 5, 10].map((s) => GestureDetector(
                onTap: () => setState(() => _timerSeconds = s),
                child: Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: _timerSeconds == s ? _uiColor : _uiColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text(s == 0 ? 'OFF' : '${s}s', style: TextStyle(color: _timerSeconds == s ? Colors.black : _uiColor, fontSize: 11, fontWeight: FontWeight.bold)),
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 32),
          child: Column(
            children: [
              Text(
                _timerCountdown > 0 ? '⏱️ Fotím za $_timerCountdown s...'
                    : _isLocked ? '🔒 Ťukni na spúšť pre fotku'
                    : inFrame ? '👆 Ťukni na mesiac pre zamknutie'
                    : _moonPosition != null ? (_moonPosition!.isAboveHorizon ? '👆 Namiery telefón podľa šípky' : '😔 Mesiac je pod horizontom')
                    : _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _isLocked ? Colors.amber : inFrame ? Colors.greenAccent : _uiColorDim,
                  fontSize: 13,
                  fontWeight: _isLocked || inFrame ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_timerSeconds > 0)
                    Container(margin: const EdgeInsets.only(right: 20), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: _uiColor.withOpacity(0.3))), child: Text('⏱ ${_timerSeconds}s', style: TextStyle(color: _uiColor, fontSize: 12))),
                  GestureDetector(
                    onTap: _timerCountdown > 0 ? null : _startTimerAndShoot,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isTakingPhoto || _timerCountdown > 0
                            ? _uiColor.withOpacity(0.3)
                            : _isLocked ? Colors.amber : inFrame ? _uiColor : _uiColor.withOpacity(0.4),
                        border: Border.all(color: _isLocked ? Colors.amber : inFrame ? _uiColor : _uiColor.withOpacity(0.4), width: 3),
                        boxShadow: _isLocked || inFrame
                            ? [BoxShadow(color: (_isLocked ? Colors.amber : _uiColor).withOpacity(0.4), blurRadius: 20, spreadRadius: 5)]
                            : null,
                      ),
                      child: _isTakingPhoto
                          ? Center(child: CircularProgressIndicator(color: _uiColor))
                          : Icon(Icons.camera, size: 36, color: _isLocked ? Colors.black : inFrame ? Colors.black : _uiColor.withOpacity(0.5)),
                    ),
                  ),
                  if (_zoomLevel > 1.0)
                    Container(margin: const EdgeInsets.only(left: 20), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: _uiColor.withOpacity(0.3))), child: Text('🔭 ${_zoomLevel.toStringAsFixed(1)}x', style: TextStyle(color: _uiColor, fontSize: 12))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SkyMapPainter extends CustomPainter {
  final double moonAzimuth, moonAltitude, deviceAzimuth;
  final bool nightMode;
  SkyMapPainter({required this.moonAzimuth, required this.moonAltitude, required this.deviceAzimuth, this.nightMode = false});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2 - 4;
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = nightMode ? Colors.red.shade900 : const Color(0xFF0A0A2A));
    canvas.drawCircle(Offset(cx, cy), r * 0.95, Paint()..color = (nightMode ? Colors.red : Colors.white).withOpacity(0.12)..style = PaintingStyle.stroke..strokeWidth = 0.5);
    for (double alt in [30, 60]) {
      canvas.drawCircle(Offset(cx, cy), r * (1 - alt / 90) * 0.95, Paint()..color = (nightMode ? Colors.red : Colors.white).withOpacity(0.1)..style = PaintingStyle.stroke..strokeWidth = 0.5);
    }
    final dirPaint = TextPainter(textDirection: TextDirection.ltr);
    for (var entry in {'N': 0.0, 'E': 90.0, 'S': 180.0, 'W': 270.0}.entries) {
      final angle = (entry.value - deviceAzimuth) * pi / 180;
      final dx = cx + sin(angle) * (r * 0.82), dy = cy - cos(angle) * (r * 0.82);
      dirPaint.text = TextSpan(text: entry.key, style: TextStyle(color: entry.key == 'N' ? (nightMode ? Colors.red.shade300 : Colors.redAccent) : (nightMode ? Colors.red.shade700 : Colors.white38), fontSize: 8, fontWeight: FontWeight.bold));
      dirPaint.layout();
      dirPaint.paint(canvas, Offset(dx - dirPaint.width / 2, dy - dirPaint.height / 2));
    }
    final fovAngle = 30.0 * pi / 180;
    final wedgePath = Path()..moveTo(cx, cy)..arcTo(Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.9), -pi / 2 - fovAngle / 2, fovAngle, false)..close();
    canvas.drawPath(wedgePath, Paint()..color = (nightMode ? Colors.red : Colors.white).withOpacity(0.08));
    if (moonAltitude > -10) {
      final moonAngle = (moonAzimuth - deviceAzimuth) * pi / 180;
      final moonR = r * (1 - (moonAltitude.clamp(-10.0, 90.0) + 10) / 100) * 0.9;
      final mx = cx + sin(moonAngle) * moonR, my = cy - cos(moonAngle) * moonR;
      canvas.drawCircle(Offset(mx, my), 8, Paint()..color = Colors.yellow.withOpacity(0.2)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(Offset(mx, my), 5, Paint()..color = moonAltitude > 0 ? Colors.yellow : Colors.yellow.withOpacity(0.4));
      final moonTp = TextPainter(text: const TextSpan(text: '🌙', style: TextStyle(fontSize: 8)), textDirection: TextDirection.ltr)..layout();
      moonTp.paint(canvas, Offset(mx - moonTp.width / 2, my - moonTp.height - 3));
    }
    canvas.drawCircle(Offset(cx, cy), 3, Paint()..color = (nightMode ? Colors.red.shade400 : Colors.white54)..style = PaintingStyle.fill);
    final labelTp = TextPainter(text: TextSpan(text: 'OBLOHA', style: TextStyle(color: (nightMode ? Colors.red.shade800 : Colors.white30), fontSize: 7, letterSpacing: 1)), textDirection: TextDirection.ltr)..layout();
    labelTp.paint(canvas, Offset(cx - labelTp.width / 2, size.height - 12));
  }

  @override
  bool shouldRepaint(SkyMapPainter old) => true;
}

class MoonCirclePainter extends CustomPainter {
  final Offset center;
  final double radius, rotation;
  final bool nightMode;
  final bool isLocked;
  final double lockProgress;

  MoonCirclePainter({
    required this.center,
    required this.radius,
    this.rotation = 0,
    this.nightMode = false,
    this.isLocked = false,
    this.lockProgress = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final color = isLocked ? Colors.amber : (nightMode ? Colors.red.shade400 : Colors.white);

    // Glow
    canvas.drawCircle(center, radius, Paint()
      ..color = color.withOpacity(0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15));

    // Main circle
    canvas.drawCircle(center, radius, Paint()
      ..color = color.withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isLocked ? 3 : 2);

    // Rotating dashes
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    final dashPaint = Paint()..color = color.withOpacity(0.4)..style = PaintingStyle.stroke..strokeWidth = 1;
    for (int i = 0; i < 24; i++) {
      final angle = (i / 24) * 2 * pi;
      canvas.drawLine(
        Offset(cos(angle) * (radius + 8), sin(angle) * (radius + 8)),
        Offset(cos(angle) * (radius + 16), sin(angle) * (radius + 16)),
        dashPaint,
      );
    }
    canvas.restore();

    // Lock icon when locked
    if (isLocked && lockProgress > 0.5) {
      final lockPaint = TextPainter(
        text: const TextSpan(text: '🔒', style: TextStyle(fontSize: 14)),
        textDirection: TextDirection.ltr,
      )..layout();
      lockPaint.paint(canvas, Offset(center.dx - lockPaint.width / 2, center.dy - radius - 30));
    }

    // Crosshair
    final lp = Paint()..color = color.withOpacity(0.5)..strokeWidth = 1;
    canvas.drawLine(Offset(center.dx, center.dy - radius - 10), Offset(center.dx, center.dy - radius + 10), lp);
    canvas.drawLine(Offset(center.dx, center.dy + radius - 10), Offset(center.dx, center.dy + radius + 10), lp);
    canvas.drawLine(Offset(center.dx - radius - 10, center.dy), Offset(center.dx - radius + 10, center.dy), lp);
    canvas.drawLine(Offset(center.dx + radius - 10, center.dy), Offset(center.dx + radius + 10, center.dy), lp);
    canvas.drawCircle(center, 3, Paint()..color = color.withOpacity(0.6)..style = PaintingStyle.fill);

    // Label
    final label = isLocked ? '🔒 ZAMKNUTÝ' : '🌙 MESIAC';
    final tp = TextPainter(
      text: TextSpan(text: label, style: TextStyle(color: color.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.bold, shadows: [Shadow(color: Colors.black, blurRadius: 4)])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + radius + 14));
  }

  @override
  bool shouldRepaint(MoonCirclePainter old) => old.radius != radius || old.rotation != rotation || old.isLocked != isLocked || old.lockProgress != lockProgress;
}

class MoonArrowPainter extends CustomPainter {
  final double centerX, centerY, angle, altitude;
  final bool nightMode;
  MoonArrowPainter({required this.centerX, required this.centerY, required this.angle, required this.altitude, this.nightMode = false});

  @override
  void paint(Canvas canvas, Size size) {
    final color = nightMode ? Colors.red.shade400 : Colors.white;
    final ax = centerX + cos(angle) * 120.0, ay = centerY + sin(angle) * 120.0;
    canvas.drawCircle(Offset(ax, ay), 36, Paint()..color = Colors.black.withOpacity(0.4));
    canvas.drawCircle(Offset(ax, ay), 36, Paint()..color = color.withOpacity(0.6)..style = PaintingStyle.stroke..strokeWidth = 1.5);
    canvas.save();
    canvas.translate(ax, ay);
    canvas.rotate(angle);
    canvas.drawPath(Path()..moveTo(20, 0)..lineTo(-10, -10)..lineTo(-5, 0)..lineTo(-10, 10)..close(), Paint()..color = color..style = PaintingStyle.fill);
    canvas.restore();
    final tp = TextPainter(text: const TextSpan(text: '🌙', style: TextStyle(fontSize: 16)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(ax - tp.width / 2, ay - tp.height / 2 - 20));
    final altTp = TextPainter(text: TextSpan(text: '${altitude.toStringAsFixed(0)}°', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
    altTp.paint(canvas, Offset(ax - altTp.width / 2, ay + 14));
  }

  @override
  bool shouldRepaint(MoonArrowPainter old) => true;
}