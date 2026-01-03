import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hardware_button_listener/hardware_button_listener.dart';
import 'package:hardware_button_listener/models/hardware_button.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Global theme notifier
final themeNotifier = ValueNotifier<bool>(false); // true = dark mode

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
  static const onYourMarksStart = Color(0xFFFFCC00);
  static const setStart = Color(0xFFEF5350); // Clear red from the start
  static const goStart = Color(0xFFFF1744); // Same as end (no countdown for Go)

  // End colors (fully saturated/vivid) - shown when countdown reaches 0
  static const ready = Color(0xFF4CAF50);
  static const readySecondary = Color(0xFF2E7D32);
  static const onYourMarks = Color(0xFFFF9800);
  static const onYourMarksSecondary = Color(0xFFEF6C00);
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
    _progressController.dispose();
    _player.dispose();
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
    // Migrate old trigger methods to new ones
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
      if (!mounted || runId != _runToken) {
        return false;
      }

      if (_isPaused) {
        // While paused, don't count time
        while (_isPaused && mounted && runId == _runToken) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (!mounted || runId != _runToken) return false;
        lastTime = DateTime.now(); // Reset timer after pause
      }

      await Future.delayed(const Duration(milliseconds: 16)); // ~60fps

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
    if (!mounted || runId != _runToken) {
      return false;
    }

    // Update state directly for background support
    if (labelBeforePlay != null) {
      _phaseLabel = labelBeforePlay;
    }
    if (mounted && !_isInBackground) setState(() {});

    final waitOk = await _waitWithPause(runId, seconds);
    if (!waitOk) {
      return false;
    }

    if (!mounted || runId != _runToken) {
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
    // Only play audio if path is not empty
    if (assetPath.isNotEmpty) {
      await _player.play(AssetSource(assetPath));
    }
    return mounted && runId == _runToken;
  }

  Future<void> _startSequence() async {
    if (_isRunning && _isPaused) {
      _isPaused = false;
      if (mounted && !_isInBackground) setState(() {});
      return;
    }
    if (_isRunning) {
      return;
    }

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

      // Start accelerometer listening BEFORE GO for reaction measurement
      if (_timeMeasurementEnabled &&
          (_measurementTarget == 'reaction' || _measurementTarget == 'goal_and_reaction')) {
        _startReactionListening();
      }

      final panOk = await _runPhase(
        runId: runId,
        seconds: panDelay,
        assetPath: _goAudioPath,
        labelOnPlay: 'Go',
        completedPhaseColor: setColor,
      );

      // Record GO signal time for reaction measurement
      if (_timeMeasurementEnabled &&
          (_measurementTarget == 'reaction' || _measurementTarget == 'goal_and_reaction')) {
        _goSignalTime = DateTime.now();
        // If flying was detected before GO, calculate how early
        if (_isFlying && _flyingEarlyTime == null) {
          // Flying was already detected, stop everything
          _stopTimeMeasurement();
          return;
        }
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
    if (!_isRunning && !_isPaused && !_isFinished && !_autoSavedResult) {
      return;
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

  void _startTimeMeasurement() async {
    if (!_timeMeasurementEnabled) return;

    _isMeasuring = true;
    _measuredTime = null;
    _reactionTime = null;
    _isFlying = false;
    _flyingEarlyTime = null;
    _showMeasurementResult = false;

    // Start stopwatch for goal measurement
    if (_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction') {
      _stopwatch.reset();
      _stopwatch.start();
    }

    // Set up volume key listener for earphone/Bluetooth remote triggers (goal modes only)
    // This uses native Android integration to intercept volume keys without showing HUD
    if ((_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction') &&
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
    if (!_isMeasuring && _measuredTime == null && _reactionTime == null) {
      _volumeKeySubscription?.cancel();
      _hardwareButtonSubscription?.cancel();
      _accelerometerSubscription?.cancel();
      return;
    }

    _stopwatch.stop();
    _volumeKeySubscription?.cancel();
    _hardwareButtonSubscription?.cancel();
    _accelerometerSubscription?.cancel();

    if (_isMeasuring) {
      // For goal measurement
      if (_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction') {
        _measuredTime = _stopwatch.elapsedMilliseconds / 1000.0;
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

    _accelerometerSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 10),
    ).listen((AccelerometerEvent event) {
      // Use Z-axis for detecting forward movement
      final zForce = event.z.abs();

      if (zForce >= _reactionThreshold) {
        final now = DateTime.now();

        if (_goSignalTime == null) {
          // Movement detected BEFORE GO signal = FLYING
          _isFlying = true;
          _flyingEarlyTime = null; // Will be calculated when GO plays
          
          // Play buzzer sound for flying
          if (_player.state != PlayerState.playing) {
            _player.play(AssetSource('audio/Flying/buzzer.mp3'));
          }
          
          _stopReactionMeasurement();
        } else {
          // Movement detected AFTER GO signal = Valid reaction
          _reactionTime = now.difference(_goSignalTime!).inMilliseconds / 1000.0;
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

  // Get measurement tags based on current mode
  List<String> _getMeasurementTags() {
    switch (_measurementTarget) {
      case 'goal':
        return ['ゴール'];
      case 'reaction':
        return ['リアクション'];
      case 'goal_and_reaction':
        return ['ゴール', 'リアクション'];
      default:
        return ['ゴール'];
    }
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

  // Build measurement target option for accordion menu
  Widget _buildMeasurementTargetOption(String value, String label, IconData icon, bool isDark) {
    final isSelected = _measurementTarget == value;
    final isReactionRelated = value == 'reaction' || value == 'goal_and_reaction';
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
          color: isSelected
              ? accentColor.withOpacity(0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isSelected
              ? Border.all(color: accentColor, width: 1)
              : null,
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
    double? adjustedTime;
    if (_measuredTime != null) {
      adjustedTime = (_measuredTime! - _lagCompensation).clamp(
        0.0,
        double.infinity,
      );
    }

    return {
      'time': adjustedTime,
      'reactionTime': _reactionTime,
      'date': DateTime.now().toIso8601String(),
      'title': '',
      'memo': '',
      'tags': _getMeasurementTags(),
      'isFlying': _isFlying,
      'flyingEarlyTime': _flyingEarlyTime,
    };
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
        final adjustedTime = (_measuredTime! - _lagCompensation).clamp(0.0, double.infinity);
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
        final adjustedTime = (_measuredTime! - _lagCompensation).clamp(0.0, double.infinity);
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

      // Random time between 8.0 and 15.0 seconds
      final time = 8.0 + random.nextDouble() * 7.0;

      logs.add({
        'time': double.parse(time.toStringAsFixed(2)),
        'date': date.toIso8601String(),
        'title': '[テスト用] 記録 ${i + 1}',
        'memo': 'テスト用の記録です',
      });
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
    final isReactionRelated = value == 'reaction' || value == 'goal_and_reaction';
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
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF6BCB1F),
                      inactiveTrackColor: isDark
                          ? const Color(0xFF2A3543)
                          : const Color(0xFFD0D0D0),
                      thumbColor: const Color(0xFF6BCB1F),
                      overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                      trackShape: const RoundedRectSliderTrackShape(),
                      rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
                    ),
                    child: RangeSlider(
                      values: rangeValues,
                      min: sliderMin,
                      max: sliderMax,
                      divisions: ((sliderMax - sliderMin) * 10).round(),
                      onChanged: _isRunning
                          ? null
                          : (values) {
                              final roundedStart = (values.start * 10).round() / 10;
                              final roundedEnd = (values.end * 10).round() / 10;
                              onRangeChanged(RangeValues(roundedStart, roundedEnd));
                            },
                    ),
                  ),
                ),
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
            )
          else
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF6BCB1F),
                      inactiveTrackColor: isDark
                          ? const Color(0xFF2A3543)
                          : const Color(0xFFD0D0D0),
                      thumbColor: const Color(0xFF6BCB1F),
                      overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                      trackShape: const RoundedRectSliderTrackShape(),
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
                ),
                _buildNumberInput(
                  value: fixedValue,
                  min: sliderMin,
                  max: sliderMax,
                  enabled: !_isRunning,
                  onChanged: onFixedChanged,
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
      if (_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction') {
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
        displayText = 'FLYING';
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
        if (_reactionTime != null) {
          reactionDisplayText = _reactionTime!.toStringAsFixed(3);
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
    final enableFullScreenTap = _isMeasuring &&
        _triggerMethod == 'tap' &&
        (_measurementTarget == 'goal' || _measurementTarget == 'goal_and_reaction');

    Widget body = SafeArea(
      child: OrientationBuilder(
        builder: (context, orientation) {
          final isLandscape = orientation == Orientation.landscape;

          return isLandscape
              ? _buildLandscapeLayout(displayText, showCountdown,
                  reactionText: reactionDisplayText, isFlying: showFlying)
              : _buildPortraitLayout(displayText, showCountdown,
                  reactionText: reactionDisplayText, isFlying: showFlying);
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

    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF5F5F5),
      body: body,
    );
  }

  Widget _buildPortraitLayout(String countdownText, bool showCountdown,
      {String? reactionText, bool isFlying = false}) {
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
                        final infoColor = isDark
                            ? const Color(0xFF4DD0E1)
                            : const Color(0xFF00838F);
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
                              color: modeColor.withOpacity(0.5),
                              width: 1,
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _getMeasurementTargetIcon(),
                                    size: 16,
                                    color: modeColor,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '計測モード：${_getMeasurementTargetLabel()}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: modeColor,
                                    ),
                                  ),
                                ],
                              ),
                              if (_autoSaveEnabled) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'オートセーブ',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: infoColor,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                'トリガー：${_triggerMethod == 'tap' ? 'タップ' : 'ボタン'}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: infoColor,
                                ),
                              ),
                              if (_lagCompensation > 0 &&
                                  _triggerMethod == 'hardware_button') ...[
                                const SizedBox(height: 4),
                                Text(
                                  'ラグタイム：${_lagCompensation.toStringAsFixed(2)}秒',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: infoColor,
                                  ),
                                ),
                              ],
                            ],
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

  Widget _buildLandscapeLayout(String countdownText, bool showCountdown,
      {String? reactionText, bool isFlying = false}) {
    final isDark = themeNotifier.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Left side: Settings button and time measurement indicator
          Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              if (_timeMeasurementEnabled && !_isSettingsOpen) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0D2A3A)
                        : const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF00BCD4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00BCD4).withOpacity(0.25),
                        blurRadius: 6,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.timer,
                            size: 16,
                            color: Color(0xFF00BCD4),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'タイム計測モード',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? const Color(0xFF00BCD4)
                                  : const Color(0xFF0097A7),
                            ),
                          ),
                        ],
                      ),
                      if (_autoSaveEnabled) ...[
                        const SizedBox(height: 4),
                        Text(
                          'オートセーブ',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? const Color(0xFF4DD0E1)
                                : const Color(0xFF00838F),
                          ),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        'トリガー：${_triggerMethod == 'tap' ? 'タップ' : 'ボタン'}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFF4DD0E1)
                              : const Color(0xFF00838F),
                        ),
                      ),
                      if (_lagCompensation > 0 &&
                          _triggerMethod == 'hardware_button') ...[
                        const SizedBox(height: 2),
                        Text(
                          'ラグタイム：${_lagCompensation.toStringAsFixed(2)}秒',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? const Color(0xFF4DD0E1)
                                : const Color(0xFF00838F),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 16),
          // Center: Timer panel (larger)
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
          // Right side: Measurement target selector and Buttons
          if (!_isSettingsOpen) ...[
            const SizedBox(width: 16),
            Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Measurement mode display (right side for landscape)
                if (_timeMeasurementEnabled)
                  Builder(
                    builder: (context) {
                      final modeColor = _getMeasurementTargetColor();
                      return Container(
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
                              _getMeasurementTargetIcon(),
                              size: 14,
                              color: modeColor,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '計測モード：${_getMeasurementTargetLabel()}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: modeColor,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 16),
                // Buttons
                SizedBox(width: 90, child: _buildButtons(isLandscape: true)),
              ],
            ),
          ],
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
            ? 12.0
            : (isSmallScreen ? 14.0 : 18.0);
        final borderRadius = isSmallScreen ? 18.0 : 22.0;

        final progress = _animatedProgress;

        // Interpolate colors based on progress (light -> dark as countdown approaches 0)
        // For 'Go', 'Measuring', 'FINISH', 'FLYING' phases, always use full intensity (progress = 1.0)
        final effectiveProgress =
            (_phaseLabel == 'Go' ||
                _phaseLabel == 'Measuring' ||
                _phaseLabel == 'FINISH' ||
                _phaseLabel == 'FLYING')
            ? 1.0
            : progress;

        // Use red color for flying
        final progressColor = isFlying
            ? const Color(0xFFE53935)
            : PhaseColors.getInterpolatedColor(_phaseLabel, effectiveProgress);
        final secondaryColor = isFlying
            ? const Color(0xFFFF5252)
            : PhaseColors.getInterpolatedSecondaryColor(_phaseLabel, effectiveProgress);

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

        return RepaintBoundary(
          child: CustomPaint(
            painter: progressPainter,
            child: Container(
              constraints: BoxConstraints(
                minWidth: panelWidth,
                maxWidth: panelWidth,
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Phase label with glow - fixed height to prevent size changes
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
                            'リアクション: ${reactionText}s',
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
          if (_autoSavedResult) {
            // Auto-saved result: RESET only (full width)
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
              SizedBox(
                width: isLandscape ? 0 : buttonSpacing,
                height: isLandscape ? buttonSpacing : 0,
              ),
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
            SizedBox(
              width: isLandscape ? 0 : buttonSpacing,
              height: isLandscape ? buttonSpacing : 0,
            ),
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
          // In landscape, replace Expanded with fixed height buttons
          final landscapeButtons = buttons.map((widget) {
            if (widget is Expanded) {
              return SizedBox(width: double.infinity, child: widget.child);
            }
            return widget;
          }).toList();

          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: landscapeButtons,
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
                  // Calendar grid
                  Expanded(
                    child: GridView.count(
                      crossAxisCount: 7,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      padding: EdgeInsets.zero,
                      children: days,
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
                    onPressed: selectedDates.isEmpty
                        ? null
                        : () => Navigator.pop(context, selectedDates),
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
        _isFilteredByCalendar = true;
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
                if (_isSelectionMode && _selectedIndices.isNotEmpty)
                  TextButton(
                    onPressed: _deleteSelectedLogs,
                    child: const Text(
                      '選択項目を削除',
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
                                      if (_isSearching) {
                                        _searchFocusNode.requestFocus();
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
                                  onTap: _showCalendarDialog,
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
                    // Search input field
                    if (_isSearching)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
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
                    Expanded(
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
                                _searchQuery.isNotEmpty
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
                                final tags = (log['tags'] as List?)
                                        ?.cast<String>() ??
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
                                    setState(() {
                                      _isSelectionMode = true;
                                      _selectedIndices.add(sortedIndex);
                                    });
                                  },
                                  onTap: () {
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
                                                          const EdgeInsets
                                                              .symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: isReaction
                                                            ? const Color(
                                                                    0xFFFF9800)
                                                                .withOpacity(
                                                                    0.2)
                                                            : const Color(
                                                                    0xFF00BCD4)
                                                                .withOpacity(
                                                                    0.2),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(4),
                                                      ),
                                                      child: Text(
                                                        tag,
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          color: isReaction
                                                              ? const Color(
                                                                  0xFFFF9800)
                                                              : const Color(
                                                                  0xFF00BCD4),
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
                                                    top: 4),
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

  const LogEditPage({
    super.key,
    required this.initialTitle,
    required this.initialMemo,
    this.time,
    this.reactionTime,
    required this.date,
    this.tags = const ['ゴール'],
    this.isFlying = false,
  });

  @override
  State<LogEditPage> createState() => _LogEditPageState();
}

class _LogEditPageState extends State<LogEditPage> {
  late TextEditingController _titleController;
  late TextEditingController _memoController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _memoController = TextEditingController(text: widget.initialMemo);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  void _save() {
    final newTitle = _titleController.text.trim().isEmpty
        ? '無題'
        : _titleController.text.trim();
    final newMemo = _memoController.text.trim();
    Navigator.pop(context, {'title': newTitle, 'memo': newMemo});
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
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                            color: isGoal ? Colors.cyan.shade900 : Colors.orange.shade900,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        backgroundColor: isGoal
                            ? Colors.cyan.withAlpha(50)
                            : Colors.orange.withAlpha(50),
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
                    fillColor: isDark
                        ? const Color(0xFF2A2A2A)
                        : const Color(0xFFF5F5F5),
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
                    fillColor: isDark
                        ? const Color(0xFF2A2A2A)
                        : const Color(0xFFF5F5F5),
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
          ),
        );
      },
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

  Widget _buildMeasurementTargetChip(
    String value,
    String label,
    IconData icon,
    bool isDark,
  ) {
    final isSelected = _measurementTarget == value;
    final isReactionRelated = value == 'reaction' || value == 'goal_and_reaction';
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
    final isReactionRelated = value == 'reaction' || value == 'goal_and_reaction';
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
            if (isSelected)
              Icon(
                Icons.check,
                size: 20,
                color: accentColor,
              ),
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
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF6BCB1F),
                      inactiveTrackColor: isDark
                          ? const Color(0xFF2A3543)
                          : const Color(0xFFD0D0D0),
                      thumbColor: const Color(0xFF6BCB1F),
                      overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                    ),
                    child: RangeSlider(
                      values: rangeValues,
                      min: sliderMin,
                      max: sliderMax,
                      divisions: ((sliderMax - sliderMin) * 10).round(),
                      onChanged: widget.isRunning ? null : onRangeChanged,
                    ),
                  ),
                ),
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
            )
          else
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF6BCB1F),
                      inactiveTrackColor: isDark
                          ? const Color(0xFF2A3543)
                          : const Color(0xFFD0D0D0),
                      thumbColor: const Color(0xFF6BCB1F),
                      overlayColor: const Color(0xFF6BCB1F).withOpacity(0.2),
                    ),
                    child: Slider(
                      value: fixedValue,
                      min: sliderMin,
                      max: sliderMax,
                      divisions: ((sliderMax - sliderMin) * 10).round(),
                      onChanged: widget.isRunning ? null : onFixedChanged,
                    ),
                  ),
                ),
                _buildNumberInput(
                  value: fixedValue,
                  min: sliderMin,
                  max: sliderMax,
                  enabled: !widget.isRunning,
                  onChanged: onFixedChanged,
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
                      Text(
                        '♪音声素材',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
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
                                'タイム計測',
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
                              color: isDark ? const Color(0xFF1A2332) : Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              itemBuilder: (context) {
                                final menuIsDark = themeNotifier.value;
                                final defaultIconColor = menuIsDark ? Colors.white70 : Colors.black54;
                                final defaultTextColor = menuIsDark ? Colors.white : Colors.black87;
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
                                            fontWeight: _measurementTarget == 'goal'
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
                                          color: _measurementTarget == 'reaction'
                                              ? const Color(0xFFFF9800)
                                              : defaultIconColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'リアクション',
                                          style: TextStyle(
                                            fontWeight: _measurementTarget == 'reaction'
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color: _measurementTarget == 'reaction'
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
                                          color: _measurementTarget == 'goal_and_reaction'
                                              ? const Color(0xFF9C27B0)
                                              : defaultIconColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'ゴール&リアクション',
                                          style: TextStyle(
                                            fontWeight: _measurementTarget == 'goal_and_reaction'
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color: _measurementTarget == 'goal_and_reaction'
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
                                  final accentColor = _measurementTarget == 'goal'
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
                                              : (_measurementTarget == 'reaction'
                                                  ? Icons.flash_on
                                                  : Icons.timer),
                                          size: 18,
                                          color: accentColor,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _measurementTarget == 'goal'
                                              ? 'ゴール'
                                              : (_measurementTarget == 'reaction'
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
                                    overlayColor: const Color(0xFFFF9800)
                                        .withOpacity(0.2),
                                  ),
                                  child: Slider(
                                    value: _reactionThreshold,
                                    min: 5.0,
                                    max: 30.0,
                                    divisions: 50,
                                    onChanged: (value) {
                                      setState(() => _reactionThreshold = value);
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
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white70 : Colors.black54,
                                ),
                              ),
                              const Spacer(),
                              _buildTriggerChip(
                                'tap',
                                'タップ',
                                Icons.touch_app,
                                isDark,
                              ),
                              const SizedBox(width: 8),
                              _buildTriggerChip(
                                'hardware_button',
                                'ボタン',
                                Icons.smart_button,
                                isDark,
                              ),
                            ],
                          ),
                        ],
                        if ((_measurementTarget == 'goal' ||
                                _measurementTarget == 'goal_and_reaction') &&
                            _triggerMethod == 'tap') ...[
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
                                    '計測中に画面をタップすると計測が停止します',
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
                        if ((_measurementTarget == 'goal' ||
                                _measurementTarget == 'goal_and_reaction') &&
                            _triggerMethod == 'hardware_button') ...[
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
                                    '計測中にイヤホンボタン、Bluetoothリモコン、または音量ボタンを押すと計測が停止します',
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
                          const SizedBox(height: 16),
                          Text(
                            'ラグを考慮',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'トリガーの遅延を補正します（0〜1秒）',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                          ),
                          const SizedBox(height: 12),
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
                const SizedBox(height: 40),
              ],
            ),
          ),
        );
      },
    );
  }
}
