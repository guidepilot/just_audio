import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe'; // GuidePilot patch: setProperty for webkitPreservesPitch
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:synchronized/synchronized.dart' as synch;
import 'package:web/web.dart';

/// The web implementation of [JustAudioPlatform].
class JustAudioPlugin extends JustAudioPlatform {
  final Map<String, JustAudioPlayer> players = {};

  /// The entrypoint called by the generated plugin registrant.
  static void registerWith(Registrar registrar) {
    JustAudioPlatform.instance = JustAudioPlugin();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (players.containsKey(request.id)) {
      throw PlatformException(
          code: "error",
          message: "Platform player ${request.id} already exists");
    }
    // GuidePilot fork: opt-in Web Audio engine for smooth playbackRate on
    // Apple WebKit (see WebAudioPlayer). Falls back to the <audio> engine.
    final JustAudioPlayer player = request.webAudioEngine
        ? WebAudioPlayer(id: request.id)
        : Html5AudioPlayer(id: request.id);
    players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await players[request.id]?.release();
    players.remove(request.id);
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    for (var player in players.values) {
      await player.release();
    }
    players.clear();
    return DisposeAllPlayersResponse();
  }
}

/// The web impluementation of [AudioPlayerPlatform].
abstract class JustAudioPlayer extends AudioPlayerPlatform {
  final _eventController =
      StreamController<PlaybackEventMessage>.broadcast(sync: true);
  final _dataEventController =
      StreamController<PlayerDataMessage>.broadcast(sync: true);
  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  bool _playing = false;
  int? _index;
  double _speed = 1.0;
  int? errorCode;
  String? errorMessage;

  /// Creates a platform player with the given [id].
  JustAudioPlayer({required String id}) : super(id);

  @mustCallSuper
  Future<void> release() async {
    _eventController.close();
    _dataEventController.close();
  }

  /// Returns the current position of the player.
  Duration getCurrentPosition();

  /// Returns the current buffered position of the player.
  Duration getBufferedPosition();

  /// Returns the duration of the current player item or `null` if unknown.
  Duration? getDuration();

  /// Broadcasts a playback event from the platform side to the plugin side.
  void broadcastPlaybackEvent() {
    var updateTime = DateTime.now();
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updatePosition: getCurrentPosition(),
      updateTime: updateTime,
      bufferedPosition: getBufferedPosition(),
      // TODO: Icy Metadata
      icyMetadata: null,
      duration: getDuration(),
      currentIndex: _index,
      androidAudioSessionId: null,
      errorCode: errorCode,
      errorMessage: errorMessage,
    ));
  }

  /// Transitions to [processingState] and broadcasts a playback event.
  void transition(ProcessingStateMessage processingState) {
    _processingState = processingState;
    if (processingState != ProcessingStateMessage.idle) {
      errorCode = null;
      errorMessage = null;
    }
    broadcastPlaybackEvent();
  }
}

/// GuidePilot fork: a Web Audio implementation of [JustAudioPlayer].
///
/// Plays a single decoded clip through an `AudioBufferSourceNode` and controls
/// speed via the node's `playbackRate` **`AudioParam`**, which changes
/// smoothly on Apple WebKit (Safari) — unlike `HTMLMediaElement.playbackRate`,
/// which re-inits/flushes the audio buffer on every change and glitches. Used
/// only when a player opts in via `InitRequest.webAudioEngine`, so it carries
/// just the surface media-sync needs (single URI source, play/pause/seek/
/// speed/volume/loop). The whole clip is fetched + decoded into memory, so
/// this is intended for short clips, not long-form streaming.
class WebAudioPlayer extends JustAudioPlayer {
  AudioContext? _ctx;
  GainNode? _gain;
  AudioBuffer? _buffer;
  AudioBufferSourceNode? _source;
  String? _src;
  double _volume = 1.0;
  bool _loop = false;

  // Position under a varying playbackRate: the content offset captured at the
  // last anchor, plus rate * elapsed AudioContext time since. We re-anchor on
  // every rate change, seek, pause and (re)start, so the integral stays exact.
  double _offsetSec = 0.0;
  double _anchorCtxTime = 0.0;
  Timer? _positionTimer; // periodic broadcast while playing (mimics 'timeupdate')

  WebAudioPlayer({required String id}) : super(id: id);

  /// Sample rate for the sync engine's AudioContext. The whole clip is decoded
  /// into memory (float32 PCM = sampleRate × 4 bytes/s per channel), so a lower
  /// rate roughly halves the footprint vs 44.1 kHz — and `decodeAudioData`
  /// resamples to it. 22.05 kHz is transparent for the mono speech this engine
  /// is used for (media-sync narration); raise it if you ever feed it music.
  static const double _sampleRate = 22050;

  AudioContext _context() =>
      _ctx ??= AudioContext(AudioContextOptions(sampleRate: _sampleRate));

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataEventController.stream;

  double get _nowCtx => (_ctx?.currentTime ?? 0).toDouble();

