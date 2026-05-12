import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class StoryAudioController extends ChangeNotifier {
  StoryAudioController({Duration loadTimeout = const Duration(seconds: 30)})
    : _loadTimeout = loadTimeout {
    _bind();
  }

  final AudioPlayer _player = AudioPlayer();
  final Duration _loadTimeout;

  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  bool _loading = false;
  String? _error;
  double _speed = 1.0;
  bool _repeatOne = false;
  String _sourceUrl = '';

  Duration get duration => _duration;
  Duration get position => _position;
  PlayerState get playerState => _playerState;
  bool get loading => _loading;
  String? get error => _error;
  double get speed => _speed;
  bool get repeatOne => _repeatOne;
  bool get hasSource => _sourceUrl.isNotEmpty;

  void _bind() {
    _durationSub = _player.onDurationChanged.listen((d) {
      _duration = d;
      notifyListeners();
    });

    _positionSub = _player.onPositionChanged.listen((p) {
      _position = p;
      notifyListeners();
    });

    _stateSub = _player.onPlayerStateChanged.listen((s) {
      _playerState = s;
      notifyListeners();
    });

    _completeSub = _player.onPlayerComplete.listen((_) async {
      if (_repeatOne) {
        await _player.seek(Duration.zero);
        await _player.resume();
        return;
      }
      _position = Duration.zero;
      _playerState = PlayerState.completed;
      notifyListeners();
    });
  }

  String _humanAudioError(Object error, {String? fallback}) {
    final raw = error.toString();
    final low = raw.toLowerCase();

    if (low.contains('timeoutexception') || low.contains('timeout')) {
      return 'Audio is taking too long to load. Check your internet and try again.';
    }
    if (low.contains('socket') || low.contains('network')) {
      return 'Network issue while loading audio. Please try again.';
    }
    if (low.contains('source') || low.contains('url') || low.contains('404')) {
      return 'Audio file is not available right now.';
    }

    return fallback ?? 'Could not load audio. Please try again.';
  }

  Future<void> ensureLoaded(String audioUrl) async {
    final nextUrl = audioUrl.trim();
    if (nextUrl.isEmpty) return;
    if (_sourceUrl == nextUrl && !_loading && _error == null) return;

    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _sourceUrl = nextUrl;
      await _player.setSourceUrl(nextUrl).timeout(_loadTimeout);
      await _player.setPlaybackRate(_speed).timeout(const Duration(seconds: 8));
      await _player
          .setReleaseMode(ReleaseMode.stop)
          .timeout(const Duration(seconds: 8));
      _loading = false;
      notifyListeners();
    } on TimeoutException {
      _loading = false;
      _error =
          'Audio is taking too long to load. Check your internet and try again.';
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = _humanAudioError(e);
      notifyListeners();
    }
  }

  Future<void> togglePlayPause() async {
    if (_loading || !hasSource) return;
    try {
      if (_playerState == PlayerState.playing) {
        await _player.pause();
      } else {
        if (_playerState == PlayerState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.resume();
      }
    } catch (e) {
      _error = _humanAudioError(e, fallback: 'Could not play audio.');
      notifyListeners();
    }
  }

  Future<void> pause() async {
    if (_playerState == PlayerState.playing) {
      await _player.pause();
    }
  }

  Future<void> seekTo(Duration target) async {
    await _player.seek(target);
  }

  Future<void> setSpeed(double speed) async {
    try {
      await _player.setPlaybackRate(speed);
      _speed = speed;
      notifyListeners();
    } catch (_) {}
  }

  void toggleRepeatOne() {
    _repeatOne = !_repeatOne;
    notifyListeners();
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
