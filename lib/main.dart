import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const StartCallApp());
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

  bool _isRunning = false;
  bool _isPaused = false;
  bool _isFinished = false;
  String _phaseLabel = 'Track Start Call';
  double _remainingSeconds = 0;
  int _runToken = 0;

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
    });

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
      assetPath: 'audio/on_your_marks.mp3',
      labelOnPlay: 'On Your Marks',
      labelBeforePlay: 'Ready',
    );
    if (!onOk) {
      return;
    }

    final setOk = await _runPhase(
      runId: runId,
      seconds: setDelay,
      assetPath: 'audio/set.mp3',
      labelOnPlay: 'Set',
    );
    if (!setOk) {
      return;
    }

    final panOk = await _runPhase(
      runId: runId,
      seconds: panDelay,
      assetPath: 'audio/pan.mp3',
      labelOnPlay: 'Go',
    );
    if (!panOk) {
      return;
    }

    if (!mounted || runId != _runToken) {
      return;
    }

    setState(() {
      _isRunning = false;
      _isPaused = false;
      _isFinished = true;
      _phaseLabel = 'Go';
      _remainingSeconds = 0;
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
      _phaseLabel = 'Track Start Call';
      _remainingSeconds = 0;
    });
  }

  Future<void> _openSettings() async {
    if (_isRunning || _isPaused) {
      await _resetSequence();
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            void sync(VoidCallback fn) {
              setState(fn);
              modalSetState(() {});
            }

            return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 12,
                bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF0E131A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 48,
                          height: 5,
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A4654),
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '設定',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFFE6FFD4),
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
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
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
  }) {
    const sliderMin = 0.5;
    final sliderMax = maxSeconds;

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
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFE6FFD4),
                      ),
                ),
              ),
              const Text(
                'ランダム',
                style: TextStyle(color: Color(0xFF9FBFA8)),
              ),
              Switch(
                value: randomEnabled,
                onChanged: _isRunning ? null : onRandomChanged,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (randomEnabled)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${rangeValues.start.toStringAsFixed(2)}s - ${rangeValues.end.toStringAsFixed(2)}s',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFFC6EFA6),
                      ),
                ),
                RangeSlider(
                  values: rangeValues,
                  min: sliderMin,
                  max: sliderMax,
                  divisions: 95,
                  labels: RangeLabels(
                    rangeValues.start.toStringAsFixed(2),
                    rangeValues.end.toStringAsFixed(2),
                  ),
                  onChanged: _isRunning ? null : onRangeChanged,
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${fixedValue.toStringAsFixed(2)}s',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFFC6EFA6),
                      ),
                ),
                Slider(
                  value: fixedValue,
                  min: sliderMin,
                  max: sliderMax,
                  divisions: 95,
                  label: fixedValue.toStringAsFixed(2),
                  onChanged: _isRunning ? null : onFixedChanged,
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final countdownText = _remainingSeconds > 0
        ? _remainingSeconds.toStringAsFixed(2)
        : '0.00';
    final showCountdown =
        _phaseLabel.isNotEmpty && _phaseLabel != 'Track Start Call';

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF0A0E0B),
                    Color(0xFF111D14),
                    Color(0xFF0B0F0C),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          Positioned(
            top: -120,
            left: -80,
            child: Container(
              width: 260,
              height: 260,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0x226BCB1F),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -140,
            right: -60,
            child: Container(
              width: 300,
              height: 300,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color(0x2237632D),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _openSettings,
                      icon: const Icon(Icons.settings),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xCC151B22),
                        foregroundColor: const Color(0xFFE6FFD4),
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
                            final panelWidth =
                                min(constraints.maxWidth * 0.75, 320.0);
                            return Container(
                              constraints: BoxConstraints(
                                minWidth: panelWidth,
                                maxWidth: panelWidth,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: const Color(0xFF2A3543),
                                ),
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xCC141B26),
                                    Color(0xAA0F151E),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      _phaseLabel,
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.bebasNeue(
                                        textStyle: Theme.of(context)
                                            .textTheme
                                            .displaySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.6,
                                              color:
                                                  const Color(0xFFE6FFD4),
                                            ),
                                      ),
                                    ),
                                    if (showCountdown) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        '$countdownText s',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  const Color(0xFF6BCB1F),
                                            ),
                                      ),
                                    ],
                                  ],
                                ),
                            );
                          },
                        ),
                ),
              ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  child: Row(
                    children: [
                      Expanded(
                      child: FilledButton(
                        onPressed:
                            _isRunning && !_isPaused ? null : _startSequence,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            backgroundColor: const Color(0xFF6BCB1F),
                            foregroundColor: const Color(0xFF0C1409),
                          ),
                          child: const Text('スタート'),
                        ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _isPaused || _isFinished
                          ? OutlinedButton(
                              onPressed: _resetSequence,
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 18),
                                foregroundColor: const Color(0xFFE85C5C),
                                side: const BorderSide(
                                  color: Color(0xFFE85C5C),
                                ),
                              ),
                              child: const Text('リセット'),
                            )
                          : OutlinedButton(
                              onPressed: _isRunning ? _pauseSequence : null,
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 18),
                                foregroundColor: const Color(0xFF6BCB1F),
                                side: const BorderSide(
                                  color: Color(0xFF6BCB1F),
                                ),
                              ),
                              child: const Text('一時停止'),
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