  double get _positionSec {
    final buffer = _buffer;
    if (buffer == null) return 0.0;
    var pos = _offsetSec;
    if (_playing) pos += _speed * (_nowCtx - _anchorCtxTime);
    return pos.clamp(0.0, buffer.duration);
  }

  /// Freezes the integral: store the current position and re-anchor the clock.
  void _anchor() {
    _offsetSec = _positionSec;
    _anchorCtxTime = _nowCtx;
  }

  @override
  Duration getCurrentPosition() =>
      Duration(milliseconds: (_positionSec * 1000).round());

  @override
  Duration getBufferedPosition() => Duration(
      milliseconds: ((_buffer?.duration ?? 0) * 1000).round());

  @override
  Duration? getDuration() => _buffer == null
      ? null
      : Duration(milliseconds: (_buffer!.duration * 1000).round());

  /// Resolves the first URI source within a (possibly wrapped) source tree.
  /// just_audio wraps even a single source in its playlist, so the load message
  /// is typically a [ConcatenatingAudioSourceMessage]. Clip bounds/loop counts
  /// are ignored — this engine plays the underlying clip.
  UriAudioSourceMessage? _firstUriSource(AudioSourceMessage m) {
    if (m is UriAudioSourceMessage) return m;
    if (m is ClippingAudioSourceMessage) return m.child;
    if (m is LoopingAudioSourceMessage) return _firstUriSource(m.child);
    if (m is ConcatenatingAudioSourceMessage) {
      for (final c in m.children) {
        final u = _firstUriSource(c);
        if (u != null) return u;
      }
    }
    return null;
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final uriMsg = _firstUriSource(request.audioSourceMessage);
    if (uriMsg == null) {
      throw PlatformException(
          code: 'error',
          message: 'WebAudioPlayer supports only URI audio sources');
    }
    _stopSource();
    transition(ProcessingStateMessage.loading);
    try {
      final ctx = _context();
      if (_gain == null) {
        final g = ctx.createGain();
        g.gain.value = _volume;
        g.connect(ctx.destination);
        _gain = g;
      }
      // decodeAudioData requires a CORS-readable response (the audio host must
      // send Access-Control-Allow-Origin) — unlike <audio> playback.
      if (_src != uriMsg.uri || _buffer == null) {
        _src = uriMsg.uri;
        final resp = await window.fetch(uriMsg.uri.toJS).toDart;
        final bytes = await resp.arrayBuffer().toDart;
        _buffer = await ctx.decodeAudioData(bytes).toDart;
      }
      _offsetSec = (request.initialPosition?.inMilliseconds ?? 0) / 1000.0;
      _anchorCtxTime = _nowCtx;
      transition(ProcessingStateMessage.ready);
      if (_playing) _startSource();
      return LoadResponse(duration: getDuration());
    } catch (e) {
      errorMessage = e.toString();
      transition(ProcessingStateMessage.idle);
      throw PlatformException(
          code: 'error', message: 'WebAudioPlayer failed to load: $e');
    }
  }

  void _startSource() {
    final ctx = _context();
    final buffer = _buffer;
    if (buffer == null) return;
    _stopSource();
    final src = ctx.createBufferSource();
    src.buffer = buffer;
    src.loop = _loop;
    src.playbackRate.value = _speed;
    src.connect(_gain!);
    src.addEventListener('ended', ((Event _) => _onEnded(src)).toJS);
    src.start(0, _offsetSec);
    _anchorCtxTime = _nowCtx;
    _source = src;
    _startPositionTimer();
  }

  void _stopSource() {
    final s = _source;
    _source = null; // guard: a pending 'ended' for s is now ignored
    if (s != null) {
      try {
        s.stop();
      } catch (_) {}
      s.disconnect();
    }
    _stopPositionTimer();
  }

  // Fires on natural end. stop() also fires 'ended', but we null `_source`
  // before stopping, so only the still-current source reaches completion here.
  void _onEnded(AudioBufferSourceNode endedSrc) {
    if (!identical(_source, endedSrc) || !_playing) return;
    _offsetSec = _buffer?.duration ?? _offsetSec;
    _playing = false;
    _stopSource();
    transition(ProcessingStateMessage.completed);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_playing) return PlayResponse();
    _playing = true;
    final ctx = _context();
    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
    _startSource();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_playing) return PauseResponse();
    _anchor(); // freeze position before we stop producing sound
    _playing = false;
    _stopSource();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _offsetSec = (request.position?.inMilliseconds ?? 0) / 1000.0;
    _anchorCtxTime = _nowCtx;
    if (_playing) _startSource(); // source nodes are one-shot — recreate
    return SeekResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    if (_playing) _anchor(); // capture position at the old rate first
    _speed = request.speed;
    _source?.playbackRate.value = _speed;
    return SetSpeedResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    _volume = request.volume;
    _gain?.gain.value = _volume;
    return SetVolumeResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loop = request.loopMode != LoopModeMessage.off;
    _source?.loop = _loop;
    return SetLoopModeResponse();
  }

  // No-ops: just_audio replays shuffle state onto every new player, but a
  // single-clip engine has nothing to shuffle. Must be implemented so the
  // base class's UnimplementedError doesn't abort load().
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();

  void _startPositionTimer() {
    _positionTimer ??= Timer.periodic(
        const Duration(milliseconds: 200), (_) => broadcastPlaybackEvent());
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  @override
  Future<void> release() async {
    _stopSource();
    _buffer = null;
    await _ctx?.close().toDart;
    _ctx = null;
    await super.release();
  }
}

