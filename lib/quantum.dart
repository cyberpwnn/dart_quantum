library quantum;

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:delayed_progress_indicator/delayed_progress_indicator.dart';
import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';
import 'package:jpatch/jpatch.dart';
import 'package:json_compress/json_compress.dart';
import 'package:throttled/throttled.dart';

typedef Deserializer<T> = T Function(Map<String, dynamic>? value);
typedef Serializer<T> = Map<String, dynamic> Function(T? value);

enum QuantumCompressionMode { none, threshold, thresholdAndForceEncoded }

Future<void> patchDocument(DocumentReference<Map<String, dynamic>> document,
    Map<String, dynamic> original, Map<String, dynamic> altered,
    {bool logPatchDetails = true, bool logPushes = true}) async {
  Map<String, dynamic> before = flatMap(original);
  Map<String, dynamic> after = flatMap(altered);
  Map<String, dynamic> diff = <String, dynamic>{};
  Set<String> removalCheck = <String>{};
  double keyCount = max(before.length, after.length).toDouble();
  before.forEach((key, value) {
    if (after.containsKey(key)) {
      if (!eq(value, after[key])) {
        diff[key] = after[key];
        if (logPatchDetails) {
          verbose("[Quantum]: Modified Field $key $value => ${after[key]}");
        }
      }
    } else {
      diff[key] = FieldValue.delete();
      if (logPatchDetails) {
        verbose("[Quantum]: Removed Field $key");
      }
      List<String> k = key.split(".");
      k.removeLast();
      removalCheck.add(k.join("."));
    }
  });

  for (final key in removalCheck) {
    if (after.keys.where((element) => element.startsWith("$key.")).isEmpty) {
      if (logPatchDetails) {
        verbose("[Quantum]: Removed Field Group $key");
      }
      diff.removeWhere((kkey, value) {
        if (value == FieldValue.delete() && kkey.startsWith("$key.")) {
          if (logPatchDetails) {
            verbose("[Quantum]:  -- Caused by Removing Field $kkey");
          }
          return true;
        }

        return false;
      });
      diff[key] = FieldValue.delete();
    }
  }

  after.forEach((key, value) {
    if (!before.containsKey(key)) {
      diff[key] = value;
      if (logPatchDetails) {
        verbose("[Quantum]: Added Field $key $value");
      }
    }
  });

  if (diff.isNotEmpty) {
    diff.removeWhere((key, value) => key.trim().isEmpty);

    double len = diff.length.toDouble();
    double percent = ((len / keyCount) * 100);
    if (logPushes) {
      actioned(
          "[Quantum]: Pushed Document with ${(100.0 - percent).toStringAsFixed(0)}% efficiency (${diff.length} / ${keyCount.toInt()})");
    }

    return document.update(diff);
  }
}

abstract class QuantumHistory {
  int getLastQuantumPush();

  void setLastQuantumPush(int lastWrite);
}

typedef QuantumBuilderCallback<T> = Widget Function(
    BuildContext context, QuantumController<T> controller, T data);

typedef QuantumLoadingBuilder = Widget Function(BuildContext context);

class QuantumStreamBuilder<T> extends StatelessWidget {
  final QuantumController<T> controller;
  final QuantumBuilderCallback<T> builder;
  final QuantumLoadingBuilder? loadingBuilder;

  const QuantumStreamBuilder({
    Key? key,
    required this.controller,
    required this.builder,
    this.loadingBuilder,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) => StreamBuilder<T>(
      stream: controller.stream(),
      builder: (context, snap) => snap.hasData
          ? builder(context, controller, snap.data as T)
          : loadingBuilder?.call(context) ??
              const Center(
                child: DelayedProgressIndicator(),
              ));
}

class QuantumBuilder<T> extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> document;
  final Deserializer<T> deserializer;
  final Serializer<T> serializer;
  final Duration phasingDuration;
  final Duration feedbackDuration;
  final QuantumBuilderCallback<T> builder;
  final QuantumLoadingBuilder? loadingBuilder;

  const QuantumBuilder(
      {Key? key,
      required this.document,
      required this.deserializer,
      required this.serializer,
      required this.builder,
      this.loadingBuilder,
      this.phasingDuration = const Duration(milliseconds: 1000),
      this.feedbackDuration = const Duration(milliseconds: 100)})
      : super(key: key);

  @override
  State<QuantumBuilder> createState() => _QuantumBuilderState<T>();
}

class _QuantumBuilderState<T> extends State<QuantumBuilder> {
  late QuantumController<T> _controller;

  @override
  void initState() {
    _controller = QuantumController<T>(
        document: widget.document,
        deserializer: widget.deserializer as Deserializer<T>,
        serializer: widget.serializer,
        phasingDuration: widget.phasingDuration,
        feedbackDuration: widget.feedbackDuration);
    _controller.open();
    super.initState();
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => QuantumStreamBuilder<T>(
      controller: _controller,
      builder: widget.builder,
      loadingBuilder: widget.loadingBuilder);
}

class QuantumController<T> {
  final QuantumCompressionMode compressionMode;
  final DocumentReference<Map<String, dynamic>> document;
  final Deserializer<T> deserializer;
  final Serializer<T> serializer;
  final Duration phasingDuration;
  final Duration feedbackDuration;
  final int compressionChunkSize;
  T? _latest;
  Map<String, dynamic>? _lastLive;
  Map<String, dynamic>? _lastLiveBeforePush;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;
  StreamController<T>? _controller;
  bool _mirroring = false;
  int _lastCompletedPushHistory = -1;
  int _lastPushHistory = -1;
  bool logPatchDetails = true;
  bool logPushes = true;
  bool logWarnings = true;

