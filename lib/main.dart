import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hardware_button_listener/hardware_button_listener.dart';
import 'package:hardware_button_listener/models/hardware_button.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Global theme notifier
final themeNotifier = ValueNotifier<bool>(false); // true = dark mode

// ============================================================================
// GPS & Sensor Measurement Classes
// ============================================================================

/// GPS point with timestamp and accuracy
class GpsPoint {
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime timestamp;

  GpsPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lon': longitude,
        't': timestamp.millisecondsSinceEpoch,
      };

  factory GpsPoint.fromJson(Map<String, dynamic> json) => GpsPoint(
        latitude: json['lat'] as double,
        longitude: json['lon'] as double,
        accuracy: 0.0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
      );
}

/// Speed sample at a specific distance
class SpeedSample {
  final double distance;
  final double speed;
  final DateTime timestamp;

  SpeedSample({
    required this.distance,
    required this.speed,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'distance': distance,
        'speed': speed,
      };
}

/// Course type for GPS measurement
enum GpsCourseType { straight, track }

/// GPS warmup status
class GpsWarmupStatus {
  final bool isReady;
  final double accuracy;
  final String message;

  GpsWarmupStatus({
    required this.isReady,
    required this.accuracy,
    required this.message,
  });
}

/// GPS measurement result
class GpsMeasurementResult {
  final double elapsedTime;
  final double totalDistance;
  final double initialSpeed;
  final double finalSpeed;
  final double topSpeed;
  final double averageSpeed;
  final double estimatedAccuracy;
  final List<GpsPoint> trackPoints;
  final List<SpeedSample> speedProfile;
  final int gpsUpdateCount; // Number of GPS updates received

  GpsMeasurementResult({
    required this.elapsedTime,
    required this.totalDistance,
    required this.initialSpeed,
    required this.finalSpeed,
    required this.topSpeed,
    required this.averageSpeed,
    required this.estimatedAccuracy,
    required this.trackPoints,
    required this.speedProfile,
    required this.gpsUpdateCount,
  });

  Map<String, dynamic> toJson() => {
        'distance': totalDistance,
        'initialSpeed': initialSpeed,
        'finalSpeed': finalSpeed,
        'topSpeed': topSpeed,
        'averageSpeed': averageSpeed,
        'estimatedAccuracy': estimatedAccuracy,
        'gpsUpdateCount': gpsUpdateCount,
        'trackPoints': trackPoints
            .where((p) => trackPoints.indexOf(p) % max(1, trackPoints.length ~/ 100) == 0)
            .map((p) => p.toJson())
            .toList(),
        'speedProfile': speedProfile.map((s) => s.toJson()).toList(),
      };
}

/// 6-dimensional Kalman Filter for GPS + IMU fusion
/// State vector: [x, y, vx, vy, ax, ay]
/// x, y: Position in meters (local tangent plane)
/// vx, vy: Velocity in m/s
/// ax, ay: Acceleration in m/s²
class KalmanFilter6D {
  // State vector [x, y, vx, vy, ax, ay]
  List<double> _state = List.filled(6, 0.0);

  // 6x6 Error covariance matrix P (stored as flat list)
  List<double> _P = List.filled(36, 0.0);

  // Origin for local coordinate conversion
  double? _originLat;
  double? _originLon;

  // Last update time for dt calculation
  DateTime? _lastUpdate;

  // Process noise parameters
  final double _processNoisePosition = 0.1;
  final double _processNoiseVelocity = 1.0;
  final double _processNoiseAccel = 5.0;

  /// Initialize filter with starting GPS position
  void initialize(double latitude, double longitude) {
    _originLat = latitude;
    _originLon = longitude;
    _state = List.filled(6, 0.0);
    _lastUpdate = DateTime.now();

    // Initialize covariance with high uncertainty
    _P = List.filled(36, 0.0);
    _P[0] = 10.0;  // x variance (position uncertainty ~3m)
    _P[7] = 10.0;  // y variance
    _P[14] = 100.0; // vx variance (velocity unknown, ~10 m/s std dev)
    _P[21] = 100.0; // vy variance
    _P[28] = 25.0;  // ax variance (acceleration ~5 m/s² std dev)
    _P[35] = 25.0;  // ay variance
  }

  /// Predict step: project state forward
  void predict(double dt) {
    if (dt <= 0) return;

    final dt2 = dt * dt * 0.5;

    // State prediction (constant acceleration model)
    final x = _state[0] + _state[2] * dt + _state[4] * dt2;
    final y = _state[1] + _state[3] * dt + _state[5] * dt2;
    final vx = _state[2] + _state[4] * dt;
    final vy = _state[3] + _state[5] * dt;
    final ax = _state[4];
    final ay = _state[5];

    _state = [x, y, vx, vy, ax, ay];

    // Simplified covariance prediction (add process noise)
    _P[0] += _processNoisePosition * dt;
    _P[7] += _processNoisePosition * dt;
    _P[14] += _processNoiseVelocity * dt;
    _P[21] += _processNoiseVelocity * dt;
    _P[28] += _processNoiseAccel * dt;
    _P[35] += _processNoiseAccel * dt;
  }

  // Previous GPS position for velocity calculation
  double? _prevGpsX;
  double? _prevGpsY;
  DateTime? _prevGpsTime;

  /// Update with GPS measurement
  /// gpsSpeed: GPS-reported speed in m/s (negative if unavailable)
  /// gpsHeading: GPS-reported heading in degrees (negative if unavailable)
  void updateWithGPS(double latitude, double longitude, double accuracy,
      {double gpsSpeed = -1, double gpsHeading = -1}) {
    if (_originLat == null || _originLon == null) {
      initialize(latitude, longitude);
      return;
    }

    final now = DateTime.now();
    double dt = 0.0;
    if (_lastUpdate != null) {
      dt = now.difference(_lastUpdate!).inMicroseconds / 1e6;
      if (dt > 0) {
        predict(dt);
      }
    }
    _lastUpdate = now;

    // Convert GPS to local coordinates
    final localPos = _gpsToLocal(latitude, longitude);
    final zx = localPos[0];
    final zy = localPos[1];

    // Measurement noise based on GPS accuracy (minimum 3m)
    final R = max(accuracy * accuracy, 9.0);

    // Update position with Kalman filter
    final Kx = _P[0] / (_P[0] + R);
    final Ky = _P[7] / (_P[7] + R);

    _state[0] += Kx * (zx - _state[0]);
    _state[1] += Ky * (zy - _state[1]);

    _P[0] *= (1 - Kx);
    _P[7] *= (1 - Ky);

    // Update velocity from GPS position change
    if (_prevGpsX != null && _prevGpsY != null && _prevGpsTime != null) {
      final gpsDt = now.difference(_prevGpsTime!).inMicroseconds / 1e6;
      if (gpsDt > 0.05) {  // At least 50ms between measurements
        // Calculate velocity from position change
        final observedVx = (zx - _prevGpsX!) / gpsDt;
        final observedVy = (zy - _prevGpsY!) / gpsDt;
        final observedSpeed = sqrt(observedVx * observedVx + observedVy * observedVy);

        // If GPS provides valid speed (> 0), use it to validate/correct
        // gpsSpeed < 0 means unavailable (iOS), gpsSpeed = 0 could be unavailable (Android) or stationary
        double finalVx = observedVx;
        double finalVy = observedVy;

        if (gpsSpeed > 0.5) {
          // GPS speed is available and user is moving - use GPS speed magnitude
          // Scale the direction from position change, magnitude from GPS
          if (observedSpeed > 0.1) {
            final scale = gpsSpeed / observedSpeed;
            finalVx = observedVx * scale;
            finalVy = observedVy * scale;
          } else {
            // Position change is too small, use GPS speed with heading if available
            if (gpsHeading >= 0) {
              final headingRad = gpsHeading * pi / 180;
              finalVx = gpsSpeed * sin(headingRad);
              finalVy = gpsSpeed * cos(headingRad);
            }
          }
        }

        // Velocity measurement noise
        // If GPS speed was used, noise is low (GPS Doppler speed is accurate ~0.1 m/s)
        // If position-based only, noise is high (position uncertainty / time)
        final double Rv;
        if (gpsSpeed > 0.5) {
          // GPS speed is accurate (Doppler-based)
          Rv = 0.25;  // ~0.5 m/s standard deviation
        } else {
          // Position-derived velocity has higher noise
          Rv = (R * 2) / (gpsDt * gpsDt) + 1.0;
        }

        final Kvx = _P[14] / (_P[14] + Rv);
        final Kvy = _P[21] / (_P[21] + Rv);

        _state[2] += Kvx * (finalVx - _state[2]);
        _state[3] += Kvy * (finalVy - _state[3]);

        _P[14] *= (1 - Kvx);
        _P[21] *= (1 - Kvy);
      }
    }

    // Store current GPS position for next velocity calculation
    _prevGpsX = zx;
    _prevGpsY = zy;
    _prevGpsTime = now;
  }

  /// Get current estimated position in local coordinates
  List<double> getPositionLocal() => [_state[0], _state[1]];

  /// Get current estimated position in GPS coordinates
  List<double> getPositionGPS() {
    if (_originLat == null || _originLon == null) return [0.0, 0.0];
    return _localToGps(_state[0], _state[1]);
  }

  /// Get current estimated speed (magnitude)
  double getSpeed() => sqrt(_state[2] * _state[2] + _state[3] * _state[3]);

  /// Get current velocity vector
  List<double> getVelocity() => [_state[2], _state[3]];

  /// Get current acceleration magnitude
  double getAcceleration() =>
      sqrt(_state[4] * _state[4] + _state[5] * _state[5]);

  /// Get position uncertainty (1-sigma)
  double getPositionUncertainty() => sqrt((_P[0] + _P[7]) / 2);

  /// Convert GPS to local tangent plane coordinates (meters)
  List<double> _gpsToLocal(double lat, double lon) {
    if (_originLat == null || _originLon == null) return [0.0, 0.0];

    const R = 6371000.0; // Earth radius in meters
    final latRad = _originLat! * pi / 180;

    final x = (lon - _originLon!) * pi / 180 * R * cos(latRad);
    final y = (lat - _originLat!) * pi / 180 * R;

    return [x, y];
  }

  /// Convert local coordinates back to GPS
  List<double> _localToGps(double x, double y) {
    if (_originLat == null || _originLon == null) return [0.0, 0.0];

    const R = 6371000.0;
    final latRad = _originLat! * pi / 180;

    final lon = _originLon! + (x / (R * cos(latRad))) * 180 / pi;
    final lat = _originLat! + (y / R) * 180 / pi;

    return [lat, lon];
  }

  /// Reset the filter
  void reset() {
    _state = List.filled(6, 0.0);
    _P = List.filled(36, 0.0);
    _originLat = null;
    _originLon = null;
    _lastUpdate = null;
    _prevGpsX = null;
    _prevGpsY = null;
    _prevGpsTime = null;
  }
}

/// Main GPS measurement service (GPS only, no accelerometer/gyroscope)
class GpsSensorMeasurement {
  // Configuration
  double targetDistance;
  GpsCourseType courseType;

  // Kalman filter for GPS smoothing
  final KalmanFilter6D _kalman = KalmanFilter6D();

  // GPS subscription
  StreamSubscription<Position>? _gpsSubscription;

  // State
  bool _isRunning = false;
  DateTime? _startTime;
  GpsPoint? _startPosition;
  double _totalDistance = 0.0;
  GpsPoint? _lastGpsPoint;

  // Data collection
  final List<GpsPoint> _trackPoints = [];
  final List<SpeedSample> _speedSamples = [];
  double _maxSpeed = 0.0;
  double? _initialSpeed;
  double? _finalSpeed;
  double _avgGpsAccuracy = 0.0;
  int _gpsAccuracyCount = 0;

  // Stream controllers for UI updates
  final _distanceController = StreamController<double>.broadcast();
  final _speedController = StreamController<double>.broadcast();
  final _accuracyController = StreamController<double>.broadcast();

  // Public streams
  Stream<double> get distanceStream => _distanceController.stream;
  Stream<double> get speedStream => _speedController.stream;
  Stream<double> get accuracyStream => _accuracyController.stream;

  GpsSensorMeasurement({
    this.targetDistance = 100.0,
    this.courseType = GpsCourseType.straight,
  });

  /// Check and request GPS permissions (including background location)
  Future<bool> requestPermissions() async {
    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    // Check permission status
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    // For background operation, we need 'always' permission
    // If only 'whileInUse', the app will work but may not track in background
    // Note: On Android 10+, background permission must be requested separately
    // and users may need to manually enable it in settings
    return true;
  }

  /// Check if background location is enabled
  Future<bool> isBackgroundLocationEnabled() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always;
  }

  /// GPS warmup - get initial fix and accuracy
  Future<GpsWarmupStatus> warmup({Duration timeout = const Duration(seconds: 30)}) async {
    try {
      // Try to get a high-accuracy position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: timeout,
      );

      final isReady = position.accuracy <= 10.0;
      return GpsWarmupStatus(
        isReady: isReady,
        accuracy: position.accuracy,
        message: isReady
            ? 'GPS準備完了 (精度: ${position.accuracy.toStringAsFixed(1)}m)'
            : 'GPS精度が低いです (${position.accuracy.toStringAsFixed(1)}m)',
      );
    } catch (e) {
      return GpsWarmupStatus(
        isReady: false,
        accuracy: 0.0,
        message: 'GPS取得に失敗しました: $e',
      );
    }
  }

  /// Sensor calibration (stub - sensors removed, GPS-only mode)
  Future<void> calibrateSensors() async {
    // No-op: Accelerometer and gyroscope sensors have been removed
    // GPS doesn't require calibration
    return;
  }

  /// Start GPS measurement
  void startMeasurement(DateTime goSignalTime) {
    if (_isRunning) return;

    _isRunning = true;
    _startTime = goSignalTime;
    _totalDistance = 0.0;
    _maxSpeed = 0.0;
    _initialSpeed = null;
    _finalSpeed = null;
    _trackPoints.clear();
    _speedSamples.clear();
    _avgGpsAccuracy = 0.0;
    _gpsAccuracyCount = 0;
    _lastGpsPoint = null;
    _startPosition = null;

    _kalman.reset();

    // Start GPS subscription with platform-specific settings for background operation
    late LocationSettings locationSettings;

    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 100), // Request updates every 100ms
        forceLocationManager: true, // Use LocationManager instead of FusedLocationProvider for higher frequency
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: 'GPS計測中...',
          notificationTitle: 'STARTER PISTOL',
          enableWakeLock: true,
          notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        ),
      );
    } else if (Platform.isIOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.fitness,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      );
    }

    _gpsSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(_onGpsUpdate);
  }

  /// Stop measurement and return results
  GpsMeasurementResult stopMeasurement() {
    _isRunning = false;

    // Cancel GPS subscription
    _gpsSubscription?.cancel();
    _gpsSubscription = null;

    final elapsed = _startTime != null
        ? DateTime.now().difference(_startTime!).inMilliseconds / 1000.0
        : 0.0;

    final avgSpeed = elapsed > 0 ? _totalDistance / elapsed : 0.0;

    return GpsMeasurementResult(
      elapsedTime: elapsed,
      totalDistance: _totalDistance,
      initialSpeed: _initialSpeed ?? 0.0,
      finalSpeed: _finalSpeed ?? _kalman.getSpeed(),
      topSpeed: _maxSpeed,
      averageSpeed: avgSpeed,
      estimatedAccuracy: _calculateTimeAccuracy(),
      trackPoints: List.from(_trackPoints),
      speedProfile: List.from(_speedSamples),
      gpsUpdateCount: _gpsAccuracyCount,
    );
  }

  void _onGpsUpdate(Position position) {
    if (!_isRunning) return;

    final now = DateTime.now();
    final point = GpsPoint(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      timestamp: now,
    );

    // Update accuracy tracking
    _avgGpsAccuracy = (_avgGpsAccuracy * _gpsAccuracyCount + position.accuracy) /
        (_gpsAccuracyCount + 1);
    _gpsAccuracyCount++;

    _accuracyController.add(position.accuracy);

    // Initialize Kalman filter with first GPS point
    if (_startPosition == null) {
      _startPosition = point;
      _kalman.initialize(position.latitude, position.longitude);
    }

    // Update Kalman filter with GPS (including speed and heading if available)
    _kalman.updateWithGPS(
      position.latitude,
      position.longitude,
      position.accuracy,
      gpsSpeed: position.speed,
      gpsHeading: position.heading,
    );

    // Calculate distance from last point
    if (_lastGpsPoint != null) {
      final dist = _haversineDistance(
        _lastGpsPoint!.latitude,
        _lastGpsPoint!.longitude,
        position.latitude,
        position.longitude,
      );
      _totalDistance += dist;
    }
    _lastGpsPoint = point;

    // Record track point
    _trackPoints.add(point);

    // Get current speed from Kalman filter
    final speed = _kalman.getSpeed();
    _updateSpeedData(speed);

    // Broadcast updates
    _distanceController.add(_totalDistance);
    _speedController.add(speed);
  }

  void _updateSpeedData(double speed) {
    // Update max speed
    if (speed > _maxSpeed) _maxSpeed = speed;

    // Update initial speed (at ~10m)
    if (_initialSpeed == null && _totalDistance >= 10.0) {
      _initialSpeed = speed;
    }

    // Always update final speed
    _finalSpeed = speed;

    // Add speed sample (throttled to ~10Hz)
    if (_speedSamples.isEmpty ||
        DateTime.now().difference(_speedSamples.last.timestamp).inMilliseconds >= 100) {
      _speedSamples.add(SpeedSample(
        distance: _totalDistance,
        speed: speed,
        timestamp: DateTime.now(),
      ));
    }
  }

  double _calculateTimeAccuracy() {
    // Estimate time accuracy based on GPS accuracy and speed
    final speed = _finalSpeed ?? _kalman.getSpeed();
    if (speed <= 0) return 1.0;

    // Position uncertainty / speed = time uncertainty
    final posUncertainty = max(_avgGpsAccuracy, 3.0);
    return posUncertainty / speed;
  }

  /// Haversine formula for distance between two GPS points
  double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius in meters
    final phi1 = lat1 * pi / 180;
    final phi2 = lat2 * pi / 180;
    final deltaPhi = (lat2 - lat1) * pi / 180;
    final deltaLambda = (lon2 - lon1) * pi / 180;

    final a = sin(deltaPhi / 2) * sin(deltaPhi / 2) +
        cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return R * c;
  }

  /// Get current state
  bool get isRunning => _isRunning;
  double get currentDistance => _totalDistance;
  double get currentSpeed => _kalman.getSpeed();

  /// Dispose resources
  void dispose() {
    _gpsSubscription?.cancel();
    _distanceController.close();
    _speedController.close();
    _accuracyController.close();
  }
}

// ============================================================================
// End of GPS & Sensor Measurement Classes
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  themeNotifier.value = prefs.getBool('dark_mode') ?? false;
  runApp(const StartCallApp());
}

// Theme colors for dark and light modes
class AppColors {
  final bool isDark;

  AppColors({required this.isDark});

  // Background colors
  Color get scaffoldBackground =>
      isDark ? Colors.black : const Color(0xFFF5F5F5);
  Color get cardBackground => isDark ? const Color(0xFF141B26) : Colors.white;
  Color get sheetBackground =>
      isDark ? const Color(0xFF0E131A) : const Color(0xFFF0F0F0);
  Color get inputBackground =>
      isDark ? const Color(0xFF1A2332) : const Color(0xFFE8E8E8);
  Color get dragHandleColor =>
      isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD);

  // Border/shadow colors
  Color get cardBorder =>
      isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0);
  Color get inputBorder =>
      isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD);

  // Text colors
  Color get primaryText => isDark ? Colors.white : Colors.black87;
  Color get secondaryText => isDark ? Colors.white70 : Colors.black54;

  // Accent colors (same for both themes)
  static const accent = Color(0xFF6BCB1F);
  static const accentDark = Color(0xFF1D2B21);

  // Settings button background
  Color get settingsButtonBackground =>
      isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0);

  // Timer panel background
  Color get timerPanelBackground =>
      isDark ? const Color(0xFF141B26) : Colors.white;
  Color get timerProgressBackground =>
      isDark ? const Color(0xFF1A2332) : const Color(0xFFE0E0E0);
}

// Audio option model
class AudioOption {
  final String name;
  final String path;

  const AudioOption({required this.name, required this.path});
}

// Audio options for each phase
class AudioOptions {
  static const String noAudio = ''; // Empty path means no audio

  static const List<AudioOption> onYourMarks = [
    AudioOption(name: '音声なし', path: ''),
    AudioOption(
      name: 'On Your Marks (男性)',
      path: 'audio/On Your Marks/On_Your_Marks_Male.mp3',
    ),
    AudioOption(
      name: 'On Your Marks (女性)',
      path: 'audio/On Your Marks/On_Your_Marks_Female.mp3',
    ),
    AudioOption(
      name: '位置について (男性)',
      path: 'audio/On Your Marks/ichinitsuite_Male.mp3',
    ),
    AudioOption(
      name: '位置について (女性)',
      path: 'audio/On Your Marks/ichinitsuite_Female.mp3',
    ),
  ];

  static const List<AudioOption> set = [
    AudioOption(name: '音声なし', path: ''),
    AudioOption(name: 'Set (男性)', path: 'audio/Set/Set_Male.mp3'),
    AudioOption(name: 'Set (女性)', path: 'audio/Set/Set_Female.mp3'),
    AudioOption(name: '用意 (男性)', path: 'audio/Set/youi_Male.mp3'),
    AudioOption(name: '用意 (女性)', path: 'audio/Set/youi_Female.mp3'),
  ];

  static const List<AudioOption> go = [
    AudioOption(name: 'ピストル 01', path: 'audio/Go/pan_01.mp3'),
    AudioOption(name: 'ピストル 02', path: 'audio/Go/pan_02.mp3'),
    AudioOption(name: 'ピストル 03', path: 'audio/Go/pan_03.mp3'),
  ];
}

// Phase color definitions with gradients
class PhaseColors {
  // Start colors (medium saturation) - shown at beginning of countdown
  static const readyStart = Color(0xFF8ED860);
  static const onYourMarksStart = Color(0xFF64B5F6);
  static const setStart = Color(0xFFEF5350); // Clear red from the start
  static const goStart = Color(0xFFFF1744); // Same as end (no countdown for Go)

  // End colors (fully saturated/vivid) - shown when countdown reaches 0
  static const ready = Color(0xFF4CAF50);
  static const readySecondary = Color(0xFF2E7D32);
  static const onYourMarks = Color(0xFF2196F3);
  static const onYourMarksSecondary = Color(0xFF1976D2);
  static const set = Color(0xFFD32F2F); // Deep vivid red
  static const setSecondary = Color(0xFFB71C1C); // Dark red
  static const go = Color(0xFFFF1744); // Vivid red-pink
  static const goSecondary = Color(0xFFD50000); // Deep red

  // Measuring colors (cyan/blue for timing)
  static const measuring = Color(0xFF00BCD4);
  static const measuringSecondary = Color(0xFF0097A7);

  // Finish colors (gold for achievement)
  static const finish = Color(0xFFFFD700);
  static const finishSecondary = Color(0xFFFFA000);

  // Flying colors (red for violation)
  static const flyingStart = Color(0xFFE53935);
  static const flyingStartSecondary = Color(0xFFB71C1C);

  static Color getStartColor(String phase) {
    switch (phase) {
      case 'Ready':
        return readyStart;
      case 'On Your Marks':
        return onYourMarksStart;
      case 'Set':
        return setStart;
      case 'Go':
        return goStart;
      case 'Measuring':
        return measuring;
      case 'FINISH':
        return finish;
      case 'FLYING START':
        return flyingStart;
      default:
        return readyStart;
    }
  }

  static Color getPrimaryColor(String phase) {
    switch (phase) {
      case 'Ready':
        return ready;
      case 'On Your Marks':
        return onYourMarks;
      case 'Set':
        return set;
      case 'Go':
        return go;
      case 'Measuring':
        return measuring;
      case 'FINISH':
        return finish;
      case 'FLYING START':
        return flyingStart;
      default:
        return ready;
    }
  }

  static Color getSecondaryColor(String phase) {
    switch (phase) {
      case 'Ready':
        return readySecondary;
      case 'On Your Marks':
        return onYourMarksSecondary;
      case 'Set':
        return setSecondary;
      case 'Go':
        return goSecondary;
      case 'Measuring':
        return measuringSecondary;
      case 'FINISH':
        return finishSecondary;
      case 'FLYING START':
        return flyingStartSecondary;
      default:
        return readySecondary;
    }
  }

  // Get interpolated color based on progress (0.0 = start, 1.0 = end)
  static Color getInterpolatedColor(String phase, double progress) {
    final startColor = getStartColor(phase);
    final endColor = getPrimaryColor(phase);
    return Color.lerp(startColor, endColor, progress) ?? endColor;
  }

  static Color getInterpolatedSecondaryColor(String phase, double progress) {
    final startColor = getStartColor(phase);
    final endColor = getSecondaryColor(phase);
    return Color.lerp(startColor, endColor, progress) ?? endColor;
  }
}

class StartCallApp extends StatelessWidget {
  const StartCallApp({super.key});

  ThemeData _buildTheme(bool isDark) {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6BCB1F),
        brightness: brightness,
      ),
      useMaterial3: true,
    );

    return baseTheme.copyWith(
      textTheme: GoogleFonts.spaceGroteskTextTheme(baseTheme.textTheme),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0.5,
        color: isDark ? const Color(0xFF141B26) : Colors.white,
        surfaceTintColor: isDark ? const Color(0xFF141B26) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: const Color(0xFF6BCB1F),
        inactiveTrackColor: isDark
            ? const Color(0xFF26332A)
            : const Color(0xFFD0D0D0),
        thumbColor: const Color(0xFF6BCB1F),
        overlayColor: const Color(0x336BCB1F),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Color(0xFF6BCB1F)),
        trackColor: WidgetStatePropertyAll(
          isDark ? const Color(0xFF1D2B21) : const Color(0xFFD0D0D0),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: themeNotifier,
      builder: (context, isDark, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Starter Pistol',
          theme: _buildTheme(isDark),
          home: const StartCallHomePage(),
        );
      },
    );
  }
}

class StartCallHomePage extends StatefulWidget {
  const StartCallHomePage({super.key});

  @override
  State<StartCallHomePage> createState() => _StartCallHomePageState();
}