/// An HTML5-specific implementation of [JustAudioPlayer].
class Html5AudioPlayer extends JustAudioPlayer {
  // Uncomment after: https://github.com/dart-lang/web/issues/124
  //final _audioElement = HTMLAudioElement();
  final _audioElement = document.createElement('audio') as HTMLAudioElement;
  late final _audioElementQueue = _AudioElementQueue(_audioElement);

  // ===========================================================================
  // GuidePilot patch — iOS-web playbackRate glitch fix (preservesPitch).
  //
  // The media-sync DriftController keeps audio in sync by nudging playbackRate
  // ~4x/s. On iOS Safari every playbackRate change re-inits the time-stretch
  // (pitch-preservation) unit, producing an audible pause/resume glitch.
  // Disabling preservesPitch turns a rate change into a plain resample
  // (tape-speed) and avoids the re-init.
  //
  // SCOPED BY RATE, NOT PLATFORM. Disabling preservesPitch globally would also
  // pitch-shift the user-facing 0.75x..2x speed control on every web platform
  // (the main deployment) — a regression. So we only disable it within a small
  // band around 1.0x, where the shift is inaudible (<=[_pitchPreserveBandwidth]
  // ~= a few tenths of a semitone) and where the high-frequency sync nudges
  // live. Outside the band — deliberate speed changes — pitch preservation
  // stays on, exactly as upstream. No (unreliable) iOS detection needed.
  //
  // just_audio_web's <audio> element is created detached from the DOM and kept
  // private, so a global DOM sweep cannot reach it — hence this fork.

  /// Half-width of the band around 1.0x within which pitch preservation is
  /// disabled (covers the media-sync nudge range incl. the `glide` preset's
  /// +/-10%, with headroom; still an inaudible shift).
  static const double _pitchPreserveBandwidth = 0.15;

  /// Applies the scoped preservesPitch policy for a given playback [rate].
  /// Must run after element creation AND after each source change (Safari
  /// resets the flag on `src`), and whenever the rate changes.
  void _applyPreservesPitchFor(double rate) {
    // Preserve pitch unless we're in the near-1.0x sync band.
    final preserve = (rate - 1.0).abs() > _pitchPreserveBandwidth;
    _audioElement.preservesPitch = preserve;
    // Legacy WebKit name for older iOS Safari — not in the typed binding.
    (_audioElement as JSObject)
        .setProperty('webkitPreservesPitch'.toJS, preserve.toJS);
  }
  // ===========================================================================
  Completer<dynamic>? _durationCompleter;
  AudioSourcePlayer? _audioSourcePlayer;
  LoopModeMessage _loopMode = LoopModeMessage.off;
  bool _shuffleModeEnabled = false;
  final Map<String, AudioSourcePlayer> _audioSourcePlayers = {};

  /// Creates an [Html5AudioPlayer] with the given [id].
  Html5AudioPlayer({required String id}) : super(id: id) {
    _applyPreservesPitchFor(_speed); // GuidePilot patch (initial rate is 1.0x)
    _audioElement.addEventListener(
        'durationchange',
        (Event event) {
          _durationCompleter?.complete();
          _durationCompleter = null;
          broadcastPlaybackEvent();
        }.toJS);
    _audioElement.addEventListener(
        'error',
        (Event event) {
          _eventController.addError(PlatformException(
            code: '${_audioElement.error!.code}',
            message: _audioElement.error!.message,
          ));
          errorCode = _audioElement.error!.code;
          errorMessage = _audioElement.error!.message;
          transition(ProcessingStateMessage.idle);
          _durationCompleter?.completeError(_audioElement.error!);
          _durationCompleter = null;
        }.toJS);
    _audioElement.addEventListener(
        'ended',
        (Event event) {
          _currentAudioSourcePlayer?.complete().catchError((e, st) {});
        }.toJS);
    _audioElement.addEventListener(
        'timeupdate',
        (Event event) {
          _currentAudioSourcePlayer
              ?.timeUpdated(_audioElement.currentTime.toDouble());
        }.toJS);
    _audioElement.addEventListener(
        'loadstart',
        (Event event) {
          transition(ProcessingStateMessage.buffering);
        }.toJS);
    _audioElement.addEventListener(
        'waiting',
        (Event event) {
          transition(ProcessingStateMessage.buffering);
        }.toJS);
    _audioElement.addEventListener(
        'stalled',
        (Event event) {
          transition(ProcessingStateMessage.buffering);
        }.toJS);
    _audioElement.addEventListener(
        'canplaythrough',
        (Event event) {
          _audioElement.playbackRate = _speed;
          transition(ProcessingStateMessage.ready);
        }.toJS);
    _audioElement.addEventListener(
        'progress',
        (Event event) {
          broadcastPlaybackEvent();
        }.toJS);
  }

