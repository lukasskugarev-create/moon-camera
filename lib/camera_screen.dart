import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'moon_calculator.dart';
import 'sun_calculator.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  int _selectedCameraIndex = 0;
  bool _isSwitchingCamera = false;
  MoonPosition? _moonPosition;
  SunPosition? _sunPosition;
  Position? _devicePosition;

  double _deviceAzimuth = 0;
  double _devicePitch = 0;
  final double _smoothFactor = 0.08;

  bool _wasInFrame = false;
  static const double _enterThreshold = 0.75;
  static const double _exitThreshold = 1.1;

  bool _isTakingPhoto = false;
  String _statusMessage = 'Inicializujem...';
  bool _sunMode = false;
  bool _showGrid = false;
  bool _isLocked = false;

  // Unified panel
  bool _showPanel = false;
  int _panelTab = 0; // 0=nastavenia, 1=pocasie, 2=ukazy

  // Weather
  double? _weatherTemp;
  int? _weatherCloudCover;
  String _weatherDesc = '';
  bool _loadingWeather = false;

  double _exposureOffset = 0.0;
  double _minExposure = -4.0;
  double _maxExposure = 4.0;
  double _zoomLevel = 1.0;
  double _maxZoom = 8.0;
  bool _nightMode = false;

  int _timerSeconds = 0;
  int _timerCountdown = 0;
  Timer? _countdownTimer;

  Offset? _circlePosition;

  StreamSubscription? _accelerometerSubscription;

  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late AnimationController _lockAnimController;
  late AnimationController _panelAnimController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _rotateAnimation;
  late Animation<double> _lockAnimation;
  late Animation<double> _panelAnimation;
  Timer? _positionUpdateTimer;

  double? get _targetAzimuth => _sunMode ? _sunPosition?.azimuth : _moonPosition?.azimuth;
  double? get _targetAltitude => _sunMode ? _sunPosition?.altitude : _moonPosition?.altitude;
  bool get _targetAboveHorizon => _sunMode ? (_sunPosition?.isAboveHorizon ?? false) : (_moonPosition?.isAboveHorizon ?? false);

  List<String> get _lensLabels {
    if (_cameras == null) return [];
    switch (_cameras!.length) {
      case 1: return ['1x'];
      case 2: return ['1x', '2x'];
      case 3: return ['0.5x', '1x', '2x'];
      case 4: return ['0.5x', '1x', '2x', '3x'];
      default: return List.generate(_cameras!.length, (i) => '${i+1}x');
    }
  }

  Color get _uiColor { if (_nightMode) return Colors.red.shade400; return _sunMode ? Colors.orange : Colors.white; }
  Color get _uiColorDim { if (_nightMode) return Colors.red.shade700; return _sunMode ? Colors.orange.shade300 : Colors.white70; }
  Color get _bgColor { if (_nightMode) return Colors.red.shade900.withOpacity(0.15); return _sunMode ? Colors.orange.withOpacity(0.1) : Colors.white.withOpacity(0.1); }
  Color get _targetColor { if (_isLocked) return Colors.amber; if (_sunMode) return Colors.orange; return _nightMode ? Colors.red.shade400 : Colors.white; }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _pulseController = AnimationController(duration: const Duration(seconds: 2), vsync: this)..repeat(reverse: true);
    _rotateController = AnimationController(duration: const Duration(seconds: 20), vsync: this)..repeat();
    _lockAnimController = AnimationController(duration: const Duration(milliseconds: 400), vsync: this);
    _panelAnimController = AnimationController(duration: const Duration(milliseconds: 350), vsync: this);
    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.08).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _rotateAnimation = Tween<double>(begin: 0, end: 2 * pi).animate(_rotateController);
    _lockAnimation = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _lockAnimController, curve: Curves.elasticOut));
    _panelAnimation = CurvedAnimation(parent: _panelAnimController, curve: Curves.easeOutCubic);
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _initCamera();
    await _getLocation();
    _startCompass();
    _startAccelerometer();
    _startPositionUpdates();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.location, Permission.photos].request();
  }

  double _angleDiff(double target, double current) {
    double diff = target - current;
    while (diff > 180) diff -= 360;
    while (diff < -180) diff += 360;
    return diff;
  }

  void _startCompass() {
    FlutterCompass.events?.listen((event) {
      if (mounted && event.heading != null) {
        final diff = _angleDiff(event.heading!, _deviceAzimuth);
        setState(() {
          _deviceAzimuth = _deviceAzimuth + _smoothFactor * diff;
          if (_deviceAzimuth < 0) _deviceAzimuth += 360;
          if (_deviceAzimuth >= 360) _deviceAzimuth -= 360;
        });
      }
    });
  }

  void _startAccelerometer() {
    _accelerometerSubscription = accelerometerEventStream().listen((AccelerometerEvent event) {
      if (!mounted) return;
      final rawPitch = atan2(-event.z, sqrt(event.x * event.x + event.y * event.y)) * 180 / pi;
      setState(() { _devicePitch = _devicePitch + _smoothFactor * (rawPitch - _devicePitch); });
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
          _controller = newController; _selectedCameraIndex = safeIndex;
          _minExposure = minExp; _maxExposure = maxExp;
          _maxZoom = maxZoom.clamp(1.0, 10.0); _zoomLevel = 1.0; _exposureOffset = 0.0;
        });
      }
    } catch (e) { if (mounted) setState(() => _statusMessage = 'Chyba kamery: $e'); }
  }

  Future<void> _switchCamera(int index) async {
    if (_cameras == null || index >= _cameras!.length) return;
    if (index == _selectedCameraIndex || _isSwitchingCamera) return;
    setState(() { _isSwitchingCamera = true; _isLocked = false; _wasInFrame = false; _circlePosition = null; });
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
      _updatePositions();
      _fetchWeather();
    } catch (e) { setState(() => _statusMessage = 'Chyba GPS: $e'); }
  }

  Future<void> _fetchWeather() async {
    if (_devicePosition == null) return;
    setState(() => _loadingWeather = true);
    try {
      final lat = _devicePosition!.latitude;
      final lng = _devicePosition!.longitude;
      final url = 'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lng&current=temperature_2m,cloudcover,weathercode&timezone=auto';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final current = data['current'];
        setState(() {
          _weatherTemp = current['temperature_2m']?.toDouble();
          _weatherCloudCover = current['cloudcover']?.toInt();
          _weatherDesc = _weatherCodeToDesc(current['weathercode']?.toInt() ?? 0);
          _loadingWeather = false;
        });
      }
    } catch (e) { setState(() => _loadingWeather = false); }
  }

  String _weatherCodeToDesc(int code) {
    if (code == 0) return 'Jasno ☀️';
    if (code <= 2) return 'Čiastočne oblačno 🌤️';
    if (code == 3) return 'Zamračené ☁️';
    if (code <= 49) return 'Hmla 🌫️';
    if (code <= 59) return 'Mrholenie 🌧️';
    if (code <= 69) return 'Dážď 🌧️';
    if (code <= 79) return 'Sneh ❄️';
    if (code <= 82) return 'Sprchy 🌦️';
    if (code <= 99) return 'Búrka ⛈️';
    return 'Neznáme';
  }

  bool get _goodForAstro => (_weatherCloudCover ?? 100) < 30;

  void _startPositionUpdates() {
    _positionUpdateTimer = Timer.periodic(const Duration(seconds: 10), (_) => _updatePositions());
  }

  void _updatePositions() {
    if (_devicePosition == null) return;
    final now = DateTime.now();
    final moon = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, now);
    final sun = SunCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, now);
    setState(() { _moonPosition = moon; _sunPosition = sun; });
  }

  void _toggleMode() {
    setState(() { _sunMode = !_sunMode; _isLocked = false; _wasInFrame = false; _circlePosition = null; });
    HapticFeedback.lightImpact();
  }

  void _openPanel(int tab) {
    setState(() { _showPanel = true; _panelTab = tab; });
    _panelAnimController.forward(from: 0);
    HapticFeedback.lightImpact();
  }

  void _closePanel() {
    _panelAnimController.reverse().then((_) { if (mounted) setState(() => _showPanel = false); });
  }

  Offset? _getScreenOffset() {
    if (_targetAzimuth == null || _targetAltitude == null) return null;
    double azDiff = _targetAzimuth! - _deviceAzimuth;
    while (azDiff > 180) azDiff -= 360;
    while (azDiff < -180) azDiff += 360;
    double altDiff = _targetAltitude! - _devicePitch;
    return Offset(azDiff / 30.0, -altDiff / 22.5);
  }

  bool _isTargetInFrame() {
    final offset = _getScreenOffset();
    if (offset == null) return false;
    final threshold = _wasInFrame ? _exitThreshold : _enterThreshold;
    final inFrame = offset.dx.abs() < threshold && offset.dy.abs() < threshold;
    _wasInFrame = inFrame;
    return inFrame;
  }

  Offset? _getSmoothedCirclePosition(double cx, double cy) {
    final offset = _getScreenOffset();
    if (offset == null) return null;
    final target = Offset(cx + offset.dx * cx * 0.8, cy + offset.dy * cy * 0.8);
    if (_circlePosition == null) { _circlePosition = target; }
    else { _circlePosition = Offset(_circlePosition!.dx + 0.15 * (target.dx - _circlePosition!.dx), _circlePosition!.dy + 0.15 * (target.dy - _circlePosition!.dy)); }
    return _circlePosition;
  }

  void _onTapScreen(TapUpDetails details) {
    if (_showPanel) { _closePanel(); return; }
    if (_isLocked) { _unlockPosition(); return; }
    // Zamknúť len keď je terč v zábere
    if (!_isTargetInFrame()) return;
    setState(() => _isLocked = true);
    _lockAnimController.forward(from: 0);
    HapticFeedback.mediumImpact();
    if (_controller != null && _circlePosition != null) {
      final size = context.size;
      if (size != null) {
        final point = Offset(_circlePosition!.dx / size.width, _circlePosition!.dy / size.height);
        _controller!.setExposureMode(ExposureMode.locked);
        _controller!.setFocusMode(FocusMode.locked);
        _controller!.setExposurePoint(point);
        _controller!.setFocusPoint(point);
      }
    }
  }

  void _unlockPosition() {
    setState(() { _isLocked = false; _wasInFrame = false; });
    _lockAnimController.reverse();
    HapticFeedback.lightImpact();
    _controller?.setExposureMode(ExposureMode.auto);
    _controller?.setFocusMode(FocusMode.auto);
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
    } catch (e) { setState(() => _isTakingPhoto = false); }
  }

  Future<void> _saveToGallery(String path) async {
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final result = await ImageGallerySaver.saveImage(bytes, quality: 100, name: '${_sunMode ? "sun" : "moon"}_${DateTime.now().millisecondsSinceEpoch}');
      if (mounted) {
        final success = result['isSuccess'] == true;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success ? '✅ Fotka uložená!' : '❌ Chyba'), backgroundColor: success ? Colors.green : Colors.red));
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ $e'), backgroundColor: Colors.red)); }
  }

  void _showPhotoPreview(String path) {
    showDialog(context: context, builder: (ctx) => Dialog(
      backgroundColor: Colors.black,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(12)), child: Image.file(File(path))),
        Padding(padding: const EdgeInsets.all(12), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          TextButton.icon(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.delete, color: Colors.red), label: const Text('Zahodiť', style: TextStyle(color: Colors.red))),
          TextButton.icon(onPressed: () { Navigator.pop(ctx); _saveToGallery(path); }, icon: const Icon(Icons.save, color: Colors.green), label: const Text('Uložiť', style: TextStyle(color: Colors.green))),
        ])),
      ]),
    ));
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

  List<Map<String, String>> _getUpcomingEvents() {
    final events = <Map<String, String>>[];
    final now = DateTime.now();
    final cycleStart = now.difference(DateTime(now.year, 1, 1)).inDays % 29.5;
    final daysToNextPhase = (7.4 - (cycleStart % 7.4)) % 7.4;
    final phaseNames = ['🌑 Nov mesiaca', '🌓 Prvá štvrtina', '🌕 Spln mesiaca', '🌗 Posledná štvrtina'];
    for (int i = 0; i < 4; i++) {
      final days = (daysToNextPhase + i * 7.4).round();
      if (days <= 30) {
        final date = now.add(Duration(days: days));
        events.add({'emoji': phaseNames[i].split(' ')[0], 'name': phaseNames[i].substring(2), 'date': '${date.day}.${date.month}.'});
      }
    }
    final showers = [
      {'name': 'Perseidy', 'emoji': '☄️', 'month': 8, 'day': 12},
      {'name': 'Leonidy', 'emoji': '☄️', 'month': 11, 'day': 17},
      {'name': 'Geminidy', 'emoji': '☄️', 'month': 12, 'day': 14},
      {'name': 'Kvadrantidy', 'emoji': '☄️', 'month': 1, 'day': 3},
      {'name': 'Eta Aquaridy', 'emoji': '☄️', 'month': 5, 'day': 6},
    ];
    for (final shower in showers) {
      final showerDate = DateTime(now.year, shower['month'] as int, shower['day'] as int);
      final diff = showerDate.difference(now).inDays;
      if (diff >= 0 && diff <= 30) {
        events.add({'emoji': shower['emoji'] as String, 'name': shower['name'] as String, 'date': '${showerDate.day}.${showerDate.month}.'});
      }
    }
    events.sort((a, b) => a['date']!.compareTo(b['date']!));
    return events.take(5).toList();
  }

  String _getRiseTime(bool sun) {
    if (_devicePosition == null) return '--:--';
    final now = DateTime.now();
    for (int h = 0; h < 24; h++) {
      final t1 = DateTime(now.year, now.month, now.day, h, 0);
      final t2 = DateTime(now.year, now.month, now.day, h + 1 < 24 ? h + 1 : 23, 59);
      if (sun) {
        final m1 = SunCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t1);
        final m2 = SunCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t2);
        if (m1.altitude <= 0 && m2.altitude > 0) return '${h.toString().padLeft(2, '0')}:00';
      } else {
        final m1 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t1);
        final m2 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t2);
        if (m1.altitude <= 0 && m2.altitude > 0) return '${h.toString().padLeft(2, '0')}:00';
      }
    }
    return '--:--';
  }

  String _getSetTime(bool sun) {
    if (_devicePosition == null) return '--:--';
    final now = DateTime.now();
    for (int h = 0; h < 24; h++) {
      final t1 = DateTime(now.year, now.month, now.day, h, 0);
      final t2 = DateTime(now.year, now.month, now.day, h + 1 < 24 ? h + 1 : 23, 59);
      if (sun) {
        final m1 = SunCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t1);
        final m2 = SunCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t2);
        if (m1.altitude > 0 && m2.altitude <= 0) return '${h.toString().padLeft(2, '0')}:00';
      } else {
        final m1 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t1);
        final m2 = MoonCalculator.calculate(_devicePosition!.latitude, _devicePosition!.longitude, t2);
        if (m1.altitude > 0 && m2.altitude <= 0) return '${h.toString().padLeft(2, '0')}:00';
      }
    }
    return '--:--';
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _positionUpdateTimer?.cancel();
    _countdownTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _pulseController.dispose();
    _rotateController.dispose();
    _lockAnimController.dispose();
    _panelAnimController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: _onTapScreen,
        child: Stack(fit: StackFit.expand, children: [
          // 1. Kamera (spodná vrstva)
          if (_controller != null && _controller!.value.isInitialized)
            SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: SizedBox(
              width: _controller!.value.previewSize!.height,
              height: _controller!.value.previewSize!.width,
              child: CameraPreview(_controller!),
            ))),
          // 2. Farebné prekrytia
          if (_isSwitchingCamera) Container(color: Colors.black.withOpacity(0.6), child: Center(child: CircularProgressIndicator(color: _uiColor))),
          if (_nightMode) Container(color: Colors.red.withOpacity(0.08)),
          if (_sunMode) Container(color: Colors.orange.withOpacity(0.03)),
          // 3. Mriežka
          if (_showGrid) CustomPaint(painter: GridPainter(color: _uiColor.withOpacity(0.3)), child: const SizedBox.expand()),
          // 4. Overlay (šípky / kruh)
          _buildOverlay(),
          // 5. Horná lišta
          _buildTopBar(),
          // 6. Mapa oblohy
          _buildSkyMap(),
          // 7. Prepínač objektívov
          _buildLensSwitcher(),
          // 8. Indikátor zámku
          _buildLockIndicator(),
          // 9. Spodné ovládacie prvky
          _buildBottomControls(),
          // 10. Panel (musí byť NAD bottom controls, aby ich zakryl)
          if (_showPanel) _buildUnifiedPanel(),
          // 11. Odpočítavanie (vždy navrchu)
          if (_timerCountdown > 0) _buildCountdown(),
        ]),
      ),
    );
  }

  Widget _buildUnifiedPanel() {
    return Positioned(
      left: 0, right: 0, bottom: 0,
      child: AnimatedBuilder(
        animation: _panelAnimation,
        builder: (_, __) => Transform.translate(
          offset: Offset(0, 420 * (1 - _panelAnimation.value)),
          child: GestureDetector(
            onTap: () {}, // zabraňuje prepusteniu tapu cez panel
            child: Container(
              decoration: BoxDecoration(
                color: _nightMode
                    ? Colors.red.shade900.withOpacity(0.97)
                    : Colors.black.withOpacity(0.95), // zvýšená opacity pre lepšie zakrytie
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border.all(color: _uiColor.withOpacity(0.2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 20,
                    spreadRadius: 5,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    _panelTabBtn(0, Icons.tune, 'Nastavenia'),
                    const SizedBox(width: 8),
                    _panelTabBtn(1, Icons.cloud, 'Počasie'),
                    const SizedBox(width: 8),
                    _panelTabBtn(2, Icons.event, 'Úkazy'),
                    const Spacer(),
                    GestureDetector(
                      onTap: _closePanel,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.close, color: Colors.white54, size: 16),
                      ),
                    ),
                  ]),
                ),
                const Divider(color: Colors.white12, height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _panelTab == 0
                      ? _buildSettingsTab()
                      : _panelTab == 1
                          ? _buildWeatherTab()
                          : _buildEventsTab(),
                ),
                SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panelTabBtn(int index, IconData icon, String label) {
    final active = _panelTab == index;
    return GestureDetector(
      onTap: () => setState(() => _panelTab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? _uiColor.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? _uiColor.withOpacity(0.6) : Colors.white12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? _uiColor : Colors.white38, size: 14),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: active ? _uiColor : Colors.white38, fontSize: 12, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
        ]),
      ),
    );
  }

  Widget _buildSettingsTab() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.grid_on, color: _uiColorDim, size: 16), const SizedBox(width: 8),
        const Text('Mriežka', style: TextStyle(color: Colors.white70, fontSize: 13)), const Spacer(),
        Switch(value: _showGrid, onChanged: (v) => setState(() => _showGrid = v), activeColor: _uiColor),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Icon(Icons.bedtime, color: _uiColorDim, size: 16), const SizedBox(width: 8),
        const Text('Nočný režim', style: TextStyle(color: Colors.white70, fontSize: 13)), const Spacer(),
        Switch(value: _nightMode, onChanged: (v) => setState(() => _nightMode = v), activeColor: Colors.red.shade400),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Icon(Icons.brightness_6, color: _uiColorDim, size: 16),
        const SizedBox(width: 8),
        Text('Expozícia', style: TextStyle(color: _uiColorDim, fontSize: 12)),
        const Spacer(),
        Text(_exposureOffset.toStringAsFixed(1), style: TextStyle(color: _uiColor, fontSize: 12)),
      ]),
      SliderTheme(
        data: SliderThemeData(activeTrackColor: _uiColor, inactiveTrackColor: _uiColor.withOpacity(0.2), thumbColor: _uiColor),
        child: Slider(value: _exposureOffset, min: _minExposure, max: _maxExposure, divisions: 16, onChanged: _setExposure),
      ),
      Row(children: [
        Icon(Icons.zoom_in, color: _uiColorDim, size: 16),
        const SizedBox(width: 8),
        Text('Zoom', style: TextStyle(color: _uiColorDim, fontSize: 12)),
        const Spacer(),
        Text('${_zoomLevel.toStringAsFixed(1)}x', style: TextStyle(color: _uiColor, fontSize: 12)),
      ]),
      SliderTheme(
        data: SliderThemeData(activeTrackColor: _uiColor, inactiveTrackColor: _uiColor.withOpacity(0.2), thumbColor: _uiColor),
        child: Slider(value: _zoomLevel, min: 1.0, max: _maxZoom, onChanged: _setZoom),
      ),
      Row(children: [
        Icon(Icons.timer, color: _uiColorDim, size: 16),
        const SizedBox(width: 8),
        Text('Časovač', style: TextStyle(color: _uiColorDim, fontSize: 12)),
        const Spacer(),
        ...[0, 3, 5, 10].map((s) => GestureDetector(
          onTap: () => setState(() => _timerSeconds = s),
          child: Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _timerSeconds == s ? _uiColor : _uiColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              s == 0 ? 'OFF' : '${s}s',
              style: TextStyle(color: _timerSeconds == s ? Colors.black : _uiColor, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        )),
      ]),
    ]);
  }

  Widget _buildWeatherTab() {
    if (_loadingWeather) return const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity, padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _goodForAstro ? Colors.green.withOpacity(0.15) : Colors.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _goodForAstro ? Colors.green.withOpacity(0.4) : Colors.orange.withOpacity(0.4)),
        ),
        child: Row(children: [
          Text(_goodForAstro ? '✅' : '⚠️', style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _goodForAstro ? 'Vhodné na pozorovanie' : 'Podmienky nie sú ideálne',
              style: TextStyle(color: _goodForAstro ? Colors.greenAccent : Colors.orange, fontSize: 13, fontWeight: FontWeight.bold),
            ),
            Text(_weatherDesc, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('🌡️', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 4),
            const Text('Teplota', style: TextStyle(color: Colors.white38, fontSize: 10)),
            Text(_weatherTemp != null ? '${_weatherTemp!.toStringAsFixed(0)}°C' : '--', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
        )),
        const SizedBox(width: 12),
        Expanded(child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('☁️', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 4),
            const Text('Oblačnosť', style: TextStyle(color: Colors.white38, fontSize: 10)),
            Text(_weatherCloudCover != null ? '$_weatherCloudCover%' : '--', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
        )),
      ]),
      const SizedBox(height: 12),
      GestureDetector(
        onTap: _fetchWeather,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(10)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.refresh, color: Colors.white54, size: 14),
            SizedBox(width: 6),
            Text('Obnoviť', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
        ),
      ),
    ]);
  }

  Widget _buildEventsTab() {
    final events = _getUpcomingEvents();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Najbližších 30 dní', style: TextStyle(color: _uiColorDim, fontSize: 11)),
      const SizedBox(height: 10),
      if (events.isEmpty)
        const Text('Žiadne úkazy', style: TextStyle(color: Colors.white54, fontSize: 12))
      else
        ...events.map((e) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Text(e['emoji']!, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(child: Text(e['name']!, style: const TextStyle(color: Colors.white, fontSize: 13))),
            Text(e['date']!, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        )),
    ]);
  }

  Widget _buildLockIndicator() {
    if (!_isLocked) return const SizedBox();
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.only(top: 100),
        child: Center(child: GestureDetector(
          onTap: _unlockPosition,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.amber, width: 1.5),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock, color: Colors.amber, size: 14),
              SizedBox(width: 6),
              Text('Expozícia zamknutá — ťukni pre odomknutie', style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold)),
            ]),
          ),
        )),
      )),
    );
  }

  Widget _buildLensSwitcher() {
    if (_cameras == null || _cameras!.length <= 1) return const SizedBox();
    final labels = _lensLabels;
    return Positioned(
      bottom: 30, left: 16,
      child: SafeArea(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: List.generate(_cameras!.length, (i) {
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
        })),
      )),
    );
  }

  Widget _buildCountdown() {
    final progress = _timerSeconds > 0 ? _timerCountdown / _timerSeconds : 0.0;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: progress + (1 / _timerSeconds), end: progress),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeInOut,
        builder: (_, animProgress, __) {
          return SizedBox(
            width: 160, height: 160,
            child: CustomPaint(
              painter: _CountdownPainter(
                progress: animProgress,
                color: _uiColor,
                countdown: _timerCountdown,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSkyMap() {
    return Positioned(
      right: 16, bottom: 140,
      child: Container(
        width: 110, height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.65),
          border: Border.all(color: _nightMode ? Colors.red.shade900 : (_sunMode ? Colors.orange.withOpacity(0.4) : Colors.white24), width: 1.5),
        ),
        child: CustomPaint(painter: SkyMapPainter(
          moonAzimuth: _moonPosition?.azimuth ?? 0,
          moonAltitude: _moonPosition?.altitude ?? -90,
          sunAzimuth: _sunPosition?.azimuth ?? 0,
          sunAltitude: _sunPosition?.altitude ?? -90,
          deviceAzimuth: _deviceAzimuth,
          nightMode: _nightMode,
          sunMode: _sunMode,
        )),
      ),
    );
  }

  Widget _buildOverlay() {
    return LayoutBuilder(builder: (context, constraints) {
      final cx = constraints.maxWidth / 2, cy = constraints.maxHeight / 2;
      final offset = _getScreenOffset();
      if (offset == null) return const SizedBox();
      final inFrame = _isTargetInFrame();
      if (inFrame) {
        final smoothedPos = _getSmoothedCirclePosition(cx, cy);
        if (smoothedPos == null) return const SizedBox();
        return AnimatedBuilder(
          animation: Listenable.merge([_pulseAnimation, _rotateAnimation]),
          builder: (_, __) => CustomPaint(
            painter: TargetCirclePainter(
              center: smoothedPos,
              radius: 60 * _pulseAnimation.value,
              rotation: _rotateAnimation.value,
              color: _targetColor,
              isLocked: _isLocked,
              isSun: _sunMode,
            ),
            child: const SizedBox.expand(),
          ),
        );
      } else {
        final angle = atan2(offset.dy, offset.dx);
        return CustomPaint(
          painter: TargetArrowPainter(
            centerX: cx, centerY: cy,
            angle: angle,
            altitude: _targetAltitude ?? 0,
            color: _targetColor,
            isSun: _sunMode,
          ),
          child: const SizedBox.expand(),
        );
      }
    });
  }

  Widget _buildTopBar() {
    final aboveHorizon = _targetAboveHorizon;
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            GestureDetector(
              onTap: _toggleMode,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _sunMode ? Colors.orange.withOpacity(0.2) : Colors.blue.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _sunMode ? Colors.orange : Colors.white38, width: 1.5),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_sunMode ? '☀️' : '🌙', style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 6),
                  Text(_sunMode ? 'SLNKO' : 'MESIAC', style: TextStyle(color: _uiColor, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1)),
                ]),
              ),
            ),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: aboveHorizon ? (_sunMode ? Colors.orange.withOpacity(0.2) : Colors.blue.withOpacity(0.3)) : Colors.red.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: aboveHorizon ? (_sunMode ? Colors.orange : Colors.blue) : Colors.red),
                ),
                child: Text(aboveHorizon ? '↑ NAD' : '↓ POD', style: TextStyle(color: _uiColorDim, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _openPanel(0),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _showPanel ? _uiColor.withOpacity(0.3) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _showPanel ? _uiColor.withOpacity(0.6) : Colors.white38),
                  ),
                  child: Icon(Icons.tune, color: _showPanel ? _uiColor : Colors.white, size: 18),
                ),
              ),
            ]),
          ]),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _infoChip('AZ', '${(_targetAzimuth ?? 0).toStringAsFixed(1)}°'),
            const SizedBox(width: 6),
            _infoChip('ALT', '${(_targetAltitude ?? 0).toStringAsFixed(1)}°'),
            const SizedBox(width: 6),
            _infoChip('TILT', '${_devicePitch.toStringAsFixed(1)}°'),
          ]),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (!_sunMode) Text(_getMoonPhase(), style: TextStyle(color: _uiColorDim, fontSize: 11)),
            if (!_sunMode) const SizedBox(width: 8),
            Text('🌅 ${_getRiseTime(_sunMode)}  🌇 ${_getSetTime(_sunMode)}', style: TextStyle(color: _uiColorDim, fontSize: 11)),
          ]),
        ]),
      )),
    );
  }

  Widget _infoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: _uiColor.withOpacity(0.2))),
      child: RichText(text: TextSpan(children: [
        TextSpan(text: '$label ', style: TextStyle(color: _uiColorDim, fontSize: 10)),
        TextSpan(text: value, style: TextStyle(color: _uiColor, fontSize: 11, fontWeight: FontWeight.bold)),
      ])),
    );
  }

  Widget _buildBottomControls() {
    final inFrame = _isTargetInFrame();
    final emoji = _sunMode ? '☀️' : '🌙';
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 32),
        child: Column(children: [
          Text(
            _timerCountdown > 0
                ? '⏱️ Fotím za $_timerCountdown s...'
                : _isLocked
                    ? '🔒 Expozícia zamknutá — ťukni pre odomknutie'
                    : inFrame
                        ? '👆 Ťukni na $emoji pre zamknutie expozície'
                        : _targetAboveHorizon
                            ? '👆 Namiery telefón podľa šípky'
                            : '😔 ${_sunMode ? "Slnko" : "Mesiac"} je pod horizontom',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _isLocked ? Colors.amber : inFrame ? Colors.greenAccent : _uiColorDim,
              fontSize: 13,
              fontWeight: _isLocked || inFrame ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 80,
            child: Stack(alignment: Alignment.center, children: [
              // Tlačidlo fotky – vždy presne v strede
              GestureDetector(
                onTap: _timerCountdown > 0 ? null : _startTimerAndShoot,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isTakingPhoto || _timerCountdown > 0
                        ? _uiColor.withOpacity(0.3)
                        : _isLocked
                            ? Colors.amber
                            : inFrame
                                ? _uiColor
                                : _uiColor.withOpacity(0.4),
                    border: Border.all(
                      color: _isLocked ? Colors.amber : inFrame ? _uiColor : _uiColor.withOpacity(0.4),
                      width: 3,
                    ),
                    boxShadow: _isLocked || inFrame
                        ? [BoxShadow(color: (_isLocked ? Colors.amber : _uiColor).withOpacity(0.4), blurRadius: 20, spreadRadius: 5)]
                        : null,
                  ),
                  child: _isTakingPhoto
                      ? Center(child: CircularProgressIndicator(color: _uiColor))
                      : Icon(Icons.camera, size: 36, color: _isLocked || inFrame ? Colors.black : _uiColor.withOpacity(0.5)),
                ),
              ),
              // Timer badge – vľavo
              if (_timerSeconds > 0) Positioned(
                left: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: _uiColor.withOpacity(0.3))),
                  child: Text('⏱ ${_timerSeconds}s', style: TextStyle(color: _uiColor, fontSize: 12)),
                ),
              ),
              // Zoom badge – vpravo
              if (_zoomLevel > 1.0) Positioned(
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: _uiColor.withOpacity(0.3))),
                  child: Text('🔭 ${_zoomLevel.toStringAsFixed(1)}x', style: TextStyle(color: _uiColor, fontSize: 12)),
                ),
              ),
            ]),
          ),
        ]),
      )),
    );
  }
}