  QuantumController(
      {required this.document,
      required this.deserializer,
      required this.serializer,
      this.compressionChunkSize = 8192,
      this.compressionMode = QuantumCompressionMode.none,
      this.phasingDuration = const Duration(milliseconds: 1000),
      this.feedbackDuration = const Duration(milliseconds: 100)});

  Future<void> pushWith(ValueChanged<T> callback, {bool force = false}) {
    if (!hasLatest()) {
      if (logWarnings) {
        warn(
            "[Quantum]: Skipping push due to quantum session unit not ready yet. Next push will have these changes.");
      }
      return Future.value();
    }

    callback(_latest as T);
    return push(_latest as T, force: force);
  }

  Future<void> push(T t, {bool force = false}) {
    Completer<void> completer = Completer();

    if (t is QuantumHistory) {
      _lastPushHistory = DateTime.now().millisecondsSinceEpoch;
      t.setLastQuantumPush(_lastPushHistory);
    }

    if (force) {
      _pushFull(t);
      completer.complete();
    } else {
      throttle("qu:feedback:${document.path}", () {
        _pushFeedback(t);
        try {
          completer.complete();
        } catch (e) {
          error(e);
        }
      }, leaky: true, cooldown: feedbackDuration);
    }

    return completer.future;
  }

  bool hasLatest() => _latest != null;

  Future<void> waitForFirst() => getLatest().then((value) => Future.value());

  T? getLatestSync() => _latest;

  Future<T> getLatest() =>
      _latest != null ? Future.value(_latest!) : stream().first;

  void _pushFeedback(T t) {
    _pushPartial(t);
    throttle("qu:phasing:${document.path}", () => _pushFull(t),
        leaky: true, cooldown: phasingDuration);
  }

  void _pushPartial(T t) {
    _controller?.sink.add(t);
    _latest = t;
  }

  Stream<T> stream() => _controller!.stream;

  Map<String, dynamic> _decompress(Map<String, dynamic> json) =>
      decompressJson(json);

  Map<String, dynamic> _compress(Map<String, dynamic> json) {
    return compressionMode == QuantumCompressionMode.none
        ? json
        : compressJson(json,
            forceEncode: compressionMode ==
                QuantumCompressionMode.thresholdAndForceEncoded,
            split: compressionChunkSize);
  }

  Future<void> _pushFull(T t) {
    if (_lastLive != null) {
      _lastLiveBeforePush =
          _lastLive!.map((key, value) => MapEntry(key, value));
      return patchDocument(document, _lastLive!, _compress(serializer(t)),
              logPatchDetails: logPatchDetails, logPushes: logPushes)
          .then((value) {
        if (t is QuantumHistory) {
          _lastCompletedPushHistory = t.getLastQuantumPush();
        }
      });
    } else if (logWarnings) {
      warn("[Quantum]: No last live data yet for ${document.path}");
    }

    return Future.value();
  }

  void close() {
    if (_mirroring) {
      removeThrottle("qu:feedback:${document.path}")?.force();
      removeThrottle("qu:phasing:${document.path}")?.force();
      _subscription?.cancel();
      _controller?.close();
      _subscription = null;
      _controller = null;
      _mirroring = false;
    }
  }

  void open() {
    _latest = deserializer({});
    _mirroring = true;
    _controller = StreamController.broadcast(
        onListen: () =>
            getLatest().then((value) => _controller?.sink.add(value)));
    _subscription = document.snapshots().listen((event) {
      if (_mirroring && event.exists) {
        _lastLive = event.data();
        T t = deserializer(_decompress(event.data() ?? {}));
        if (t is QuantumHistory &&
            t.getLastQuantumPush() != _lastPushHistory &&
            t.getLastQuantumPush() != _lastCompletedPushHistory) {
          int ourChange = _lastPushHistory;
          int ourSyncedChange = _lastCompletedPushHistory;
          if (ourChange > ourSyncedChange) {
            if (logWarnings) {
              warn(
                  "[Quantum]: Received a change while pushing... Resolving conflicts with a double diff");
            }
            Map<String, dynamic> theirs = _lastLive!;
            Map<String, dynamic> beforeTheirs = _lastLiveBeforePush ?? {};
            Map<String, dynamic> ourFuture = _compress(serializer(_latest));
            Map<String, JsonPatch> theirDiff = beforeTheirs.diff(theirs);
            Map<String, dynamic> newData = ourFuture.patched(theirDiff);
            removeThrottle("qu:phasing:${document.path}")?.cid = -1;
            _pushFull(deserializer(_decompress(newData ?? {}))).then((value) {
              if (logPatchDetails) {
                success(
                    "[Quantum]: Double Diffed out of an incoming change while writing successfully");
              }
            });
            _latest = t;
            return;
          }
        }

        _controller?.sink.add(t);
        _latest = t;
      }
    });
  }
}
