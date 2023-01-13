## 1.1.4

* Support partial json compression with retainers

## 1.1.3

* Bugfixes with json compression

## 1.1.2

* Allows full json compression support using json_compress with thresholding
* Change the compression chunk size 8192 by default
* Change the compression mode between none (default), threshold, or thresholdForceEncode


## 1.1.1

* Allow toggling log types

## 1.1.0

This update has breaking changes. Simply rename your quantum units to QuantumController<T> instead of QuantumUnit<T>.

* Move to controller style
* Handle a situation when pushing a change is received that is not ours.
* Add QuantumStreamBuilders for inlining an existing controller
* Add inline QuantumBuilders for creating a controller on the fly

## 1.0.0

* Initial Release