class GridPainter extends CustomPainter {
  final Color color;
  GridPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 0.8;
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), paint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), paint);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
    final cx = size.width / 2, cy = size.height / 2;
    final cp = Paint()..color = color.withOpacity(0.8)..strokeWidth = 1;
    canvas.drawLine(Offset(cx - 20, cy), Offset(cx + 20, cy), cp);
    canvas.drawLine(Offset(cx, cy - 20), Offset(cx, cy + 20), cp);
    canvas.drawCircle(Offset(cx, cy), 3, Paint()..color = color.withOpacity(0.8));
  }
  @override
  bool shouldRepaint(GridPainter old) => false;
}

class SkyMapPainter extends CustomPainter {
  final double moonAzimuth, moonAltitude, sunAzimuth, sunAltitude, deviceAzimuth;
  final bool nightMode, sunMode;
  SkyMapPainter({required this.moonAzimuth, required this.moonAltitude, required this.sunAzimuth, required this.sunAltitude, required this.deviceAzimuth, this.nightMode = false, this.sunMode = false});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2 - 4;
    canvas.drawCircle(Offset(cx, cy), r, Paint()..color = nightMode ? Colors.red.shade900 : const Color(0xFF0A0A2A));
    canvas.drawCircle(Offset(cx, cy), r * 0.95, Paint()..color = Colors.white.withOpacity(0.12)..style = PaintingStyle.stroke..strokeWidth = 0.5);
    for (double alt in [30, 60]) {
      canvas.drawCircle(Offset(cx, cy), r * (1 - alt / 90) * 0.95, Paint()..color = Colors.white.withOpacity(0.1)..style = PaintingStyle.stroke..strokeWidth = 0.5);
    }
    final dirPaint = TextPainter(textDirection: TextDirection.ltr);
    for (var entry in {'N': 0.0, 'E': 90.0, 'S': 180.0, 'W': 270.0}.entries) {
      final angle = (entry.value - deviceAzimuth) * pi / 180;
      final dx = cx + sin(angle) * (r * 0.82), dy = cy - cos(angle) * (r * 0.82);
      dirPaint.text = TextSpan(text: entry.key, style: TextStyle(color: entry.key == 'N' ? Colors.redAccent : Colors.white38, fontSize: 8, fontWeight: FontWeight.bold));
      dirPaint.layout();
      dirPaint.paint(canvas, Offset(dx - dirPaint.width / 2, dy - dirPaint.height / 2));
    }
    final fovAngle = 30.0 * pi / 180;
    canvas.drawPath(
      Path()..moveTo(cx, cy)..arcTo(Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.9), -pi / 2 - fovAngle / 2, fovAngle, false)..close(),
      Paint()..color = Colors.white.withOpacity(0.08),
    );
    if (moonAltitude > -10) {
      final moonAngle = (moonAzimuth - deviceAzimuth) * pi / 180;
      final moonR = r * (1 - (moonAltitude.clamp(-10.0, 90.0) + 10) / 100) * 0.9;
      canvas.drawCircle(Offset(cx + sin(moonAngle) * moonR, cy - cos(moonAngle) * moonR), sunMode ? 3 : 5, Paint()..color = moonAltitude > 0 ? Colors.white70 : Colors.white30);
    }
    if (sunAltitude > -10) {
      final sunAngle = (sunAzimuth - deviceAzimuth) * pi / 180;
      final sunR = r * (1 - (sunAltitude.clamp(-10.0, 90.0) + 10) / 100) * 0.9;
      final sx = cx + sin(sunAngle) * sunR, sy = cy - cos(sunAngle) * sunR;
      canvas.drawCircle(Offset(sx, sy), 6, Paint()..color = Colors.yellow.withOpacity(0.3)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawCircle(Offset(sx, sy), sunMode ? 5 : 3, Paint()..color = sunAltitude > 0 ? Colors.yellow : Colors.yellow.withOpacity(0.4));
    }
    canvas.drawCircle(Offset(cx, cy), 3, Paint()..color = Colors.white54..style = PaintingStyle.fill);
    final labelTp = TextPainter(text: const TextSpan(text: 'OBLOHA', style: TextStyle(color: Colors.white30, fontSize: 7, letterSpacing: 1)), textDirection: TextDirection.ltr)..layout();
    labelTp.paint(canvas, Offset(cx - labelTp.width / 2, size.height - 12));
  }
  @override
  bool shouldRepaint(SkyMapPainter old) => true;
}

