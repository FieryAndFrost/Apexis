import 'dart:ffi';
import 'package:win32/win32.dart';

/// Injectable boundary: regression tests never open real MIDI devices.
class WinMmApi {
  const WinMmApi();
  int inputOpen(Pointer<HMIDIIN> h, int index) =>
      midiInOpen(h, index, 0, 0, CALLBACK_NULL);
  int outputOpen(Pointer<IntPtr> h, int index) =>
      midiOutOpen(h, index, 0, 0, CALLBACK_NULL);
  int inputPrepare(int h, Pointer<MIDIHDR> p) =>
      midiInPrepareHeader(h, p, sizeOf<MIDIHDR>());
  int inputAdd(int h, Pointer<MIDIHDR> p) =>
      midiInAddBuffer(h, p, sizeOf<MIDIHDR>());
  int inputStart(int h) => midiInStart(h);
  int inputReset(int h) => midiInReset(h);
  int inputUnprepare(int h, Pointer<MIDIHDR> p) =>
      midiInUnprepareHeader(h, p, sizeOf<MIDIHDR>());
  int inputClose(int h) => midiInClose(h);
  int outputPrepare(int h, Pointer<MIDIHDR> p) =>
      midiOutPrepareHeader(h, p, sizeOf<MIDIHDR>());
  int outputSend(int h, Pointer<MIDIHDR> p) =>
      midiOutLongMsg(h, p, sizeOf<MIDIHDR>());
  int outputReset(int h) => midiOutReset(h);
  int outputUnprepare(int h, Pointer<MIDIHDR> p) =>
      midiOutUnprepareHeader(h, p, sizeOf<MIDIHDR>());
  int outputClose(int h) => midiOutClose(h);
}