  /// The current playback order, depending on whether shuffle mode is enabled.
  List<int> get order {
    final sequence = _audioSourcePlayer!.sequence;
    return _shuffleModeEnabled
        ? _audioSourcePlayer!.shuffleIndices
        : List.generate(sequence.length, (i) => i);
  }

  /// gets the inverted order for the given order.
  List<int> getInv(List<int> order) {
    final orderInv = List<int>.filled(order.length, 0);
    for (var i = 0; i < order.length; i++) {
      orderInv[order[i]] = i;
    }
    return orderInv;
  }

  /// Called when playback reaches the end of an item.
  Future<void> onEnded() async {
    if (_loopMode == LoopModeMessage.one) {
      await _seek(0, null);
      _play();
    } else {
      final order = this.order;
      final orderInv = getInv(order);
      if (orderInv[_index!] + 1 < order.length) {
        // move to next item
        _index = order[orderInv[_index!] + 1];
        await _currentAudioSourcePlayer!.load();
        // Should always be true...
        if (_playing) {
          _play();
        }
      } else {
        // reached end of playlist
        if (_loopMode == LoopModeMessage.all) {
          // Loop back to the beginning
          if (order.length == 1) {
            await _seek(0, null);
            _play();
          } else {
            _index = order[0];
            await _currentAudioSourcePlayer!.load();
            // Should always be true...
            if (_playing) {
              _play();
            }
          }
        } else {
          await _currentAudioSourcePlayer?.pause();
          transition(ProcessingStateMessage.completed);
        }
      }
    }
  }