class TargetCirclePainter extends CustomPainter {
  final Offset center;
  final double radius, rotation;
  final Color color;
  final bool isLocked, isSun;
  TargetCirclePainter({required this.center, required this.radius, required this.rotation, required this.color, this.isLocked = false, this.isSun = false});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(center, radius, Paint()..color = color.withOpacity(0.12)..style = PaintingStyle.stroke..strokeWidth = 20..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15));
    canvas.drawCircle(center, radius, Paint()..color = color.withOpacity(0.85)..style = PaintingStyle.stroke..strokeWidth = isLocked ? 3 : 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    final dashPaint = Paint()..color = color.withOpacity(0.4)..style = PaintingStyle.stroke..strokeWidth = 1;
    for (int i = 0; i < 24; i++) {
      final angle = (i / 24) * 2 * pi;
      canvas.drawLine(Offset(cos(angle) * (radius + 8), sin(angle) * (radius + 8)), Offset(cos(angle) * (radius + 16), sin(angle) * (radius + 16)), dashPaint);
    }
    canvas.restore();
    final lp = Paint()..color = color.withOpacity(0.5)..strokeWidth = 1;
    canvas.drawLine(Offset(center.dx, center.dy - radius - 10), Offset(center.dx, center.dy - radius + 10), lp);
    canvas.drawLine(Offset(center.dx, center.dy + radius - 10), Offset(center.dx, center.dy + radius + 10), lp);
    canvas.drawLine(Offset(center.dx - radius - 10, center.dy), Offset(center.dx - radius + 10, center.dy), lp);
    canvas.drawLine(Offset(center.dx + radius - 10, center.dy), Offset(center.dx + radius + 10, center.dy), lp);
    canvas.drawCircle(center, 3, Paint()..color = color.withOpacity(0.6)..style = PaintingStyle.fill);
    final label = isLocked ? '🔒 ${isSun ? "SLNKO" : "MESIAC"}' : (isSun ? '☀️ SLNKO' : '🌙 MESIAC');
    final tp = TextPainter(
      text: TextSpan(text: label, style: TextStyle(color: color.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.bold, shadows: [Shadow(color: Colors.black, blurRadius: 4)])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + radius + 14));
  }
  @override
  bool shouldRepaint(TargetCirclePainter old) => old.radius != radius || old.rotation != rotation || old.isLocked != isLocked || old.center != center;
}

