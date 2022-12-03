Synchronize a firestore document efficiently with json patching while decoupling the state updates from doc updates.

## The Problem
Have you ever been in a situation where you needed to sync a firebase document live but also write to it and ended up just starting with a stream builder on a document which simply writes to the stream? Such as this?

![](https://raw.githubusercontent.com/ArcaneArts/quantum/main/images/A.png)

The problem with this system is that if the interactivity is directly tied into the stream, you may end up writing to a document very quickly where you otherwise really wouldnt need to. For example if you had a switch, you are faced with two options: 
1. Write to the document every time the switch is toggled causing a lot of writes to the document and potentially over the sustained 1/s limit
2. Write to the document with a 1/s throttle to prevent the changes from causing the document to write faster than recommended

![](https://raw.githubusercontent.com/ArcaneArts/quantum/main/images/B.png)

The problem with option two (above image) is that now, if the user makes 2 changes within 1 second, the ui will not update until the second write actually goes through. So to avoid this, one idea is to make the widget stateful and simply set the state and throttle the changes to the server, but this introduces a lot of complexity into a single widget... and thinking of the structuring and abstracting to use this everywhere if it's a large app...

![](https://raw.githubusercontent.com/ArcaneArts/quantum/main/images/C.png)

As you can see this is rather complex. This is where quantum comes in. It achieves the same thing as the image above but with a little more thought and care. All you have to deal with is the quantum controller

![](https://raw.githubusercontent.com/ArcaneArts/quantum/main/images/D.png)

The quantum controller is actually feeding you a merged stream beteween the real data and any local changes you make BEFORE the data has synced back to allow your UI to rebuild when say... a switch is flicked. The throttle is leaky, meaning that even if your last "change" was ignored because it was throttled, it will eventually leak back to the document after the throttle has lifted.

The quantum controller is actually doing this under the hood:

![](https://raw.githubusercontent.com/ArcaneArts/quantum/main/images/E.png)

As you can see we have decoupled the document stream from our data which makes it super easy to use.

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