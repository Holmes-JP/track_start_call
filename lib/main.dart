import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const StartCallApp());
}

// Audio option model
class AudioOption {
  final String name;
  final String path;

  const AudioOption({required this.name, required this.path});
}

// Audio options for each phase
class AudioOptions {
  static const List<AudioOption> onYourMarks = [
    AudioOption(name: 'On Your Marks (男性)', path: 'audio/On Your Marks/On_Your_Marks_Male.mp3'),
    AudioOption(name: 'On Your Marks (女性)', path: 'audio/On Your Marks/On_Your_Marks_Female.mp3'),
    AudioOption(name: '位置について (男性)', path: 'audio/On Your Marks/ichinitsuite_Male.mp3'),
    AudioOption(name: '位置について (女性)', path: 'audio/On Your Marks/ichinitsuite_Female.mp3'),
    AudioOption(name: '位置について (あみたろ)', path: 'audio/On Your Marks/ichinitsuite_amitaro.mp3'),
  ];

  static const List<AudioOption> set = [
    AudioOption(name: 'Set (男性)', path: 'audio/Set/Set_Male.mp3'),
    AudioOption(name: 'Set (女性)', path: 'audio/Set/Set_Female.mp3'),
    AudioOption(name: '用意 (男性)', path: 'audio/Set/youi_Male.mp3'),
    AudioOption(name: '用意 (女性)', path: 'audio/Set/youi_Female.mp3'),
    AudioOption(name: '用意 (あみたろ)', path: 'audio/Set/youi_amitaro.mp3'),
  ];

  static const List<AudioOption> go = [
    AudioOption(name: 'ピストル 01', path: 'audio/Go/pan_01.mp3'),
    AudioOption(name: 'ピストル 02', path: 'audio/Go/pan_02.mp3'),
    AudioOption(name: 'ピストル 03', path: 'audio/Go/pan_03.mp3'),
    AudioOption(name: 'ピストル 04', path: 'audio/Go/pan_04.mp3'),
    AudioOption(name: 'ドン (あみたろ)', path: 'audio/Go/don_amitaro.mp3'),
    AudioOption(name: 'スタート (あみたろ)', path: 'audio/Go/start_amitaro.mp3'),
  ];
}

// Phase color definitions with gradients
class PhaseColors {
  static const ready = Color(0xFF6BCB1F);
  static const readySecondary = Color(0xFF4CAF50);
  static const onYourMarks = Color(0xFFFFB800);
  static const onYourMarksSecondary = Color(0xFFFF9500);
  static const set = Color(0xFFFF6B35);
  static const setSecondary = Color(0xFFFF4757);
  static const go = Color(0xFFFF3366);
  static const goSecondary = Color(0xFFE91E63);

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
}

class StartCallApp extends StatelessWidget {
  const StartCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6BCB1F),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '陸上スタートコール',
      theme: baseTheme.copyWith(
        textTheme: GoogleFonts.spaceGroteskTextTheme(baseTheme.textTheme),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: const CardThemeData(
          elevation: 0.5,
          color: Color(0xFF141B26),
          surfaceTintColor: Color(0xFF141B26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        sliderTheme: const SliderThemeData(
          trackHeight: 3,
          activeTrackColor: Color(0xFF6BCB1F),
          inactiveTrackColor: Color(0xFF26332A),
          thumbColor: Color(0xFF6BCB1F),
          overlayColor: Color(0x336BCB1F),
        ),
        switchTheme: const SwitchThemeData(
          thumbColor: WidgetStatePropertyAll(Color(0xFF6BCB1F)),
          trackColor: WidgetStatePropertyAll(Color(0xFF1D2B21)),
        ),
      ),
      home: const StartCallHomePage(),
    );
  }
}

class StartCallHomePage extends StatefulWidget {
  const StartCallHomePage({super.key});

  @override
  State<StartCallHomePage> createState() => _StartCallHomePageState();
}

class _StartCallHomePageState extends State<StartCallHomePage> {
  final _player = AudioPlayer();
  final _random = Random();
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
  String _onAudioPath = AudioOptions.onYourMarks[0].path;
  String _setAudioPath = AudioOptions.set[0].path;
  String _goAudioPath = AudioOptions.go[0].path;

  bool _isRunning = false;
  bool _isPaused = false;
  bool _isFinished = false;
  bool _isSettingsOpen = false;
  String _phaseLabel = 'Track Starter';