  // TODO: Improve efficiency.
  IndexedAudioSourcePlayer? get _currentAudioSourcePlayer =>
      _audioSourcePlayer != null &&
              _index != null &&
              _audioSourcePlayer!.sequence.isNotEmpty &&
              _index! < _audioSourcePlayer!.sequence.length
          ? _audioSourcePlayer!.sequence[_index!]
          : null;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataEventController.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _currentAudioSourcePlayer?.pause();
    _audioSourcePlayer = getAudioSource(request.audioSourceMessage);
    _index = request.initialIndex ?? 0;
    final duration = await _currentAudioSourcePlayer!
        .load(request.initialPosition?.inMilliseconds);
    if (request.initialPosition != null) {
      await _currentAudioSourcePlayer!
          .seek(request.initialPosition!.inMilliseconds);
    }
    if (_playing) {
      _currentAudioSourcePlayer!.play();
    }
    return LoadResponse(duration: duration);
  }

  /// Loads audio from [uri] and returns the duration of the loaded audio if
  /// known.
  Future<Duration?> loadUri(
      final Uri uri, final Duration? initialPosition) async {
    transition(ProcessingStateMessage.loading);
    final src = uri.toString();
    if (src != _audioElement.src) {
      _durationCompleter = Completer<dynamic>();
      _audioElement.src = src;
      _applyPreservesPitchFor(_speed); // GuidePilot patch: Safari resets the flag on src change
      _audioElement.playbackRate = _speed;
      _audioElement.preload = 'auto';
      await _audioElementQueue.load();
      if (initialPosition != null) {
        _audioElement.currentTime = initialPosition.inMilliseconds / 1000.0;
      }
      try {
        await _durationCompleter!.future;
      } on MediaError catch (e) {
        throw PlatformException(
            code: "${e.code}", message: "Failed to load URL");
      } finally {
        _durationCompleter = null;
      }
    }
    transition(ProcessingStateMessage.ready);
    final seconds = _audioElement.duration;
    return seconds.isFinite
        ? Duration(milliseconds: (seconds * 1000).toInt())
        : null;
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_playing) return PlayResponse();
    _playing = true;
    await _play();
    return PlayResponse();
  }

  Future<void> _play() async {
    await _currentAudioSourcePlayer?.play();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_playing) return PauseResponse();
    _playing = false;
    _currentAudioSourcePlayer?.pause();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    _audioElement.volume = request.volume;
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    _applyPreservesPitchFor(request.speed); // GuidePilot patch: scope flag to the requested rate
    _audioElement.playbackRate = _speed = request.speed;
    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loopMode = request.loopMode;
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    _shuffleModeEnabled = request.shuffleMode == ShuffleModeMessage.all;
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
      SetShuffleOrderRequest request) async {
    void internalSetShuffleOrder(AudioSourceMessage sourceMessage) {
      final audioSourcePlayer = _audioSourcePlayers[sourceMessage.id];
      if (audioSourcePlayer == null) return;
      if (sourceMessage is ConcatenatingAudioSourceMessage &&
          audioSourcePlayer is ConcatenatingAudioSourcePlayer) {
        audioSourcePlayer.setShuffleOrder(sourceMessage.shuffleOrder);
        for (var childMessage in sourceMessage.children) {
          internalSetShuffleOrder(childMessage);
        }
      } else if (sourceMessage is LoopingAudioSourceMessage) {
        internalSetShuffleOrder(sourceMessage.child);
      }
    }

    internalSetShuffleOrder(request.audioSourceMessage);
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
      SetWebCrossOriginRequest request) async {
    _audioElement.crossOrigin = const {
      WebCrossOriginMessage.anonymous: 'anonymous',
      WebCrossOriginMessage.useCredentials: 'use-credentials',
    }[request.crossOrigin];
    return SetWebCrossOriginResponse();
  }

  /// Sets a specific device output id, null for default
  @override
  Future<SetWebSinkIdResponse> setWebSinkId(SetWebSinkIdRequest request) async {
    await _audioElementQueue.setSinkId(request.sinkId);
    return SetWebSinkIdResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    await _seek(request.position?.inMilliseconds ?? 0, request.index);
    return SeekResponse();
  }

  Future<void> _seek(int position, int? newIndex) async {
    var index = newIndex ?? _index;
    if (index != _index) {
      _currentAudioSourcePlayer!.pause();
      _index = index;
      await _currentAudioSourcePlayer!.load(position);
      if (_playing) {
        _currentAudioSourcePlayer!.play();
      }
    } else {
      await _currentAudioSourcePlayer!.seek(position);
    }
  }

  ConcatenatingAudioSourcePlayer? _concatenating(String playerId) =>
      _audioSourcePlayers[playerId] as ConcatenatingAudioSourcePlayer?;

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    final wasNotEmpty = _audioSourcePlayer?.sequence.isNotEmpty ?? false;
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!
        .insertAll(request.index, getAudioSources(request.children));
    if (_index != null && wasNotEmpty && request.index <= _index!) {
      _index = _index! + request.children.length;
    }
    await _currentAudioSourcePlayer!.load();
    broadcastPlaybackEvent();
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    if (_index != null &&
        _index! >= request.startIndex &&
        _index! < request.endIndex &&
        _playing) {
      // Pause if removing current item
      _currentAudioSourcePlayer!.pause();
    }
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!
        .removeRange(request.startIndex, request.endIndex);
    if (_index != null) {
      if (_index! >= request.startIndex && _index! < request.endIndex) {
        // Skip backward if there's nothing after this
        if (request.startIndex >= _audioSourcePlayer!.sequence.length) {
          _index = request.startIndex - 1;
          if (_index! < 0) _index = 0;
        } else {
          _index = request.startIndex;
        }
        // Resume playback at the new item (if it exists)
        if (_currentAudioSourcePlayer != null) {
          await _currentAudioSourcePlayer!.load();
          if (_playing) {
            _currentAudioSourcePlayer!.play();
          }
        }
      } else if (request.endIndex <= _index!) {
        // Reflect that the current item has shifted its position
        _index = _index! - (request.endIndex - request.startIndex);
      }
    }
    broadcastPlaybackEvent();
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) async {
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!.move(request.currentIndex, request.newIndex);
    if (_index != null) {
      if (request.currentIndex == _index) {
        _index = request.newIndex;
      } else if (request.currentIndex < _index! &&
          request.newIndex >= _index!) {
        _index = _index! - 1;
      } else if (request.currentIndex > _index! &&
          request.newIndex <= _index!) {
        _index = _index! + 1;
      }
    }
    broadcastPlaybackEvent();
    return ConcatenatingMoveResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
      SetAndroidAudioAttributesRequest request) async {
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
              request) async {
    return SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  }

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
      SetPreferredPeakBitRateRequest request) async {
    return SetPreferredPeakBitRateResponse();
  }

  @override
  Duration getCurrentPosition() =>
      _currentAudioSourcePlayer?.position ?? Duration.zero;

  @override
  Duration getBufferedPosition() =>
      _currentAudioSourcePlayer?.bufferedPosition ?? Duration.zero;

  @override
  Duration? getDuration() => _currentAudioSourcePlayer?.duration;

  @override
  Future<void> release() async {
    _currentAudioSourcePlayer?.pause();
    await _audioElementQueue.removeAttribute('src');
    await _audioElementQueue.load();
    transition(ProcessingStateMessage.idle);
    return await super.release();
  }

  /// Converts a list of audio source messages to players.
  List<AudioSourcePlayer> getAudioSources(List<AudioSourceMessage> messages) =>
      messages.map((message) => getAudioSource(message)).toList();

  /// Converts an audio source message to a player, using the cache if it is
  /// already cached.
  AudioSourcePlayer getAudioSource(AudioSourceMessage audioSourceMessage) {
    final id = audioSourceMessage.id;
    var audioSourcePlayer = _audioSourcePlayers[id];
    if (audioSourcePlayer == null) {
      audioSourcePlayer = decodeAudioSource(audioSourceMessage);
      _audioSourcePlayers[id] = audioSourcePlayer;
    }
    return audioSourcePlayer;
  }

  /// Converts an audio source message to a player.
  AudioSourcePlayer decodeAudioSource(AudioSourceMessage audioSourceMessage) {
    if (audioSourceMessage is ProgressiveAudioSourceMessage) {
      return ProgressiveAudioSourcePlayer(this, audioSourceMessage.id,
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers);
    } else if (audioSourceMessage is DashAudioSourceMessage) {
      return DashAudioSourcePlayer(this, audioSourceMessage.id,
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers);
    } else if (audioSourceMessage is HlsAudioSourceMessage) {
      return HlsAudioSourcePlayer(this, audioSourceMessage.id,
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers);
    } else if (audioSourceMessage is ConcatenatingAudioSourceMessage) {
      return ConcatenatingAudioSourcePlayer(
          this,
          audioSourceMessage.id,
          getAudioSources(audioSourceMessage.children),
          audioSourceMessage.useLazyPreparation,
          audioSourceMessage.shuffleOrder);
    } else if (audioSourceMessage is ClippingAudioSourceMessage) {
      return ClippingAudioSourcePlayer(
          this,
          audioSourceMessage.id,
          getAudioSource(audioSourceMessage.child) as UriAudioSourcePlayer,
          audioSourceMessage.start,
          audioSourceMessage.end);
    } else if (audioSourceMessage is LoopingAudioSourceMessage) {
      return LoopingAudioSourcePlayer(this, audioSourceMessage.id,
          getAudioSource(audioSourceMessage.child), audioSourceMessage.count);
    } else {
      throw Exception("Unknown AudioSource type: $audioSourceMessage");
    }
  }
}

