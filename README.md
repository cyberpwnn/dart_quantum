Synchronize a firestore document efficiently with json patching while decoupling the state updates from doc updates.

## Features
Decouples the document stream updates from the state updates. Essentially when you push data to a quantum unit, it will instantly push it through to the stream you are listening to, and eventually pushing that back to the actual document. It will also receive from the firestore stream applying changes to your unit and will push it to the stream you are listening to also.

## Usage

You can also use QuantumBuilders to inline the whole process

```dart
import 'package:flutter/material.dart';
import 'package:quantum/quantum.dart';

class MyScreen extends StatelessWidget {
  const MyScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: QuantumBuilder(
        document: FirebaseFirestore.instance.doc("adocument"),
        deserializer: (json) => MyData.fromJson(json),
        serializer: (myData) => myData.toJson(),
        builder: (context, controller, data) => Center(child: TextButton(
          child: Text("Clicked: ${data.clicks}"),
          onPressed: () => controller.pushWith((data) => data.clicks++),
        ))),
  );
}
```

A more in depth process manages the quantum controller in the state.

```dart
import 'package:flutter/material.dart';
import 'package:quantum/quantum.dart';

class MyQuantumWidget extends StatefulWidget {
  const MyQuantumWidget({Key? key}) : super(key: key);

  @override
  State<MyQuantumWidget> createState() => _MyQuantumWidgetState();
}

class _MyQuantumWidgetState extends State<MyQuantumWidget> {
  // Create a controller in the init state
  late QuantumController<SerializableJsonObject> _unit;

  @override
  void initState() {
    _unit = QuantumUnit(
        // Specify a doc location
        document: FirebaseFirestore.instance.doc("the_document"),
        // Teach quantum how to handle your data with json
        deserializer: (json) => SerializableJsonObject.fromJson(json),
        serializer: (o) => o.toJson());
    super.initState();
  }

  @override
  void dispose() {
    // Close your controllers!
    _unit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<SerializableJsonObject>(
    // Connect a stream from the controller
    stream: _unit.stream(),
    builder: (context, snap) => snap.hasData
        ? Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The latest data (local or live) is used to build the widget
          Text("The number is ${snap.data!.number}"),
          TextButton(
            // Push a change to the document (eventually) and the stream (instantly)
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