  // Loop setting
  bool _loopEnabled = false;

  // Hidden command tap tracking
  int _titleTapCount = 0;
  DateTime? _lastTitleTap;
  double _remainingSeconds = 0;
  double _phaseStartSeconds = 0;
  int _runToken = 0;
  List<Color> _completedPhaseColors = [];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
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
      max: 60,
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
      _setFixed = setFixed.clamp(0.5, 60);
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
    const tick = Duration(milliseconds: 50);
    var remaining = seconds;
    setState(() {
      _phaseStartSeconds = seconds;
      _remainingSeconds = remaining;
    });

    while (remaining > 0) {
      if (!mounted || runId != _runToken) {
        return false;
      }
      if (_isPaused) {
        await Future.delayed(tick);
        continue;
      }
      await Future.delayed(tick);
      if (!mounted || runId != _runToken) {
        return false;
      }
      remaining -= tick.inMilliseconds / 1000.0;
      if (remaining < 0) {
        remaining = 0;
      }
      setState(() {
        _remainingSeconds = remaining;
      });
    }
    return mounted && runId == _runToken;
  }

  Future<bool> _runPhase({
    required int runId,
    required double seconds,
    required String assetPath,
    required String labelOnPlay,
    String? labelBeforePlay,
  }) async {
    if (!mounted || runId != _runToken) {
      return false;
    }

    setState(() {
      if (labelBeforePlay != null) {
        _phaseLabel = labelBeforePlay;
      }
    });
    final waitOk = await _waitWithPause(runId, seconds);
    if (!waitOk) {
      return false;
    }

    if (!mounted || runId != _runToken) {
      return false;
    }

    setState(() {
      _phaseLabel = labelOnPlay;
    });
    await _player.play(AssetSource(assetPath));
    return mounted && runId == _runToken;
  }

  Future<void> _startSequence() async {
    if (_isRunning && _isPaused) {
      setState(() {
        _isPaused = false;
      });
      return;
    }
    if (_isRunning) {
      return;
    }

    final runId = ++_runToken;
    setState(() {
      _isRunning = true;
      _isPaused = false;
      _isFinished = false;
      _phaseLabel = 'Ready';
      _completedPhaseColors = [];
    });

    // Phase colors
    const readyColor = Color(0xFF6BCB1F);
    const onYourMarksColor = Color(0xFFFFB800);
    const setColor = Color(0xFFFF6B35);
    const goColor = Color(0xFFFF3366);

    do {
      // Reset for each loop iteration (random delays are recalculated each time)
      if (_loopEnabled && _completedPhaseColors.isNotEmpty) {
        // Starting a new loop iteration
        setState(() {
          _phaseLabel = 'Ready';
          _completedPhaseColors = [];
        });
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
      );
      if (!onOk) {
        return;
      }
      setState(() {
        _completedPhaseColors = [..._completedPhaseColors, readyColor];
      });

      final setOk = await _runPhase(
        runId: runId,
        seconds: setDelay,
        assetPath: _setAudioPath,
        labelOnPlay: 'Set',
      );
      if (!setOk) {
        return;
      }
      setState(() {
        _completedPhaseColors = [..._completedPhaseColors, onYourMarksColor];
      });

      final panOk = await _runPhase(
        runId: runId,
        seconds: panDelay,
        assetPath: _goAudioPath,
        labelOnPlay: 'Go',
      );
      if (!panOk) {
        return;
      }
      setState(() {
        _completedPhaseColors = [..._completedPhaseColors, setColor, goColor];
        _phaseLabel = 'Go';
        _remainingSeconds = 0;
      });

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

    setState(() {
      _isRunning = false;
      _isPaused = false;
      _isFinished = true;
    });
  }

  Future<void> _pauseSequence() async {
    if (!_isRunning || _isPaused) {
      return;
    }
    await _player.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _isPaused = true;
    });
  }

  Future<void> _resetSequence() async {
    if (!_isRunning && !_isPaused && !_isFinished) {
      return;
    }
    _runToken++;
    await _player.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _isRunning = false;
      _isPaused = false;
      _isFinished = false;
      _phaseLabel = 'Track Starter';
      _remainingSeconds = 0;
      _phaseStartSeconds = 0;
      _completedPhaseColors = [];
    });
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

            return Container(
              constraints: BoxConstraints(maxHeight: maxHeight),
              decoration: const BoxDecoration(
                color: Color(0xFF0E131A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                          color: const Color(0xFF3A4654),
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
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFFE6FFD4),
                                ),
                          ),
                          const SizedBox(height: 16),
                          // Loop setting
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF141B26),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFF2A3543)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.repeat,
                                      color: Color(0xFF6BCB1F),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      'ループ',
                                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: const Color(0xFFE6FFD4),
                                          ),
                                    ),
                                  ],
                                ),
                                SizedBox(
                                  height: 24,
                                  width: 40,
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
                          _player.play(AssetSource(_onAudioPath));
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
                        maxSeconds: 60,
                        audioOptions: AudioOptions.set,
                        selectedAudioPath: _setAudioPath,
                        onAudioChanged: (path) {
                          sync(() {
                            _setAudioPath = path;
                            _saveString('set_audio_path', path);
                          });
                        },
                        onPreviewAudio: () {
                          _player.play(AssetSource(_setAudioPath));
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
                          _player.play(AssetSource(_goAudioPath));
                        },
                      ),
                      const SizedBox(height: 24),
                      // Credit button
                          GestureDetector(
                            onTap: () => _showCredits(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF141B26),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF2A3543)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.info_outline,
                                          color: Color(0xFF9FBFA8),
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          child: Text(
                                            'クレジット',
                                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                                  color: const Color(0xFFE6FFD4),
                                                ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: Color(0xFF9FBFA8),
                                    size: 24,
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
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          decoration: const BoxDecoration(
            color: Color(0xFF0E131A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                      color: const Color(0xFF3A4654),
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
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFFE6FFD4),
                            ),
                      ),
                      const SizedBox(height: 24),
                      // Audio Credits Section
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141B26),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF2A3543)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.audiotrack,
                                  color: Color(0xFF6BCB1F),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '音声素材',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: const Color(0xFFE6FFD4),
                                        ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _buildCreditItem(
                              context,
                              name: 'あみたろの声素材工房',
                              url: 'https://amitaro.net/',
                            ),
                            const SizedBox(height: 12),
                            _buildCreditItem(
                              context,
                              name: '音読さん',
                              url: 'https://ondoku3.com/',
                            ),
                            const SizedBox(height: 12),
                            _buildCreditItem(
                              context,
                              name: 'On-Jin ～音人～',
                              url: 'https://on-jin.com/',
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

  Widget _buildCreditItem(BuildContext context, {required String name, required String url}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: const TextStyle(
            color: Color(0xFFC6EFA6),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        const SizedBox(height: 4),
        Text(
          url,
          style: const TextStyle(
            color: Color(0xFF6BCB1F),
            fontSize: 12,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ],
    );
  }

  void _handleTitleTap() async {
    // Only trigger when showing "Track Starter" (not running)
    if (_phaseLabel != 'Track Starter') return;

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
    double width = 70,
  }) {
    return SizedBox(
      width: width,
      height: 40,
      child: TextField(
        controller: TextEditingController(text: value.toStringAsFixed(2)),
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFC6EFA6),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true,
          fillColor: const Color(0xFF1A2332),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF3A4654)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF3A4654)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF6BCB1F), width: 2),
          ),
          suffixText: 's',
          suffixStyle: const TextStyle(
            color: Color(0xFF9FBFA8),
            fontSize: 12,
          ),
        ),
        onSubmitted: (text) {
          final parsed = double.tryParse(text);
          if (parsed != null) {
            onChanged(parsed.clamp(min, max));
          }
        },
        onTapOutside: (_) {
          FocusManager.instance.primaryFocus?.unfocus();
        },
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

    // Find selected audio name
    final selectedAudio = audioOptions.firstWhere(
      (option) => option.path == selectedAudioPath,
      orElse: () => audioOptions.first,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141B26),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2A3543)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PopupMenuButton<String>(
                enabled: !_isRunning,
                padding: EdgeInsets.zero,
                offset: const Offset(0, 40),
                color: const Color(0xFF1A2332),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF3A4654)),
                ),
                onSelected: onAudioChanged,
                itemBuilder: (context) => audioOptions.map((option) {
                  final isSelected = option.path == selectedAudioPath;
                  return PopupMenuItem<String>(
                    value: option.path,
                    child: Text(
                      option.name,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF6BCB1F)
                            : const Color(0xFFC6EFA6),
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFFE6FFD4),
                          ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.keyboard_arrow_down,
                      color: Color(0xFF9FBFA8),
                      size: 20,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                'ランダム',
                style: const TextStyle(color: Color(0xFF9FBFA8), fontSize: 12),
              ),
              const SizedBox(width: 4),
              SizedBox(
                height: 24,
                width: 40,
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
          // Selected audio display with preview button
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                GestureDetector(
                  onTap: onPreviewAudio,
                  child: const Icon(
                    Icons.play_circle_outline,
                    color: Color(0xFF6BCB1F),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  selectedAudio.name,
                  style: const TextStyle(
                    color: Color(0xFF6BCB1F),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (randomEnabled)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                    const Text(
                      '〜',
                      style: TextStyle(color: Color(0xFF9FBFA8), fontSize: 16),
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
                ),
                const SizedBox(height: 8),
                RangeSlider(
                  values: rangeValues,
                  min: sliderMin,
                  max: sliderMax,
                  divisions: ((sliderMax - sliderMin) * 10).round(),
                  onChanged: _isRunning ? null : (values) {
                    // Round to 0.1
                    final roundedStart = (values.start * 10).round() / 10;
                    final roundedEnd = (values.end * 10).round() / 10;
                    onRangeChanged(RangeValues(roundedStart, roundedEnd));
                  },
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildNumberInput(
                  value: fixedValue,
                  min: sliderMin,
                  max: sliderMax,
                  enabled: !_isRunning,
                  onChanged: onFixedChanged,
                ),
                const SizedBox(height: 8),
                Slider(
                  value: fixedValue,
                  min: sliderMin,
                  max: sliderMax,
                  divisions: ((sliderMax - sliderMin) * 10).round(),
                  onChanged: _isRunning ? null : (value) {
                    // Round to 0.1
                    final rounded = (value * 10).round() / 10;
                    onFixedChanged(rounded);
                  },
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
    return Stack(
      alignment: Alignment.center,
      children: [
        // Glow layer
        if (glowColor != null)
          Text(
            text,
            style: style.copyWith(
              foreground: Paint()
                ..color = glowColor
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
            ),
          ),
        // Main text
        Text(text, style: style),
      ],
    );
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
        boxShadow: isEnabled
            ? [
                BoxShadow(
                  color: primaryColor.withOpacity(filled ? 0.4 : 0.2),
                  blurRadius: 16,
                  spreadRadius: filled ? 2 : 0,
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
        _phaseLabel.isNotEmpty && _phaseLabel != 'Track Starter';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.tune_rounded, size: 28),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF1A1A1A),
                          foregroundColor: const Color(0xFFE6FFD4),
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
                  child: _phaseLabel.isEmpty
                      ? const SizedBox.shrink()
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            // Responsive sizing based on screen width
                            final screenWidth = constraints.maxWidth;
                            final screenHeight = constraints.maxHeight;
                            final isSmallScreen = screenWidth < 360;
                            final isTinyScreen = screenWidth < 300;

                            // Responsive panel width
                            final panelWidth = min(screenWidth * 0.85, 340.0);

                            // Responsive font sizes
                            final labelFontSize = isTinyScreen ? 28.0 : (isSmallScreen ? 32.0 : 38.0);
                            final countdownFontSize = isTinyScreen ? 36.0 : (isSmallScreen ? 40.0 : 44.0);
                            final secondsFontSize = isTinyScreen ? 10.0 : 12.0;

                            // Responsive padding
                            final horizontalPadding = isSmallScreen ? 16.0 : 20.0;
                            final verticalPadding = isSmallScreen ? 14.0 : 18.0;
                            final borderRadius = isSmallScreen ? 18.0 : 22.0;

                            final progress = _phaseStartSeconds > 0
                                ? 1.0 - (_remainingSeconds / _phaseStartSeconds)
                                : 0.0;

                            final progressColor = PhaseColors.getPrimaryColor(_phaseLabel);
                            final secondaryColor = PhaseColors.getSecondaryColor(_phaseLabel);

                            return IntrinsicWidth(
                              child: IntrinsicHeight(
                                child: CustomPaint(
                                  painter: RoundedRectProgressPainter(
                                    progress: progress,
                                    borderRadius: borderRadius,
                                    strokeWidth: isSmallScreen ? 3 : 4,
                                    progressColor: progressColor,
                                    secondaryColor: secondaryColor,
                                    backgroundColor: const Color(0xFF1A2332),
                                    completedPhaseColors: _completedPhaseColors,
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
                                      gradient: LinearGradient(
                                        colors: [
                                          const Color(0xFF141B26).withOpacity(0.95),
                                          const Color(0xFF0D1117).withOpacity(0.98),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: progressColor.withOpacity(0.15),
                                          blurRadius: 30,
                                          spreadRadius: 2,
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
                                                color: const Color(0xFFE6FFD4),
                                              ),
                                              glowColor: progressColor.withOpacity(0.3),
                                            ),
                                          ),
                                        ),
                                        if (showCountdown) ...[
                                          SizedBox(height: isSmallScreen ? 8 : 10),
                                          // Countdown with gradient and glow
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
                            );
                          },
                        ),
                ),
              ),
                if (!_isSettingsOpen)
                  Builder(
                    builder: (context) {
                      final screenWidth = MediaQuery.of(context).size.width;
                      final isSmallScreen = screenWidth < 360;
                      final horizontalPadding = isSmallScreen ? 16.0 : 24.0;
                      final bottomPadding = isSmallScreen ? 20.0 : 32.0;
                      final buttonSpacing = isSmallScreen ? 12.0 : 16.0;

                      return Padding(
                        padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, bottomPadding),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildGlowButton(
                                onPressed: _isRunning && !_isPaused ? null : _startSequence,
                                label: 'START',
                                primaryColor: PhaseColors.ready,
                                secondaryColor: PhaseColors.readySecondary,
                                filled: true,
                                isSmallScreen: isSmallScreen,
                              ),
                            ),
                            SizedBox(width: buttonSpacing),
                            Expanded(
                              child: _isPaused || _isFinished
                                  ? _buildGlowButton(
                                      onPressed: _resetSequence,
                                      label: 'RESET',
                                      primaryColor: const Color(0xFFE85C5C),
                                      secondaryColor: const Color(0xFFFF6B6B),
                                      filled: false,
                                      isSmallScreen: isSmallScreen,
                                    )
                                  : _buildGlowButton(
                                      onPressed: _isRunning ? _pauseSequence : null,
                                      label: 'PAUSE',
                                      primaryColor: PhaseColors.ready,
                                      secondaryColor: PhaseColors.readySecondary,
                                      filled: false,
                                      isSmallScreen: isSmallScreen,
                                    ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
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
  final List<Color> completedPhaseColors;

  RoundedRectProgressPainter({
    required this.progress,
    required this.borderRadius,
    this.strokeWidth = 3.0,
    this.progressColor = const Color(0xFF6BCB1F),
    Color? secondaryColor,
    this.backgroundColor = const Color(0xFF2A3543),
    this.completedPhaseColors = const [],
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
      [primary, secondary, primary],
      [0.0, 0.5, 1.0],
    );

    // Draw outer glow (largest, most diffuse)
    final outerGlowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 12
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
      ..color = primary.withOpacity(0.25);
    canvas.drawPath(progressPath, outerGlowPaint);

    // Draw middle glow
    final midGlowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 6
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
      ..color = primary.withOpacity(0.5);
    canvas.drawPath(progressPath, midGlowPaint);

    // Draw inner glow (brighter, tighter)
    final innerGlowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 2
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
      ..color = primary.withOpacity(0.8);
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

    // Draw background with subtle inner shadow effect
    final bgOuterGlow = Paint()
      ..color = backgroundColor.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 8
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(path, bgOuterGlow);

    final bgPaint = Paint()
      ..color = backgroundColor.withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawPath(path, bgPaint);

    // Draw completed phases (full circles)
    for (final color in completedPhaseColors) {
      _drawProgressWithGlow(canvas, path, color, color, size);
    }

    // Draw current progress
    if (progress <= 0) return;

    final pathMetrics = path.computeMetrics().first;
    final totalLength = pathMetrics.length;
    final progressLength = totalLength * progress.clamp(0.0, 1.0);
    final extractedPath = pathMetrics.extractPath(0, progressLength);

    _drawProgressWithGlow(canvas, extractedPath, progressColor, secondaryColor, size);
  }

  @override
  bool shouldRepaint(RoundedRectProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.completedPhaseColors.length != completedPhaseColors.length;
  }
}
