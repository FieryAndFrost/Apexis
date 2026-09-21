import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:win32/win32.dart';
import 'win_mm_api.dart';

const int _done = 1;
const int _bufferCount = 8;
const int _bufferSize = 8192;

class _MidiBuffer {
  _MidiBuffer(int size)
      : data = calloc<BYTE>(size),
        header = calloc<MIDIHDR>() {
    header.ref.lpData = data.cast();
    header.ref.dwBufferLength = size;
  }
  final Pointer<BYTE> data;
  final Pointer<MIDIHDR> header;
  bool prepared = false, submitted = false;
  void release() {
    calloc.free(header);
    calloc.free(data);
  }
}

/// Keep native buffers alive until unprepare succeeds. Consume input buffers
/// in submission order, including across the ring wraparound.
class WindowsMidiDevice extends MidiDevice {
  WindowsMidiDevice(
      String id, String name, this._rx, this._setup, int unusedCallbackAddress,
      {WinMmApi api = const WinMmApi()})
      : _api = api,
        super(id, name, 'native', false);

  final WinMmApi _api;
  final StreamController<MidiPacket> _rx;
  final StreamController<String> _setup;
  final _inputs = <int>[];
  final _outputs = <int>[];
  final _inputBuffers = Queue<_MidiBuffer>();
  final _outputBuffers = <_MidiBuffer>[];
  // Enumeration creates lightweight objects, not leaked native handle cells.
  Pointer<HMIDIIN> _in = nullptr;
  Pointer<IntPtr> _out = nullptr;
  Timer? _timer;
  bool _closing = false;
  String? _lastCleanupError;

  @visibleForTesting
  int get pendingOutputCount => _outputBuffers.length;
  /// Remains true until every driver-owned buffer and native handle is released.
  bool get hasNativeHandles => _in != nullptr || _out != nullptr;

  void _check(int result, String operation) {
    if (result != MMSYSERR_NOERROR) {
      throw StateError('WinMM $operation failed (code $result)');
    }
  }

  void _report(Object error) {
    if (!_rx.isClosed) _rx.addError(error);
  }

  bool connect() {
    if (connected) return true;
    if (_closing || hasNativeHandles) {
      throw StateError('MIDI device is still closing');
    }
    if (_inputs.isEmpty && _outputs.isEmpty) {
      throw StateError('MIDI device has no ports');
    }
    try {
      if (_inputs.isNotEmpty) {
        _in = calloc<HMIDIIN>();
        _check(_api.inputOpen(_in, _inputs.first), 'input open');
        for (var i = 0; i < _bufferCount; i++) {
          final buffer = _MidiBuffer(_bufferSize);
          _inputBuffers.add(buffer);
          _check(_api.inputPrepare(_in.value, buffer.header), 'input prepare');
          buffer.prepared = true;
          _check(_api.inputAdd(_in.value, buffer.header), 'input queue');
        }
        _check(_api.inputStart(_in.value), 'input start');
      }
      if (_outputs.isNotEmpty) {
        _out = calloc<IntPtr>();
        _check(_api.outputOpen(_out, _outputs.first), 'output open');
      }
      connected = true;
      _startTimer();
      if (!_setup.isClosed) _setup.add('deviceConnected');
      return true;
    } catch (_) {
      disconnect();
      rethrow;
    }
  }