/// A player for a single audio source.
abstract class AudioSourcePlayer {
  /// The [Html5AudioPlayer] responsible for audio I/O.
  Html5AudioPlayer html5AudioPlayer;

  /// The ID of the underlying audio source.
  final String id;

  AudioSourcePlayer(this.html5AudioPlayer, this.id);

  /// The sequence of players for the indexed items nested in this player.
  List<IndexedAudioSourcePlayer> get sequence;

  /// The order to use over [sequence] when in shuffle mode.
  List<int> get shuffleIndices;
}

/// A player for an [IndexedAudioSourceMessage].
abstract class IndexedAudioSourcePlayer extends AudioSourcePlayer {
  IndexedAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id)
      : super(html5AudioPlayer, id);

  /// Loads the audio for the underlying audio source.
  Future<Duration?> load([int? initialPosition]);

  /// Plays the underlying audio source.
  Future<void> play();

  /// Pauses playback of the underlying audio source.
  Future<void> pause();

  /// Seeks to [position] milliseconds.
  Future<void> seek(int position);

  /// Called when playback reaches the end of the underlying audio source.
  Future<void> complete();

  /// Called when the playback position of the underlying HTML5 player changes.
  Future<void> timeUpdated(double seconds) async {}

  /// The duration of the underlying audio source.
  Duration? get duration;

  /// The current playback position.
  Duration get position;

  /// The current buffered position.
  Duration get bufferedPosition;

  /// The audio element that renders the audio.
  HTMLAudioElement get _audioElement => html5AudioPlayer._audioElement;

  _AudioElementQueue get _audioElementQueue =>
      html5AudioPlayer._audioElementQueue;

  @override
  String toString() => "$runtimeType";
}

/// A player for an [UriAudioSourceMessage].
abstract class UriAudioSourcePlayer extends IndexedAudioSourcePlayer {
  /// The URL to play.
  final Uri uri;

  /// The headers to include in the request (unsupported).
  final Map<String, String>? headers;
  double? _resumePos;
  Duration? _duration;
  Completer<dynamic>? _completer;
  int? _initialPos;

  UriAudioSourcePlayer(
      Html5AudioPlayer html5AudioPlayer, String id, this.uri, this.headers)
      : super(html5AudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];

  @override
  Future<Duration?> load([int? initialPosition]) async {
    _initialPos = initialPosition;
    _resumePos = (initialPosition ?? 0) / 1000.0;
    _duration = await html5AudioPlayer.loadUri(
        uri,
        initialPosition != null
            ? Duration(milliseconds: initialPosition)
            : null);
    _initialPos = null;
    return _duration;
  }

  @override
  Future<void> play() async {
    _audioElement.currentTime = _resumePos!;
    await _audioElementQueue.play();
    _completer = Completer<dynamic>();
    await _completer!.future;
    _completer = null;
  }

  @override
  Future<void> pause() async {
    _resumePos = _audioElement.currentTime as double?;
    _audioElementQueue.pause();
    _interruptPlay();
  }

