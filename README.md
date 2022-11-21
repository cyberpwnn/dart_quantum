Synchronize a firestore document efficiently with json patching while decoupling the state updates from doc updates.

## Features
Decouples the document stream updates from the state updates. Essentially when you push data to a quantum unit, it will instantly push it through to the stream you are listening to, and eventually pushing that back to the actual document. It will also receive from the firestore stream applying changes to your unit and will push it to the stream you are listening to also.

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:quantum/quantum.dart';

class MyQuantumWidget extends StatefulWidget {
  const MyQuantumWidget({Key? key}) : super(key: key);

  @override
  State<MyQuantumWidget> createState() => _MyQuantumWidgetState();
}

class _MyQuantumWidgetState extends State<MyQuantumWidget> {
  late QuantumUnit<SerializableJsonObject> _unit;

  @override
  void initState() {
    _unit = QuantumUnit(
        document: FirebaseFirestore.instance.doc("the_document"),
        deserializer: (json) => SerializableJsonObject.fromJson(json),
        serializer: (o) => o.toJson());
    super.initState();
  }

  @override
  void dispose() {
    _unit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<SerializableJsonObject>(
    stream: _unit.stream(),
    builder: (context, snap) => snap.hasData
        ? Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("The number is ${snap.data!.number}"),
          TextButton(
            onPressed: () => _unit.pushWith((value) {
              value.number++;
            }),
            child: const Text("Increment"),
          ),
        ],
      ),
    )
        : const Center(
      child: CircularProgressIndicator(),
    ),
  );
}

```