  void _startTimer() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 1), (_) => poll());
  }

  @visibleForTesting
  void poll() {
    try {
      if (connected && !_closing && _in != nullptr) {
        for (var n = 0; n < _bufferCount && _inputBuffers.isNotEmpty; n++) {
          final buffer = _inputBuffers.first;
          if (buffer.header.ref.dwFlags & _done == 0) break;
          final length = buffer.header.ref.dwBytesRecorded;
          if (length < 0 || length > _bufferSize) {
            throw StateError('Invalid MIDI input length');
          }
          if (length > 0 && !_rx.isClosed) {
            // ProtocolSession owns SysEx framing, not the transport layer.
            _rx.add(MidiPacket(
                Uint8List.fromList(buffer.data.asTypedList(length)), 0, this));
          }
          // Do not clear MHDR_PREPARED: prepared buffers can be requeued.
          buffer.header.ref.dwBytesRecorded = 0;
          _check(_api.inputAdd(_in.value, buffer.header), 'input requeue');
          _inputBuffers.removeFirst();
          _inputBuffers.addLast(buffer);
        }
      }
      if (_closing) {
        _finishClose();
      } else {
        _releaseOutputs();
      }
    } catch (e) {
      _report(e);
      disconnect();
    }
  }

  void send(Uint8List data) {
    if (!connected || _closing || _out == nullptr || _out.value == 0) {
      throw StateError('MIDI output is not connected');
    }
    if (data.isEmpty) return;
    final buffer = _MidiBuffer(data.length);
    buffer.data.asTypedList(data.length).setAll(0, data);
    try {
      _check(_api.outputPrepare(_out.value, buffer.header), 'output prepare');
      buffer.prepared = true;
      _outputBuffers.add(buffer);
      _check(_api.outputSend(_out.value, buffer.header), 'output send');
      buffer.submitted = true;
      _startTimer();
    } catch (_) {
      if (!buffer.prepared) {
        buffer.release();
      } else {
        _releaseOutputs();
      }
      rethrow;
    }
  }

  void _releaseOutputs() {
    if (_out == nullptr || _out.value == 0) return;
    for (final buffer in List<_MidiBuffer>.of(_outputBuffers)) {
      if (buffer.submitted && buffer.header.ref.dwFlags & _done == 0) continue;
      final result = _api.outputUnprepare(_out.value, buffer.header);
      if (result == MIDIERR_STILLPLAYING) continue;
      _check(result, 'output unprepare');
      _outputBuffers.remove(buffer);
      buffer.release();
    }
  }

  bool disconnect() {
    if (!_closing) {
      _closing = true;
      connected = false;
      // Reset returns pending buffers; never free them on a fixed timeout.
      try {
        if (_in != nullptr && _in.value != 0) {
          _check(_api.inputReset(_in.value), 'input reset');
        }
        if (_out != nullptr && _out.value != 0) {
          _check(_api.outputReset(_out.value), 'output reset');
        }
      } catch (e) {
        _report(e);
      }
    }
    _finishClose();
    if (_closing) _startTimer();
    return true;
  }

  void _finishClose() {
    try {
      for (final buffer in List<_MidiBuffer>.of(_inputBuffers)) {
        if (buffer.prepared) {
          final result = _api.inputUnprepare(_in.value, buffer.header);
          if (result == MIDIERR_STILLPLAYING) continue;
          _check(result, 'input unprepare');
        }
        _inputBuffers.remove(buffer);
        buffer.release();
      }
      _releaseOutputs();
      if (_inputBuffers.isEmpty && _in != nullptr) {
        if (_in.value != 0) _check(_api.inputClose(_in.value), 'input close');
        calloc.free(_in);
        _in = nullptr;
      }
      if (_outputBuffers.isEmpty && _out != nullptr) {
        if (_out.value != 0) {
          _check(_api.outputClose(_out.value), 'output close');
        }
        calloc.free(_out);
        _out = nullptr;
      }
      if (!hasNativeHandles) {
        _timer?.cancel();
        _timer = null;
        _closing = false;
        _lastCleanupError = null;
      }
    } catch (e) {
      // Retain driver-owned memory and retry. Do not turn an API failure into
      // use-after-free, and do not flood the error stream every millisecond.
      if (_lastCleanupError != e.toString()) {
        _lastCleanupError = e.toString();
        _report(e);
      }
    }
  }

  void addInput(int index, MIDIINCAPS caps) {
    addInputPort(index, caps.wPid);
  }

  void addInputPort(int index, int portId) {
    _inputs.add(index);
    inputPorts.add(MidiPort(portId, MidiPortType.IN));
  }

  void addOutput(int index, MIDIOUTCAPS caps) {
    addOutputPort(index, caps.wPid);
  }

  void addOutputPort(int index, int portId) {
    _outputs.add(index);
    outputPorts.add(MidiPort(portId, MidiPortType.OUT));
  }

  bool containsMidiIn(int handle) => _in != nullptr && _in.value == handle;
  void handleData(Uint8List data, int timestamp) {
    if (!_rx.isClosed) _rx.add(MidiPacket(data, timestamp, this));
  }

  void handleSysexData(Uint8List data, Pointer<MIDIHDR> header) =>
      handleData(data, 0);
}