class TargetArrowPainter extends CustomPainter {
  final double centerX, centerY, angle, altitude;
  final Color color;
  final bool isSun;
  TargetArrowPainter({required this.centerX, required this.centerY, required this.angle, required this.altitude, required this.color, this.isSun = false});
  @override
  void paint(Canvas canvas, Size size) {
    final ax = centerX + cos(angle) * 120.0, ay = centerY + sin(angle) * 120.0;
    canvas.drawCircle(Offset(ax, ay), 36, Paint()..color = Colors.black.withOpacity(0.4));
    canvas.drawCircle(Offset(ax, ay), 36, Paint()..color = color.withOpacity(0.6)..style = PaintingStyle.stroke..strokeWidth = 1.5);
    canvas.save();
    canvas.translate(ax, ay);
    canvas.rotate(angle);
    canvas.drawPath(Path()..moveTo(20, 0)..lineTo(-10, -10)..lineTo(-5, 0)..lineTo(-10, 10)..close(), Paint()..color = color..style = PaintingStyle.fill);
    canvas.restore();
    final emoji = isSun ? '☀️' : '🌙';
    final tp = TextPainter(text: TextSpan(text: emoji, style: const TextStyle(fontSize: 16)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(ax - tp.width / 2, ay - tp.height / 2 - 20));
    final altTp = TextPainter(
      text: TextSpan(text: '${altitude.toStringAsFixed(0)}°', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    altTp.paint(canvas, Offset(ax - altTp.width / 2, ay + 14));
  }
  @override
  bool shouldRepaint(TargetArrowPainter old) => true;
}

class _CountdownPainter extends CustomPainter {
  final double progress; // 1.0 = plný kruh, 0.0 = prázdny
  final Color color;
  final int countdown;

  _CountdownPainter({required this.progress, required this.color, required this.countdown});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final radius = size.width / 2 - 8;

    // Tmavé pozadie kruhu
    canvas.drawCircle(
      Offset(cx, cy), radius,
      Paint()..color = Colors.black.withOpacity(0.75),
    );

    // Tichý kruh (pozadie oblúka)
    canvas.drawCircle(
      Offset(cx, cy), radius,
      Paint()
        ..color = color.withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );

    // Svietiaci oblúk – progress
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -pi / 2,
      2 * pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Ostrá vrstva oblúka nad blur
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      -pi / 2,
      2 * pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );

    // Číslo v strede
    final tp = TextPainter(
      text: TextSpan(
        text: '$countdown',
        style: TextStyle(
          color: color,
          fontSize: 64,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

    // Malý popis pod číslom
    final subTp = TextPainter(
      text: TextSpan(
        text: 'sekúnd',
        style: TextStyle(color: color.withOpacity(0.5), fontSize: 13, letterSpacing: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    subTp.paint(canvas, Offset(cx - subTp.width / 2, cy + tp.height / 2 - 4));
  }

  @override
  bool shouldRepaint(_CountdownPainter old) => old.progress != progress || old.countdown != countdown;
}