  @override
  Future<void> seek(int position) async {
    _audioElement.currentTime = _resumePos = position / 1000.0;
  }

  @override
  Future<void> complete() async {
    _interruptPlay();
    await html5AudioPlayer.onEnded().catchError((e, st) {});
  }

  void _interruptPlay() {
    if (_completer?.isCompleted == false) {
      _completer!.complete();
    }
  }

  @override
  Duration? get duration {
    return _duration;
    //final seconds = _audioElement.duration;
    //return seconds.isFinite
    //    ? Duration(milliseconds: (seconds * 1000).toInt())
    //    : null;
  }

  @override
  Duration get position {
    if (_initialPos != null) return Duration(milliseconds: _initialPos!);
    final seconds = _audioElement.currentTime;
    return Duration(milliseconds: (seconds * 1000).toInt());
  }

  @override
  Duration get bufferedPosition {
    if (_audioElement.buffered.length > 0) {
      return Duration(
          milliseconds:
              (_audioElement.buffered.end(_audioElement.buffered.length - 1) *
                      1000)
                  .toInt());
    } else {
      return Duration.zero;
    }
  }
}

/// A player for a [ProgressiveAudioSourceMessage].
class ProgressiveAudioSourcePlayer extends UriAudioSourcePlayer {
  ProgressiveAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id,
      Uri uri, Map<String, String>? headers)
      : super(html5AudioPlayer, id, uri, headers);
}

/// A player for a [DashAudioSourceMessage].
class DashAudioSourcePlayer extends UriAudioSourcePlayer {
  DashAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id, Uri uri,
      Map<String, String>? headers)
      : super(html5AudioPlayer, id, uri, headers);
}

/// A player for a [HlsAudioSourceMessage].
class HlsAudioSourcePlayer extends UriAudioSourcePlayer {
  HlsAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id, Uri uri,
      Map<String, String>? headers)
      : super(html5AudioPlayer, id, uri, headers);
}

/// A player for a [ConcatenatingAudioSourceMessage].
class ConcatenatingAudioSourcePlayer extends AudioSourcePlayer {
  /// The players for each child audio source.
  final List<AudioSourcePlayer> audioSourcePlayers;

  /// Whether audio should be loaded as late as possible. (Currently ignored.)
  final bool useLazyPreparation;
  List<int> _shuffleOrder;

  ConcatenatingAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id,
      this.audioSourcePlayers, this.useLazyPreparation, List<int> shuffleOrder)
      : _shuffleOrder = shuffleOrder,
        super(html5AudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence =>
      audioSourcePlayers.expand((p) => p.sequence).toList();

  @override
  List<int> get shuffleIndices {
    final order = <int>[];
    var offset = order.length;
    final childOrders = <List<int>>[];
    for (var audioSourcePlayer in audioSourcePlayers) {
      final childShuffleIndices = audioSourcePlayer.shuffleIndices;
      childOrders.add(childShuffleIndices.map((i) => i + offset).toList());
      offset += childShuffleIndices.length;
    }
    for (var i = 0; i < childOrders.length; i++) {
      order.addAll(childOrders[_shuffleOrder[i]]);
    }
    return order;
  }

  /// Sets the current shuffle order.
  void setShuffleOrder(List<int> shuffleOrder) {
    _shuffleOrder = shuffleOrder;
  }

  /// Inserts [players] into this player at position [index].
  void insertAll(int index, List<AudioSourcePlayer> players) {
    audioSourcePlayers.insertAll(index, players);
    for (var i = 0; i < audioSourcePlayers.length; i++) {
      if (_shuffleOrder[i] >= index) {
        _shuffleOrder[i] += players.length;
      }
    }
  }

  /// Removes the child players in the specified range.
  void removeRange(int start, int end) {
    audioSourcePlayers.removeRange(start, end);
    for (var i = 0; i < audioSourcePlayers.length; i++) {
      if (_shuffleOrder[i] >= end) {
        _shuffleOrder[i] -= (end - start);
      }
    }
  }

  /// Moves a child player from [currentIndex] to [newIndex].
  void move(int currentIndex, int newIndex) {
    audioSourcePlayers.insert(
        newIndex, audioSourcePlayers.removeAt(currentIndex));
  }
}

/// A player for a [ClippingAudioSourceMessage].
class ClippingAudioSourcePlayer extends IndexedAudioSourcePlayer {
  final UriAudioSourcePlayer audioSourcePlayer;
  final Duration? start;
  final Duration? end;
  Completer<ClipInterruptReason>? _completer;
  double? _resumePos;
  Duration? _duration;
  int? _initialPos;

  ClippingAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id,
      this.audioSourcePlayer, this.start, this.end)
      : super(html5AudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];

  Duration get effectiveStart => start ?? Duration.zero;

  @override
  Future<Duration?> load([int? initialPosition]) async {
    initialPosition ??= 0;
    _initialPos = initialPosition;
    final absoluteInitialPosition =
        effectiveStart.inMilliseconds + initialPosition;
    _resumePos = absoluteInitialPosition / 1000.0;
    final fullDuration = (await html5AudioPlayer.loadUri(audioSourcePlayer.uri,
        Duration(milliseconds: absoluteInitialPosition)));
    _initialPos = null;
    if (fullDuration != null) {
      _duration = Duration(
          milliseconds: min((end ?? fullDuration).inMilliseconds,
                  fullDuration.inMilliseconds) -
              effectiveStart.inMilliseconds);
    } else if (end != null) {
      _duration = Duration(
          milliseconds: end!.inMilliseconds - effectiveStart.inMilliseconds);
    }
    return _duration;
  }

  double get remaining =>
      end!.inMilliseconds / 1000 - _audioElement.currentTime;

  @override
  Future<void> play() async {
    if (_completer != null) return;
    _completer = Completer<ClipInterruptReason>();
    _audioElement.currentTime = _resumePos!;
    await _audioElementQueue.play();
    ClipInterruptReason reason;
    while ((reason = await _completer!.future) == ClipInterruptReason.seek) {
      _completer = Completer<ClipInterruptReason>();
    }
    if (reason == ClipInterruptReason.end) {
      await html5AudioPlayer.onEnded().catchError((e, st) {});
    }
    _completer = null;
  }

  @override
  Future<void> pause() async {
    _interruptPlay(ClipInterruptReason.pause);
    _resumePos = _audioElement.currentTime as double?;
    _audioElementQueue.pause();
  }

  @override
  Future<void> seek(int position) async {
    _interruptPlay(ClipInterruptReason.seek);
    _audioElement.currentTime =
        _resumePos = effectiveStart.inMilliseconds / 1000.0 + position / 1000.0;
  }

  @override
  Future<void> complete() async {
    _interruptPlay(ClipInterruptReason.end);
  }

  @override
  Future<void> timeUpdated(double seconds) async {
    if (end != null) {
      if (seconds >= end!.inMilliseconds / 1000) {
        _interruptPlay(ClipInterruptReason.end);
      }
    }
  }

  @override
  Duration? get duration {
    return _duration;
  }

  @override
  Duration get position {
    if (_initialPos != null) return Duration(milliseconds: _initialPos!);
    final seconds = _audioElement.currentTime;
    var position = Duration(milliseconds: (seconds * 1000).toInt());
    position -= effectiveStart;
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    return position;
  }

  @override
  Duration get bufferedPosition {
    if (_audioElement.buffered.length > 0) {
      var seconds =
          _audioElement.buffered.end(_audioElement.buffered.length - 1);
      var position = Duration(milliseconds: (seconds * 1000).toInt());
      position -= effectiveStart;
      if (position < Duration.zero) {
        position = Duration.zero;
      }
      if (duration != null && position > duration!) {
        position = duration!;
      }
      return position;
    } else {
      return Duration.zero;
    }
  }

  void _interruptPlay(ClipInterruptReason reason) {
    if (_completer?.isCompleted == false) {
      _completer!.complete(reason);
    }
  }
}

/// Reasons why playback of a clipping audio source may be interrupted.
enum ClipInterruptReason { end, pause, seek }

/// A player for a [LoopingAudioSourceMessage].
class LoopingAudioSourcePlayer extends AudioSourcePlayer {
  /// The child audio source player to loop.
  final AudioSourcePlayer audioSourcePlayer;

  /// The number of times to loop.
  final int count;

  LoopingAudioSourcePlayer(Html5AudioPlayer html5AudioPlayer, String id,
      this.audioSourcePlayer, this.count)
      : super(html5AudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence =>
      List.generate(count, (i) => audioSourcePlayer)
          .expand((p) => p.sequence)
          .toList();

  @override
  List<int> get shuffleIndices {
    final order = <int>[];
    var offset = order.length;
    for (var i = 0; i < count; i++) {
      final childShuffleOrder = audioSourcePlayer.shuffleIndices;
      order.addAll(childShuffleOrder.map((i) => i + offset).toList());
      offset += childShuffleOrder.length;
    }
    return order;
  }
}

class _AudioElementQueue {
  final _lock = synch.Lock();
  final HTMLAudioElement audioElement;

  _AudioElementQueue(this.audioElement);

  Future<void> pause() {
    return _lock.synchronized(() => audioElement.pause());
  }

  Future<JSAny?> play() {
    return _lock.synchronized(() => audioElement.play().toDart);
  }

  Future<void> load() {
    return _lock.synchronized(() => audioElement.load());
  }

  Future<void> removeAttribute(String qualifiedName) {
    return _lock
        .synchronized(() => audioElement.removeAttribute(qualifiedName));
  }

  Future<JSAny?> setSinkId(String sinkId) {
    return _lock.synchronized(() => audioElement.setSinkId(sinkId).toDart);
  }
}
