library quantum;

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fast_log/fast_log.dart';
import 'package:flutter/foundation.dart';
import 'package:jpatch/jpatch.dart';
import 'package:throttled/throttled.dart';

typedef Deserializer<T> = T Function(Map<String, dynamic>? value);
typedef Serializer<T> = Map<String, dynamic> Function(T? value);

Future<void> patchDocument(DocumentReference<Map<String, dynamic>> document,
    Map<String, dynamic> original, Map<String, dynamic> altered) async {
  Map<String, dynamic> before = flatMap(original);
  Map<String, dynamic> after = flatMap(altered);
  Map<String, dynamic> diff = <String, dynamic>{};
  Set<String> removalCheck = <String>{};
  double keyCount = max(before.length, after.length).toDouble();
  before.forEach((key, value) {
    if (after.containsKey(key)) {
      if (!eq(value, after[key])) {
        diff[key] = after[key];
        verbose("[Patch]: Modified Field $key $value => ${after[key]}");
      }
    } else {
      diff[key] = FieldValue.delete();
      verbose("[Patch]: Removed Field $key");
      List<String> k = key.split(".");
      k.removeLast();
      removalCheck.add(k.join("."));
    }
  });

  for (final key in removalCheck) {
    if (after.keys.where((element) => element.startsWith("$key.")).isEmpty) {
      verbose("[Patch]: Removed Field Group $key");
      diff.removeWhere((kkey, value) {
        if (value == FieldValue.delete() && kkey.startsWith("$key.")) {
          verbose("[Patch]: -- Caused by Removing Field $kkey");
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
      verbose("[Patch]: Added Field $key $value");
    }
  });

  if (diff.isNotEmpty) {
    diff.removeWhere((key, value) => key.trim().isEmpty);

    double len = diff.length.toDouble();
    double percent = ((len / keyCount) * 100);
    actioned(
        "[Patch]: Pushed Document with ${(100.0 - percent).toStringAsFixed(0)}% efficiency (${diff.length} / ${keyCount.toInt()})");

    return document.update(diff);
  }
}

class QuantumUnit<T> {
  final DocumentReference<Map<String, dynamic>> document;
  final Deserializer<T> deserializer;
  final Serializer<T> serializer;
  final Duration phasingDuration;
  final Duration feedbackDuration;
  T? _latest;
  Map<String, dynamic>? _lastLive;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;
  StreamController<T>? _controller;
  bool _mirroring = false;

  QuantumUnit(
      {required this.document,
      required this.deserializer,
      required this.serializer,
      this.phasingDuration = const Duration(milliseconds: 1000),
      this.feedbackDuration = const Duration(milliseconds: 100)});

  Future<void> pushWith(ValueChanged<T> callback, {bool force = false}) {
    if (!hasLatest()) {
      warn(
          "Skipping push due to quantum session unit not ready yet. Next push will have these changes.");
      return Future.value();
    }

    callback(_latest!);
    return push(_latest!, force: force);
  }

  Future<void> push(T t, {bool force = false}) {
    Completer<void> completer = Completer();

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

  T getLatest() => _latest!;

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

  Future<void> _pushFull(T t) {
    if (_lastLive != null) {
      return patchDocument(document, _lastLive!, serializer(t));
    } else {
      warn("No last live data yet for ${document.path}");
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
    _controller = StreamController.broadcast();
    _subscription = document.snapshots().listen((event) {
      if (_mirroring && event.exists) {
        _lastLive = event.data();
        T t = deserializer(event.data());
        _controller?.sink.add(t);
        _latest = t;
      }
    });
  }
}
