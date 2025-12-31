import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
  Color get scaffoldBackground => isDark ? Colors.black : const Color(0xFFF5F5F5);
  Color get cardBackground => isDark ? const Color(0xFF141B26) : Colors.white;
  Color get sheetBackground => isDark ? const Color(0xFF0E131A) : const Color(0xFFF0F0F0);
  Color get inputBackground => isDark ? const Color(0xFF1A2332) : const Color(0xFFE8E8E8);
  Color get dragHandleColor => isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD);

  // Border/shadow colors
  Color get cardBorder => isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0);
  Color get inputBorder => isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD);

  // Text colors
  Color get primaryText => isDark ? Colors.white : Colors.black87;
  Color get secondaryText => isDark ? Colors.white70 : Colors.black54;

  // Accent colors (same for both themes)
  static const accent = Color(0xFF6BCB1F);
  static const accentDark = Color(0xFF1D2B21);

  // Settings button background
  Color get settingsButtonBackground => isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0);

  // Timer panel background
  Color get timerPanelBackground => isDark ? const Color(0xFF141B26) : Colors.white;
  Color get timerProgressBackground => isDark ? const Color(0xFF1A2332) : const Color(0xFFE0E0E0);
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
    AudioOption(name: 'On Your Marks (男性)', path: 'audio/On Your Marks/On_Your_Marks_Male.mp3'),
    AudioOption(name: 'On Your Marks (女性)', path: 'audio/On Your Marks/On_Your_Marks_Female.mp3'),
    AudioOption(name: '位置について (男性)', path: 'audio/On Your Marks/ichinitsuite_Male.mp3'),
    AudioOption(name: '位置について (女性)', path: 'audio/On Your Marks/ichinitsuite_Female.mp3'),
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
  static const setStart = Color(0xFFEF5350);  // Clear red from the start
  static const goStart = Color(0xFFFF1744);   // Same as end (no countdown for Go)

  // End colors (fully saturated/vivid) - shown when countdown reaches 0
  static const ready = Color(0xFF4CAF50);
  static const readySecondary = Color(0xFF2E7D32);
  static const onYourMarks = Color(0xFFFF9800);
  static const onYourMarksSecondary = Color(0xFFEF6C00);
  static const set = Color(0xFFD32F2F);  // Deep vivid red
  static const setSecondary = Color(0xFFB71C1C);  // Dark red
  static const go = Color(0xFFFF1744);  // Vivid red-pink
  static const goSecondary = Color(0xFFD50000);  // Deep red

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
        inactiveTrackColor: isDark ? const Color(0xFF26332A) : const Color(0xFFD0D0D0),
        thumbColor: const Color(0xFF6BCB1F),
        overlayColor: const Color(0x336BCB1F),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Color(0xFF6BCB1F)),
        trackColor: WidgetStatePropertyAll(isDark ? const Color(0xFF1D2B21) : const Color(0xFFD0D0D0)),
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
    await _player.setAudioContext(AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: {
          AVAudioSessionOptions.mixWithOthers,
        },
      ),
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: true,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.gain,
      ),
    ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final wasInBackground = _isInBackground;
    _isInBackground = state == AppLifecycleState.paused ||
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

    if (!mounted) {
      return;
    }

    final clampedOn = _clampRange(
      RangeValues(onMin, onMax),
      min: 0.5,
      max: 30,
    );
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

      final panOk = await _runPhase(
        runId: runId,
        seconds: panDelay,
        assetPath: _goAudioPath,
        labelOnPlay: 'Go',
        completedPhaseColor: setColor,
      );
      if (!panOk) {
        return;
      }
      _completedPhaseColors = [..._completedPhaseColors, goColor];
      _remainingSeconds = 0;
      if (mounted && !_isInBackground) setState(() {});

      if (!mounted || runId != _runToken) {
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
    if (!_isRunning && !_isPaused && !_isFinished) {
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
    if (!_isInBackground) setState(() {});
  }

  Future<void> _openSettings() async {
    if (_isRunning || _isPaused) {
      await _resetSequence();
    }
    setState(() {
      _isSettingsOpen = true;
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            void sync(VoidCallback fn) {
              setState(fn);
              modalSetState(() {});
            }

            final maxHeight = MediaQuery.of(context).size.height * 0.85;

            final isDark = themeNotifier.value;
            return Container(
              constraints: BoxConstraints(maxHeight: maxHeight),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0E131A) : const Color(0xFFF0F0F0),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Fixed drag handle at top
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 8),
                    child: Center(
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                  // Scrollable content
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(
                        left: 20,
                        right: 20,
                        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '設定',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                          ),
                          const SizedBox(height: 16),
                          // Theme setting
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF141B26) : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
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
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                                        final prefs = await SharedPreferences.getInstance();
                                        prefs.setBool('dark_mode', value);
                                        modalSetState(() {});
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Loop setting
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF141B26) : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
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
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                                      value: _loopEnabled,
                                      onChanged: (value) {
                                        sync(() {
                                          _loopEnabled = value;
                                          _saveBool('loop_enabled', value);
                                        });
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildPhaseSetting(
                        title: 'On Your Marks',
                        randomEnabled: _randomOn,
                        onRandomChanged: (value) {
                          sync(() {
                            _randomOn = value;
                            _saveBool('on_random', value);
                          });
                        },
                        fixedValue: _onFixed,
                        rangeValues: _onRange,
                        onFixedChanged: (value) {
                          sync(() {
                            _onFixed = value;
                            _saveDouble('on_fixed', value);
                          });
                        },
                        onRangeChanged: (values) {
                          sync(() {
                            _onRange = values;
                            _saveDouble('on_min', values.start);
                            _saveDouble('on_max', values.end);
                          });
                        },
                        maxSeconds: 30,
                        audioOptions: AudioOptions.onYourMarks,
                        selectedAudioPath: _onAudioPath,
                        onAudioChanged: (path) {
                          sync(() {
                            _onAudioPath = path;
                            _saveString('on_audio_path', path);
                          });
                        },
                        onPreviewAudio: () {
                          if (_onAudioPath.isNotEmpty) {
                            _player.play(AssetSource(_onAudioPath));
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      _buildPhaseSetting(
                        title: 'Set',
                        randomEnabled: _randomSet,
                        onRandomChanged: (value) {
                          sync(() {
                            _randomSet = value;
                            _saveBool('set_random', value);
                          });
                        },
                        fixedValue: _setFixed,
                        rangeValues: _setRange,
                        onFixedChanged: (value) {
                          sync(() {
                            _setFixed = value;
                            _saveDouble('set_fixed', value);
                          });
                        },
                        onRangeChanged: (values) {
                          sync(() {
                            _setRange = values;
                            _saveDouble('set_min', values.start);
                            _saveDouble('set_max', values.end);
                          });
                        },
                        maxSeconds: 40,
                        audioOptions: AudioOptions.set,
                        selectedAudioPath: _setAudioPath,
                        onAudioChanged: (path) {
                          sync(() {
                            _setAudioPath = path;
                            _saveString('set_audio_path', path);
                          });
                        },
                        onPreviewAudio: () {
                          if (_setAudioPath.isNotEmpty) {
                            _player.play(AssetSource(_setAudioPath));
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      _buildPhaseSetting(
                        title: 'Go',
                        randomEnabled: _randomPan,
                        onRandomChanged: (value) {
                          sync(() {
                            _randomPan = value;
                            _saveBool('pan_random', value);
                          });
                        },
                        fixedValue: _panFixed,
                        rangeValues: _panRange,
                        onFixedChanged: (value) {
                          sync(() {
                            _panFixed = value;
                            _saveDouble('pan_fixed', value);
                          });
                        },
                        onRangeChanged: (values) {
                          sync(() {
                            _panRange = values;
                            _saveDouble('pan_min', values.start);
                            _saveDouble('pan_max', values.end);
                          });
                        },
                        maxSeconds: 10,
                        audioOptions: AudioOptions.go,
                        selectedAudioPath: _goAudioPath,
                        onAudioChanged: (path) {
                          sync(() {
                            _goAudioPath = path;
                            _saveString('go_audio_path', path);
                          });
                        },
                        onPreviewAudio: () {
                          if (_goAudioPath.isNotEmpty) {
                            _player.play(AssetSource(_goAudioPath));
                          }
                        },
                      ),
                      const SizedBox(height: 24),
                      // Credit button
                          GestureDetector(
                            onTap: () => _showCredits(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF141B26) : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: isDark ? const Color(0xFF2A3543) : const Color(0xFFE0E0E0),
                                    spreadRadius: 1,
                                    blurRadius: 0,
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.info_outline,
                                          color: isDark ? Colors.white70 : Colors.black54,
                                          size: 26,
                                        ),
                                        const SizedBox(width: 14),
                                        Flexible(
                                          child: Text(
                                            'クレジット',
                                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                  color: isDark ? Colors.white : Colors.black87,
                                                ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
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
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
            },
          );
        },
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
                      color: isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD),
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
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
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
                          color: isDark ? const Color(0xFF141B26) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
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
                                const Icon(
                                  Icons.audiotrack,
                                  color: Color(0xFF6BCB1F),
                                  size: 26,
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    '音声素材',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? Colors.white : Colors.black87,
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

  Widget _buildCreditItem(BuildContext context, {required String name, required String url, bool isDark = true}) {
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
          style: const TextStyle(
            color: Color(0xFF6BCB1F),
            fontSize: 14,
          ),
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
    if (_lastTitleTap != null && now.difference(_lastTitleTap!).inMilliseconds > 1000) {
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
                        color: isSelected
                            ? const Color(0xFF6BCB1F)
                            : (isDark ? Colors.white : Colors.black87),
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
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
              style: const TextStyle(
                color: Color(0xFF6BCB1F),
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Number input row
          if (randomEnabled)
            Row(
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
                const SizedBox(width: 8),
                Text(
                  '〜',
                  style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 16),
                ),
                const SizedBox(width: 8),
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
            _buildNumberInput(
              value: fixedValue,
              min: sliderMin,
              max: sliderMax,
              enabled: !_isRunning,
              onChanged: onFixedChanged,
            ),
          const SizedBox(height: 8),
          // Slider
          if (randomEnabled)
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackShape: const RoundedRectSliderTrackShape(),
                rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
              ),
              child: RangeSlider(
                values: rangeValues,
                min: sliderMin,
                max: sliderMax,
                onChanged: _isRunning ? null : (values) {
                  // Round to 0.1
                  final roundedStart = (values.start * 10).round() / 10;
                  final roundedEnd = (values.end * 10).round() / 10;
                  onRangeChanged(RangeValues(roundedStart, roundedEnd));
                },
              ),
            )
          else
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: Slider(
                value: fixedValue,
                min: sliderMin,
                max: sliderMax,
                onChanged: _isRunning ? null : (value) {
                  // Round to 0.1
                  final rounded = (value * 10).round() / 10;
                  onFixedChanged(rounded);
                },
              ),
            ),
          // Random switch row (below slider, right-aligned)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'ランダム',
                style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 15),
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

  Widget _buildGlowingText(
    String text,
    TextStyle style, {
    Color? glowColor,
  }) {
    // Simplified: just return text with shadow instead of blur filter
    if (glowColor != null) {
      return Text(
        text,
        style: style.copyWith(
          shadows: [
            Shadow(
              color: glowColor,
              blurRadius: 8,
            ),
          ],
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
    final countdownText = _remainingSeconds > 0
        ? _remainingSeconds.toStringAsFixed(2)
        : '0.00';
    final showCountdown =
        _phaseLabel.isNotEmpty && _phaseLabel != 'Starter Pistol';
    final isDark = themeNotifier.value;

    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF5F5F5),
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            final isLandscape = orientation == Orientation.landscape;

            return isLandscape
                ? _buildLandscapeLayout(countdownText, showCountdown)
                : _buildPortraitLayout(countdownText, showCountdown);
          },
        ),
      ),
    );
  }

  Widget _buildPortraitLayout(String countdownText, bool showCountdown) {
    final isDark = themeNotifier.value;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: _openSettings,
                icon: const Icon(Icons.tune_rounded, size: 28),
                style: IconButton.styleFrom(
                  backgroundColor: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  padding: const EdgeInsets.all(12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: _buildTimerPanel(countdownText, showCountdown, isLandscape: false),
          ),
        ),
        if (!_isSettingsOpen) _buildButtons(isLandscape: false),
      ],
    );
  }

  Widget _buildLandscapeLayout(String countdownText, bool showCountdown) {
    final isDark = themeNotifier.value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Left side: Settings button
          Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              IconButton(
                onPressed: _openSettings,
                icon: const Icon(Icons.tune_rounded, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  padding: const EdgeInsets.all(8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          // Center: Timer panel (larger)
          Expanded(
            child: Center(
              child: _buildTimerPanel(countdownText, showCountdown, isLandscape: true),
            ),
          ),
          // Right side: Buttons (smaller)
          if (!_isSettingsOpen) ...[
            const SizedBox(width: 24),
            SizedBox(
              width: 90,
              child: _buildButtons(isLandscape: true),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimerPanel(String countdownText, bool showCountdown, {required bool isLandscape}) {
    if (_phaseLabel.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = themeNotifier.value;

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;
        final isSmallScreen = screenWidth < 360 || (isLandscape && screenHeight < 250);
        final isTinyScreen = screenWidth < 300 || (isLandscape && screenHeight < 180);

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
        final horizontalPadding = isLandscape ? 20.0 : (isSmallScreen ? 16.0 : 20.0);
        final verticalPadding = isLandscape ? 12.0 : (isSmallScreen ? 14.0 : 18.0);
        final borderRadius = isSmallScreen ? 18.0 : 22.0;

        final progress = _animatedProgress;

        // Interpolate colors based on progress (light -> dark as countdown approaches 0)
        // For 'Go' phase or when finished, always use full intensity (progress = 1.0)
        final effectiveProgress = (_phaseLabel == 'Go' || _isFinished) ? 1.0 : progress;
        final progressColor = PhaseColors.getInterpolatedColor(_phaseLabel, effectiveProgress);
        final secondaryColor = PhaseColors.getInterpolatedSecondaryColor(_phaseLabel, effectiveProgress);

        return RepaintBoundary(
          child: IntrinsicWidth(
            child: IntrinsicHeight(
              child: CustomPaint(
                painter: RoundedRectProgressPainter(
                  progress: progress,
                  borderRadius: borderRadius,
                  strokeWidth: isSmallScreen ? 3 : 4,
                  progressColor: progressColor,
                  secondaryColor: secondaryColor,
                  backgroundColor: isDark ? const Color(0xFF1A2332) : const Color(0xFFE0E0E0),
                  previousPhaseColor: _previousPhaseColor,
                ),
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
                  boxShadow: [
                    BoxShadow(
                      color: progressColor.withOpacity(0.12),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Phase label with glow - auto-fit to prevent overflow
                    GestureDetector(
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
                    if (showCountdown) ...[
                      SizedBox(height: isLandscape ? 4 : (isSmallScreen ? 8 : 10)),
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
                        'seconds',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: secondsFontSize,
                          fontWeight: FontWeight.w500,
                          color: progressColor.withOpacity(0.7),
                          letterSpacing: 3,
                        ),
                      ),
                    ],
                  ],
                ),
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
        final isSmallScreen = isLandscape ? screenHeight < 400 : screenWidth < 360;
        final horizontalPadding = isLandscape ? 0.0 : (isSmallScreen ? 16.0 : 24.0);
        final bottomPadding = isLandscape ? 0.0 : (isSmallScreen ? 40.0 : 56.0);
        final buttonSpacing = isLandscape ? 12.0 : (isSmallScreen ? 12.0 : 16.0);

        // Left button: START/PAUSE toggle
        // - Running (not paused): show PAUSE
        // - Otherwise: show START
        final isShowingPause = _isRunning && !_isPaused;

        final buttons = [
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
          // Right button: RESET (enabled when paused or finished)
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

        if (isLandscape) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: buttons,
          );
        } else {
          return Padding(
            padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, bottomPadding),
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
  })  : secondaryColor = secondaryColor ?? progressColor,
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
      final remainingPath = pathMetrics.extractPath(progressLength, totalLength);
      _drawProgressWithGlow(canvas, remainingPath, previousPhaseColor!, previousPhaseColor!, size);
    }

    // Draw current progress
    if (clampedProgress > 0) {
      final extractedPath = pathMetrics.extractPath(0, progressLength);
      _drawProgressWithGlow(canvas, extractedPath, progressColor, secondaryColor, size);
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

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toStringAsFixed(1));
  }

  @override
  void didUpdateWidget(_NumberInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update text when value changes from parent (e.g., slider)
    if (oldWidget.value != widget.value) {
      _controller.text = widget.value.toStringAsFixed(1);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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
        enabled: widget.enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          filled: true,
          fillColor: isDark ? const Color(0xFF1A2332) : const Color(0xFFE8E8E8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: isDark ? const Color(0xFF3A4654) : const Color(0xFFBDBDBD)),
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