class _StartCallHomePageState extends State<StartCallHomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AudioPlayer _player;
  late AudioPlayer _buzzerPlayer; // Separate player for flying buzzer
  final _random = Random();
  bool _isInBackground = false;
  SharedPreferences? _prefs;

  double _onFixed = 5.0;
  RangeValues _onRange = const RangeValues(1.5, 2.5);
  bool _randomOn = false;

  double _setFixed = 5.0;
  RangeValues _setRange = const RangeValues(0.8, 1.2);
  bool _randomSet = false;

  double _panFixed = 5.0;
  RangeValues _panRange = const RangeValues(0.8, 1.5);
  bool _randomPan = false;

  // Selected audio paths
  String _onAudioPath = AudioOptions.onYourMarks[1].path; // On Your Marks (男性)
  String _setAudioPath = AudioOptions.set[1].path; // Set (男性)
  String _goAudioPath = AudioOptions.go[0].path;

  bool _isRunning = false;
  bool _isPaused = false;
  bool _isFinished = false;
  bool _isSettingsOpen = false;
  String _phaseLabel = 'Starter Pistol';

  // Loop setting
  bool _loopEnabled = false;

  // Time measurement mode
  bool _timeMeasurementEnabled = false;

  // Trigger settings for time measurement
  // 'tap', 'hardware_button'
  String _triggerMethod = 'tap';

  // Lag compensation for trigger delay (0.00 - 1.00 seconds)
  double _lagCompensation = 0.0;

  // Auto-save mode - automatically save and reset after measurement
  bool _autoSaveEnabled = false;

  // Measurement target selector expansion state
  bool _measurementTargetExpanded = false;

  // GPS & Sensor measurement settings
  double _gpsTargetDistance = 100.0;
  String _gpsCourseType = 'straight'; // 'straight' or 'track'
  bool _gpsWarmupComplete = false;
  bool _gpsSensorCalibrated = false;
  double _gpsCurrentAccuracy = 0.0;
  GpsSensorMeasurement? _gpsMeasurement;
  GpsMeasurementResult? _gpsResult;
  StreamSubscription<double>? _gpsDistanceSubscription;
  StreamSubscription<double>? _gpsSpeedSubscription;
  double _gpsCurrentDistance = 0.0;
  double _gpsCurrentSpeed = 0.0;

  // Detailed info toggle (GPS/sensor data collection)
  bool _detailedInfoEnabled = true;

  // Calibration settings and state
  double _calibrationCountdown = 5.0; // seconds before calibration starts (0-30)
  bool _isInCalibrationPhase = false;
  String _calibrationPhase = 'idle'; // 'idle', 'countdown', 'calibrating', 'complete'
  double _calibrationRemainingSeconds = 0.0;
  Timer? _calibrationTimer;
  Timer? _reactionStartTimer; // Timer to delay reaction listening until 1s before GO

  // Hardware button listener instance and subscription
  final _hardwareButtonListener = HardwareButtonListener();
  StreamSubscription<HardwareButton>? _hardwareButtonSubscription;

  // Volume key event channel for native Android integration
  static const _volumeKeyChannel = EventChannel(
    'jp.holmes.track_start_call/volume_keys',
  );
  StreamSubscription? _volumeKeySubscription;

  // Time measurement state
  bool _isMeasuring = false;
  final Stopwatch _stopwatch = Stopwatch();
  double? _measuredTime; // Measured time in seconds
  bool _showMeasurementResult = false;
  bool _autoSavedResult =
      false; // True when showing auto-saved result (reset button only)
  String _logSortOrder = 'date_desc'; // Default sort order for logs

  // Measurement target mode: 'goal', 'reaction', 'goal_and_reaction'
  String _measurementTarget = 'goal';

  // Reaction time measurement
  double _reactionThreshold = 12.0; // Accelerometer threshold in m/s²
  double? _reactionTime; // Measured reaction time in seconds
  bool _isFlying = false; // True if movement detected before GO
  double? _flyingEarlyTime; // How early (in seconds) if flying
  DateTime? _goSignalTime; // Timestamp when GO signal played
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  // Hidden command tap tracking
  int _titleTapCount = 0;
  DateTime? _lastTitleTap;
  double _remainingSeconds = 0;
  double _phaseStartSeconds = 0;
  int _runToken = 0;

  // Previous phase color for smooth transition
  Color? _previousPhaseColor;
  List<Color> _completedPhaseColors = [];

  // Animation controller for smooth progress
  late AnimationController _progressController;
  double _animatedProgress = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioPlayer();
    _progressController = AnimationController(vsync: this);
    _progressController.addListener(() {
      setState(() {
        _animatedProgress = _progressController.value;
      });
    });
    _loadPrefs();
  }

  Future<void> _initAudioPlayer() async {
    _player = AudioPlayer();
    _buzzerPlayer = AudioPlayer();

    // Configure audio player for background playback
    await _player.setPlayerMode(PlayerMode.mediaPlayer);
    await _player.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ),
    );

    // Configure buzzer player (use same settings as main player)
    await _buzzerPlayer.setPlayerMode(PlayerMode.mediaPlayer);
    await _buzzerPlayer.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final wasInBackground = _isInBackground;
    _isInBackground =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive;

    // When coming back to foreground, trigger UI rebuild
    if (wasInBackground && !_isInBackground && mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Ensure wakelock is disabled when widget is disposed
    WakelockPlus.disable();
    _volumeKeySubscription?.cancel();
    _hardwareButtonSubscription?.cancel();
    _calibrationTimer?.cancel();
    _reactionStartTimer?.cancel();
    _progressController.dispose();
    _player.dispose();
    _buzzerPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final onFixed = prefs.getDouble('on_fixed') ?? _onFixed;
    final onMin = prefs.getDouble('on_min') ?? _onRange.start;
    final onMax = prefs.getDouble('on_max') ?? _onRange.end;
    final randomOn = prefs.getBool('on_random') ?? _randomOn;

    final setFixed = prefs.getDouble('set_fixed') ?? _setFixed;
    final setMin = prefs.getDouble('set_min') ?? _setRange.start;
    final setMax = prefs.getDouble('set_max') ?? _setRange.end;
    final randomSet = prefs.getBool('set_random') ?? _randomSet;

    final panFixed = prefs.getDouble('pan_fixed') ?? _panFixed;
    final panMin = prefs.getDouble('pan_min') ?? _panRange.start;
    final panMax = prefs.getDouble('pan_max') ?? _panRange.end;
    final randomPan = prefs.getBool('pan_random') ?? _randomPan;

    final onAudioPath = prefs.getString('on_audio_path') ?? _onAudioPath;
    final setAudioPath = prefs.getString('set_audio_path') ?? _setAudioPath;
    final goAudioPath = prefs.getString('go_audio_path') ?? _goAudioPath;

    final loopEnabled = prefs.getBool('loop_enabled') ?? _loopEnabled;
    final timeMeasurementEnabled =
        prefs.getBool('time_measurement_enabled') ?? _timeMeasurementEnabled;
    var triggerMethod = prefs.getString('trigger_method') ?? _triggerMethod;
    // Migrate old trigger methods to new ones (gps_sensor removed)
    final validMethods = ['tap', 'hardware_button'];
    if (!validMethods.contains(triggerMethod)) {
      triggerMethod = 'tap';
    }
    final logSortOrder = prefs.getString('log_sort_order') ?? _logSortOrder;
    final lagCompensation =
        (prefs.getDouble('lag_compensation') ?? _lagCompensation).clamp(
          0.0,
          1.0,
        );
    final autoSaveEnabled =
        prefs.getBool('auto_save_enabled') ?? _autoSaveEnabled;

    // Measurement target and reaction settings
    var measurementTarget =
        prefs.getString('measurement_target') ?? _measurementTarget;
    final validTargets = ['goal', 'reaction', 'goal_and_reaction'];
    if (!validTargets.contains(measurementTarget)) {
      measurementTarget = 'goal';
    }
    final reactionThreshold =
        (prefs.getDouble('reaction_threshold') ?? _reactionThreshold).clamp(
          5.0,
          30.0,
        );

    // GPS & Sensor settings
    final gpsTargetDistance =
        (prefs.getDouble('gps_target_distance') ?? _gpsTargetDistance).clamp(
          10.0,
          10000.0,
        );
    var gpsCourseType = prefs.getString('gps_course_type') ?? _gpsCourseType;
    if (!['straight', 'track'].contains(gpsCourseType)) {
      gpsCourseType = 'straight';
    }
    final detailedInfoEnabled =
        prefs.getBool('detailed_info_enabled') ?? _detailedInfoEnabled;
    final calibrationCountdown =
        (prefs.getDouble('calibration_countdown') ?? _calibrationCountdown)
            .clamp(0.0, 30.0);

    if (!mounted) {
      return;
    }

    final clampedOn = _clampRange(RangeValues(onMin, onMax), min: 0.5, max: 30);
    final clampedSet = _clampRange(
      RangeValues(setMin, setMax),
      min: 0.5,
      max: 40,
    );
    final clampedPan = _clampRange(
      RangeValues(panMin, panMax),
      min: 0.5,
      max: 10,
    );

    setState(() {
      _prefs = prefs;
      _onFixed = onFixed.clamp(0.5, 30);
      _onRange = clampedOn;
      _randomOn = randomOn;
      _setFixed = setFixed.clamp(0.5, 40);
      _setRange = clampedSet;
      _randomSet = randomSet;
      _panFixed = panFixed.clamp(0.5, 10);
      _panRange = clampedPan;
      _randomPan = randomPan;
      _onAudioPath = onAudioPath;
      _setAudioPath = setAudioPath;
      _goAudioPath = goAudioPath;
      _loopEnabled = loopEnabled;
      _timeMeasurementEnabled = timeMeasurementEnabled;
      _triggerMethod = triggerMethod;
      _logSortOrder = logSortOrder;
      _lagCompensation = lagCompensation;
      _autoSaveEnabled = autoSaveEnabled;
      _measurementTarget = measurementTarget;
      _reactionThreshold = reactionThreshold;
      _gpsTargetDistance = gpsTargetDistance;
      _gpsCourseType = gpsCourseType;
      _detailedInfoEnabled = detailedInfoEnabled;
      _calibrationCountdown = calibrationCountdown;
    });
  }

  RangeValues _clampRange(
    RangeValues values, {
    required double min,
    required double max,
  }) {
    var start = values.start.clamp(min, max);
    var end = values.end.clamp(min, max);
    if (start > end) {
      final temp = start;
      start = end;
      end = temp;
    }
    return RangeValues(start, end);
  }

  void _saveDouble(String key, double value) {
    _prefs?.setDouble(key, value);
  }

  void _saveBool(String key, bool value) {
    _prefs?.setBool(key, value);
  }

  void _saveString(String key, String value) {
    _prefs?.setString(key, value);
  }

  double _randomBetween(double min, double max) {
    if (min == max) {
      return min;
    }
    return min + _random.nextDouble() * (max - min);
  }

  double _getDelay({
    required bool random,
    required double fixed,
    required RangeValues range,
  }) {
    if (random) {
      return _randomBetween(range.start, range.end);
    }
    return fixed;
  }

  Future<bool> _waitWithPause(int runId, double seconds) async {
    _phaseStartSeconds = seconds;
    _remainingSeconds = seconds;
    _animatedProgress = 0.0;

    if (mounted && !_isInBackground) setState(() {});

    // Use real-time clock instead of AnimationController for background support
    final totalMs = (seconds * 1000).round();
    var elapsedMs = 0;
    var lastTime = DateTime.now();

    while (elapsedMs < totalMs) {
      if (!mounted || runId != _runToken || _isFlying) {
        return false;
      }

      if (_isPaused) {
        // While paused, don't count time
        while (_isPaused && mounted && runId == _runToken && !_isFlying) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (!mounted || runId != _runToken || _isFlying) return false;
        lastTime = DateTime.now(); // Reset timer after pause
      }

      await Future.delayed(const Duration(milliseconds: 16)); // ~60fps

      // Check for flying after delay
      if (_isFlying) return false;

      final now = DateTime.now();
      final deltaMs = now.difference(lastTime).inMilliseconds;
      lastTime = now;
      elapsedMs += deltaMs;

      // Update progress
      final progress = (elapsedMs / totalMs).clamp(0.0, 1.0);
      _remainingSeconds = seconds * (1.0 - progress);
      _animatedProgress = progress;

      // Only update UI when in foreground
      if (mounted && !_isInBackground) {
        setState(() {});
      }
    }

    _remainingSeconds = 0;
    _animatedProgress = 1.0;
    if (mounted && !_isInBackground) setState(() {});

    return mounted && runId == _runToken;
  }

  Future<bool> _runPhase({
    required int runId,
    required double seconds,
    required String assetPath,
    required String labelOnPlay,
    String? labelBeforePlay,
    Color? completedPhaseColor, // Color to add when this phase completes
  }) async {
    if (!mounted || runId != _runToken || _isFlying) {
      return false;
    }

    // Update state directly for background support
    if (labelBeforePlay != null) {
      _phaseLabel = labelBeforePlay;
    }
    if (mounted && !_isInBackground) setState(() {});

    final waitOk = await _waitWithPause(runId, seconds);
    if (!waitOk || _isFlying) {
      return false;
    }

    if (!mounted || runId != _runToken || _isFlying) {
      return false;
    }

    // Update state directly for background support
    if (completedPhaseColor != null) {
      _previousPhaseColor = completedPhaseColor;
      _completedPhaseColors = [..._completedPhaseColors, completedPhaseColor];
    }
    _phaseLabel = labelOnPlay;
    _animatedProgress = 0.0;
    if (mounted && !_isInBackground) setState(() {});
    // Only play audio if path is not empty and not flying
    if (assetPath.isNotEmpty && !_isFlying) {
      await _player.play(AssetSource(assetPath));
    }
    return mounted && runId == _runToken && !_isFlying;
  }

  Future<void> _startSequence() async {
    if (_isRunning && _isPaused) {
      _isPaused = false;
      if (mounted && !_isInBackground) setState(() {});
      return;
    }
    if (_isRunning || _isInCalibrationPhase) {
      return;
    }

    // Check if calibration is needed for this measurement
    if (_timeMeasurementEnabled && _needsCalibration()) {
      // Start calibration flow first
      _startCalibrationFlow();
      return;
    }

    _startSequenceInternal();
  }

  /// Called after calibration completes to start the normal sequence
  void _startSequenceAfterCalibration() {
    _startSequenceInternal();
  }

  /// Internal sequence logic (called directly or after calibration)
  Future<void> _startSequenceInternal() async {
    // Enable wakelock to keep the app running in background
    WakelockPlus.enable();

    final runId = ++_runToken;
    _isRunning = true;
    _isPaused = false;
    _isFinished = false;
    _phaseLabel = 'Ready';
    _completedPhaseColors = [];
    _previousPhaseColor = null;
    if (mounted && !_isInBackground) setState(() {});

    // Phase colors (use end colors from PhaseColors)
    const readyColor = PhaseColors.ready;
    const onYourMarksColor = PhaseColors.onYourMarks;
    const setColor = PhaseColors.set;
    const goColor = PhaseColors.go;

    do {
      // Reset for each loop iteration (random delays are recalculated each time)
      if (_loopEnabled && _completedPhaseColors.isNotEmpty) {
        // Starting a new loop iteration
        _phaseLabel = 'Ready';
        _completedPhaseColors = [];
        _previousPhaseColor = null;
        if (mounted && !_isInBackground) setState(() {});
      }

      final onDelay = _getDelay(
        random: _randomOn,
        fixed: _onFixed,
        range: _onRange,
      );
      final setDelay = _getDelay(
        random: _randomSet,
        fixed: _setFixed,
        range: _setRange,
      );
      final panDelay = _getDelay(
        random: _randomPan,
        fixed: _panFixed,
        range: _panRange,
      );

      final onOk = await _runPhase(
        runId: runId,
        seconds: onDelay,
        assetPath: _onAudioPath,
        labelOnPlay: 'On Your Marks',
        labelBeforePlay: 'Ready',
        completedPhaseColor: readyColor,
      );
      if (!onOk) {
        return;
      }

      final setOk = await _runPhase(
        runId: runId,
        seconds: setDelay,
        assetPath: _setAudioPath,
        labelOnPlay: 'Set',
        completedPhaseColor: onYourMarksColor,
      );
      if (!setOk) {
        return;
      }

      // Schedule accelerometer listening to start 1 second before GO
      // This prevents false flying detection from slow movements during Set phase
      if (_timeMeasurementEnabled &&
          (_measurementTarget == 'reaction' ||
              _measurementTarget == 'goal_and_reaction')) {
        _reactionStartTimer?.cancel();
        final delayBeforeListening = (panDelay - 1.0).clamp(0.0, panDelay);
        if (delayBeforeListening > 0) {
          _reactionStartTimer = Timer(
            Duration(milliseconds: (delayBeforeListening * 1000).round()),
            () {
              if (mounted && runId == _runToken && !_isFlying) {
                _startReactionListening();
              }
            },
          );
        } else {
          // If panDelay <= 1 second, start immediately
          _startReactionListening();
        }
      }

      final panOk = await _runPhase(
        runId: runId,
        seconds: panDelay,
        assetPath: _goAudioPath,
        labelOnPlay: 'Go',
        completedPhaseColor: setColor,
      );

      // Check again if flying was detected during Go countdown
      if (_isFlying) {
        return;
      }

      // Record GO signal time for reaction measurement
      if (_timeMeasurementEnabled &&
          (_measurementTarget == 'reaction' ||
              _measurementTarget == 'goal_and_reaction')) {
        _goSignalTime = DateTime.now();
      }

      if (!panOk) {
        return;
      }
      _completedPhaseColors = [..._completedPhaseColors, goColor];
      _remainingSeconds = 0;
      if (mounted && !_isInBackground) setState(() {});

      if (!mounted || runId != _runToken) {
        return;
      }

      // Start time measurement if enabled
      if (_timeMeasurementEnabled) {
        _phaseLabel = 'Measuring';
        _startTimeMeasurement();
        // Don't finish - wait for impact detection
        // The sequence will be considered "running" until measurement is complete
        return;
      }

      // Brief pause before next loop iteration
      if (_loopEnabled) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted || runId != _runToken) {
          return;
        }
      }
    } while (_loopEnabled && mounted && runId == _runToken);

    // Disable wakelock when sequence ends
    WakelockPlus.disable();

    _isRunning = false;
    _isPaused = false;
    _isFinished = true;
    if (mounted && !_isInBackground) setState(() {});
  }

  Future<void> _pauseSequence() async {
    // If measuring, stop the measurement instead of pausing
    if (_isMeasuring) {
      _stopTimeMeasurement();
      return;
    }

    if (!_isRunning || _isPaused) {
      return;
    }
    await _player.stop();
    if (!mounted) {
      return;
    }
    _isPaused = true;
    if (!_isInBackground) setState(() {});
  }

  Future<void> _resetSequence() async {
    if (!_isRunning && !_isPaused && !_isFinished && !_autoSavedResult && !_isInCalibrationPhase) {
      return;
    }

    // Cancel calibration if in progress
    if (_isInCalibrationPhase) {
      _cancelCalibration();
    }

    // Disable wakelock when reset
    WakelockPlus.disable();

    _runToken++;
    await _player.stop();
    if (!mounted) {
      return;
    }
    _isRunning = false;
    _isPaused = false;
    _isFinished = false;
    _phaseLabel = 'Starter Pistol';
    _remainingSeconds = 0;
    _phaseStartSeconds = 0;
    _animatedProgress = 0.0;
    _completedPhaseColors = [];
    _previousPhaseColor = null;
    _stopTimeMeasurement();
    _measuredTime = null;
    _reactionTime = null;
    _isFlying = false;
    _flyingEarlyTime = null;
    _goSignalTime = null;
    _showMeasurementResult = false;
    _autoSavedResult = false;
    if (!_isInBackground) setState(() {});
  }

  /// Check if calibration is needed for the current measurement settings
  bool _needsCalibration() {
    // Calibration is needed for goal/goal_and_reaction measurements when detailed info is enabled
    if (_measurementTarget != 'goal' && _measurementTarget != 'goal_and_reaction') {
      return false;
    }
    return _detailedInfoEnabled;
  }

  /// Start the calibration flow before measurement
  Future<void> _startCalibrationFlow() async {
    // Request GPS permissions first
    _gpsMeasurement ??= GpsSensorMeasurement(
      targetDistance: _gpsTargetDistance,
      courseType: _gpsCourseType == 'track'
          ? GpsCourseType.track
          : GpsCourseType.straight,
    );

    final hasPermission = await _gpsMeasurement!.requestPermissions();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('位置情報の権限が必要です'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    _isInCalibrationPhase = true;
    _calibrationRemainingSeconds = _calibrationCountdown;

    // If countdown is 0, start calibration immediately
    if (_calibrationCountdown == 0) {
      _calibrationPhase = 'calibrating';
      if (mounted) setState(() {});
      await _performCalibration();
      return;
    }

    _calibrationPhase = 'countdown';
    if (mounted) setState(() {});

    // Start countdown timer
    _calibrationTimer?.cancel();
    _calibrationTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _calibrationRemainingSeconds -= 0.1;
      if (_calibrationRemainingSeconds <= 0) {
        timer.cancel();
        _calibrationRemainingSeconds = 0;
        _calibrationPhase = 'calibrating';
        if (mounted) setState(() {});
        _performCalibration();
      } else {
        if (mounted) setState(() {});
      }
    });
  }

  /// Perform the actual calibration (GPS warmup)
  Future<void> _performCalibration() async {
    if (!_isInCalibrationPhase) return;

    try {
      // Run GPS warmup
      await _gpsMeasurement!.warmup(timeout: const Duration(seconds: 10));

      if (!_isInCalibrationPhase) return; // Check if cancelled

      _calibrationPhase = 'complete';
      if (mounted) setState(() {});

      // Vibrate to notify completion
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 200));
      HapticFeedback.mediumImpact();

      // Wait a moment to show completion message
      await Future.delayed(const Duration(milliseconds: 800));

      if (!_isInCalibrationPhase) return; // Check if cancelled

      // Exit calibration phase and start normal sequence
      _isInCalibrationPhase = false;
      _calibrationPhase = 'idle';
      if (mounted) setState(() {});

      // Start the normal measurement sequence
      _startSequenceAfterCalibration();
    } catch (e) {
      // Calibration failed - show error and reset
      _cancelCalibration();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('キャリブレーションに失敗しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Cancel the calibration process and reset
  void _cancelCalibration() {
    _calibrationTimer?.cancel();
    _calibrationTimer = null;
    _isInCalibrationPhase = false;
    _calibrationPhase = 'idle';
    _calibrationRemainingSeconds = 0.0;
    if (mounted) setState(() {});
  }

  void _startTimeMeasurement() async {
    if (!_timeMeasurementEnabled) return;

    _isMeasuring = true;
    _measuredTime = null;
    _reactionTime = null;
    _isFlying = false;
    _flyingEarlyTime = null;
    _showMeasurementResult = false;
    _gpsResult = null;
    _gpsCurrentDistance = 0.0;
    _gpsCurrentSpeed = 0.0;

    // Start stopwatch for goal measurement
    if (_measurementTarget == 'goal' ||
        _measurementTarget == 'goal_and_reaction') {
      _stopwatch.reset();
      _stopwatch.start();
    }

    // GPS & Sensor measurement (always used for goal measurements)
    if (_measurementTarget == 'goal' ||
        _measurementTarget == 'goal_and_reaction') {
      // Initialize GPS measurement service
      _gpsMeasurement ??= GpsSensorMeasurement(
        targetDistance: _gpsTargetDistance,
        courseType: _gpsCourseType == 'track'
            ? GpsCourseType.track
            : GpsCourseType.straight,
      );
      _gpsMeasurement!.targetDistance = _gpsTargetDistance;
      _gpsMeasurement!.courseType = _gpsCourseType == 'track'
          ? GpsCourseType.track
          : GpsCourseType.straight;

      // Subscribe to GPS updates
      _gpsDistanceSubscription?.cancel();
      _gpsSpeedSubscription?.cancel();

      _gpsDistanceSubscription = _gpsMeasurement!.distanceStream.listen((distance) {
        if (mounted) {
          setState(() {
            _gpsCurrentDistance = distance;
          });
        }
      });

      _gpsSpeedSubscription = _gpsMeasurement!.speedStream.listen((speed) {
        if (mounted) {
          setState(() {
            _gpsCurrentSpeed = speed;
          });
        }
      });

      // Start GPS measurement
      _gpsMeasurement!.startMeasurement(_goSignalTime ?? DateTime.now());
    }

    // Set up volume key listener for earphone/Bluetooth remote triggers (goal modes only)
    // This uses native Android integration to intercept volume keys without showing HUD
    if ((_measurementTarget == 'goal' ||
            _measurementTarget == 'goal_and_reaction') &&
        _triggerMethod == 'hardware_button') {
      _volumeKeySubscription?.cancel();
      _hardwareButtonSubscription?.cancel();

      // Listen to native volume key events (intercepted at Android level, no HUD shown)
      _volumeKeySubscription = _volumeKeyChannel
          .receiveBroadcastStream()
          .listen((event) {
            if (_isMeasuring) {
              _stopTimeMeasurement();
            }
          });

      // Also listen to hardware button listener as fallback for other hardware buttons
      _hardwareButtonSubscription = _hardwareButtonListener.listen((event) {
        if (_isMeasuring) {
          _stopTimeMeasurement();
        }
      });
    }

    // For 'tap' trigger, measurement stops when user taps the screen
    // (handled in the UI via gesture detector)

    if (mounted && !_isInBackground) setState(() {});
  }

  void _stopTimeMeasurement() {
    _reactionStartTimer?.cancel();
    if (!_isMeasuring && _measuredTime == null && _reactionTime == null) {
      _volumeKeySubscription?.cancel();
      _hardwareButtonSubscription?.cancel();
      _accelerometerSubscription?.cancel();
      _gpsDistanceSubscription?.cancel();
      _gpsSpeedSubscription?.cancel();
      return;
    }

    _stopwatch.stop();
    _volumeKeySubscription?.cancel();
    _hardwareButtonSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    _gpsDistanceSubscription?.cancel();
    _gpsSpeedSubscription?.cancel();

    // Stop GPS measurement if running (always used for goal measurements)
    if ((_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction') &&
        _gpsMeasurement != null && _gpsMeasurement!.isRunning) {
      _gpsResult = _gpsMeasurement!.stopMeasurement();
    }

    if (_isMeasuring) {
      // For goal measurement
      if (_measurementTarget == 'goal' ||
          _measurementTarget == 'goal_and_reaction') {
        // Use GPS result time if available, otherwise use stopwatch
        if (_gpsResult != null) {
          _measuredTime = _gpsResult!.elapsedTime;
        } else {
          _measuredTime = _stopwatch.elapsedMilliseconds / 1000.0;
        }
      }
      _isMeasuring = false;
      _phaseLabel = _isFlying ? 'FLYING' : 'FINISH';
      _isRunning = false;
      _isFinished = true;
      WakelockPlus.disable();

      // Auto-save if enabled
      if (_autoSaveEnabled) {
        _showMeasurementResult = true;
        _autoSavedResult = true;
        _saveTimeLogWithoutReset();
      } else {
        _showMeasurementResult = true;
        _autoSavedResult = false;
      }
    }

    if (mounted && !_isInBackground) setState(() {});
  }

  // Start listening for reaction (accelerometer)
  void _startReactionListening() {
    _accelerometerSubscription?.cancel();
    _isFlying = false;
    _flyingEarlyTime = null;
    _reactionTime = null;
    _goSignalTime = null;

    _accelerometerSubscription =
        accelerometerEventStream(
          samplingPeriod: const Duration(
            microseconds: 5000,
          ), // 5ms for better precision
        ).listen((AccelerometerEvent event) {
          // Use Z-axis for detecting forward movement
          final zForce = event.z.abs();

          if (zForce >= _reactionThreshold && !_isFlying) {
            final now = DateTime.now();

            if (_goSignalTime == null) {
              // Movement detected BEFORE GO signal = FLYING
              _isFlying = true;
              _flyingEarlyTime = null;

              // Cancel accelerometer immediately to prevent multiple triggers
              _accelerometerSubscription?.cancel();

              // Play buzzer sound
              _buzzerPlayer.stop();
              _buzzerPlayer.play(AssetSource('audio/Flying/buzzer.mp3'));

              // Stop main player
              _player.stop();

              // Stop everything and show FLYING
              _stopFlyingDetected();
            } else {
              // Movement detected AFTER GO signal = Valid reaction
              _reactionTime =
                  now.difference(_goSignalTime!).inMilliseconds / 1000.0;
              _stopReactionMeasurement();
            }
          }
        });
  }

  // Stop reaction measurement (accelerometer)
  void _stopReactionMeasurement() {
    _accelerometerSubscription?.cancel();

    // For reaction-only mode, stop the entire measurement
    if (_measurementTarget == 'reaction') {
      _stopTimeMeasurement();
    }
    // For goal_and_reaction mode, reaction is recorded but goal continues
    // (measurement continues until user triggers stop)
    if (mounted && !_isInBackground) setState(() {});
  }

  // Stop everything when flying is detected
  void _stopFlyingDetected() {
    _reactionStartTimer?.cancel();
    _accelerometerSubscription?.cancel();
    _volumeKeySubscription?.cancel();
    _hardwareButtonSubscription?.cancel();
    _stopwatch.stop();
    _stopwatch.reset();

    // Stop the progress animation and complete it immediately
    _progressController.stop();
    _animatedProgress = 1.0;

    // Stop the measurement and show FLYING START
    _isRunning = false;
    _isPaused = false;
    _isMeasuring = false;
    _isFinished = true;
    _phaseLabel = 'FLYING'; // Use FLYING as phase label (will be hidden)
    _showMeasurementResult = true;
    WakelockPlus.disable();

    if (mounted && !_isInBackground) setState(() {});
  }

  // Get measurement tags based on current mode
  List<String> _getMeasurementTags() {
    final tags = <String>[];
    switch (_measurementTarget) {
      case 'goal':
        tags.add('ゴール');
        break;
      case 'reaction':
        tags.add('リアクション');
        break;
      case 'goal_and_reaction':
        tags.addAll(['ゴール', 'リアクション']);
        break;
      default:
        tags.add('ゴール');
    }
    // Add "詳細あり" tag when detailed info is enabled for goal measurements
    if (_detailedInfoEnabled &&
        (_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction')) {
      tags.add('詳細あり');
    }
    return tags;
  }

  // Get measurement target icon
  IconData _getMeasurementTargetIcon() {
    switch (_measurementTarget) {
      case 'goal':
        return Icons.flag;
      case 'reaction':
        return Icons.flash_on;
      case 'goal_and_reaction':
        return Icons.timer;
      default:
        return Icons.flag;
    }
  }

  // Get measurement target label
  String _getMeasurementTargetLabel() {
    switch (_measurementTarget) {
      case 'goal':
        return 'ゴール';
      case 'reaction':
        return 'リアクション';
      case 'goal_and_reaction':
        return 'ゴール&リアクション';
      default:
        return 'ゴール';
    }
  }

  // Get measurement target color
  Color _getMeasurementTargetColor() {
    switch (_measurementTarget) {
      case 'goal':
        return const Color(0xFF00BCD4); // Cyan
      case 'reaction':
        return const Color(0xFFFF9800); // Orange
      case 'goal_and_reaction':
        return const Color(0xFF9C27B0); // Purple
      default:
        return const Color(0xFF00BCD4);
    }
  }

  // Show measurement mode info dialog
  void _showMeasurementModeInfo(BuildContext context) {
    final isDark = themeNotifier.value;
    final modeColor = _getMeasurementTargetColor();

    // Check if GPS will be used for this measurement
    final isGoalMode = _measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction';
    final willUseGpsSensors = isGoalMode && _detailedInfoEnabled;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(
                Icons.info_outline,
                color: modeColor,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                '計測モード設定',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow(
                  'オートセーブ',
                  _autoSaveEnabled ? 'オン' : 'オフ',
                  isDark,
                ),
                const SizedBox(height: 10),
                _buildInfoRow(
                  '計測対象',
                  _getMeasurementTargetLabel(),
                  isDark,
                ),
                // Show trigger only for goal modes
                if (_measurementTarget != 'reaction') ...[
                  const SizedBox(height: 10),
                  _buildInfoRow(
                    'トリガー',
                    _triggerMethod == 'tap'
                        ? 'タップ'
                        : (_triggerMethod == 'hardware_button'
                            ? 'ボタン'
                            : 'GPS & センサー'),
                    isDark,
                  ),
                  // Show lag time only for hardware button trigger
                  if (_triggerMethod == 'hardware_button' && _lagCompensation > 0) ...[
                    const SizedBox(height: 10),
                    _buildInfoRow(
                      'ラグタイム',
                      '${_lagCompensation.toStringAsFixed(2)}秒',
                      isDark,
                    ),
                  ],
                  // Show detailed info setting for goal modes
                  const SizedBox(height: 10),
                  _buildInfoRow(
                    '詳細情報を取得',
                    _detailedInfoEnabled ? 'オン' : 'オフ',
                    isDark,
                  ),
                  // Show calibration countdown when GPS/sensors will be used
                  if (willUseGpsSensors) ...[
                    const SizedBox(height: 10),
                    _buildInfoRow(
                      'キャリブレーション',
                      _calibrationCountdown > 0
                          ? '${_calibrationCountdown.toInt()}秒後に開始'
                          : '即時開始',
                      isDark,
                    ),
                  ],
                ],
                // Show acceleration threshold for reaction modes
                if (_measurementTarget != 'goal') ...[
                  const SizedBox(height: 10),
                  _buildInfoRow(
                    '加速度しきい値',
                    _reactionThreshold.toStringAsFixed(1),
                    isDark,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  // Helper to build info row
  Widget _buildInfoRow(String label, String value, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
      ],
    );
  }

  // Build measurement target option for accordion menu
  Widget _buildMeasurementTargetOption(
    String value,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _measurementTarget == value;
    final isReactionRelated =
        value == 'reaction' || value == 'goal_and_reaction';
    final accentColor = isReactionRelated
        ? const Color(0xFFFF9800)
        : const Color(0xFF00BCD4);

    return GestureDetector(
      onTap: () {
        setState(() {
          _measurementTarget = value;
          _measurementTargetExpanded = false; // Close accordion after selection
        });
        _saveString('measurement_target', value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isSelected ? Border.all(color: accentColor, width: 1) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected
                  ? accentColor
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? accentColor
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Create log entry with all relevant data
  Map<String, dynamic> _createLogEntry() {
    // Apply lag compensation to goal time
    // GPS-based measurements don't need lag compensation (already accurate)
    double? adjustedTime;
    if (_measuredTime != null) {
      if (_gpsResult != null) {
        adjustedTime = _measuredTime; // GPS doesn't need lag compensation
      } else {
        adjustedTime = (_measuredTime! - _lagCompensation).clamp(
          0.0,
          double.infinity,
        );
      }
    }

    final entry = <String, dynamic>{
      'time': adjustedTime,
      'reactionTime': _reactionTime,
      'date': DateTime.now().toIso8601String(),
      'title': '',
      'memo': '',
      'tags': _getMeasurementTags(),
      'isFlying': _isFlying,
      'flyingEarlyTime': _flyingEarlyTime,
    };

    // Add GPS data if available and detailed info is enabled
    if (_gpsResult != null && _detailedInfoEnabled) {
      entry['gpsData'] = {
        'distance': _gpsResult!.totalDistance,
        'courseType': _gpsCourseType,
        'initialSpeed': _gpsResult!.initialSpeed,
        'finalSpeed': _gpsResult!.finalSpeed,
        'topSpeed': _gpsResult!.topSpeed,
        'averageSpeed': _gpsResult!.averageSpeed,
        'estimatedAccuracy': _gpsResult!.estimatedAccuracy,
        'gpsUpdateCount': _gpsResult!.gpsUpdateCount,
        'trackPoints': _gpsResult!.trackPoints
            .where((p) => _gpsResult!.trackPoints.indexOf(p) %
                    max(1, _gpsResult!.trackPoints.length ~/ 100) ==
                0)
            .map((p) => p.toJson())
            .toList(),
        'speedProfile': _gpsResult!.speedProfile.map((s) => s.toJson()).toList(),
      };
    }

    return entry;
  }

  // Save time log without resetting (for auto-save mode)
  Future<void> _saveTimeLogWithoutReset() async {
    if (_measuredTime == null && _reactionTime == null && !_isFlying) return;

    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    final logs = List<Map<String, dynamic>>.from(jsonDecode(logsJson));

    logs.add(_createLogEntry());

    await prefs.setString('time_logs', jsonEncode(logs));

    if (mounted) {
      String message;
      if (_isFlying) {
        message = 'フライング を記録しました';
      } else if (_measurementTarget == 'reaction' && _reactionTime != null) {
        message = 'リアクション ${_reactionTime!.toStringAsFixed(3)}秒 を保存しました';
      } else if (_measuredTime != null) {
        final adjustedTime = (_measuredTime! - _lagCompensation).clamp(
          0.0,
          double.infinity,
        );
        message = 'タイム ${adjustedTime.toStringAsFixed(2)}秒 を保存しました';
      } else {
        message = '記録を保存しました';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _saveTimeLog() async {
    if (_measuredTime == null && _reactionTime == null && !_isFlying) return;

    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    final logs = List<Map<String, dynamic>>.from(jsonDecode(logsJson));

    logs.add(_createLogEntry());

    await prefs.setString('time_logs', jsonEncode(logs));

    // Reset display after saving
    _resetSequence();

    if (mounted) {
      String message;
      if (_isFlying) {
        message = 'フライング を記録しました';
      } else if (_measurementTarget == 'reaction' && _reactionTime != null) {
        message = 'リアクション ${_reactionTime!.toStringAsFixed(3)}秒 を保存しました';
      } else if (_measuredTime != null) {
        final adjustedTime = (_measuredTime! - _lagCompensation).clamp(
          0.0,
          double.infinity,
        );
        message = 'タイム ${adjustedTime.toStringAsFixed(2)}秒 を保存しました';
      } else {
        message = '記録を保存しました';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _updateTimeLog(int index, {String? title, String? memo}) async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    final logs = List<Map<String, dynamic>>.from(jsonDecode(logsJson));

    if (index >= 0 && index < logs.length) {
      if (title != null) {
        logs[index]['title'] = title;
      }
      if (memo != null) {
        logs[index]['memo'] = memo;
      }
      await prefs.setString('time_logs', jsonEncode(logs));
    }
  }

  Future<List<Map<String, dynamic>>> _loadTimeLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    return List<Map<String, dynamic>>.from(jsonDecode(logsJson));
  }

  Future<void> _deleteTimeLog(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    final logs = List<Map<String, dynamic>>.from(jsonDecode(logsJson));

    if (index >= 0 && index < logs.length) {
      logs.removeAt(index);
      await prefs.setString('time_logs', jsonEncode(logs));
    }
  }

  Future<void> _clearAllTimeLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('time_logs', '[]');
  }

  // Debug: Add 50 random test records
  Future<void> _addTestRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    final logs = List<Map<String, dynamic>>.from(jsonDecode(logsJson));

    final now = DateTime.now();
    final random = Random();

    for (int i = 0; i < 50; i++) {
      // Random date between 2 years ago and now
      final daysAgo = random.nextInt(730); // 0-730 days ago (2 years)
      final date = now.subtract(
        Duration(
          days: daysAgo,
          hours: random.nextInt(24),
          minutes: random.nextInt(60),
          seconds: random.nextInt(60),
        ),
      );

      // Random measurement type: 0=goal only, 1=reaction only, 2=goal+reaction
      // All goal measurements include GPS/sensor data
      final measurementType = random.nextInt(100);

      // Build tags based on measurement type
      final List<String> tags = [];
      double? time;
      double? reactionTime;
      Map<String, dynamic>? gpsData;
      String memo = '';
      String titleSuffix = '';

      if (measurementType < 45) {
        // 45% - Goal only (with GPS data)
        tags.add('ゴール');
        titleSuffix = 'ゴール';
      } else if (measurementType < 60) {
        // 15% - Reaction only (no GPS data)
        tags.add('リアクション');
        reactionTime = 0.1 + random.nextDouble() * 0.4; // 0.1-0.5 seconds
        memo = 'リアクションタイム: ${reactionTime.toStringAsFixed(3)}秒';
        titleSuffix = 'リアクション';
      } else {
        // 40% - Goal + Reaction (with GPS data)
        tags.add('ゴール');
        tags.add('リアクション');
        reactionTime = 0.1 + random.nextDouble() * 0.4;
        titleSuffix = 'ゴール＆リアクション';
      }

      // Generate GPS data for all goal measurements
      // Only reaction-only (45-59) doesn't have GPS data
      if (measurementType < 45 || measurementType >= 60) {
        final distance = [50.0, 100.0, 200.0, 400.0][random.nextInt(4)];
        time = distance == 50.0
            ? 5.5 + random.nextDouble() * 2.0
            : (distance == 100.0
                ? 10.0 + random.nextDouble() * 4.0
                : (distance == 200.0
                    ? 22.0 + random.nextDouble() * 8.0
                    : 48.0 + random.nextDouble() * 15.0));

        // Generate realistic speed profile
        final topSpeed = distance == 50.0
            ? 9.0 + random.nextDouble() * 2.0
            : (distance == 100.0
                ? 10.0 + random.nextDouble() * 2.0
                : (distance == 200.0
                    ? 9.5 + random.nextDouble() * 1.5
                    : 8.5 + random.nextDouble() * 1.5));
        final initialSpeed = 3.0 + random.nextDouble() * 2.0;
        final finalSpeed = topSpeed - 0.5 - random.nextDouble() * 1.5;
        final averageSpeed = distance / time!;

        // Generate speed profile (10m intervals)
        final speedProfile = <Map<String, dynamic>>[];
        final numPoints = (distance / 10).round();
        for (int j = 0; j <= numPoints; j++) {
          final d = j * 10.0;
          double speed;
          if (d == 0) {
            speed = 0;
          } else if (d < 30) {
            // Acceleration phase
            speed = initialSpeed + (topSpeed - initialSpeed) * (d / 30);
          } else if (d < distance - 20) {
            // Max speed phase
            speed = topSpeed - random.nextDouble() * 0.3;
          } else {
            // Deceleration phase
            speed = topSpeed - (topSpeed - finalSpeed) * ((d - (distance - 20)) / 20);
          }
          speedProfile.add({'distance': d, 'speed': double.parse(speed.toStringAsFixed(2))});
        }

        // Generate track points (simple straight line with slight variation)
        final trackPoints = <Map<String, dynamic>>[];
        final startLat = 35.6762 + random.nextDouble() * 0.01;
        final startLon = 139.6503 + random.nextDouble() * 0.01;
        final direction = random.nextDouble() * 2 * pi;
        for (int j = 0; j <= numPoints; j++) {
          final d = j * 10.0;
          final lat = startLat + (d / 111000) * cos(direction) + (random.nextDouble() - 0.5) * 0.00001;
          final lon = startLon + (d / 111000) * sin(direction) + (random.nextDouble() - 0.5) * 0.00001;
          trackPoints.add({'lat': lat, 'lon': lon, 't': date.millisecondsSinceEpoch + (d / averageSpeed * 1000).round()});
        }

        gpsData = {
          'distance': distance,
          'courseType': random.nextBool() ? 'straight' : 'track',
          'initialSpeed': double.parse(initialSpeed.toStringAsFixed(2)),
          'finalSpeed': double.parse(finalSpeed.toStringAsFixed(2)),
          'topSpeed': double.parse(topSpeed.toStringAsFixed(2)),
          'averageSpeed': double.parse(averageSpeed.toStringAsFixed(2)),
          'estimatedAccuracy': 0.05 + random.nextDouble() * 0.1,
          'speedProfile': speedProfile,
          'trackPoints': trackPoints,
        };
      }

      // Generate memo based on measurement data
      if (memo.isEmpty && gpsData != null) {
        final dist = gpsData['distance'] as double;
        final topSpd = gpsData['topSpeed'] as double;
        memo = '${dist.toInt()}m走 / 最高速度: ${topSpd.toStringAsFixed(1)}m/s';
      }

      // Add "詳細あり" tag when gpsData is present
      if (gpsData != null) {
        tags.add('詳細あり');
      }

      final record = <String, dynamic>{
        'date': date.toIso8601String(),
        'title': '[テスト用] $titleSuffix ${i + 1}',
        'memo': memo,
        'tags': tags,
        'isFlying': false,
      };

      if (time != null) {
        record['time'] = double.parse(time.toStringAsFixed(2));
      }
      if (reactionTime != null) {
        record['reactionTime'] = double.parse(reactionTime.toStringAsFixed(3));
      }
      if (gpsData != null) {
        record['gpsData'] = gpsData;
      }

      logs.add(record);
    }

    await prefs.setString('time_logs', jsonEncode(logs));
  }

  // Debug: Delete all test records
  Future<void> _deleteTestRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('time_logs') ?? '[]';
    final logs = List<Map<String, dynamic>>.from(jsonDecode(logsJson));

    // Remove all records with title starting with "[テスト用]"
    logs.removeWhere((log) {
      final title = log['title'] as String? ?? '';
      return title.startsWith('[テスト用]');
    });

    await prefs.setString('time_logs', jsonEncode(logs));
  }

  // Reset all settings to defaults
  Future<void> _resetSettings() async {
    final prefs = await SharedPreferences.getInstance();

    // Clear all settings (but keep time_logs)
    await prefs.remove('on_fixed');
    await prefs.remove('on_min');
    await prefs.remove('on_max');
    await prefs.remove('on_random');
    await prefs.remove('set_fixed');
    await prefs.remove('set_min');
    await prefs.remove('set_max');
    await prefs.remove('set_random');
    await prefs.remove('pan_fixed');
    await prefs.remove('pan_min');
    await prefs.remove('pan_max');
    await prefs.remove('pan_random');
    await prefs.remove('on_audio_path');
    await prefs.remove('set_audio_path');
    await prefs.remove('go_audio_path');
    await prefs.remove('loop_enabled');
    await prefs.remove('time_measurement_enabled');
    await prefs.remove('trigger_method');
    await prefs.remove('lag_compensation');
    await prefs.remove('auto_save_enabled');
    await prefs.remove('measurement_target');
    await prefs.remove('reaction_threshold');
    await prefs.remove('log_sort_order');

    // Reset state to defaults
    if (mounted) {
      setState(() {
        _onFixed = 5.0;
        _onRange = const RangeValues(1.5, 2.5);
        _randomOn = false;
        _setFixed = 5.0;
        _setRange = const RangeValues(0.8, 1.2);
        _randomSet = false;
        _panFixed = 5.0;
        _panRange = const RangeValues(0.8, 1.5);
        _randomPan = false;
        _onAudioPath = AudioOptions.onYourMarks[1].path;
        _setAudioPath = AudioOptions.set[1].path;
        _goAudioPath = AudioOptions.go[0].path;
        _loopEnabled = false;
        _timeMeasurementEnabled = false;
        _triggerMethod = 'tap';
        _lagCompensation = 0.0;
        _autoSaveEnabled = false;
        _measurementTarget = 'goal';
        _reactionThreshold = 12.0;
        _logSortOrder = 'date_desc';
      });
    }
  }

  Future<void> _showLogEditDialog(
    BuildContext context,
    int logIndex,
    Map<String, dynamic> log,
    bool isDark,
    void Function(String title, String memo) onSave,
  ) async {
    final titleController = TextEditingController(
      text: (log['title'] as String?) ?? '無題',
    );
    final memoController = TextEditingController(
      text: (log['memo'] as String?) ?? '',
    );
    final time = (log['time'] as num).toDouble();
    final date = DateTime.parse(log['date'] as String);
    final dateStr =
        "${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}";

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black26,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header with time display
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '記録を編集',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          Text(
                            '${time.toStringAsFixed(2)}s',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFFFD700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Title field
                      Text(
                        '題名',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: titleController,
                        autofocus: true,
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        decoration: InputDecoration(
                          hintText: '無題',
                          hintStyle: TextStyle(
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? const Color(0xFF2A2A2A)
                              : const Color(0xFFF5F5F5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Memo field
                      Text(
                        'メモ',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: memoController,
                        maxLines: 3,
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        decoration: InputDecoration(
                          hintText: 'メモを入力...',
                          hintStyle: TextStyle(
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? const Color(0xFF2A2A2A)
                              : const Color(0xFFF5F5F5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Save button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () async {
                            final newTitle = titleController.text.trim().isEmpty
                                ? '無題'
                                : titleController.text.trim();
                            final newMemo = memoController.text.trim();
                            await _updateTimeLog(
                              logIndex,
                              title: newTitle,
                              memo: newMemo,
                            );
                            onSave(newTitle, newMemo);
                            if (context.mounted) {
                              Navigator.pop(context);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6BCB1F),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '保存',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openTimeLogsPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TimeLogsPage(
          loadTimeLogs: _loadTimeLogs,
          deleteTimeLog: _deleteTimeLog,
          clearAllTimeLogs: _clearAllTimeLogs,
          updateTimeLog: _updateTimeLog,
          logSortOrder: _logSortOrder,
          onSortOrderChanged: (order) {
            setState(() {
              _logSortOrder = order;
            });
          },
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    if (_isRunning ||
        _isPaused ||
        _isFinished ||
        _isMeasuring ||
        _showMeasurementResult) {
      // Disable wakelock when opening settings
      WakelockPlus.disable();
      _runToken++;
      await _player.stop();
      _stopTimeMeasurement();
      if (!mounted) return;

      // Reset all state including progress colors and measurement
      _isRunning = false;
      _isPaused = false;
      _isFinished = false;
      _phaseLabel = 'Starter Pistol';
      _remainingSeconds = 0;
      _phaseStartSeconds = 0;
      _animatedProgress = 0.0;
      _completedPhaseColors = [];
      _previousPhaseColor = null;
      _isMeasuring = false;
      _measuredTime = null;
      _showMeasurementResult = false;
    }
    setState(() {
      _isSettingsOpen = true;
    });

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          timeMeasurementEnabled: _timeMeasurementEnabled,
          autoSaveEnabled: _autoSaveEnabled,
          triggerMethod: _triggerMethod,
          lagCompensation: _lagCompensation,
          measurementTarget: _measurementTarget,
          reactionThreshold: _reactionThreshold,
          loopEnabled: _loopEnabled,
          randomOn: _randomOn,
          randomSet: _randomSet,
          randomPan: _randomPan,
          onFixed: _onFixed,
          setFixed: _setFixed,
          panFixed: _panFixed,
          onRange: _onRange,
          setRange: _setRange,
          panRange: _panRange,
          onAudioPath: _onAudioPath,
          setAudioPath: _setAudioPath,
          goAudioPath: _goAudioPath,
          isRunning: _isRunning,
          player: _player,
          onTimeMeasurementChanged: (value) {
            setState(() {
              _timeMeasurementEnabled = value;
              _saveBool('time_measurement_enabled', value);
              if (value && _loopEnabled) {
                _loopEnabled = false;
                _saveBool('loop_enabled', false);
              }
            });
          },
          onAutoSaveChanged: (value) {
            setState(() {
              _autoSaveEnabled = value;
              _saveBool('auto_save_enabled', value);
            });
          },
          onTriggerMethodChanged: (value) {
            setState(() {
              _triggerMethod = value;
              _saveString('trigger_method', value);
            });
          },
          onLagCompensationChanged: (value) {
            setState(() {
              _lagCompensation = value;
              _saveDouble('lag_compensation', value);
            });
          },
          onMeasurementTargetChanged: (value) {
            setState(() {
              _measurementTarget = value;
              _saveString('measurement_target', value);
            });
          },
          onReactionThresholdChanged: (value) {
            setState(() {
              _reactionThreshold = value;
              _saveDouble('reaction_threshold', value);
            });
          },
          onLoopChanged: (value) {
            setState(() {
              _loopEnabled = value;
              _saveBool('loop_enabled', value);
            });
          },
          onRandomOnChanged: (value) {
            setState(() {
              _randomOn = value;
              _saveBool('on_random', value);
            });
          },
          onRandomSetChanged: (value) {
            setState(() {
              _randomSet = value;
              _saveBool('set_random', value);
            });
          },
          onRandomPanChanged: (value) {
            setState(() {
              _randomPan = value;
              _saveBool('pan_random', value);
            });
          },
          onOnFixedChanged: (value) {
            setState(() {
              _onFixed = value;
              _saveDouble('on_fixed', value);
            });
          },
          onSetFixedChanged: (value) {
            setState(() {
              _setFixed = value;
              _saveDouble('set_fixed', value);
            });
          },
          onPanFixedChanged: (value) {
            setState(() {
              _panFixed = value;
              _saveDouble('pan_fixed', value);
            });
          },
          onOnRangeChanged: (values) {
            setState(() {
              _onRange = values;
              _saveDouble('on_min', values.start);
              _saveDouble('on_max', values.end);
            });
          },
          onSetRangeChanged: (values) {
            setState(() {
              _setRange = values;
              _saveDouble('set_min', values.start);
              _saveDouble('set_max', values.end);
            });
          },
          onPanRangeChanged: (values) {
            setState(() {
              _panRange = values;
              _saveDouble('pan_min', values.start);
              _saveDouble('pan_max', values.end);
            });
          },
          onOnAudioChanged: (path) {
            setState(() {
              _onAudioPath = path;
              _saveString('on_audio_path', path);
            });
          },
          onSetAudioChanged: (path) {
            setState(() {
              _setAudioPath = path;
              _saveString('set_audio_path', path);
            });
          },
          onGoAudioChanged: (path) {
            setState(() {
              _goAudioPath = path;
              _saveString('go_audio_path', path);
            });
          },
          openTimeLogsPage: _openTimeLogsPage,
          addTestRecords: _addTestRecords,
          deleteTestRecords: _deleteTestRecords,
          resetSettings: _resetSettings,
          gpsTargetDistance: _gpsTargetDistance,
          gpsCourseType: _gpsCourseType,
          gpsWarmupComplete: _gpsWarmupComplete,
          gpsSensorCalibrated: _gpsSensorCalibrated,
          gpsCurrentAccuracy: _gpsCurrentAccuracy,
          onGpsTargetDistanceChanged: (value) {
            setState(() {
              _gpsTargetDistance = value;
              _saveDouble('gps_target_distance', value);
            });
          },
          onGpsCourseTypeChanged: (value) {
            setState(() {
              _gpsCourseType = value;
              _saveString('gps_course_type', value);
            });
          },
          detailedInfoEnabled: _detailedInfoEnabled,
          calibrationCountdown: _calibrationCountdown,
          onDetailedInfoChanged: (value) {
            setState(() {
              _detailedInfoEnabled = value;
              _saveBool('detailed_info_enabled', value);
            });
          },
          onCalibrationCountdownChanged: (value) {
            setState(() {
              _calibrationCountdown = value;
              _saveDouble('calibration_countdown', value);
            });
          },
        ),
      ),
    );

    if (mounted) {
      setState(() {
        _isSettingsOpen = false;
      });
    }
  }

  void _showCredits(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
        final isDark = themeNotifier.value;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0E131A) : const Color(0xFFF0F0F0),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Fixed drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Center(
                  child: Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF3A4654)
                          : const Color(0xFFBDBDBD),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
              // Scrollable content
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    left: 24,
                    right: 24,
                    bottom: 24 + bottomPadding,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'クレジット',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                      ),
                      const SizedBox(height: 24),
                      // Audio Credits Section
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF141B26)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: isDark
                                  ? const Color(0xFF2A3543)
                                  : const Color(0xFFE0E0E0),
                              spreadRadius: 1,
                              blurRadius: 0,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.audiotrack,
                                  color: Color(0xFF6BCB1F),
                                  size: 26,
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    '音声素材',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: isDark
                                              ? Colors.white
                                              : Colors.black87,
                                        ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            _buildCreditItem(
                              context,
                              name: '音読さん',
                              url: 'https://ondoku3.com/',
                              isDark: isDark,
                            ),
                            const SizedBox(height: 16),
                            _buildCreditItem(
                              context,
                              name: 'On-Jin ～音人～',
                              url: 'https://on-jin.com/',
                              isDark: isDark,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTriggerChip(
    String value,
    String label,
    IconData icon,
    bool isDark,
    void Function(void Function()) sync,
  ) {
    final isSelected = _triggerMethod == value;
    return GestureDetector(
      onTap: () {
        sync(() {
          _triggerMethod = value;
          _saveString('trigger_method', value);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00BCD4).withOpacity(0.2)
              : (isDark ? const Color(0xFF1A2332) : const Color(0xFFF0F0F0)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF00BCD4)
                : (isDark ? const Color(0xFF2A3543) : const Color(0xFFD0D0D0)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? const Color(0xFF00BCD4)
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? const Color(0xFF00BCD4)
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMeasurementTargetChip(
    String value,
    String label,
    IconData icon,
    bool isDark,
    void Function(void Function()) sync,
  ) {
    final isSelected = _measurementTarget == value;
    final isReactionRelated =
        value == 'reaction' || value == 'goal_and_reaction';
    final accentColor = isReactionRelated
        ? const Color(0xFFFF9800)
        : const Color(0xFF00BCD4);
    return GestureDetector(
      onTap: () {
        sync(() {
          _measurementTarget = value;
          _saveString('measurement_target', value);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withOpacity(0.2)
              : (isDark ? const Color(0xFF1A2332) : const Color(0xFFF0F0F0)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? accentColor
                : (isDark ? const Color(0xFF2A3543) : const Color(0xFFD0D0D0)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? accentColor
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? accentColor
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreditItem(
    BuildContext context, {
    required String name,
    required String url,
    bool isDark = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontSize: 17,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        const SizedBox(height: 6),
        Text(
          url,
          style: const TextStyle(color: Color(0xFF6BCB1F), fontSize: 14),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ],
    );
  }

  void _handleTitleTap() async {
    // Only trigger when showing "Starter Pistol" (not running)
    if (_phaseLabel != 'Starter Pistol') return;

    final now = DateTime.now();

    // Reset count if more than 1 second has passed since last tap
    if (_lastTitleTap != null &&
        now.difference(_lastTitleTap!).inMilliseconds > 1000) {
      _titleTapCount = 0;
    }

    _lastTitleTap = now;
    _titleTapCount++;

    // Open URL after 5 rapid taps
    if (_titleTapCount >= 5) {
      _titleTapCount = 0;
      final uri = Uri.parse('https://usefulhub.net/');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  Widget _buildNumberInput({
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required bool enabled,
    double width = 85,
  }) {
    return _NumberInputField(
      value: value,
      min: min,
      max: max,
      onChanged: onChanged,
      enabled: enabled,
      width: width,
    );
  }

  Widget _buildPhaseSetting({
    required String title,
    required bool randomEnabled,
    required ValueChanged<bool> onRandomChanged,
    required double fixedValue,
    required RangeValues rangeValues,
    required ValueChanged<double> onFixedChanged,
    required ValueChanged<RangeValues> onRangeChanged,
    required double maxSeconds,
    required List<AudioOption> audioOptions,
    required String selectedAudioPath,
    required ValueChanged<String> onAudioChanged,
    required VoidCallback onPreviewAudio,
  }) {
    const sliderMin = 0.5;
    final sliderMax = maxSeconds;
    final isDark = themeNotifier.value;

    // Find selected audio name
    final selectedAudio = audioOptions.firstWhere(
      (option) => option.path == selectedAudioPath,
      orElse: () => audioOptions.first,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141B26) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
            spreadRadius: 1,
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row with play button on right
          Row(
            children: [
              PopupMenuButton<String>(
                enabled: !_isRunning,
                padding: EdgeInsets.zero,
                offset: const Offset(0, 48),
                elevation: 8,
                color: isDark ? const Color(0xFF1A2332) : Colors.white,
                shadowColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onSelected: onAudioChanged,
                itemBuilder: (context) => audioOptions.map((option) {
                  final isSelected = option.path == selectedAudioPath;
                  return PopupMenuItem<String>(
                    value: option.path,
                    height: 52,
                    child: Text(
                      option.name,
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark
                            ? (isSelected ? Colors.white : Colors.white70)
                            : (isSelected
                                  ? const Color(0xFF3A3A3A)
                                  : const Color(0xFF1F1F1F)),
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  );
                }).toList(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.keyboard_arrow_down,
                      color: isDark ? Colors.white70 : Colors.black54,
                      size: 26,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onPreviewAudio,
                child: const Icon(
                  Icons.volume_up,
                  color: Color(0xFF6BCB1F),
                  size: 28,
                ),
              ),
            ],
          ),
          // Selected audio name
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              selectedAudio.name,
              style: const TextStyle(color: Color(0xFF6BCB1F), fontSize: 14),
            ),
          ),
          const SizedBox(height: 12),
          if (randomEnabled)
            Column(
              children: [
                // Number inputs on top
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildNumberInput(
                      value: rangeValues.start,
                      min: sliderMin,
                      max: rangeValues.end,
                      enabled: !_isRunning,
                      onChanged: (value) {
                        if (value <= rangeValues.end) {
                          onRangeChanged(RangeValues(value, rangeValues.end));
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '〜',
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ),
                    _buildNumberInput(
                      value: rangeValues.end,
                      min: rangeValues.start,
                      max: sliderMax,
                      enabled: !_isRunning,
                      onChanged: (value) {
                        if (value >= rangeValues.start) {
                          onRangeChanged(RangeValues(rangeValues.start, value));
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Slider below
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF6BCB1F),
                    inactiveTrackColor: isDark
                        ? const Color(0xFF2A3543)
                        : const Color(0xFFD0D0D0),
                    thumbColor: const Color(0xFF6BCB1F),
                    overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                    trackShape: const RoundedRectSliderTrackShape(),
                    rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
                    activeTickMarkColor: Colors.transparent,
                    inactiveTickMarkColor: Colors.transparent,
                  ),
                  child: RangeSlider(
                    values: rangeValues,
                    min: sliderMin,
                    max: sliderMax,
                    divisions: ((sliderMax - sliderMin) * 10).round(),
                    onChanged: _isRunning
                        ? null
                        : (values) {
                            final roundedStart =
                                (values.start * 10).round() / 10;
                            final roundedEnd = (values.end * 10).round() / 10;
                            onRangeChanged(
                              RangeValues(roundedStart, roundedEnd),
                            );
                          },
                  ),
                ),
              ],
            )
          else
            Column(
              children: [
                // Number input on top
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildNumberInput(
                      value: fixedValue,
                      min: sliderMin,
                      max: sliderMax,
                      enabled: !_isRunning,
                      onChanged: onFixedChanged,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Slider below
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF6BCB1F),
                    inactiveTrackColor: isDark
                        ? const Color(0xFF2A3543)
                        : const Color(0xFFD0D0D0),
                    thumbColor: const Color(0xFF6BCB1F),
                    overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                    trackShape: const RoundedRectSliderTrackShape(),
                    trackHeight: 4.0,
                    activeTickMarkColor: Colors.transparent,
                    inactiveTickMarkColor: Colors.transparent,
                  ),
                  child: Slider(
                    value: fixedValue,
                    min: sliderMin,
                    max: sliderMax,
                    divisions: ((sliderMax - sliderMin) * 10).round(),
                    onChanged: _isRunning
                        ? null
                        : (value) {
                            final rounded = (value * 10).round() / 10;
                            onFixedChanged(rounded);
                          },
                  ),
                ),
              ],
            ),
          // Random switch row (below slider, right-aligned)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'ランダム',
                style: TextStyle(
                  color: isDark ? Colors.white70 : Colors.black54,
                  fontSize: 15,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 32,
                width: 52,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Switch(
                    value: randomEnabled,
                    onChanged: _isRunning ? null : onRandomChanged,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGlowingText(String text, TextStyle style, {Color? glowColor}) {
    // Simplified: just return text with shadow instead of blur filter
    if (glowColor != null) {
      return Text(
        text,
        style: style.copyWith(
          shadows: [Shadow(color: glowColor, blurRadius: 8)],
        ),
      );
    }
    return Text(text, style: style);
  }

  Widget _buildGlowButton({
    required VoidCallback? onPressed,
    required String label,
    required Color primaryColor,
    required Color secondaryColor,
    required bool filled,
    bool isSmallScreen = false,
  }) {
    final isEnabled = onPressed != null;
    final opacity = isEnabled ? 1.0 : 0.4;
    final borderRadiusValue = isSmallScreen ? 12.0 : 16.0;
    final verticalPadding = isSmallScreen ? 14.0 : 18.0;
    final fontSize = isSmallScreen ? 14.0 : 16.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadiusValue),
        boxShadow: isEnabled && filled
            ? [
                BoxShadow(
                  color: primaryColor.withOpacity(0.3),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(borderRadiusValue),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: verticalPadding),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadiusValue),
              gradient: filled
                  ? LinearGradient(
                      colors: [
                        primaryColor.withOpacity(opacity),
                        secondaryColor.withOpacity(opacity),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              border: filled
                  ? null
                  : Border.all(
                      color: primaryColor.withOpacity(opacity),
                      width: 2,
                    ),
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: filled
                        ? const Color(0xFF0C1409).withOpacity(opacity)
                        : primaryColor.withOpacity(opacity),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Determine display text based on state
    String displayText;
    String? reactionDisplayText;
    bool showFlying = false;

    if (_isMeasuring) {
      // Show elapsed time during measurement (for goal modes)
      if (_measurementTarget == 'goal' ||
          _measurementTarget == 'goal_and_reaction') {
        final elapsed = _stopwatch.elapsedMilliseconds / 1000.0;
        displayText = elapsed.toStringAsFixed(2);
      } else {
        // Reaction-only mode during measurement
        displayText = '---';
      }
      // Show reaction time if already captured (for goal_and_reaction mode)
      if (_reactionTime != null) {
        reactionDisplayText = _reactionTime!.toStringAsFixed(3);
      }
    } else if (_showMeasurementResult) {
      // Check for flying first
      if (_isFlying) {
        showFlying = true;
        displayText = 'FLYING START';
      } else if (_measurementTarget == 'goal' && _measuredTime != null) {
        // Goal only mode
        final adjustedTime = (_measuredTime! - _lagCompensation).clamp(
          0.0,
          double.infinity,
        );
        displayText = adjustedTime.toStringAsFixed(2);
      } else if (_measurementTarget == 'reaction' && _reactionTime != null) {
        // Reaction only mode
        displayText = _reactionTime!.toStringAsFixed(3);
      } else if (_measurementTarget == 'goal_and_reaction') {
        // Goal & Reaction mode - show goal time as main
        if (_measuredTime != null) {
          final adjustedTime = (_measuredTime! - _lagCompensation).clamp(
            0.0,
            double.infinity,
          );
          displayText = adjustedTime.toStringAsFixed(2);
        } else {
          displayText = '---';
        }
        // Show reaction time or "----" if not captured
        if (_reactionTime != null) {
          reactionDisplayText = _reactionTime!.toStringAsFixed(3);
        } else {
          reactionDisplayText = '----';
        }
      } else {
        displayText = '---';
      }
    } else if (_remainingSeconds > 0) {
      displayText = _remainingSeconds.toStringAsFixed(2);
    } else {
      displayText = '0.00';
    }

    final showCountdown =
        _phaseLabel.isNotEmpty && _phaseLabel != 'Starter Pistol';
    final isDark = themeNotifier.value;

    // Trigger rebuild during measurement to update elapsed time
    if (_isMeasuring) {
      Future.delayed(const Duration(milliseconds: 16), () {
        if (mounted && _isMeasuring) setState(() {});
      });
    }

    // Check if we should enable full-screen tap to stop (only for goal modes with tap trigger)
    final enableFullScreenTap =
        _isMeasuring &&
        _triggerMethod == 'tap' &&
        (_measurementTarget == 'goal' ||
            _measurementTarget == 'goal_and_reaction');

    Widget body = SafeArea(
      child: OrientationBuilder(
        builder: (context, orientation) {
          final isLandscape = orientation == Orientation.landscape;

          return isLandscape
              ? _buildLandscapeLayout(
                  displayText,
                  showCountdown,
                  reactionText: reactionDisplayText,
                  isFlying: showFlying,
                )
              : _buildPortraitLayout(
                  displayText,
                  showCountdown,
                  reactionText: reactionDisplayText,
                  isFlying: showFlying,
                );
        },
      ),
    );

    // Wrap with GestureDetector for full-screen tap when measuring with tap trigger
    if (enableFullScreenTap) {
      body = GestureDetector(
        onTap: _stopTimeMeasurement,
        behavior: HitTestBehavior.opaque,
        child: body,
      );
    }

    // Show calibration overlay if in calibration phase
    if (_isInCalibrationPhase) {
      body = Stack(
        children: [
          body,
          _buildCalibrationOverlay(isDark),
        ],
      );
    }

    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF5F5F5),
      body: body,
    );
  }

  /// Build the calibration overlay widget
  Widget _buildCalibrationOverlay(bool isDark) {
    final backgroundColor = isDark
        ? Colors.black.withOpacity(0.95)
        : Colors.white.withOpacity(0.95);
    final textColor = isDark ? Colors.white : Colors.black87;

    String title;
    String message;
    IconData icon;
    Color iconColor;

    switch (_calibrationPhase) {
      case 'countdown':
        title = 'キャリブレーション準備';
        message = 'あと${_calibrationRemainingSeconds.ceil()}秒でキャリブレーションが開始されます。\nスマホを体に固定して直立してください。';
        icon = Icons.timer_outlined;
        iconColor = Colors.orange;
        break;
      case 'calibrating':
        title = 'キャリブレーション中...';
        message = 'GPS位置取得とセンサーキャリブレーションを行っています。\nそのままお待ちください。';
        icon = Icons.sync;
        iconColor = Colors.blue;
        break;
      case 'complete':
        title = 'キャリブレーション完了';
        message = '計測を開始します。';
        icon = Icons.check_circle;
        iconColor = Colors.green;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: backgroundColor,
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon with animation for calibrating state
              if (_calibrationPhase == 'calibrating')
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 2 * 3.14159),
                  duration: const Duration(seconds: 2),
                  builder: (context, value, child) {
                    return Transform.rotate(
                      angle: value,
                      child: Icon(icon, size: 80, color: iconColor),
                    );
                  },
                  onEnd: () {
                    // Keep rotating
                    if (mounted && _calibrationPhase == 'calibrating') {
                      setState(() {});
                    }
                  },
                )
              else
                Icon(icon, size: 80, color: iconColor),
              const SizedBox(height: 32),
              Text(
                title,
                style: GoogleFonts.notoSansJp(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.notoSansJp(
                    fontSize: 16,
                    color: textColor.withOpacity(0.8),
                    height: 1.5,
                  ),
                ),
              ),
              if (_calibrationPhase == 'countdown') ...[
                const SizedBox(height: 48),
                // Countdown display
                Text(
                  _calibrationRemainingSeconds.ceil().toString(),
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 72,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 48),
                // Cancel button
                ElevatedButton.icon(
                  onPressed: _cancelCalibration,
                  icon: const Icon(Icons.close),
                  label: const Text('キャンセル'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
              if (_calibrationPhase == 'calibrating') ...[
                const SizedBox(height: 32),
                const CircularProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout(
    String countdownText,
    bool showCountdown, {
    String? reactionText,
    bool isFlying = false,
  }) {
    final isDark = themeNotifier.value;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                onPressed: _showMeasurementResult ? null : _openSettings,
                icon: const Icon(Icons.tune_rounded, size: 28),
                style: IconButton.styleFrom(
                  backgroundColor: isDark
                      ? const Color(0xFF1A1A1A)
                      : const Color(0xFFE0E0E0),
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  disabledForegroundColor: isDark
                      ? Colors.white24
                      : Colors.black26,
                  padding: const EdgeInsets.all(12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              // Measurement mode display (right side) or placeholder
              (_timeMeasurementEnabled && !_isSettingsOpen)
                  ? Builder(
                      builder: (context) {
                        final modeColor = _getMeasurementTargetColor();
                        return GestureDetector(
                          onTap: () => _showMeasurementModeInfo(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF0D2A3A)
                                  : const Color(0xFFE3F2FD),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: modeColor.withOpacity(0.5),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.timer,
                                  size: 16,
                                  color: modeColor,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '計測モード',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: modeColor,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.info_outline,
                                  size: 16,
                                  color: modeColor.withOpacity(0.7),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    )
                  : const SizedBox(
                      width: 52,
                    ), // Placeholder to keep settings button position stable
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: _buildTimerPanel(
              countdownText,
              showCountdown,
              isLandscape: false,
              reactionText: reactionText,
              isFlying: isFlying,
            ),
          ),
        ),
        if (!_isSettingsOpen) _buildButtons(isLandscape: false),
      ],
    );
  }

  Widget _buildLandscapeLayout(
    String countdownText,
    bool showCountdown, {
    String? reactionText,
    bool isFlying = false,
  }) {
    final isDark = themeNotifier.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // Top row: Settings button (left) and Measurement mode (right)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Settings button
              IconButton(
                onPressed: _showMeasurementResult ? null : _openSettings,
                icon: const Icon(Icons.tune_rounded, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: isDark
                      ? const Color(0xFF1A1A1A)
                      : const Color(0xFFE0E0E0),
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  disabledForegroundColor: isDark
                      ? Colors.white24
                      : Colors.black26,
                  padding: const EdgeInsets.all(8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              // Measurement mode display (top right)
              if (_timeMeasurementEnabled && !_isSettingsOpen)
                Builder(
                  builder: (context) {
                    final modeColor = _getMeasurementTargetColor();
                    return GestureDetector(
                      onTap: () => _showMeasurementModeInfo(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF0D2A3A)
                              : const Color(0xFFE3F2FD),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: modeColor.withOpacity(0.5),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.timer,
                              size: 14,
                              color: modeColor,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '計測モード',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: modeColor,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.info_outline,
                              size: 14,
                              color: modeColor.withOpacity(0.7),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
          // Center: Timer panel (expanded to fill space)
          Expanded(
            child: Center(
              child: _buildTimerPanel(
                countdownText,
                showCountdown,
                isLandscape: true,
                reactionText: reactionText,
                isFlying: isFlying,
              ),
            ),
          ),
          // Bottom: Buttons (horizontal layout)
          if (!_isSettingsOpen)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildButtons(isLandscape: true),
            ),
        ],
      ),
    );
  }

  Widget _buildTimerPanel(
    String countdownText,
    bool showCountdown, {
    required bool isLandscape,
    String? reactionText,
    bool isFlying = false,
  }) {
    if (_phaseLabel.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = themeNotifier.value;

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;
        final isSmallScreen =
            screenWidth < 360 || (isLandscape && screenHeight < 250);
        final isTinyScreen =
            screenWidth < 300 || (isLandscape && screenHeight < 180);

        // Responsive panel width - larger in landscape to fill space
        final panelWidth = isLandscape
            ? min(screenWidth * 0.95, 400.0)
            : min(screenWidth * 0.85, 340.0);

        // Responsive font sizes - larger in landscape
        final labelFontSize = isLandscape
            ? (isTinyScreen ? 32.0 : 42.0)
            : (isTinyScreen ? 28.0 : (isSmallScreen ? 32.0 : 38.0));
        final countdownFontSize = isLandscape
            ? (isTinyScreen ? 40.0 : 52.0)
            : (isTinyScreen ? 36.0 : (isSmallScreen ? 40.0 : 44.0));
        final secondsFontSize = isTinyScreen ? 10.0 : 12.0;

        // Responsive padding
        final horizontalPadding = isLandscape
            ? 20.0
            : (isSmallScreen ? 16.0 : 20.0);
        final verticalPadding = isLandscape
            ? 10.0
            : (isSmallScreen ? 14.0 : 18.0);
        final borderRadius = isSmallScreen ? 18.0 : 22.0;

        final progress = _animatedProgress;

        // Interpolate colors based on progress (light -> dark as countdown approaches 0)
        // For 'Go', 'Measuring', 'FINISH', 'FLYING', 'FLYING START' phases, always use full intensity (progress = 1.0)
        final effectiveProgress =
            (_phaseLabel == 'Go' ||
                _phaseLabel == 'Measuring' ||
                _phaseLabel == 'FINISH' ||
                _phaseLabel == 'FLYING' ||
                _phaseLabel == 'FLYING START')
            ? 1.0
            : progress;

        // Use red color for flying
        final isFlyingPhase = isFlying || _phaseLabel == 'FLYING START';
        final progressColor = isFlyingPhase
            ? const Color(0xFFE53935)
            : PhaseColors.getInterpolatedColor(_phaseLabel, effectiveProgress);
        final secondaryColor = isFlyingPhase
            ? const Color(0xFFFF5252)
            : PhaseColors.getInterpolatedSecondaryColor(
                _phaseLabel,
                effectiveProgress,
              );

        // Fixed height for phase label to prevent size changes between phases
        final labelHeight = isLandscape
            ? (isTinyScreen ? 40.0 : 52.0)
            : (isTinyScreen ? 36.0 : (isSmallScreen ? 40.0 : 48.0));

        // Only show progress painter when countdown is active
        final progressPainter = showCountdown
            ? RoundedRectProgressPainter(
                progress: progress,
                borderRadius: borderRadius,
                strokeWidth: isSmallScreen ? 3 : 4,
                progressColor: progressColor,
                secondaryColor: secondaryColor,
                backgroundColor: isDark
                    ? const Color(0xFF1A2332)
                    : const Color(0xFFE0E0E0),
                previousPhaseColor: _previousPhaseColor,
              )
            : null;

        // Calculate max panel height for landscape to prevent overflow
        final maxPanelHeight = isLandscape
            ? screenHeight * 0.85  // Leave space for buttons
            : double.infinity;

        return RepaintBoundary(
          child: CustomPaint(
            painter: progressPainter,
            child: Container(
              constraints: BoxConstraints(
                minWidth: panelWidth,
                maxWidth: panelWidth,
                maxHeight: maxPanelHeight,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(borderRadius),
                color: isDark ? const Color(0xFF141B26) : Colors.white,
                boxShadow: showCountdown
                    ? [
                        BoxShadow(
                          color: progressColor.withOpacity(0.12),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  // Phase label with glow - fixed height to prevent size changes
                  // Hide label when flying (show only FLYING START in countdown area)
                  if (!isFlying && _phaseLabel != 'FLYING')
                    SizedBox(
                      height: labelHeight,
                      child: GestureDetector(
                        onTap: _handleTitleTap,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _buildGlowingText(
                            _phaseLabel,
                            GoogleFonts.bebasNeue(
                              fontSize: labelFontSize,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            glowColor: progressColor.withOpacity(0.3),
                          ),
                        ),
                      ),
                    ),
                  if (showCountdown) ...[
                    SizedBox(
                      height: isLandscape ? 4 : (isSmallScreen ? 8 : 10),
                    ),
                    // Countdown with gradient and glow - colors interpolate with progress
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          colors: [progressColor, secondaryColor],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ).createShader(bounds),
                        child: _buildGlowingText(
                          countdownText,
                          GoogleFonts.robotoMono(
                            fontSize: countdownFontSize,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                          glowColor: progressColor.withOpacity(0.5),
                        ),
                      ),
                    ),
                    Text(
                      isFlying ? '' : 'seconds',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: secondsFontSize,
                        fontWeight: FontWeight.w500,
                        color: progressColor.withOpacity(0.7),
                        letterSpacing: 3,
                      ),
                    ),
                  ],
                  // Reaction time display - show regardless of showCountdown for goal_and_reaction mode
                  if (reactionText != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF9800).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFFF9800).withOpacity(0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.flash_on,
                            color: Color(0xFFFF9800),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'リアクション: $reactionText${reactionText != '----' ? 's' : ''}',
                            style: GoogleFonts.robotoMono(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFFFF9800),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildButtons({required bool isLandscape}) {
    return Builder(
      builder: (context) {
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final isSmallScreen = isLandscape
            ? screenHeight < 400
            : screenWidth < 360;
        final horizontalPadding = isLandscape
            ? 0.0
            : (isSmallScreen ? 16.0 : 24.0);
        final bottomPadding = isLandscape ? 0.0 : (isSmallScreen ? 40.0 : 56.0);
        final buttonSpacing = isLandscape
            ? 12.0
            : (isSmallScreen ? 12.0 : 16.0);

        // Button layout depends on state
        // - Measuring: STOP only
        // - Measurement result: SAVE (left), RESET (right)
        // - Running (not paused): PAUSE, RESET
        // - Otherwise: START, RESET
        final isShowingStop = _isMeasuring;
        final isShowingPause = !_isMeasuring && _isRunning && !_isPaused;
        final isShowingResult = _showMeasurementResult;

        List<Widget> buttons;

        if (isShowingResult) {
          if (_autoSavedResult || _isFlying) {
            // Auto-saved result or Flying: RESET only (full width)
            buttons = [
              Expanded(
                child: _buildGlowButton(
                  onPressed: _resetSequence,
                  label: 'RESET',
                  primaryColor: const Color(0xFFE85C5C),
                  secondaryColor: const Color(0xFFFF6B6B),
                  filled: true,
                  isSmallScreen: isSmallScreen || isLandscape,
                ),
              ),
            ];
          } else {
            // Normal measurement result: SAVE (left), RESET (right)
            buttons = [
              Expanded(
                child: _buildGlowButton(
                  onPressed: _saveTimeLog,
                  label: 'SAVE',
                  primaryColor: PhaseColors.finish,
                  secondaryColor: PhaseColors.finishSecondary,
                  filled: true,
                  isSmallScreen: isSmallScreen || isLandscape,
                ),
              ),
              SizedBox(width: buttonSpacing),
              Expanded(
                child: _buildGlowButton(
                  onPressed: _resetSequence,
                  label: 'RESET',
                  primaryColor: const Color(0xFFE85C5C),
                  secondaryColor: const Color(0xFFFF6B6B),
                  filled: false,
                  isSmallScreen: isSmallScreen || isLandscape,
                ),
              ),
            ];
          }
        } else if (isShowingStop) {
          if (_triggerMethod == 'tap') {
            // Tap trigger: show message instead of button
            buttons = [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      '画面をタップして計測をストップ',
                      style: TextStyle(
                        fontSize: isSmallScreen || isLandscape ? 14 : 16,
                        fontWeight: FontWeight.w600,
                        color: PhaseColors.measuring,
                      ),
                    ),
                  ),
                ),
              ),
            ];
          } else {
            // Other triggers: STOP button
            buttons = [
              Expanded(
                child: _buildGlowButton(
                  onPressed: _stopTimeMeasurement,
                  label: 'STOP',
                  primaryColor: PhaseColors.measuring,
                  secondaryColor: PhaseColors.measuringSecondary,
                  filled: true,
                  isSmallScreen: isSmallScreen || isLandscape,
                ),
              ),
            ];
          }
        } else {
          // Normal state: START/PAUSE, RESET
          buttons = [
            Expanded(
              child: isShowingPause
                  ? _buildGlowButton(
                      onPressed: _pauseSequence,
                      label: 'PAUSE',
                      primaryColor: const Color(0xFFE53935),
                      secondaryColor: const Color(0xFFB71C1C),
                      filled: true,
                      isSmallScreen: isSmallScreen || isLandscape,
                    )
                  : _buildGlowButton(
                      onPressed: _startSequence,
                      label: 'START',
                      primaryColor: const Color(0xFF66DE5A),
                      secondaryColor: const Color(0xFF4CAF50),
                      filled: true,
                      isSmallScreen: isSmallScreen || isLandscape,
                    ),
            ),
            SizedBox(width: buttonSpacing),
            Expanded(
              child: _buildGlowButton(
                onPressed: (_isPaused || _isFinished) ? _resetSequence : null,
                label: 'RESET',
                primaryColor: const Color(0xFFE85C5C),
                secondaryColor: const Color(0xFFFF6B6B),
                filled: false,
                isSmallScreen: isSmallScreen || isLandscape,
              ),
            ),
          ];
        }

        if (isLandscape) {
          // In landscape, use horizontal layout at bottom
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: buttons,
          );
        } else {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              bottomPadding,
            ),
            child: Row(children: buttons),
          );
        }
      },
    );
  }
}

class RoundedRectProgressPainter extends CustomPainter {
  final double progress;
  final double borderRadius;
  final double strokeWidth;
  final Color progressColor;
  final Color secondaryColor;
  final Color backgroundColor;
  final Color glowColor;
  final Color? previousPhaseColor;

  RoundedRectProgressPainter({
    required this.progress,
    required this.borderRadius,
    this.strokeWidth = 3.0,
    this.progressColor = const Color(0xFF6BCB1F),
    Color? secondaryColor,
    this.backgroundColor = const Color(0xFF2A3543),
    this.previousPhaseColor,
    Color? glowColor,
  }) : secondaryColor = secondaryColor ?? progressColor,
       glowColor = glowColor ?? progressColor.withOpacity(0.5);

  Path _createPathFromTopCenter(Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final r = borderRadius;
    final path = Path();

    // Start from top center
    path.moveTo(rect.left + rect.width / 2, rect.top);

    // Top right (from center to corner)
    path.lineTo(rect.right - r, rect.top);
    path.arcToPoint(
      Offset(rect.right, rect.top + r),
      radius: Radius.circular(r),
    );

    // Right side
    path.lineTo(rect.right, rect.bottom - r);
    path.arcToPoint(
      Offset(rect.right - r, rect.bottom),
      radius: Radius.circular(r),
    );

    // Bottom side
    path.lineTo(rect.left + r, rect.bottom);
    path.arcToPoint(
      Offset(rect.left, rect.bottom - r),
      radius: Radius.circular(r),
    );

    // Left side
    path.lineTo(rect.left, rect.top + r);
    path.arcToPoint(
      Offset(rect.left + r, rect.top),
      radius: Radius.circular(r),
    );

    // Top left (from corner back to center)
    path.lineTo(rect.left + rect.width / 2, rect.top);

    return path;
  }

  void _drawProgressWithGlow(
    Canvas canvas,
    Path progressPath,
    Color primary,
    Color secondary,
    Size size,
  ) {
    final bounds = progressPath.getBounds();

    // Create gradient shader
    final gradient = ui.Gradient.linear(
      Offset(bounds.left, bounds.top),
      Offset(bounds.right, bounds.bottom),
      [primary, secondary],
      [0.0, 1.0],
    );

    // Outer glow layer (large, soft)
    final outerGlowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 16
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16)
      ..color = primary.withOpacity(0.3);
    canvas.drawPath(progressPath, outerGlowPaint);

    // Middle glow layer
    final middleGlowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 10
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
      ..color = primary.withOpacity(0.5);
    canvas.drawPath(progressPath, middleGlowPaint);

    // Inner glow layer (bright, focused)
    final innerGlowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 4
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..color = primary.withOpacity(0.7);
    canvas.drawPath(progressPath, innerGlowPaint);

    // Draw main progress line with gradient
    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = gradient;
    canvas.drawPath(progressPath, progressPaint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _createPathFromTopCenter(size);

    // Draw background
    final bgPaint = Paint()
      ..color = backgroundColor.withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawPath(path, bgPaint);

    final pathMetrics = path.computeMetrics().first;
    final totalLength = pathMetrics.length;
    final clampedProgress = progress.clamp(0.0, 1.0);
    final progressLength = totalLength * clampedProgress;

    // Draw previous phase color in the remaining part (being "eaten" by new progress)
    if (previousPhaseColor != null && clampedProgress < 1.0) {
      final remainingPath = pathMetrics.extractPath(
        progressLength,
        totalLength,
      );
      _drawProgressWithGlow(
        canvas,
        remainingPath,
        previousPhaseColor!,
        previousPhaseColor!,
        size,
      );
    }

    // Draw current progress
    if (clampedProgress > 0) {
      final extractedPath = pathMetrics.extractPath(0, progressLength);
      _drawProgressWithGlow(
        canvas,
        extractedPath,
        progressColor,
        secondaryColor,
        size,
      );
    }
  }

  @override
  bool shouldRepaint(RoundedRectProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.previousPhaseColor != previousPhaseColor;
  }
}

class _NumberInputField extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final bool enabled;
  final double width;

  const _NumberInputField({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.enabled,
    this.width = 85,
  });

  @override
  State<_NumberInputField> createState() => _NumberInputFieldState();
}

class _NumberInputFieldState extends State<_NumberInputField> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toStringAsFixed(1));
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(_NumberInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update text when value changes from parent (e.g., slider)
    if (oldWidget.value != widget.value) {
      // Unfocus when slider is moved
      if (_focusNode.hasFocus) {
        _focusNode.unfocus();
      }
      _controller.text = widget.value.toStringAsFixed(1);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSubmit(String text) {
    final trimmed = text.trim();
    double newValue;
    if (trimmed.isEmpty) {
      // Empty input: use current value
      newValue = widget.value;
    } else {
      final parsed = double.tryParse(trimmed);
      if (parsed != null) {
        final rounded = (parsed * 10).round() / 10;
        newValue = rounded.clamp(widget.min, widget.max);
      } else {
        // Invalid input: use current value
        newValue = widget.value;
      }
    }
    // Always update the text field to show properly formatted value
    _controller.text = newValue.toStringAsFixed(1);
    widget.onChanged(newValue);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.value;
    return SizedBox(
      width: widget.width,
      height: 50,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: widget.enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 12,
          ),
          filled: true,
          fillColor: isDark ? const Color(0xFF1A2332) : const Color(0xFFE8E8E8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF6BCB1F), width: 2),
          ),
          suffixText: 's',
          suffixStyle: TextStyle(
            color: isDark ? Colors.white70 : Colors.black54,
            fontSize: 15,
          ),
        ),
        onSubmitted: _handleSubmit,
      ),
    );
  }
}

class TimeLogsPage extends StatefulWidget {
  final Future<List<Map<String, dynamic>>> Function() loadTimeLogs;
  final Future<void> Function(int index) deleteTimeLog;
  final Future<void> Function() clearAllTimeLogs;
  final Future<void> Function(int index, {String? title, String? memo})
  updateTimeLog;
  final String logSortOrder;
  final void Function(String order) onSortOrderChanged;

  const TimeLogsPage({
    super.key,
    required this.loadTimeLogs,
    required this.deleteTimeLog,
    required this.clearAllTimeLogs,
    required this.updateTimeLog,
    required this.logSortOrder,
    required this.onSortOrderChanged,
  });

  @override
  State<TimeLogsPage> createState() => _TimeLogsPageState();
}

class _TimeLogsPageState extends State<TimeLogsPage> {
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  Set<int> _selectedIndices = {};
  late String _logSortOrder;
  Set<DateTime> _filterDates = {};
  bool _isFilteredByCalendar = false;

  // Search state
  String _searchQuery = '';
  bool _isSearching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Set<String> _selectedTags = {}; // Selected tags for filtering (empty = show all)

  // Cached sorted indices for performance
  List<int>? _cachedSortedIndices;

  final sortLabels = <String, String>{
    'time_asc': '秒数（昇順）',
    'time_desc': '秒数（降順）',
    'date_asc': '日付順（昇順）',
    'date_desc': '日付順（降順）',
    'name_asc': '名前順（昇順）',
    'name_desc': '名前順（降順）',
  };

  // Helper to get display name for sorting (use date if title is empty)
  String _getDisplayName(Map<String, dynamic> log) {
    final title = (log['title'] as String?) ?? '';
    if (title.isEmpty || title == '無題') {
      final date = DateTime.parse(log['date'] as String);
      return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return title;
  }

  @override
  void initState() {
    super.initState();
    _logSortOrder = widget.logSortOrder;
    _loadLogs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    final logs = await widget.loadTimeLogs();
    if (mounted) {
      setState(() {
        _logs = logs;
        _isLoading = false;
        _invalidateSortCache();
      });
    }
  }

  // Get all unique tags from logs
  Set<String> get _allTags {
    final tags = <String>{};
    for (final log in _logs) {
      final logTags = (log['tags'] as List?) ?? [];
      for (final tag in logTags) {
        if (tag is String) tags.add(tag);
      }
    }
    return tags;
  }

  void _showTagFilterPanel(BuildContext context, bool isDark) {
    // Unfocus search field when opening tag panel
    _searchFocusNode.unfocus();

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
      elevation: 16,
      barrierColor: Colors.black54,
      clipBehavior: Clip.antiAliasWithSaveLayer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final availableTags = _allTags.toList()..sort();
            return Material(
              color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              clipBehavior: Clip.antiAliasWithSaveLayer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'タグで絞り込み',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      if (_selectedTags.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              _selectedTags.clear();
                            });
                            setState(() {
                              _invalidateSortCache();
                            });
                          },
                          child: const Text('クリア'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (availableTags.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text(
                          'タグがありません',
                          style: TextStyle(
                            color: isDark ? Colors.white54 : Colors.black45,
                          ),
                        ),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: availableTags.map((tag) {
                        final isSelected = _selectedTags.contains(tag);
                        return FilterChip(
                          label: Text(tag),
                          selected: isSelected,
                          onSelected: (selected) {
                            setModalState(() {
                              if (selected) {
                                _selectedTags.add(tag);
                              } else {
                                _selectedTags.remove(tag);
                              }
                            });
                            setState(() {
                              _invalidateSortCache();
                            });
                          },
                          backgroundColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8),
                          selectedColor: Theme.of(context).colorScheme.primaryContainer,
                          checkmarkColor: Theme.of(context).colorScheme.primary,
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('完了'),
                    ),
                  ),
                ],
              ),
            ),
            );
          },
        );
      },
    );
  }

  // Get all unique dates that have logs (date only, no time)
  Set<DateTime> get _logDates {
    return _logs.map((log) {
      final date = DateTime.parse(log['date'] as String);
      return DateTime(date.year, date.month, date.day);
    }).toSet();
  }

  List<int> _computeSortedIndices() {
    var indices = List<int>.generate(_logs.length, (i) => i);

    // Apply search filter if active (space-separated OR search)
    if (_searchQuery.isNotEmpty) {
      final keywords = _searchQuery
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((k) => k.isNotEmpty)
          .toList();
      if (keywords.isNotEmpty) {
        indices = indices.where((i) {
          final log = _logs[i];
          final title = ((log['title'] as String?) ?? '').toLowerCase();
          final memo = ((log['memo'] as String?) ?? '').toLowerCase();
          final time = log['time'] != null
              ? (log['time'] as num).toDouble().toStringAsFixed(2)
              : '';
          final reactionTime = log['reactionTime'] != null
              ? (log['reactionTime'] as num).toDouble().toStringAsFixed(3)
              : '';
          final tags = ((log['tags'] as List?) ?? []).join(' ').toLowerCase();
          // Match if any keyword is found in title, memo, time, reactionTime, or tags
          return keywords.any(
            (keyword) =>
                title.contains(keyword) ||
                memo.contains(keyword) ||
                time.contains(keyword) ||
                reactionTime.contains(keyword) ||
                tags.contains(keyword),
          );
        }).toList();
      }
    }

    // Apply tag filter if any tags are selected
    if (_selectedTags.isNotEmpty) {
      indices = indices.where((i) {
        final log = _logs[i];
        final tags = ((log['tags'] as List?) ?? []).cast<String>().toSet();
        // Show records that have ALL selected tags
        return _selectedTags.every((tag) => tags.contains(tag));
      }).toList();
    }

    // Apply calendar filter if active
    if (_isFilteredByCalendar && _filterDates.isNotEmpty) {
      indices = indices.where((i) {
        final date = DateTime.parse(_logs[i]['date'] as String);
        final dateOnly = DateTime(date.year, date.month, date.day);
        return _filterDates.contains(dateOnly);
      }).toList();
    }

    indices.sort((a, b) {
      final timeA = _logs[a]['time'] != null
          ? (_logs[a]['time'] as num).toDouble()
          : double.infinity;
      final timeB = _logs[b]['time'] != null
          ? (_logs[b]['time'] as num).toDouble()
          : double.infinity;
      final dateA = DateTime.parse(_logs[a]['date'] as String);
      final dateB = DateTime.parse(_logs[b]['date'] as String);
      switch (_logSortOrder) {
        case 'time_asc':
          final cmp = timeA.compareTo(timeB);
          return cmp != 0 ? cmp : dateA.compareTo(dateB);
        case 'time_desc':
          final cmp = timeB.compareTo(timeA);
          return cmp != 0 ? cmp : dateB.compareTo(dateA);
        case 'date_asc':
          final cmp = dateA.compareTo(dateB);
          return cmp != 0 ? cmp : timeA.compareTo(timeB);
        case 'name_asc':
          final nameA = _getDisplayName(_logs[a]).toLowerCase();
          final nameB = _getDisplayName(_logs[b]).toLowerCase();
          final cmp = nameA.compareTo(nameB);
          return cmp != 0 ? cmp : dateA.compareTo(dateB);
        case 'name_desc':
          final nameA = _getDisplayName(_logs[a]).toLowerCase();
          final nameB = _getDisplayName(_logs[b]).toLowerCase();
          final cmp = nameB.compareTo(nameA);
          return cmp != 0 ? cmp : dateB.compareTo(dateA);
        case 'date_desc':
        default:
          final cmp = dateB.compareTo(dateA);
          return cmp != 0 ? cmp : timeB.compareTo(timeA);
      }
    });
    return indices;
  }

  // Invalidate cache when data changes
  void _invalidateSortCache() {
    _cachedSortedIndices = null;
  }

  // Get cached sorted indices
  List<int> get _sortedIndices {
    _cachedSortedIndices ??= _computeSortedIndices();
    return _cachedSortedIndices!;
  }

  Future<void> _deleteSelectedLogs() async {
    if (_selectedIndices.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('選択項目を削除'),
        content: Text('${_selectedIndices.length}件のログを削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Delete in reverse order to maintain correct indices
      final sortedIndices = _selectedIndices.toList()
        ..sort((a, b) => b.compareTo(a));
      for (final index in sortedIndices) {
        await widget.deleteTimeLog(index);
        _logs.removeAt(index);
      }
      setState(() {
        _selectedIndices.clear();
        _isSelectionMode = false;
      });
    }
  }

  // Check if selected logs have GPS data for comparison
  List<Map<String, dynamic>> _getSelectedLogsWithGpsData() {
    final logsWithGps = <Map<String, dynamic>>[];
    for (final index in _selectedIndices) {
      if (index < _logs.length) {
        final log = _logs[index];
        if (log['gpsData'] != null) {
          logsWithGps.add(log);
        }
      }
    }
    return logsWithGps;
  }

  void _compareSelectedLogs() {
    final logsWithGps = _getSelectedLogsWithGpsData();
    if (logsWithGps.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('GPS計測データがある記録を2件以上選択してください'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LogComparisonPage(logs: logsWithGps),
      ),
    );
  }

  void _openLogEditPage(int index, Map<String, dynamic> log) async {
    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (context) => LogEditPage(
          initialTitle: (log['title'] as String?) ?? '無題',
          initialMemo: (log['memo'] as String?) ?? '',
          time: log['time'] != null ? (log['time'] as num).toDouble() : null,
          reactionTime: log['reactionTime'] != null
              ? (log['reactionTime'] as num).toDouble()
              : null,
          date: DateTime.parse(log['date'] as String),
          tags: (log['tags'] as List?)?.cast<String>() ?? ['ゴール'],
          isFlying: log['isFlying'] == true,
          gpsData: log['gpsData'] as Map<String, dynamic>?,
        ),
      ),
    );

    if (result != null) {
      await widget.updateTimeLog(
        index,
        title: result['title'],
        memo: result['memo'],
      );
      setState(() {
        _logs[index]['title'] = result['title'];
        _logs[index]['memo'] = result['memo'];
      });
    }
  }

  Future<void> _showCalendarDialog() async {
    final logDates = _logDates;
    if (logDates.isEmpty) return;

    // Find oldest and newest log dates
    DateTime? oldestLogDate;
    DateTime? newestLogDate;
    for (final date in logDates) {
      if (oldestLogDate == null || date.isBefore(oldestLogDate)) {
        oldestLogDate = date;
      }
      if (newestLogDate == null || date.isAfter(newestLogDate)) {
        newestLogDate = date;
      }
    }
    final now = DateTime.now();
    final minYear = oldestLogDate?.year ?? now.year;
    final maxYear = now.year;
    final maxMonth = now.month;

    Set<DateTime> selectedDates = Set.from(_filterDates);
    DateTime displayedMonth = DateTime.now();

    // Picker mode: 'calendar', 'year', 'month'
    String pickerMode = 'calendar';

    final result = await showDialog<Set<DateTime>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, dialogSetState) {
            final isDark = themeNotifier.value;

            // Check if can navigate to previous/next month
            bool canGoPrevMonth() {
              final prevMonth = DateTime(
                displayedMonth.year,
                displayedMonth.month - 1,
              );
              return prevMonth.year > minYear ||
                  (prevMonth.year == minYear &&
                      prevMonth.month >= (oldestLogDate?.month ?? 1));
            }

            bool canGoNextMonth() {
              final nextMonth = DateTime(
                displayedMonth.year,
                displayedMonth.month + 1,
              );
              return nextMonth.year < maxYear ||
                  (nextMonth.year == maxYear && nextMonth.month <= maxMonth);
            }

            // Build year picker
            Widget buildYearPicker() {
              final years = List.generate(
                maxYear - minYear + 1,
                (i) => minYear + i,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Text(
                      '年を選択',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 2.0,
                          ),
                      itemCount: years.length,
                      itemBuilder: (context, index) {
                        final year = years[index];
                        final isSelected = year == displayedMonth.year;
                        return GestureDetector(
                          onTap: () {
                            dialogSetState(() {
                              // When selecting a year, adjust month if needed
                              int newMonth = displayedMonth.month;
                              if (year == maxYear && newMonth > maxMonth) {
                                newMonth = maxMonth;
                              }
                              displayedMonth = DateTime(year, newMonth);
                              pickerMode = 'month';
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF2196F3)
                                  : (isDark
                                        ? const Color(0xFF2A3543)
                                        : const Color(0xFFF0F0F0)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$year年',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isSelected
                                    ? Colors.white
                                    : (isDark ? Colors.white : Colors.black87),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            }

            // Build month picker
            Widget buildMonthPicker() {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            dialogSetState(() {
                              pickerMode = 'year';
                            });
                          },
                          child: Row(
                            children: [
                              Icon(
                                Icons.chevron_left,
                                size: 20,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                              Text(
                                '${displayedMonth.year}年',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF2196F3),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '月を選択',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 1.5,
                          ),
                      itemCount: 12,
                      itemBuilder: (context, index) {
                        final month = index + 1;
                        final isSelected = month == displayedMonth.month;
                        // Disable future months in current year
                        final isDisabled =
                            displayedMonth.year == maxYear && month > maxMonth;
                        // Disable months before oldest log in the oldest year
                        final isBeforeOldest =
                            displayedMonth.year == minYear &&
                            month < (oldestLogDate?.month ?? 1);
                        final isAvailable = !isDisabled && !isBeforeOldest;

                        return GestureDetector(
                          onTap: isAvailable
                              ? () {
                                  dialogSetState(() {
                                    displayedMonth = DateTime(
                                      displayedMonth.year,
                                      month,
                                    );
                                    pickerMode = 'calendar';
                                  });
                                }
                              : null,
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF2196F3)
                                  : (isAvailable
                                        ? (isDark
                                              ? const Color(0xFF2A3543)
                                              : const Color(0xFFF0F0F0))
                                        : (isDark
                                              ? const Color(0xFF1A1A1A)
                                              : const Color(0xFFE0E0E0))),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$month月',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isSelected
                                    ? Colors.white
                                    : (isAvailable
                                          ? (isDark
                                                ? Colors.white
                                                : Colors.black87)
                                          : (isDark
                                                ? Colors.white38
                                                : Colors.black26)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            }

            // Build calendar grid
            Widget buildCalendar() {
              final firstDayOfMonth = DateTime(
                displayedMonth.year,
                displayedMonth.month,
                1,
              );
              final lastDayOfMonth = DateTime(
                displayedMonth.year,
                displayedMonth.month + 1,
                0,
              );
              final startWeekday = firstDayOfMonth.weekday % 7;
              final daysInMonth = lastDayOfMonth.day;

              final days = <Widget>[];

              // Weekday headers
              const weekdays = ['日', '月', '火', '水', '木', '金', '土'];
              for (var i = 0; i < 7; i++) {
                days.add(
                  Center(
                    child: Text(
                      weekdays[i],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: i == 0
                            ? Colors.red
                            : (i == 6
                                  ? Colors.blue
                                  : (isDark ? Colors.white70 : Colors.black54)),
                      ),
                    ),
                  ),
                );
              }

              // Empty cells before first day
              for (var i = 0; i < startWeekday; i++) {
                days.add(const SizedBox());
              }

              // Day cells
              for (var day = 1; day <= daysInMonth; day++) {
                final date = DateTime(
                  displayedMonth.year,
                  displayedMonth.month,
                  day,
                );
                final hasLog = logDates.contains(date);
                final isSelected = selectedDates.contains(date);
                final weekday = date.weekday;
                final isToday =
                    DateTime.now().year == date.year &&
                    DateTime.now().month == date.month &&
                    DateTime.now().day == date.day;
                // Disable future dates
                final isFutureDate = date.isAfter(now);

                days.add(
                  GestureDetector(
                    onTap: isFutureDate
                        ? null
                        : () {
                            dialogSetState(() {
                              if (isSelected) {
                                selectedDates.remove(date);
                              } else {
                                selectedDates.add(date);
                              }
                            });
                          },
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF2196F3)
                            : (isToday
                                  ? (isDark
                                        ? const Color(0xFF2A3543)
                                        : const Color(0xFFE0E0E0))
                                  : Colors.transparent),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Text(
                            '$day',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: hasLog
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                              color: isFutureDate
                                  ? (isDark ? Colors.white24 : Colors.black26)
                                  : (isSelected
                                        ? Colors.white
                                        : (weekday == 7
                                              ? Colors.red
                                              : (weekday == 6
                                                    ? Colors.blue
                                                    : (isDark
                                                          ? Colors.white
                                                          : Colors.black87)))),
                            ),
                          ),
                          // Blue dot for days with logs
                          if (hasLog && !isSelected)
                            Positioned(
                              bottom: 4,
                              child: Container(
                                width: 5,
                                height: 5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF2196F3),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              return Column(
                children: [
                  // Month navigation with tappable year/month
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: canGoPrevMonth()
                            ? () {
                                dialogSetState(() {
                                  displayedMonth = DateTime(
                                    displayedMonth.year,
                                    displayedMonth.month - 1,
                                  );
                                });
                              }
                            : null,
                        icon: Icon(
                          Icons.chevron_left,
                          color: canGoPrevMonth()
                              ? (isDark ? Colors.white : Colors.black87)
                              : (isDark ? Colors.white24 : Colors.black26),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          dialogSetState(() {
                            pickerMode = 'year';
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2A3543)
                                : const Color(0xFFF0F0F0),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${displayedMonth.year}年${displayedMonth.month}月',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 20,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: canGoNextMonth()
                            ? () {
                                dialogSetState(() {
                                  displayedMonth = DateTime(
                                    displayedMonth.year,
                                    displayedMonth.month + 1,
                                  );
                                });
                              }
                            : null,
                        icon: Icon(
                          Icons.chevron_right,
                          color: canGoNextMonth()
                              ? (isDark ? Colors.white : Colors.black87)
                              : (isDark ? Colors.white24 : Colors.black26),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Calendar grid with swipe support
                  Expanded(
                    child: GestureDetector(
                      onHorizontalDragEnd: (details) {
                        if (details.primaryVelocity == null) return;
                        // Swipe left (negative velocity) = next month
                        if (details.primaryVelocity! < -100 && canGoNextMonth()) {
                          dialogSetState(() {
                            displayedMonth = DateTime(
                              displayedMonth.year,
                              displayedMonth.month + 1,
                            );
                          });
                        }
                        // Swipe right (positive velocity) = previous month
                        else if (details.primaryVelocity! > 100 && canGoPrevMonth()) {
                          dialogSetState(() {
                            displayedMonth = DateTime(
                              displayedMonth.year,
                              displayedMonth.month - 1,
                            );
                          });
                        }
                      },
                      child: GridView.count(
                        crossAxisCount: 7,
                        mainAxisSpacing: 4,
                        crossAxisSpacing: 4,
                        padding: EdgeInsets.zero,
                        children: days,
                      ),
                    ),
                  ),
                ],
              );
            }

            return AlertDialog(
              backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
              contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (pickerMode != 'calendar')
                    Text(
                      pickerMode == 'year' ? '年を選択' : '月を選択',
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: selectedDates.isNotEmpty
                            ? const Color(0xFF2196F3)
                            : (isDark
                                  ? const Color(0xFF2A3543)
                                  : const Color(0xFFE0E0E0)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${selectedDates.length}個 選択中',
                        style: TextStyle(
                          color: selectedDates.isNotEmpty
                              ? Colors.white
                              : (isDark ? Colors.white70 : Colors.black54),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 350,
                child: pickerMode == 'calendar'
                    ? buildCalendar()
                    : (pickerMode == 'year'
                          ? buildYearPicker()
                          : buildMonthPicker()),
              ),
              actions: [
                if (pickerMode != 'calendar')
                  TextButton(
                    onPressed: () {
                      dialogSetState(() {
                        pickerMode = 'calendar';
                      });
                    },
                    child: const Text('カレンダーに戻る'),
                  ),
                if (pickerMode == 'calendar') ...[
                  TextButton(
                    onPressed: () {
                      dialogSetState(() {
                        selectedDates.clear();
                      });
                    },
                    child: const Text('クリア'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('キャンセル'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, selectedDates),
                    child: const Text('開く'),
                  ),
                ],
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      setState(() {
        _filterDates = result;
        // If no dates selected, clear the filter
        _isFilteredByCalendar = result.isNotEmpty;
        _selectedIndices.clear();
        _isSelectionMode = false;
        _invalidateSortCache();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: themeNotifier,
      builder: (context, isDark, child) {
        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          appBar: AppBar(
            backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
            foregroundColor: isDark ? Colors.white : Colors.black87,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: false,
            titleSpacing: 0,
            toolbarHeight: kToolbarHeight,
            leading: Center(
              child: _isSelectionMode
                  ? IconButton(
                      onPressed: () {
                        setState(() {
                          _isSelectionMode = false;
                          _selectedIndices.clear();
                        });
                      },
                      icon: const Icon(Icons.close),
                    )
                  : IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                    ),
            ),
            title: Text(
              _isSelectionMode ? '${_selectedIndices.length}件選択中' : '計測ログ',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            actions: [
              if (_logs.isNotEmpty) ...[
                if (_isSelectionMode && _selectedIndices.length >= 2)
                  TextButton(
                    onPressed: _compareSelectedLogs,
                    child: const Text(
                      '比較',
                      style: TextStyle(color: Color(0xFF00BCD4), fontSize: 15),
                    ),
                  ),
                if (_isSelectionMode && _selectedIndices.isNotEmpty)
                  TextButton(
                    onPressed: _deleteSelectedLogs,
                    child: const Text(
                      '削除',
                      style: TextStyle(color: Colors.red, fontSize: 15),
                    ),
                  ),
                if (!_isSelectionMode)
                  TextButton(
                    onPressed: () async {
                      final isFiltered =
                          (_isFilteredByCalendar && _filterDates.isNotEmpty) ||
                          _searchQuery.isNotEmpty;
                      final filteredCount = isFiltered
                          ? _sortedIndices.length
                          : _logs.length;

                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(
                            isFiltered ? '絞り込み中の記録を削除' : '全て削除',
                            softWrap: false,
                            overflow: TextOverflow.visible,
                          ),
                          content: Text(
                            isFiltered
                                ? '現在絞り込まれている$filteredCount件の計測ログを削除しますか？'
                                : '全ての計測ログを削除しますか？',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('キャンセル'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text(
                                '削除',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        if (isFiltered) {
                          // Delete only filtered logs (in reverse order to maintain indices)
                          final indicesToDelete = _sortedIndices.toList()
                            ..sort((a, b) => b.compareTo(a));
                          for (final index in indicesToDelete) {
                            await widget.deleteTimeLog(index);
                            _logs.removeAt(index);
                          }
                          setState(() {
                            _filterDates.clear();
                            _isFilteredByCalendar = false;
                            _searchQuery = '';
                            _searchController.clear();
                            _isSearching = false;
                            _selectedTags.clear();
                            _invalidateSortCache();
                          });
                        } else {
                          await widget.clearAllTimeLogs();
                          setState(() {
                            _logs.clear();
                            _invalidateSortCache();
                          });
                        }
                      }
                    },
                    child: Text(
                      '全て削除',
                      style: const TextStyle(color: Colors.red),
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ],
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    // Calendar filter indicator
                    if (_isFilteredByCalendar)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        color: isDark
                            ? const Color(0xFF1E3A5F)
                            : const Color(0xFFE3F2FD),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${_filterDates.length}個 選択中',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: isDark
                                      ? const Color(0xFF64B5F6)
                                      : const Color(0xFF1976D2),
                                ),
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _isFilteredByCalendar = false;
                                  _filterDates.clear();
                                  _invalidateSortCache();
                                });
                              },
                              child: Icon(
                                Icons.close,
                                size: 20,
                                color: isDark
                                    ? const Color(0xFF64B5F6)
                                    : const Color(0xFF1976D2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_logs.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Search and Calendar buttons
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Search button
                                GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _isSearching = !_isSearching;
                                      if (!_isSearching) {
                                        // Reset search when closing
                                        _searchQuery = '';
                                        _searchController.clear();
                                        _selectedTags.clear();
                                        _searchFocusNode.unfocus();
                                        _invalidateSortCache();
                                      }
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _isSearching
                                          ? const Color(
                                              0xFFFF9800,
                                            ).withOpacity(0.15)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.search,
                                          size: 20,
                                          color: _isSearching
                                              ? const Color(0xFFFF9800)
                                              : (isDark
                                                    ? Colors.white70
                                                    : Colors.black54),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '検索',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: _isSearching
                                                ? const Color(0xFFFF9800)
                                                : (isDark
                                                      ? Colors.white70
                                                      : Colors.black54),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                // Calendar button
                                GestureDetector(
                                  onTap: () {
                                    _searchFocusNode.unfocus();
                                    _showCalendarDialog();
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.calendar_month,
                                        size: 20,
                                        color: _isFilteredByCalendar
                                            ? const Color(0xFF2196F3)
                                            : (isDark
                                                  ? Colors.white70
                                                  : Colors.black54),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'カレンダー',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: _isFilteredByCalendar
                                              ? const Color(0xFF2196F3)
                                              : (isDark
                                                    ? Colors.white70
                                                    : Colors.black54),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            // Sort dropdown
                            PopupMenuButton<String>(
                              onOpened: () {
                                _searchFocusNode.unfocus();
                              },
                              onSelected: (value) async {
                                final prefs =
                                    await SharedPreferences.getInstance();
                                await prefs.setString('log_sort_order', value);
                                widget.onSortOrderChanged(value);
                                setState(() {
                                  _logSortOrder = value;
                                  _invalidateSortCache();
                                });
                              },
                              itemBuilder: (context) => sortLabels.entries
                                  .map(
                                    (entry) => PopupMenuItem<String>(
                                      value: entry.key,
                                      child: Text(entry.value),
                                    ),
                                  )
                                  .toList(),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    sortLabels[_logSortOrder]!,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.expand_more,
                                    size: 18,
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black54,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Search input field and tag filter
                    if (_isSearching) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                decoration: InputDecoration(
                                  hintText: '題名、メモ、秒数で検索',
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: _searchController.text.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(Icons.clear),
                                          onPressed: () {
                                            setState(() {
                                              _searchController.clear();
                                              _searchQuery = '';
                                              _invalidateSortCache();
                                            });
                                          },
                                        )
                                      : null,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  isDense: true,
                                ),
                                onChanged: (value) {
                                  setState(() {
                                    _searchQuery = value;
                                    _invalidateSortCache();
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Tag filter button
                            TextButton.icon(
                              onPressed: () {
                                _showTagFilterPanel(context, isDark);
                              },
                              icon: Icon(
                                Icons.label,
                                size: 18,
                                color: _selectedTags.isNotEmpty
                                    ? Theme.of(context).colorScheme.primary
                                    : (isDark ? Colors.white70 : Colors.black54),
                              ),
                              label: Text(
                                'タグ${_selectedTags.isNotEmpty ? '(${_selectedTags.length})' : ''}',
                                style: TextStyle(
                                  color: _selectedTags.isNotEmpty
                                      ? Theme.of(context).colorScheme.primary
                                      : (isDark ? Colors.white70 : Colors.black54),
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Selected tags display
                      if (_selectedTags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: _selectedTags.map((tag) {
                              return Chip(
                                label: Text(
                                  tag,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                deleteIcon: const Icon(Icons.close, size: 16),
                                onDeleted: () {
                                  setState(() {
                                    _selectedTags.remove(tag);
                                    _invalidateSortCache();
                                  });
                                },
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          // Unfocus search field when tapping on list area
                          _searchFocusNode.unfocus();
                        },
                        behavior: HitTestBehavior.translucent,
                        child: _logs.isEmpty
                          ? Center(
                              child: Text(
                                '計測ログがありません',
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                            )
                          : _sortedIndices.isEmpty
                          ? Center(
                              child: Text(
                                _searchQuery.isNotEmpty || _selectedTags.isNotEmpty
                                    ? '検索結果がありません'
                                    : '選択した日付に記録がありません',
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(20),
                              itemCount: _sortedIndices.length,
                              addAutomaticKeepAlives: false,
                              addRepaintBoundaries: true,
                              itemBuilder: (context, index) {
                                final sortedIndex = _sortedIndices[index];
                                final log = _logs[sortedIndex];
                                final time = log['time'] != null
                                    ? (log['time'] as num).toDouble()
                                    : null;
                                final reactionTime = log['reactionTime'] != null
                                    ? (log['reactionTime'] as num).toDouble()
                                    : null;
                                final tags =
                                    (log['tags'] as List?)?.cast<String>() ??
                                    ['ゴール']; // Default for old logs
                                final isFlying = log['isFlying'] == true;
                                final date = DateTime.parse(
                                  log['date'] as String,
                                );
                                final dateStr =
                                    "${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}";
                                final isSelected = _selectedIndices.contains(
                                  sortedIndex,
                                );
                                final rawTitle =
                                    (log['title'] as String?) ?? '';
                                final hasTitle =
                                    rawTitle.isNotEmpty && rawTitle != '無題';
                                final memo = (log['memo'] as String?) ?? '';

                                return GestureDetector(
                                  onLongPress: () {
                                    // If search is focused, just unfocus first
                                    if (_searchFocusNode.hasFocus) {
                                      _searchFocusNode.unfocus();
                                      return;
                                    }
                                    setState(() {
                                      _isSelectionMode = true;
                                      _selectedIndices.add(sortedIndex);
                                    });
                                  },
                                  onTap: () {
                                    // If search is focused, just unfocus first
                                    if (_searchFocusNode.hasFocus) {
                                      _searchFocusNode.unfocus();
                                      return;
                                    }
                                    if (_isSelectionMode) {
                                      setState(() {
                                        if (_selectedIndices.contains(
                                          sortedIndex,
                                        )) {
                                          _selectedIndices.remove(sortedIndex);
                                          if (_selectedIndices.isEmpty) {
                                            _isSelectionMode = false;
                                          }
                                        } else {
                                          _selectedIndices.add(sortedIndex);
                                        }
                                      });
                                    } else {
                                      _openLogEditPage(sortedIndex, log);
                                    }
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? (isDark
                                                ? const Color(0xFF3A3A3A)
                                                : const Color(0xFFE0E0E0))
                                          : (isDark
                                                ? const Color(0xFF1F1F1F)
                                                : const Color(0xFFF5F5F5)),
                                      borderRadius: BorderRadius.circular(12),
                                      border: isSelected
                                          ? Border.all(
                                              color: Colors.red,
                                              width: 2,
                                            )
                                          : Border.all(
                                              color: isDark
                                                  ? Colors.transparent
                                                  : const Color(0xFFE0E0E0),
                                              width: 1,
                                            ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              if (hasTitle) ...[
                                                Text(
                                                  rawTitle,
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    color: isDark
                                                        ? Colors.white
                                                        : Colors.black87,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                if (memo.isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    memo,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: isDark
                                                          ? Colors.white54
                                                          : Colors.black45,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                                const SizedBox(height: 4),
                                                Text(
                                                  dateStr,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: isDark
                                                        ? Colors.white54
                                                        : Colors.black45,
                                                  ),
                                                ),
                                              ] else ...[
                                                // No title: show date as main text
                                                Text(
                                                  dateStr,
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    color: isDark
                                                        ? Colors.white
                                                        : Colors.black87,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                if (memo.isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    memo,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: isDark
                                                          ? Colors.white54
                                                          : Colors.black45,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                              // Tags display
                                              if (tags.isNotEmpty) ...[
                                                const SizedBox(height: 6),
                                                Wrap(
                                                  spacing: 4,
                                                  runSpacing: 4,
                                                  children: tags.map((tag) {
                                                    final isReaction =
                                                        tag == 'リアクション';
                                                    return Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 6,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: isReaction
                                                            ? const Color(
                                                                0xFFFF9800,
                                                              ).withOpacity(0.2)
                                                            : const Color(
                                                                0xFF00BCD4,
                                                              ).withOpacity(
                                                                0.2,
                                                              ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              4,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        tag,
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          color: isReaction
                                                              ? const Color(
                                                                  0xFFFF9800,
                                                                )
                                                              : const Color(
                                                                  0xFF00BCD4,
                                                                ),
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    );
                                                  }).toList(),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        // Time display
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            if (isFlying)
                                              const Text(
                                                'FLYING',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFFE53935),
                                                ),
                                              )
                                            else if (time != null)
                                              Text(
                                                '${time.toStringAsFixed(2)}s',
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFFFFD700),
                                                ),
                                              ),
                                            if (reactionTime != null &&
                                                !isFlying)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 4,
                                                ),
                                                child: Text(
                                                  '${reactionTime.toStringAsFixed(3)}s',
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                    color: Color(0xFFFF9800),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        if (_isSelectionMode)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 12,
                                            ),
                                            child: Checkbox(
                                              value: isSelected,
                                              activeColor: Colors.red,
                                              onChanged: (value) {
                                                setState(() {
                                                  if (value == true) {
                                                    _selectedIndices.add(
                                                      sortedIndex,
                                                    );
                                                  } else {
                                                    _selectedIndices.remove(
                                                      sortedIndex,
                                                    );
                                                    if (_selectedIndices
                                                        .isEmpty) {
                                                      _isSelectionMode = false;
                                                    }
                                                  }
                                                });
                                              },
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class LogEditPage extends StatefulWidget {
  final String initialTitle;
  final String initialMemo;
  final double? time;
  final double? reactionTime;
  final DateTime date;
  final List<String> tags;
  final bool isFlying;
  final Map<String, dynamic>? gpsData;

  const LogEditPage({
    super.key,
    required this.initialTitle,
    required this.initialMemo,
    this.time,
    this.reactionTime,
    required this.date,
    this.tags = const ['ゴール'],
    this.isFlying = false,
    this.gpsData,
  });

  @override
  State<LogEditPage> createState() => _LogEditPageState();
}

class _LogEditPageState extends State<LogEditPage>
    with SingleTickerProviderStateMixin {
  late TextEditingController _titleController;
  late TextEditingController _memoController;
  TabController? _tabController;

  // For chart touch tracking
  double? _touchedDistance;
  double? _touchedSpeed;

  // Chart display mode: 'distance' or 'time'
  String _chartMode = 'distance';

  bool get hasGpsData => widget.gpsData != null;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _memoController = TextEditingController(text: widget.initialMemo);
    if (hasGpsData) {
      _tabController = TabController(length: 2, vsync: this);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _tabController?.dispose();
    super.dispose();
  }

  void _save() {
    final newTitle = _titleController.text.trim().isEmpty
        ? '無題'
        : _titleController.text.trim();
    final newMemo = _memoController.text.trim();
    Navigator.pop(context, {'title': newTitle, 'memo': newMemo});
  }

  // Build the header section (tags, time, date)
  Widget _buildHeaderSection(bool isDark, String dateStr) {
    return Column(
      children: [
        // Tags display
        Center(
          child: Wrap(
            spacing: 8,
            children: widget.tags.map((tag) {
              final isGoal = tag == 'ゴール';
              return Chip(
                label: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 12,
                    color: isGoal ? Colors.cyan : Colors.orange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor:
                    isGoal ? Colors.cyan.withAlpha(30) : Colors.orange.withAlpha(30),
                side: BorderSide(
                  color: isGoal ? Colors.cyan : Colors.orange,
                  width: 1,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 16),
        // Flying indicator
        if (widget.isFlying)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(30),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red, width: 1.5),
              ),
              child: const Text(
                'FLYING',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.red,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        if (widget.isFlying) const SizedBox(height: 16),
        // Goal time display
        if (widget.time != null)
          Center(
            child: Column(
              children: [
                if (widget.tags.contains('リアクション') && widget.tags.contains('ゴール'))
                  Text(
                    'ゴール',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                Text(
                  '${widget.time!.toStringAsFixed(2)}s',
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFFFD700),
                  ),
                ),
              ],
            ),
          ),
        // Reaction time display
        if (widget.reactionTime != null)
          Center(
            child: Column(
              children: [
                if (widget.time != null) const SizedBox(height: 8),
                if (widget.tags.contains('リアクション') && widget.tags.contains('ゴール'))
                  Text(
                    'リアクション',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                Text(
                  '${widget.reactionTime!.toStringAsFixed(3)}s',
                  style: TextStyle(
                    fontSize: widget.time != null ? 28 : 36,
                    fontWeight: FontWeight.w700,
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
          ),
        // Show "計測失敗" when goal_and_reaction mode but no reaction time detected
        if (widget.reactionTime == null &&
            widget.tags.contains('リアクション') &&
            widget.tags.contains('ゴール'))
          Center(
            child: Column(
              children: [
                if (widget.time != null) const SizedBox(height: 8),
                Text(
                  'リアクション',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
                Text(
                  '計測失敗',
                  style: TextStyle(
                    fontSize: widget.time != null ? 24 : 32,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            dateStr,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white54 : Colors.black45,
            ),
          ),
        ),
      ],
    );
  }

  // Build the memo tab content
  Widget _buildMemoTab(bool isDark, String dateStr) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeaderSection(isDark, dateStr),
          const SizedBox(height: 24),
          // Title field
          Text(
            '題名',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            decoration: InputDecoration(
              hintText: '無題',
              hintStyle: TextStyle(
                color: isDark ? Colors.white38 : Colors.black26,
              ),
              filled: true,
              fillColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFFFFD700),
                  width: 2,
                ),
              ),
            ),
            style: TextStyle(
              fontSize: 18,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 24),
          // Memo field
          Text(
            'メモ',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _memoController,
            decoration: InputDecoration(
              hintText: 'メモを入力...',
              hintStyle: TextStyle(
                color: isDark ? Colors.white38 : Colors.black26,
              ),
              filled: true,
              fillColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFFFFD700),
                  width: 2,
                ),
              ),
            ),
            style: TextStyle(
              fontSize: 16,
              color: isDark ? Colors.white : Colors.black87,
            ),
            maxLines: 12,
            minLines: 6,
          ),
        ],
      ),
    );
  }

  // Build GPS stats card
  Widget _buildGpsStatsCard(bool isDark) {
    final gpsData = widget.gpsData!;
    final distance = (gpsData['distance'] as num?)?.toDouble() ?? 0;
    final initialSpeed = (gpsData['initialSpeed'] as num?)?.toDouble() ?? 0;
    final finalSpeed = (gpsData['finalSpeed'] as num?)?.toDouble() ?? 0;
    final topSpeed = (gpsData['topSpeed'] as num?)?.toDouble() ?? 0;
    final averageSpeed = (gpsData['averageSpeed'] as num?)?.toDouble() ?? 0;
    final courseType = gpsData['courseType'] as String? ?? 'straight';
    final gpsUpdateCount = (gpsData['gpsUpdateCount'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.gps_fixed,
                color: const Color(0xFF00BCD4),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'GPS計測データ',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Stats grid
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              _buildStatItem(
                  '距離', '${distance.toStringAsFixed(0)}m', Icons.straighten, isDark),
              _buildStatItem(
                  'コース',
                  courseType == 'straight' ? '直線' : 'トラック',
                  courseType == 'straight' ? Icons.straighten : Icons.stadium,
                  isDark),
              _buildStatItem('初速', '${initialSpeed.toStringAsFixed(1)} m/s',
                  Icons.play_arrow, isDark),
              _buildStatItem('終速', '${finalSpeed.toStringAsFixed(1)} m/s',
                  Icons.stop, isDark),
              _buildStatItem('最高速度', '${topSpeed.toStringAsFixed(1)} m/s',
                  Icons.speed, isDark),
              _buildStatItem('平均速度', '${averageSpeed.toStringAsFixed(1)} m/s',
                  Icons.av_timer, isDark),
              _buildStatItem('GPS更新', '$gpsUpdateCount回',
                  Icons.update, isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, bool isDark) {
    return SizedBox(
      width: 140,
      child: Row(
        children: [
          Icon(icon, size: 16, color: isDark ? Colors.white54 : Colors.black45),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Build speed chart (distance or time based)
  Widget _buildSpeedDistanceChart(bool isDark) {
    final gpsData = widget.gpsData!;
    final speedProfileRaw = gpsData['speedProfile'] as List?;
    if (speedProfileRaw == null || speedProfileRaw.isEmpty) {
      return Container(
        height: 200,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        child: Text(
          '速度データがありません',
          style: TextStyle(color: isDark ? Colors.white54 : Colors.black45),
        ),
      );
    }

    // Parse speed profile data
    final rawData = speedProfileRaw.map((item) {
      final map = item as Map<String, dynamic>;
      return {
        'distance': (map['distance'] as num).toDouble(),
        'speed': (map['speed'] as num).toDouble(),
      };
    }).toList();

    // Calculate time-based data by integrating distance/speed
    final List<FlSpot> distanceProfile = [];
    final List<FlSpot> timeProfile = [];
    double cumulativeTime = 0;

    for (int i = 0; i < rawData.length; i++) {
      final distance = rawData[i]['distance']!;
      final speed = rawData[i]['speed']!;

      distanceProfile.add(FlSpot(distance, speed));

      if (i > 0) {
        final prevDistance = rawData[i - 1]['distance']!;
        final prevSpeed = rawData[i - 1]['speed']!;
        final deltaDistance = distance - prevDistance;
        final avgSpeed = (speed + prevSpeed) / 2;
        if (avgSpeed > 0) {
          cumulativeTime += deltaDistance / avgSpeed;
        }
      }
      timeProfile.add(FlSpot(cumulativeTime, speed));
    }

    final isTimeMode = _chartMode == 'time';
    final chartData = isTimeMode ? timeProfile : distanceProfile;

    final maxSpeed = chartData.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final maxX = chartData.map((s) => s.x).reduce((a, b) => a > b ? a : b);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.show_chart, color: const Color(0xFFFFD700), size: 20),
              const SizedBox(width: 8),
              Text(
                isTimeMode ? '速度-時間グラフ' : '速度-距離グラフ',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              // Touch info display
              if (_touchedDistance != null && _touchedSpeed != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF3A3A3A) : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFFFD700).withAlpha(100),
                    ),
                  ),
                  child: Text(
                    isTimeMode
                        ? '${_touchedDistance!.toStringAsFixed(1)}秒: ${_touchedSpeed!.toStringAsFixed(1)} m/s'
                        : '${_touchedDistance!.toInt()}m: ${_touchedSpeed!.toStringAsFixed(1)} m/s',
                    style: const TextStyle(
                      color: Color(0xFFFFD700),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Mode toggle buttons
          Row(
            children: [
              _buildChartModeButton('distance', '距離', Icons.straighten, isDark),
              const SizedBox(width: 8),
              _buildChartModeButton('time', '時間', Icons.timer, isDark),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              // Chart area dimensions (accounting for axis labels)
              const leftPadding = 40.0; // Left axis reserved size
              const bottomPadding = 30.0; // Bottom axis reserved size
              final chartWidth = constraints.maxWidth - leftPadding;
              const chartHeight = 200.0 - bottomPadding;
              final effectiveMaxX = maxX > 0 ? maxX : 100.0;
              final effectiveMaxY = (maxSpeed * 1.1).ceilToDouble();

              // Helper function to interpolate speed at any x position
              double interpolateSpeed(double x) {
                if (chartData.isEmpty) return 0;
                if (x <= chartData.first.x) return chartData.first.y;
                if (x >= chartData.last.x) return chartData.last.y;

                // Find surrounding points
                for (int i = 0; i < chartData.length - 1; i++) {
                  if (chartData[i].x <= x && chartData[i + 1].x >= x) {
                    final t = (x - chartData[i].x) / (chartData[i + 1].x - chartData[i].x);
                    return chartData[i].y + t * (chartData[i + 1].y - chartData[i].y);
                  }
                }
                return chartData.last.y;
              }

              return GestureDetector(
                onPanStart: (details) {
                  final localX = details.localPosition.dx - leftPadding;
                  if (localX >= 0 && localX <= chartWidth) {
                    final x = (localX / chartWidth) * effectiveMaxX;
                    final clampedX = x.clamp(0.0, effectiveMaxX);
                    setState(() {
                      _touchedDistance = clampedX;
                      _touchedSpeed = interpolateSpeed(clampedX);
                    });
                  }
                },
                onPanUpdate: (details) {
                  final localX = details.localPosition.dx - leftPadding;
                  if (localX >= 0 && localX <= chartWidth) {
                    final x = (localX / chartWidth) * effectiveMaxX;
                    final clampedX = x.clamp(0.0, effectiveMaxX);
                    setState(() {
                      _touchedDistance = clampedX;
                      _touchedSpeed = interpolateSpeed(clampedX);
                    });
                  }
                },
                onTapDown: (details) {
                  final localX = details.localPosition.dx - leftPadding;
                  if (localX >= 0 && localX <= chartWidth) {
                    final x = (localX / chartWidth) * effectiveMaxX;
                    final clampedX = x.clamp(0.0, effectiveMaxX);
                    setState(() {
                      _touchedDistance = clampedX;
                      _touchedSpeed = interpolateSpeed(clampedX);
                    });
                  }
                },
                child: SizedBox(
                  height: 200,
                  child: LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        horizontalInterval: 2,
                        verticalInterval: effectiveMaxX / 5,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: isDark
                              ? Colors.white.withAlpha(30)
                              : Colors.black.withAlpha(30),
                          strokeWidth: 1,
                        ),
                        getDrawingVerticalLine: (value) => FlLine(
                          color: isDark
                              ? Colors.white.withAlpha(30)
                              : Colors.black.withAlpha(30),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          axisNameWidget: Text(
                            isTimeMode ? '時間 (秒)' : '距離 (m)',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30,
                            interval: effectiveMaxX / 5,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                isTimeMode ? value.toStringAsFixed(1) : value.toInt().toString(),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isDark ? Colors.white54 : Colors.black45,
                                ),
                              );
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          axisNameWidget: Text(
                            '速度 (m/s)',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            interval: 2,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                value.toInt().toString(),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isDark ? Colors.white54 : Colors.black45,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withAlpha(50)
                              : Colors.black.withAlpha(50),
                        ),
                      ),
                      minX: 0,
                      maxX: effectiveMaxX,
                      minY: 0,
                      maxY: effectiveMaxY,
                      lineBarsData: [
                        LineChartBarData(
                          spots: chartData,
                          isCurved: true,
                          color: const Color(0xFFFFD700),
                          barWidth: 3,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: const Color(0xFFFFD700).withAlpha(50),
                          ),
                        ),
                        // Show persistent dot at touched point
                        if (_touchedDistance != null && _touchedSpeed != null)
                          LineChartBarData(
                            spots: [FlSpot(_touchedDistance!, _touchedSpeed!)],
                            barWidth: 0,
                            dotData: FlDotData(
                              show: true,
                              getDotPainter: (spot, percent, barData, index) {
                                return FlDotCirclePainter(
                                  radius: 6,
                                  color: const Color(0xFFFFD700),
                                  strokeWidth: 2,
                                  strokeColor: Colors.white,
                                );
                              },
                            ),
                          ),
                      ],
                      extraLinesData: ExtraLinesData(
                        verticalLines: _touchedDistance != null
                            ? [
                                VerticalLine(
                                  x: _touchedDistance!,
                                  color: const Color(0xFFFFD700),
                                  strokeWidth: 2,
                                  label: VerticalLineLabel(
                                    show: false,
                                  ),
                                ),
                              ]
                            : [],
                      ),
                      lineTouchData: const LineTouchData(
                        enabled: false, // Disable built-in touch - we handle it manually
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChartModeButton(String mode, String label, IconData icon, bool isDark) {
    final isSelected = _chartMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() {
          _chartMode = mode;
          _touchedDistance = null;
          _touchedSpeed = null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFFFD700).withAlpha(30)
              : (isDark ? const Color(0xFF3A3A3A) : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? const Color(0xFFFFD700)
                : (isDark ? const Color(0xFF4A4A4A) : const Color(0xFFE0E0E0)),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected
                  ? const Color(0xFFFFD700)
                  : (isDark ? Colors.white54 : Colors.black45),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? const Color(0xFFFFD700)
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build track map (trajectory visualization)
  Widget _buildTrackMap(bool isDark) {
    final gpsData = widget.gpsData!;
    final trackPointsRaw = gpsData['trackPoints'] as List?;
    if (trackPointsRaw == null || trackPointsRaw.length < 2) {
      return Container(
        height: 200,
        margin: const EdgeInsets.all(16),
        alignment: Alignment.center,
        child: Text(
          '軌跡データがありません',
          style: TextStyle(color: isDark ? Colors.white54 : Colors.black45),
        ),
      );
    }

    final trackPoints = trackPointsRaw.map((item) {
      final map = item as Map<String, dynamic>;
      return Offset(
        (map['lat'] as num).toDouble(),
        (map['lon'] as num).toDouble(),
      );
    }).toList();

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route, color: const Color(0xFF00BCD4), size: 20),
              const SizedBox(width: 8),
              Text(
                '走行軌跡',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: CustomPaint(
              size: const Size(double.infinity, 200),
              painter: TrackMapPainter(
                points: trackPoints,
                isDark: isDark,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegendItem('スタート', Colors.green, isDark),
              const SizedBox(width: 16),
              _buildLegendItem('ゴール', Colors.red, isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color, bool isDark) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
      ],
    );
  }

  // _buildCadenceChart and _buildVerticalOscillationChart removed (stride data not collected)

  // Build the graph tab content
  Widget _buildGraphTab(bool isDark, String dateStr) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 16),
          _buildHeaderSection(isDark, dateStr),
          const SizedBox(height: 16),
          _buildGpsStatsCard(isDark),
          _buildSpeedDistanceChart(isDark),
          const SizedBox(height: 16),
          _buildTrackMap(isDark),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        "${widget.date.year}/${widget.date.month.toString().padLeft(2, '0')}/${widget.date.day.toString().padLeft(2, '0')} ${widget.date.hour.toString().padLeft(2, '0')}:${widget.date.minute.toString().padLeft(2, '0')}:${widget.date.second.toString().padLeft(2, '0')}";

    return ValueListenableBuilder<bool>(
      valueListenable: themeNotifier,
      builder: (context, isDark, child) {
        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          appBar: AppBar(
            backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
            foregroundColor: isDark ? Colors.white : Colors.black87,
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
            actions: [
              TextButton(
                onPressed: _save,
                child: const Text(
                  '保存',
                  style: TextStyle(
                    color: Color(0xFFFFD700),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            bottom: hasGpsData
                ? TabBar(
                    controller: _tabController,
                    labelColor: const Color(0xFFFFD700),
                    unselectedLabelColor: isDark ? Colors.white54 : Colors.black45,
                    indicatorColor: const Color(0xFFFFD700),
                    tabs: const [
                      Tab(text: 'メモ'),
                      Tab(text: 'グラフ'),
                    ],
                  )
                : null,
          ),
          body: hasGpsData
              ? TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _buildMemoTab(isDark, dateStr),
                    _buildGraphTab(isDark, dateStr),
                  ],
                )
              : _buildMemoTab(isDark, dateStr),
        );
      },
    );
  }
}

// Custom painter for track map visualization
class TrackMapPainter extends CustomPainter {
  final List<Offset> points;
  final bool isDark;

  TrackMapPainter({required this.points, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    // Find bounds
    double minLat = points.first.dx;
    double maxLat = points.first.dx;
    double minLon = points.first.dy;
    double maxLon = points.first.dy;

    for (final p in points) {
      if (p.dx < minLat) minLat = p.dx;
      if (p.dx > maxLat) maxLat = p.dx;
      if (p.dy < minLon) minLon = p.dy;
      if (p.dy > maxLon) maxLon = p.dy;
    }

    // Add padding
    final latRange = maxLat - minLat;
    final lonRange = maxLon - minLon;
    final padding = 0.1;
    minLat -= latRange * padding;
    maxLat += latRange * padding;
    minLon -= lonRange * padding;
    maxLon += lonRange * padding;

    // Ensure minimum range to avoid division by zero
    final effectiveLatRange = (maxLat - minLat) > 0.00001 ? (maxLat - minLat) : 0.00001;
    final effectiveLonRange = (maxLon - minLon) > 0.00001 ? (maxLon - minLon) : 0.00001;

    // Convert to screen coordinates
    Offset toScreen(Offset gps) {
      final x = (gps.dy - minLon) / effectiveLonRange * size.width;
      final y = size.height - (gps.dx - minLat) / effectiveLatRange * size.height;
      return Offset(x, y);
    }

    // Draw track line
    final trackPaint = Paint()
      ..color = const Color(0xFF00BCD4)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final firstScreen = toScreen(points.first);
    path.moveTo(firstScreen.dx, firstScreen.dy);

    for (int i = 1; i < points.length; i++) {
      final screen = toScreen(points[i]);
      path.lineTo(screen.dx, screen.dy);
    }

    canvas.drawPath(path, trackPaint);

    // Draw start point (green)
    final startPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.fill;
    canvas.drawCircle(firstScreen, 8, startPaint);

    // Draw end point (red)
    final endScreen = toScreen(points.last);
    final endPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;
    canvas.drawCircle(endScreen, 8, endPaint);

    // Draw direction arrows along the path
    if (points.length >= 4) {
      final arrowPaint = Paint()
        ..color = isDark ? Colors.white54 : Colors.black45
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      for (int i = points.length ~/ 4; i < points.length; i += points.length ~/ 4) {
        if (i > 0 && i < points.length - 1) {
          final current = toScreen(points[i]);
          final prev = toScreen(points[i - 1]);
          final angle = atan2(current.dy - prev.dy, current.dx - prev.dx);

          // Draw small arrow
          final arrowSize = 6.0;
          final arrowPath = Path();
          arrowPath.moveTo(
            current.dx - arrowSize * cos(angle - 0.5),
            current.dy - arrowSize * sin(angle - 0.5),
          );
          arrowPath.lineTo(current.dx, current.dy);
          arrowPath.lineTo(
            current.dx - arrowSize * cos(angle + 0.5),
            current.dy - arrowSize * sin(angle + 0.5),
          );
          canvas.drawPath(arrowPath, arrowPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Log Comparison Page - compare multiple GPS measurement logs
class LogComparisonPage extends StatelessWidget {
  final List<Map<String, dynamic>> logs;

  const LogComparisonPage({super.key, required this.logs});

  // Generate distinct colors for each log
  static final List<Color> _colors = [
    const Color(0xFFFFD700), // Gold
    const Color(0xFF00BCD4), // Cyan
    const Color(0xFFFF5722), // Deep Orange
    const Color(0xFF4CAF50), // Green
    const Color(0xFF9C27B0), // Purple
    const Color(0xFFE91E63), // Pink
    const Color(0xFF2196F3), // Blue
    const Color(0xFFFF9800), // Orange
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: themeNotifier,
      builder: (context, isDark, child) {
        return Scaffold(
          backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          appBar: AppBar(
            backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
            foregroundColor: isDark ? Colors.white : Colors.black87,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: Text(
              '記録比較 (${logs.length}件)',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLegend(isDark),
                const SizedBox(height: 16),
                _buildComparisonChart(isDark),
                const SizedBox(height: 24),
                _buildStatsTable(isDark),
                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLegend(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '凡例',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: List.generate(logs.length, (index) {
              final log = logs[index];
              final title = (log['title'] as String?) ?? '無題';
              final date = DateTime.parse(log['date'] as String);
              final dateStr =
                  '${date.month}/${date.day} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 16,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _colors[index % _colors.length],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    title.isEmpty ? dateStr : '$title ($dateStr)',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonChart(bool isDark) {
    // Gather all speed profiles and find max values
    final allProfiles = <int, List<FlSpot>>{};
    double maxSpeed = 0;
    double maxDistance = 0;

    for (int i = 0; i < logs.length; i++) {
      final gpsData = logs[i]['gpsData'] as Map<String, dynamic>?;
      if (gpsData == null) continue;

      final speedProfileRaw = gpsData['speedProfile'] as List?;
      if (speedProfileRaw == null || speedProfileRaw.isEmpty) continue;

      final profile = speedProfileRaw.map((item) {
        final map = item as Map<String, dynamic>;
        return FlSpot(
          (map['distance'] as num).toDouble(),
          (map['speed'] as num).toDouble(),
        );
      }).toList();

      allProfiles[i] = profile;

      for (final spot in profile) {
        if (spot.y > maxSpeed) maxSpeed = spot.y;
        if (spot.x > maxDistance) maxDistance = spot.x;
      }
    }

    if (allProfiles.isEmpty) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        child: Text(
          '速度データがありません',
          style: TextStyle(color: isDark ? Colors.white54 : Colors.black45),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.compare_arrows, color: const Color(0xFFFFD700), size: 20),
              const SizedBox(width: 8),
              Text(
                '速度-距離比較グラフ',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 250,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  horizontalInterval: 2,
                  verticalInterval: maxDistance > 0 ? maxDistance / 5 : 20,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: isDark
                        ? Colors.white.withAlpha(30)
                        : Colors.black.withAlpha(30),
                    strokeWidth: 1,
                  ),
                  getDrawingVerticalLine: (value) => FlLine(
                    color: isDark
                        ? Colors.white.withAlpha(30)
                        : Colors.black.withAlpha(30),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: Text(
                      '距離 (m)',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: maxDistance > 0 ? maxDistance / 5 : 20,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          value.toInt().toString(),
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white54 : Colors.black45,
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: Text(
                      '速度 (m/s)',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      interval: 2,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          value.toInt().toString(),
                          style: TextStyle(
                            fontSize: 10,
                            color: isDark ? Colors.white54 : Colors.black45,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withAlpha(50)
                        : Colors.black.withAlpha(50),
                  ),
                ),
                minX: 0,
                maxX: maxDistance > 0 ? maxDistance : 100,
                minY: 0,
                maxY: (maxSpeed * 1.1).ceilToDouble(),
                lineBarsData: allProfiles.entries.map((entry) {
                  return LineChartBarData(
                    spots: entry.value,
                    isCurved: true,
                    color: _colors[entry.key % _colors.length],
                    barWidth: 2.5,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                  );
                }).toList(),
                lineTouchData: LineTouchData(
                  enabled: true,
                  handleBuiltInTouches: true,
                  touchSpotThreshold: 50,
                  touchTooltipData: LineTouchTooltipData(
                    tooltipBgColor:
                        isDark ? const Color(0xFF3A3A3A) : Colors.white,
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    tooltipMargin: 10,
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        final color = _colors[spot.barIndex % _colors.length];
                        return LineTooltipItem(
                          '${spot.x.toInt()}m: ${spot.y.toStringAsFixed(1)} m/s',
                          TextStyle(
                            color: color,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        );
                      }).toList();
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsTable(bool isDark) {
    final headerStyle = TextStyle(
      fontWeight: FontWeight.w600,
      color: isDark ? Colors.white70 : Colors.black54,
      fontSize: 12,
    );
    final cellStyle = TextStyle(
      color: isDark ? Colors.white : Colors.black87,
      fontSize: 12,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.table_chart, color: const Color(0xFF00BCD4), size: 20),
              const SizedBox(width: 8),
              Text(
                '統計比較',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 12,
              headingRowHeight: 40,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 36,
              columns: [
                DataColumn(label: Text('記録', style: headerStyle)),
                DataColumn(label: Text('タイム', style: headerStyle)),
                DataColumn(label: Text('初速', style: headerStyle)),
                DataColumn(label: Text('終速', style: headerStyle)),
                DataColumn(label: Text('最高速度', style: headerStyle)),
                DataColumn(label: Text('平均速度', style: headerStyle)),
              ],
              rows: List.generate(logs.length, (index) {
                final log = logs[index];
                final gpsData = log['gpsData'] as Map<String, dynamic>?;
                final title = (log['title'] as String?) ?? '無題';
                final time = log['time'] != null
                    ? (log['time'] as num).toDouble()
                    : 0.0;

                final initialSpeed =
                    (gpsData?['initialSpeed'] as num?)?.toDouble() ?? 0;
                final finalSpeed =
                    (gpsData?['finalSpeed'] as num?)?.toDouble() ?? 0;
                final topSpeed =
                    (gpsData?['topSpeed'] as num?)?.toDouble() ?? 0;
                final averageSpeed =
                    (gpsData?['averageSpeed'] as num?)?.toDouble() ?? 0;

                return DataRow(
                  cells: [
                    DataCell(
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: _colors[index % _colors.length],
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            title.isEmpty ? '#${index + 1}' : (title.length > 8 ? '${title.substring(0, 8)}...' : title),
                            style: cellStyle,
                          ),
                        ],
                      ),
                    ),
                    DataCell(
                      Text(
                        '${time.toStringAsFixed(2)}s',
                        style: TextStyle(
                          color: const Color(0xFFFFD700),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    DataCell(Text('${initialSpeed.toStringAsFixed(1)}', style: cellStyle)),
                    DataCell(Text('${finalSpeed.toStringAsFixed(1)}', style: cellStyle)),
                    DataCell(Text('${topSpeed.toStringAsFixed(1)}', style: cellStyle)),
                    DataCell(Text('${averageSpeed.toStringAsFixed(1)}', style: cellStyle)),
                  ],
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
          // Unit legend
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              Text(
                '速度: m/s',
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Lag Calibration Dialog
enum _LagCalibrationState { idle, countdown, measuring, completed }

class _LagCalibrationDialog extends StatefulWidget {
  final bool isDark;
  final ValueChanged<double> onCalibrated;

  const _LagCalibrationDialog({
    required this.isDark,
    required this.onCalibrated,
  });

  @override
  State<_LagCalibrationDialog> createState() => _LagCalibrationDialogState();
}

class _LagCalibrationDialogState extends State<_LagCalibrationDialog> {
  // Calibration state
  _LagCalibrationState _state = _LagCalibrationState.idle;

  // Countdown timer
  int _countdown = 3;
  Timer? _countdownTimer;

  // Stopwatch for measuring
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _displayTimer;
  double _measuredTime = 0.0;

  // Hardware button listener
  final _hardwareButtonListener = HardwareButtonListener();
  StreamSubscription<HardwareButton>? _hardwareButtonSubscription;

  // Volume key event channel for native Android integration
  static const _volumeKeyChannel = EventChannel(
    'jp.holmes.track_start_call/volume_keys',
  );
  StreamSubscription? _volumeKeySubscription;

  @override
  void initState() {
    super.initState();
    _initHardwareButtonListener();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _displayTimer?.cancel();
    _stopwatch.stop();
    _hardwareButtonSubscription?.cancel();
    _volumeKeySubscription?.cancel();
    super.dispose();
  }

  void _initHardwareButtonListener() {
    // Listen to native volume key events (intercepted at Android level)
    _volumeKeySubscription = _volumeKeyChannel
        .receiveBroadcastStream()
        .listen((event) {
          _handleButtonPress();
        });

    // Also listen to hardware button listener for other hardware buttons
    _hardwareButtonSubscription = _hardwareButtonListener.listen((event) {
      _handleButtonPress();
    });
  }

  void _handleButtonPress() {
    if (_state == _LagCalibrationState.measuring) {
      _stopMeasurement();
    } else if (_state == _LagCalibrationState.countdown) {
      // Allow canceling during countdown
      _cancelCalibration();
    }
  }

  void _startCalibration() {
    setState(() {
      _state = _LagCalibrationState.countdown;
      _countdown = 3;
      _measuredTime = 0.0;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdown--;
      });

      if (_countdown <= 0) {
        timer.cancel();
        _startMeasurement();
      }
    });
  }

  void _startMeasurement() {
    setState(() {
      _state = _LagCalibrationState.measuring;
    });

    _stopwatch.reset();
    _stopwatch.start();

    // Update display every 10ms
    _displayTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) {
      if (mounted && _state == _LagCalibrationState.measuring) {
        setState(() {
          _measuredTime = _stopwatch.elapsedMilliseconds / 1000.0;
        });
      }
    });
  }

  void _stopMeasurement() {
    _stopwatch.stop();
    _displayTimer?.cancel();

    setState(() {
      _measuredTime = _stopwatch.elapsedMilliseconds / 1000.0;
      _state = _LagCalibrationState.completed;
    });
  }

  void _cancelCalibration() {
    _countdownTimer?.cancel();
    _displayTimer?.cancel();
    _stopwatch.stop();

    setState(() {
      _state = _LagCalibrationState.idle;
      _countdown = 3;
      _measuredTime = 0.0;
    });
  }

  void _restart() {
    _cancelCalibration();
    _startCalibration();
  }

  void _applyCalibration() {
    widget.onCalibrated(_measuredTime);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF141B26) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with close button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'ラグ計測',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(
                    Icons.close,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Main display area
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _state == _LagCalibrationState.measuring
                      ? const Color(0xFF00BCD4)
                      : (isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0)),
                  width: _state == _LagCalibrationState.measuring ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  if (_state == _LagCalibrationState.idle) ...[
                    Icon(
                      Icons.touch_app,
                      size: 48,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '開始を押してください',
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ] else if (_state == _LagCalibrationState.countdown) ...[
                    Text(
                      '$_countdown',
                      style: TextStyle(
                        fontSize: 72,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFFF9800),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'カウントダウン中...',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                  ] else if (_state == _LagCalibrationState.measuring) ...[
                    Text(
                      _measuredTime.toStringAsFixed(2),
                      style: TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: const Color(0xFF00BCD4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '秒',
                      style: TextStyle(
                        fontSize: 18,
                        color: const Color(0xFF00BCD4),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BCD4).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.radio_button_checked,
                            size: 16,
                            color: const Color(0xFF00BCD4),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'ボタンを押して停止',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF00BCD4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (_state == _LagCalibrationState.completed) ...[
                    Text(
                      _measuredTime.toStringAsFixed(2),
                      style: TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: const Color(0xFF4CAF50),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '秒',
                      style: TextStyle(
                        fontSize: 18,
                        color: const Color(0xFF4CAF50),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4CAF50).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: const Color(0xFF4CAF50),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '計測完了',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF4CAF50),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Instructions
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _state == _LagCalibrationState.idle
                    ? 'カウントダウン後、タイマーが開始します。\nボタンを押してタイマーを停止してください。'
                    : _state == _LagCalibrationState.measuring
                        ? 'イヤホンボタン、Bluetoothリモコン、\nまたは音量ボタンを押してください'
                        : _state == _LagCalibrationState.completed
                            ? 'この値をラグ補正値として設定しますか？'
                            : 'ボタンを押すとキャンセルできます',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black45,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Action buttons
            if (_state == _LagCalibrationState.idle) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _startCalibration,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00BCD4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    '開始',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ] else if (_state == _LagCalibrationState.completed) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _restart,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00BCD4),
                        side: const BorderSide(color: Color(0xFF00BCD4)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'リスタート',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _measuredTime <= 1.0 ? _applyCalibration : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        _measuredTime <= 1.0 ? '設定' : '1秒以上',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_measuredTime > 1.0) ...[
                const SizedBox(height: 8),
                Text(
                  '※ラグは1秒以内である必要があります',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFFFF5722),
                  ),
                ),
              ],
            ] else ...[
              // During countdown or measuring - show cancel button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _cancelCalibration,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isDark ? Colors.white54 : Colors.black45,
                    side: BorderSide(
                      color: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'キャンセル',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Settings Page as full screen
class SettingsPage extends StatefulWidget {
  final bool timeMeasurementEnabled;
  final bool autoSaveEnabled;
  final String triggerMethod;
  final double lagCompensation;
  final String measurementTarget;
  final double reactionThreshold;
  final bool loopEnabled;
  final bool randomOn;
  final bool randomSet;
  final bool randomPan;
  final double onFixed;
  final double setFixed;
  final double panFixed;
  final RangeValues onRange;
  final RangeValues setRange;
  final RangeValues panRange;
  final String onAudioPath;
  final String setAudioPath;
  final String goAudioPath;
  final bool isRunning;
  final AudioPlayer player;
  final ValueChanged<bool> onTimeMeasurementChanged;
  final ValueChanged<bool> onAutoSaveChanged;
  final ValueChanged<String> onTriggerMethodChanged;
  final ValueChanged<double> onLagCompensationChanged;
  final ValueChanged<String> onMeasurementTargetChanged;
  final ValueChanged<double> onReactionThresholdChanged;
  final ValueChanged<bool> onLoopChanged;
  final ValueChanged<bool> onRandomOnChanged;
  final ValueChanged<bool> onRandomSetChanged;
  final ValueChanged<bool> onRandomPanChanged;
  final ValueChanged<double> onOnFixedChanged;
  final ValueChanged<double> onSetFixedChanged;
  final ValueChanged<double> onPanFixedChanged;
  final ValueChanged<RangeValues> onOnRangeChanged;
  final ValueChanged<RangeValues> onSetRangeChanged;
  final ValueChanged<RangeValues> onPanRangeChanged;
  final ValueChanged<String> onOnAudioChanged;
  final ValueChanged<String> onSetAudioChanged;
  final ValueChanged<String> onGoAudioChanged;
  final VoidCallback openTimeLogsPage;
  final Future<void> Function() addTestRecords;
  final Future<void> Function() deleteTestRecords;
  final Future<void> Function() resetSettings;
  // GPS & Sensor settings
  final double gpsTargetDistance;
  final String gpsCourseType;
  final bool gpsWarmupComplete;
  final bool gpsSensorCalibrated;
  final double gpsCurrentAccuracy;
  final ValueChanged<double> onGpsTargetDistanceChanged;
  final ValueChanged<String> onGpsCourseTypeChanged;
  // Detailed info and calibration settings
  final bool detailedInfoEnabled;
  final double calibrationCountdown;
  final ValueChanged<bool> onDetailedInfoChanged;
  final ValueChanged<double> onCalibrationCountdownChanged;

  const SettingsPage({
    super.key,
    required this.timeMeasurementEnabled,
    required this.autoSaveEnabled,
    required this.triggerMethod,
    required this.lagCompensation,
    required this.measurementTarget,
    required this.reactionThreshold,
    required this.loopEnabled,
    required this.randomOn,
    required this.randomSet,
    required this.randomPan,
    required this.onFixed,
    required this.setFixed,
    required this.panFixed,
    required this.onRange,
    required this.setRange,
    required this.panRange,
    required this.onAudioPath,
    required this.setAudioPath,
    required this.goAudioPath,
    required this.isRunning,
    required this.player,
    required this.onTimeMeasurementChanged,
    required this.onAutoSaveChanged,
    required this.onTriggerMethodChanged,
    required this.onLagCompensationChanged,
    required this.onMeasurementTargetChanged,
    required this.onReactionThresholdChanged,
    required this.onLoopChanged,
    required this.onRandomOnChanged,
    required this.onRandomSetChanged,
    required this.onRandomPanChanged,
    required this.onOnFixedChanged,
    required this.onSetFixedChanged,
    required this.onPanFixedChanged,
    required this.onOnRangeChanged,
    required this.onSetRangeChanged,
    required this.onPanRangeChanged,
    required this.onOnAudioChanged,
    required this.onSetAudioChanged,
    required this.onGoAudioChanged,
    required this.openTimeLogsPage,
    required this.addTestRecords,
    required this.deleteTestRecords,
    required this.resetSettings,
    required this.gpsTargetDistance,
    required this.gpsCourseType,
    required this.gpsWarmupComplete,
    required this.gpsSensorCalibrated,
    required this.gpsCurrentAccuracy,
    required this.onGpsTargetDistanceChanged,
    required this.onGpsCourseTypeChanged,
    required this.detailedInfoEnabled,
    required this.calibrationCountdown,
    required this.onDetailedInfoChanged,
    required this.onCalibrationCountdownChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _timeMeasurementEnabled;
  late bool _autoSaveEnabled;
  late String _triggerMethod;
  late double _lagCompensation;
  late String _measurementTarget;
  late double _reactionThreshold;
  late bool _loopEnabled;
  late bool _randomOn;
  late bool _randomSet;
  late bool _randomPan;
  late double _onFixed;
  late double _setFixed;
  late double _panFixed;
  late RangeValues _onRange;
  late RangeValues _setRange;
  late RangeValues _panRange;
  late String _onAudioPath;
  late String _setAudioPath;
  late String _goAudioPath;
  late TextEditingController _lagController;
  late FocusNode _lagFocusNode;
  bool _audioSettingsExpanded = false;
  bool _measurementTargetExpanded = false;
  // GPS & Sensor settings
  late double _gpsTargetDistance;
  late String _gpsCourseType;
  late bool _gpsWarmupComplete;
  late bool _gpsSensorCalibrated;
  late double _gpsCurrentAccuracy;
  GpsSensorMeasurement? _gpsMeasurement;
  // Detailed info and calibration settings
  late bool _detailedInfoEnabled;
  late double _calibrationCountdown;
  bool _lagEnabled = false;

  @override
  void initState() {
    super.initState();
    _timeMeasurementEnabled = widget.timeMeasurementEnabled;
    _autoSaveEnabled = widget.autoSaveEnabled;
    _triggerMethod = widget.triggerMethod;
    _lagCompensation = widget.lagCompensation;
    _measurementTarget = widget.measurementTarget;
    _reactionThreshold = widget.reactionThreshold;
    _loopEnabled = widget.loopEnabled;
    _randomOn = widget.randomOn;
    _randomSet = widget.randomSet;
    _randomPan = widget.randomPan;
    _onFixed = widget.onFixed;
    _setFixed = widget.setFixed;
    _panFixed = widget.panFixed;
    _onRange = widget.onRange;
    _setRange = widget.setRange;
    _panRange = widget.panRange;
    _onAudioPath = widget.onAudioPath;
    _setAudioPath = widget.setAudioPath;
    _goAudioPath = widget.goAudioPath;
    _lagController = TextEditingController(
      text: _lagCompensation.toStringAsFixed(2),
    );
    _lagFocusNode = FocusNode();
    // GPS & Sensor settings
    _gpsTargetDistance = widget.gpsTargetDistance;
    _gpsCourseType = widget.gpsCourseType;
    _gpsWarmupComplete = widget.gpsWarmupComplete;
    _gpsSensorCalibrated = widget.gpsSensorCalibrated;
    _gpsCurrentAccuracy = widget.gpsCurrentAccuracy;
    // Detailed info and calibration settings
    _detailedInfoEnabled = widget.detailedInfoEnabled;
    _calibrationCountdown = widget.calibrationCountdown;
    // Initialize lag enabled based on current lag compensation value
    _lagEnabled = widget.lagCompensation > 0;
  }

  @override
  void dispose() {
    _lagController.dispose();
    _lagFocusNode.dispose();
    super.dispose();
  }

  Widget _buildTriggerChip(
    String value,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _triggerMethod == value;
    return GestureDetector(
      onTap: () {
        setState(() {
          _triggerMethod = value;
        });
        widget.onTriggerMethodChanged(value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00BCD4).withOpacity(0.2)
              : (isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF00BCD4)
                : (isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? const Color(0xFF00BCD4)
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? const Color(0xFF00BCD4)
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build calibration countdown setting
  Widget _buildCalibrationCountdownSetting(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'キャリブレーションカウント',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white70 : Colors.black54,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'スタート前にGPS取得とセンサーキャリブレーションを行います',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: const Color(0xFF4CAF50),
                  inactiveTrackColor: isDark
                      ? const Color(0xFF1A2332)
                      : const Color(0xFFE0E0E0),
                  thumbColor: const Color(0xFF4CAF50),
                  overlayColor: const Color(0xFF4CAF50).withAlpha(50),
                  trackHeight: 4.0,
                ),
                child: Slider(
                  value: _calibrationCountdown,
                  min: 0.0,
                  max: 30.0,
                  divisions: 30,
                  onChanged: (value) {
                    setState(() {
                      _calibrationCountdown = value;
                    });
                    widget.onCalibrationCountdownChanged(value);
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 60,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF4CAF50),
                  width: 1.5,
                ),
              ),
              child: Text(
                '${_calibrationCountdown.toInt()}秒',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF4CAF50),
                ),
              ),
            ),
          ],
        ),
        if (_calibrationCountdown == 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF9800).withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber,
                  size: 16,
                  color: const Color(0xFFFF9800),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '0秒の場合、キャリブレーションはスキップされます',
                    style: TextStyle(
                      fontSize: 11,
                      color: const Color(0xFFFF9800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // Show lag calibration dialog
  void _showLagCalibrationDialog(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _LagCalibrationDialog(
        isDark: isDark,
        onCalibrated: (measuredLag) {
          setState(() {
            _lagCompensation = measuredLag.clamp(0.0, 1.0);
            _lagController.text = _lagCompensation.toStringAsFixed(2);
          });
          widget.onLagCompensationChanged(_lagCompensation);
        },
      ),
    );
  }

  // GPS warmup state
  bool _isGpsWarming = false;
  bool _isSensorCalibrating = false;

  Future<void> _startGpsWarmup() async {
    setState(() {
      _isGpsWarming = true;
      _gpsWarmupComplete = false;
    });

    // Initialize GPS measurement if needed
    _gpsMeasurement ??= GpsSensorMeasurement(
      targetDistance: _gpsTargetDistance,
      courseType: _gpsCourseType == 'track' ? GpsCourseType.track : GpsCourseType.straight,
    );

    // Request permissions first
    final hasPermission = await _gpsMeasurement!.requestPermissions();
    if (!hasPermission) {
      if (mounted) {
        setState(() {
          _isGpsWarming = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置情報の権限が必要です')),
        );
      }
      return;
    }

    // Start warmup
    final status = await _gpsMeasurement!.warmup();

    if (mounted) {
      setState(() {
        _isGpsWarming = false;
        _gpsWarmupComplete = status.isReady;
        _gpsCurrentAccuracy = status.accuracy;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(status.message)),
      );
    }
  }

  Future<void> _startSensorCalibration() async {
    setState(() {
      _isSensorCalibrating = true;
      _gpsSensorCalibrated = false;
    });

    // Initialize GPS measurement if needed
    _gpsMeasurement ??= GpsSensorMeasurement(
      targetDistance: _gpsTargetDistance,
      courseType: _gpsCourseType == 'track' ? GpsCourseType.track : GpsCourseType.straight,
    );

    // Calibrate sensors
    await _gpsMeasurement!.calibrateSensors();

    if (mounted) {
      setState(() {
        _isSensorCalibrating = false;
        _gpsSensorCalibrated = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('センサーキャリブレーション完了')),
      );
    }
  }

  Widget _buildMeasurementTargetChip(
    String value,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _measurementTarget == value;
    final isReactionRelated =
        value == 'reaction' || value == 'goal_and_reaction';
    final accentColor = isReactionRelated
        ? const Color(0xFFFF9800)
        : const Color(0xFF00BCD4);
    return GestureDetector(
      onTap: () {
        setState(() {
          _measurementTarget = value;
        });
        widget.onMeasurementTargetChanged(value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withOpacity(0.2)
              : (isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? accentColor
                : (isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0)),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? accentColor
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? accentColor
                    : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMeasurementTargetOption(
    String value,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _measurementTarget == value;
    final isReactionRelated =
        value == 'reaction' || value == 'goal_and_reaction';
    final accentColor = isReactionRelated
        ? const Color(0xFFFF9800)
        : const Color(0xFF00BCD4);

    return GestureDetector(
      onTap: () {
        setState(() {
          _measurementTarget = value;
          _measurementTargetExpanded = false; // Close accordion after selection
        });
        widget.onMeasurementTargetChanged(value);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withOpacity(0.15)
              : (isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? accentColor
                : (isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0)),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected
                  ? accentColor
                  : (isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? accentColor
                      : (isDark ? Colors.white70 : Colors.black54),
                ),
              ),
            ),
            if (isSelected) Icon(Icons.check, size: 20, color: accentColor),
          ],
        ),
      ),
    );
  }

  Widget _buildPhaseSetting({
    required String title,
    required bool randomEnabled,
    required ValueChanged<bool> onRandomChanged,
    required double fixedValue,
    required RangeValues rangeValues,
    required ValueChanged<double> onFixedChanged,
    required ValueChanged<RangeValues> onRangeChanged,
    required double maxSeconds,
    required List<AudioOption> audioOptions,
    required String selectedAudioPath,
    required ValueChanged<String> onAudioChanged,
    required VoidCallback onPreviewAudio,
  }) {
    const sliderMin = 0.5;
    final sliderMax = maxSeconds;
    final isDark = themeNotifier.value;

    final selectedAudio = audioOptions.firstWhere(
      (option) => option.path == selectedAudioPath,
      orElse: () => audioOptions.first,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141B26) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
            spreadRadius: 1,
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PopupMenuButton<String>(
                enabled: !widget.isRunning,
                padding: EdgeInsets.zero,
                offset: const Offset(0, 48),
                elevation: 8,
                color: isDark ? const Color(0xFF1A2332) : Colors.white,
                shadowColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onSelected: onAudioChanged,
                itemBuilder: (context) => audioOptions.map((option) {
                  final isSelected = option.path == selectedAudioPath;
                  return PopupMenuItem<String>(
                    value: option.path,
                    height: 52,
                    child: Text(
                      option.name,
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark
                            ? (isSelected ? Colors.white : Colors.white70)
                            : (isSelected
                                  ? const Color(0xFF3A3A3A)
                                  : const Color(0xFF1F1F1F)),
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  );
                }).toList(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.keyboard_arrow_down,
                      color: isDark ? Colors.white70 : Colors.black54,
                      size: 26,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onPreviewAudio,
                child: const Icon(
                  Icons.volume_up,
                  color: Color(0xFF6BCB1F),
                  size: 28,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              selectedAudio.name,
              style: const TextStyle(color: Color(0xFF6BCB1F), fontSize: 14),
            ),
          ),
          const SizedBox(height: 12),
          if (randomEnabled)
            Column(
              children: [
                // Number inputs on top
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildNumberInput(
                      value: rangeValues.start,
                      min: sliderMin,
                      max: rangeValues.end,
                      enabled: !widget.isRunning,
                      onChanged: (value) {
                        if (value <= rangeValues.end) {
                          onRangeChanged(RangeValues(value, rangeValues.end));
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '〜',
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ),
                    _buildNumberInput(
                      value: rangeValues.end,
                      min: rangeValues.start,
                      max: sliderMax,
                      enabled: !widget.isRunning,
                      onChanged: (value) {
                        if (value >= rangeValues.start) {
                          onRangeChanged(RangeValues(rangeValues.start, value));
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Slider below
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF6BCB1F),
                    inactiveTrackColor: isDark
                        ? const Color(0xFF2A3543)
                        : const Color(0xFFD0D0D0),
                    thumbColor: const Color(0xFF6BCB1F),
                    overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                    activeTickMarkColor: Colors.transparent,
                    inactiveTickMarkColor: Colors.transparent,
                  ),
                  child: RangeSlider(
                    values: rangeValues,
                    min: sliderMin,
                    max: sliderMax,
                    divisions: ((sliderMax - sliderMin) * 10).round(),
                    onChanged: widget.isRunning ? null : onRangeChanged,
                  ),
                ),
              ],
            )
          else
            Column(
              children: [
                // Number input on top
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildNumberInput(
                      value: fixedValue,
                      min: sliderMin,
                      max: sliderMax,
                      enabled: !widget.isRunning,
                      onChanged: onFixedChanged,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Slider below
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF6BCB1F),
                    inactiveTrackColor: isDark
                        ? const Color(0xFF2A3543)
                        : const Color(0xFFD0D0D0),
                    thumbColor: const Color(0xFF6BCB1F),
                    overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                    trackHeight: 4.0,
                    activeTickMarkColor: Colors.transparent,
                    inactiveTickMarkColor: Colors.transparent,
                  ),
                  child: Slider(
                    value: fixedValue,
                    min: sliderMin,
                    max: sliderMax,
                    divisions: ((sliderMax - sliderMin) * 10).round(),
                    onChanged: widget.isRunning ? null : onFixedChanged,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'ランダム',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 28,
                width: 48,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Switch(
                    value: randomEnabled,
                    activeColor: const Color(0xFF6BCB1F),
                    onChanged: widget.isRunning ? null : onRandomChanged,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNumberInput({
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required bool enabled,
    double width = 85,
  }) {
    return _NumberInputField(
      value: value,
      min: min,
      max: max,
      onChanged: onChanged,
      enabled: enabled,
      width: width,
    );
  }

  void _showCreditsDialog(BuildContext context) {
    final isDark = themeNotifier.value;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomPadding),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0E131A) : const Color(0xFFF0F0F0),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF3A4654)
                        : const Color(0xFFBDBDBD),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'クレジット',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.music_note,
                            size: 18,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '音声素材',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildCreditLink('音読さん', 'https://ondoku3.com/', isDark),
                      _buildCreditLink(
                        'On-Jin ~音人~',
                        'https://on-jin.com/',
                        isDark,
                      ),
                      _buildCreditLink(
                        'OtoLogic',
                        'https://otologic.jp',
                        isDark,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCreditLink(String name, String url, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        onTap: () async {
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: Text(
          name,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2),
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: themeNotifier,
      builder: (context, isDark, _) {
        return Scaffold(
          backgroundColor: isDark
              ? const Color(0xFF0E131A)
              : const Color(0xFFF0F0F0),
          appBar: AppBar(
            backgroundColor: isDark
                ? const Color(0xFF0E131A)
                : const Color(0xFFF0F0F0),
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              icon: Icon(
                Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black87,
              ),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              '設定',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Time logs button
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.openTimeLogsPage,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 20,
                      ),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF141B26) : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: isDark
                                ? const Color(0xFF2A3543)
                                : const Color(0xFFE0E0E0),
                            spreadRadius: 1,
                            blurRadius: 0,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.history,
                                color: PhaseColors.finish,
                                size: 28,
                              ),
                              const SizedBox(width: 14),
                              Text(
                                '計測ログ',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                              ),
                            ],
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: isDark ? Colors.white54 : Colors.black45,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Theme setting
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 20,
                  ),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF141B26) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? const Color(0xFF2A3543)
                            : const Color(0xFFE0E0E0),
                        spreadRadius: 1,
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isDark ? Icons.dark_mode : Icons.light_mode,
                            color: const Color(0xFF6BCB1F),
                            size: 28,
                          ),
                          const SizedBox(width: 14),
                          Text(
                            'ダークモード',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 32,
                        width: 52,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: Switch(
                            value: isDark,
                            onChanged: (value) async {
                              themeNotifier.value = value;
                              final prefs =
                                  await SharedPreferences.getInstance();
                              prefs.setBool('dark_mode', value);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Time measurement setting
                Container(
                  padding: EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 20,
                  ).copyWith(bottom: _timeMeasurementEnabled ? 20 : 16),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF141B26) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: isDark
                            ? const Color(0xFF2A3543)
                            : const Color(0xFFE0E0E0),
                        spreadRadius: 1,
                        blurRadius: 0,
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.timer,
                                color: Color(0xFF6BCB1F),
                                size: 28,
                              ),
                              const SizedBox(width: 14),
                              Text(
                                '計測モード',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                              ),
                            ],
                          ),
                          SizedBox(
                            height: 32,
                            width: 52,
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: Switch(
                                value: _timeMeasurementEnabled,
                                onChanged: (value) {
                                  setState(() {
                                    _timeMeasurementEnabled = value;
                                    if (value && _loopEnabled) {
                                      _loopEnabled = false;
                                      widget.onLoopChanged(false);
                                    }
                                  });
                                  widget.onTimeMeasurementChanged(value);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_timeMeasurementEnabled) ...[
                        const SizedBox(height: 16),
                        Divider(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          height: 1,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(
                              Icons.save_alt,
                              color: Color(0xFF00BCD4),
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'オートセーブ',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 28,
                              width: 48,
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Switch(
                                  value: _autoSaveEnabled,
                                  activeColor: const Color(0xFF00BCD4),
                                  onChanged: (value) {
                                    setState(() => _autoSaveEnabled = value);
                                    widget.onAutoSaveChanged(value);
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Measurement Target Selector - Dropdown Style
                        Row(
                          children: [
                            Text(
                              '計測対象',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const Spacer(),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                setState(() {
                                  _measurementTarget = value;
                                });
                                widget.onMeasurementTargetChanged(value);
                              },
                              offset: const Offset(0, 40),
                              color: isDark
                                  ? const Color(0xFF1A2332)
                                  : Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              itemBuilder: (context) {
                                final menuIsDark = themeNotifier.value;
                                final defaultIconColor = menuIsDark
                                    ? Colors.white70
                                    : Colors.black54;
                                final defaultTextColor = menuIsDark
                                    ? Colors.white
                                    : Colors.black87;
                                return [
                                  PopupMenuItem<String>(
                                    value: 'goal',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.flag,
                                          size: 18,
                                          color: _measurementTarget == 'goal'
                                              ? const Color(0xFF00BCD4)
                                              : defaultIconColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'ゴール',
                                          style: TextStyle(
                                            fontWeight:
                                                _measurementTarget == 'goal'
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color: _measurementTarget == 'goal'
                                                ? const Color(0xFF00BCD4)
                                                : defaultTextColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'reaction',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.flash_on,
                                          size: 18,
                                          color:
                                              _measurementTarget == 'reaction'
                                              ? const Color(0xFFFF9800)
                                              : defaultIconColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'リアクション',
                                          style: TextStyle(
                                            fontWeight:
                                                _measurementTarget == 'reaction'
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color:
                                                _measurementTarget == 'reaction'
                                                ? const Color(0xFFFF9800)
                                                : defaultTextColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'goal_and_reaction',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.timer,
                                          size: 18,
                                          color:
                                              _measurementTarget ==
                                                  'goal_and_reaction'
                                              ? const Color(0xFF9C27B0)
                                              : defaultIconColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'ゴール&リアクション',
                                          style: TextStyle(
                                            fontWeight:
                                                _measurementTarget ==
                                                    'goal_and_reaction'
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color:
                                                _measurementTarget ==
                                                    'goal_and_reaction'
                                                ? const Color(0xFF9C27B0)
                                                : defaultTextColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ];
                              },
                              child: Builder(
                                builder: (context) {
                                  final accentColor =
                                      _measurementTarget == 'goal'
                                      ? const Color(0xFF00BCD4)
                                      : (_measurementTarget == 'reaction'
                                            ? const Color(0xFFFF9800)
                                            : const Color(0xFF9C27B0));
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0xFF0D2A3A)
                                          : const Color(0xFFE3F2FD),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: accentColor,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _measurementTarget == 'goal'
                                              ? Icons.flag
                                              : (_measurementTarget ==
                                                        'reaction'
                                                    ? Icons.flash_on
                                                    : Icons.timer),
                                          size: 18,
                                          color: accentColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _measurementTarget == 'goal'
                                              ? 'ゴール'
                                              : (_measurementTarget ==
                                                        'reaction'
                                                    ? 'リアクション'
                                                    : 'ゴール&リアクション'),
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: accentColor,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Icon(
                                          Icons.expand_more,
                                          size: 18,
                                          color: accentColor,
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        // Reaction threshold slider (only for reaction modes)
                        if (_measurementTarget == 'reaction' ||
                            _measurementTarget == 'goal_and_reaction') ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1A2332)
                                  : const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFFFF9800).withOpacity(0.3),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.speed,
                                      color: Color(0xFFFF9800),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '加速度しきい値',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: isDark
                                              ? Colors.white
                                              : Colors.black87,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${_reactionThreshold.toStringAsFixed(1)} m/s²',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFFFF9800),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    activeTrackColor: const Color(0xFFFF9800),
                                    inactiveTrackColor: isDark
                                        ? const Color(0xFF2A3543)
                                        : const Color(0xFFE0E0E0),
                                    thumbColor: const Color(0xFFFF9800),
                                    overlayColor: const Color(
                                      0xFFFF9800,
                                    ).withOpacity(0.2),
                                    trackHeight: 4.0,
                                    activeTickMarkColor: Colors.transparent,
                                    inactiveTickMarkColor: Colors.transparent,
                                  ),
                                  child: Slider(
                                    value: _reactionThreshold,
                                    min: 5.0,
                                    max: 30.0,
                                    divisions: 50,
                                    onChanged: (value) {
                                      setState(
                                        () => _reactionThreshold = value,
                                      );
                                      widget.onReactionThresholdChanged(value);
                                    },
                                  ),
                                ),
                                Text(
                                  'スタート後の動き出しを検出するしきい値です。高いほど鈍感になります。',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark
                                        ? Colors.white54
                                        : Colors.black45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        // Trigger settings (only for goal modes)
                        if (_measurementTarget == 'goal' ||
                            _measurementTarget == 'goal_and_reaction') ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Text(
                                'トリガー',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              const Spacer(),
                              PopupMenuButton<String>(
                                onSelected: (value) {
                                  setState(() {
                                    _triggerMethod = value;
                                  });
                                  widget.onTriggerMethodChanged(value);
                                },
                                offset: const Offset(0, 40),
                                color: isDark
                                    ? const Color(0xFF1A2332)
                                    : Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                itemBuilder: (context) {
                                  final menuIsDark = themeNotifier.value;
                                  final defaultIconColor = menuIsDark
                                      ? Colors.white70
                                      : Colors.black54;
                                  final defaultTextColor = menuIsDark
                                      ? Colors.white
                                      : Colors.black87;
                                  return [
                                    PopupMenuItem<String>(
                                      value: 'tap',
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.touch_app,
                                            size: 18,
                                            color: _triggerMethod == 'tap'
                                                ? const Color(0xFF00BCD4)
                                                : defaultIconColor,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'タップ',
                                            style: TextStyle(
                                              fontWeight:
                                                  _triggerMethod == 'tap'
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              color: _triggerMethod == 'tap'
                                                  ? const Color(0xFF00BCD4)
                                                  : defaultTextColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    PopupMenuItem<String>(
                                      value: 'hardware_button',
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.smart_button,
                                            size: 18,
                                            color:
                                                _triggerMethod == 'hardware_button'
                                                ? const Color(0xFFFF9800)
                                                : defaultIconColor,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'ボタン',
                                            style: TextStyle(
                                              fontWeight:
                                                  _triggerMethod == 'hardware_button'
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              color:
                                                  _triggerMethod == 'hardware_button'
                                                  ? const Color(0xFFFF9800)
                                                  : defaultTextColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ];
                                },
                                child: Builder(
                                  builder: (context) {
                                    final accentColor =
                                        _triggerMethod == 'tap'
                                        ? const Color(0xFF00BCD4)
                                        : const Color(0xFFFF9800);
                                    final triggerIcon =
                                        _triggerMethod == 'tap'
                                        ? Icons.touch_app
                                        : Icons.smart_button;
                                    final triggerLabel =
                                        _triggerMethod == 'tap'
                                        ? 'タップ'
                                        : 'ボタン';
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? const Color(0xFF0D2A3A)
                                            : const Color(0xFFE3F2FD),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: accentColor,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            triggerIcon,
                                            size: 18,
                                            color: accentColor,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            triggerLabel,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: accentColor,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Icon(
                                            Icons.expand_more,
                                            size: 18,
                                            color: accentColor,
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                        // Detailed info toggle (for goal measurements)
                        if (_measurementTarget == 'goal' ||
                            _measurementTarget == 'goal_and_reaction') ...[
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '詳細情報を取得',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white70 : Colors.black54,
                                ),
                              ),
                              Switch(
                                value: _detailedInfoEnabled,
                                onChanged: (value) {
                                  setState(() {
                                    _detailedInfoEnabled = value;
                                  });
                                  widget.onDetailedInfoChanged(value);
                                },
                                activeColor: const Color(0xFF4CAF50),
                              ),
                            ],
                          ),
                          Text(
                            'ONの場合、GPSで速度などの詳細データを取得します',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                        ],
                        // Calibration countdown (when GPS will be used for detailed info)
                        if ((_measurementTarget == 'goal' ||
                            _measurementTarget == 'goal_and_reaction') &&
                            _detailedInfoEnabled) ...[
                          const SizedBox(height: 16),
                          _buildCalibrationCountdownSetting(isDark),
                        ],
                        // Info message for goal measurements
                        if (_measurementTarget == 'goal' ||
                            _measurementTarget == 'goal_and_reaction') ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1A2332)
                                  : const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  size: 16,
                                  color: isDark
                                      ? Colors.white54
                                      : Colors.black45,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _triggerMethod == 'tap'
                                        ? '計測中に画面をタップすると計測が停止します。'
                                        : '計測中にイヤホンボタン、Bluetoothリモコン、または音量ボタンで停止できます。',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        // Lag compensation settings (only for hardware_button trigger)
                        if (_triggerMethod == 'hardware_button') ...[
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'ラグを考慮',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white70 : Colors.black54,
                                ),
                              ),
                              Switch(
                                value: _lagEnabled,
                                onChanged: (value) {
                                  setState(() {
                                    _lagEnabled = value;
                                    if (!value) {
                                      _lagCompensation = 0.0;
                                      _lagController.text = '0.00';
                                      widget.onLagCompensationChanged(0.0);
                                    }
                                  });
                                },
                                activeColor: const Color(0xFF00BCD4),
                              ),
                            ],
                          ),
                          Text(
                            'ボタン入力からアプリ処理までの遅延を補正します',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                          if (_lagEnabled) ...[
                            const SizedBox(height: 12),
                            // Lag calibration button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () => _showLagCalibrationDialog(context, isDark),
                                icon: const Icon(Icons.speed, size: 18),
                                label: const Text('ラグ計測'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00BCD4),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'ラグ補正値（0〜1秒）',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white54 : Colors.black45,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: const Color(0xFF00BCD4),
                                      inactiveTrackColor: isDark
                                          ? const Color(0xFF1A2332)
                                          : const Color(0xFFE0E0E0),
                                      thumbColor: const Color(0xFF00BCD4),
                                      overlayColor: const Color(
                                        0xFF00BCD4,
                                      ).withOpacity(0.2),
                                      trackHeight: 4.0,
                                      activeTickMarkColor: Colors.transparent,
                                      inactiveTickMarkColor: Colors.transparent,
                                    ),
                                    child: Slider(
                                      value: _lagCompensation,
                                      min: 0.0,
                                      max: 1.0,
                                      divisions: 100,
                                      onChanged: (value) {
                                        setState(() => _lagCompensation = value);
                                        widget.onLagCompensationChanged(value);
                                        if (_lagFocusNode.hasFocus)
                                          _lagFocusNode.unfocus();
                                        _lagController.text = value
                                            .toStringAsFixed(2);
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 70,
                                  child: TextField(
                                    controller: _lagController,
                                    focusNode: _lagFocusNode,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 8,
                                      ),
                                      suffixText: '秒',
                                      suffixStyle: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.black45,
                                      ),
                                      filled: true,
                                      fillColor: isDark
                                          ? const Color(0xFF1A2332)
                                          : const Color(0xFFF0F0F0),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                          color: isDark
                                              ? const Color(0xFF2A3543)
                                              : const Color(0xFFD0D0D0),
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                          color: isDark
                                              ? const Color(0xFF2A3543)
                                              : const Color(0xFFD0D0D0),
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(
                                          color: Color(0xFF00BCD4),
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'^\d*\.?\d{0,2}'),
                                      ),
                                    ],
                                    onSubmitted: (value) {
                                      final trimmed = value.trim();
                                      double newValue;
                                      if (trimmed.isEmpty) {
                                        newValue = _lagCompensation;
                                      } else {
                                        final parsed = double.tryParse(trimmed);
                                        newValue = parsed != null
                                            ? parsed.clamp(0.0, 1.0)
                                            : _lagCompensation;
                                      }
                                      setState(() => _lagCompensation = newValue);
                                      widget.onLagCompensationChanged(newValue);
                                      _lagController.text = newValue
                                          .toStringAsFixed(2);
                                    },
                                  ),
                                ),
                              ],
                            ),
                            if (_lagCompensation > 0) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00BCD4).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(
                                      0xFF00BCD4,
                                    ).withOpacity(0.3),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.timer,
                                      size: 16,
                                      color: Color(0xFF00BCD4),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '計測終了時、タイムから${_lagCompensation.toStringAsFixed(2)}秒を差し引きます',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF00BCD4),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ],
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Loop setting
                Opacity(
                  opacity: _timeMeasurementEnabled ? 0.5 : 1.0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.repeat,
                              color: Color(0xFF6BCB1F),
                              size: 28,
                            ),
                            const SizedBox(width: 14),
                            Text(
                              'ループ',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                            ),
                          ],
                        ),
                        SizedBox(
                          height: 32,
                          width: 52,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: Switch(
                              value: _loopEnabled,
                              onChanged: _timeMeasurementEnabled
                                  ? null
                                  : (value) {
                                      setState(() => _loopEnabled = value);
                                      widget.onLoopChanged(value);
                                    },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Audio settings (collapsible)
                GestureDetector(
                  onTap: () => setState(
                    () => _audioSettingsExpanded = !_audioSettingsExpanded,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: _audioSettingsExpanded
                          ? const BorderRadius.vertical(
                              top: Radius.circular(16),
                            )
                          : BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.volume_up,
                              color: Color(0xFF6BCB1F),
                              size: 28,
                            ),
                            const SizedBox(width: 14),
                            Text(
                              '音声設定',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                            ),
                          ],
                        ),
                        Icon(
                          _audioSettingsExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_audioSettingsExpanded) ...[
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        _buildPhaseSetting(
                          title: 'On Your Marks',
                          randomEnabled: _randomOn,
                          onRandomChanged: (value) {
                            setState(() => _randomOn = value);
                            widget.onRandomOnChanged(value);
                          },
                          fixedValue: _onFixed,
                          rangeValues: _onRange,
                          onFixedChanged: (value) {
                            setState(() => _onFixed = value);
                            widget.onOnFixedChanged(value);
                          },
                          onRangeChanged: (values) {
                            setState(() => _onRange = values);
                            widget.onOnRangeChanged(values);
                          },
                          maxSeconds: 30,
                          audioOptions: AudioOptions.onYourMarks,
                          selectedAudioPath: _onAudioPath,
                          onAudioChanged: (path) {
                            setState(() => _onAudioPath = path);
                            widget.onOnAudioChanged(path);
                          },
                          onPreviewAudio: () {
                            if (_onAudioPath.isNotEmpty)
                              widget.player.play(AssetSource(_onAudioPath));
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildPhaseSetting(
                          title: 'Set',
                          randomEnabled: _randomSet,
                          onRandomChanged: (value) {
                            setState(() => _randomSet = value);
                            widget.onRandomSetChanged(value);
                          },
                          fixedValue: _setFixed,
                          rangeValues: _setRange,
                          onFixedChanged: (value) {
                            setState(() => _setFixed = value);
                            widget.onSetFixedChanged(value);
                          },
                          onRangeChanged: (values) {
                            setState(() => _setRange = values);
                            widget.onSetRangeChanged(values);
                          },
                          maxSeconds: 40,
                          audioOptions: AudioOptions.set,
                          selectedAudioPath: _setAudioPath,
                          onAudioChanged: (path) {
                            setState(() => _setAudioPath = path);
                            widget.onSetAudioChanged(path);
                          },
                          onPreviewAudio: () {
                            if (_setAudioPath.isNotEmpty)
                              widget.player.play(AssetSource(_setAudioPath));
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildPhaseSetting(
                          title: 'Go',
                          randomEnabled: _randomPan,
                          onRandomChanged: (value) {
                            setState(() => _randomPan = value);
                            widget.onRandomPanChanged(value);
                          },
                          fixedValue: _panFixed,
                          rangeValues: _panRange,
                          onFixedChanged: (value) {
                            setState(() => _panFixed = value);
                            widget.onPanFixedChanged(value);
                          },
                          onRangeChanged: (values) {
                            setState(() => _panRange = values);
                            widget.onPanRangeChanged(values);
                          },
                          maxSeconds: 10,
                          audioOptions: AudioOptions.go,
                          selectedAudioPath: _goAudioPath,
                          onAudioChanged: (path) {
                            setState(() => _goAudioPath = path);
                            widget.onGoAudioChanged(path);
                          },
                          onPreviewAudio: () {
                            if (_goAudioPath.isNotEmpty)
                              widget.player.play(AssetSource(_goAudioPath));
                          },
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                // Credit button
                GestureDetector(
                  onTap: () => _showCreditsDialog(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 18,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: isDark ? Colors.white70 : Colors.black54,
                              size: 26,
                            ),
                            const SizedBox(width: 14),
                            Text(
                              'クレジット',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                            ),
                          ],
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: isDark ? Colors.white70 : Colors.black54,
                          size: 28,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Debug section
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    'デバッグ',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 12),
                  child: Text(
                    'この設定は早期アクセス版のデバッグのための機能です。\n正式リリース時にはこの機能は削除します。\nカレンダーの動作検証などにお使いください。',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    await widget.addTestRecords();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('50個のテスト用記録を追加しました'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.add_circle_outline,
                          color: Colors.orange,
                          size: 24,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'テスト用の記録を追加（50件）',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    await widget.deleteTestRecords();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('テスト用の記録を削除しました'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                          size: 24,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'テスト用の記録を消す',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                // Reset settings section
                GestureDetector(
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
                        title: Text(
                          '設定をリセット',
                          style: TextStyle(
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        content: Text(
                          'すべての設定を初期状態に戻しますか？\n計測ログは削除されません。',
                          style: TextStyle(
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('キャンセル'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text(
                              'リセット',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await widget.resetSettings();
                      if (mounted) {
                        // Update local state to reflect reset
                        setState(() {
                          _timeMeasurementEnabled = false;
                          _autoSaveEnabled = false;
                          _triggerMethod = 'tap';
                          _lagCompensation = 0.0;
                          _measurementTarget = 'goal';
                          _reactionThreshold = 12.0;
                          _loopEnabled = false;
                          _randomOn = false;
                          _randomSet = false;
                          _randomPan = false;
                          _onFixed = 5.0;
                          _setFixed = 5.0;
                          _panFixed = 5.0;
                          _onRange = const RangeValues(1.5, 2.5);
                          _setRange = const RangeValues(0.8, 1.2);
                          _panRange = const RangeValues(0.8, 1.5);
                          _onAudioPath = AudioOptions.onYourMarks[1].path;
                          _setAudioPath = AudioOptions.set[1].path;
                          _goAudioPath = AudioOptions.go[0].path;
                          _lagController.text = '0.00';
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('設定をリセットしました'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF141B26) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0xFF2A3543)
                              : const Color(0xFFE0E0E0),
                          spreadRadius: 1,
                          blurRadius: 0,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.settings_backup_restore,
                          color: isDark ? Colors.white70 : Colors.black54,
                          size: 24,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            '設定をリセット',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: isDark ? Colors.white38 : Colors.black26,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        );
      },
    );
  }
}
