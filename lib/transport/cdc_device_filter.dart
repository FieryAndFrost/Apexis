/// Trial firmware: VID 3654, PID 4B55 = SDK base 4155 + audio(2+3)
/// + CDC(5) in the high PID byte. Interface 03 is the CDC ACM function.
/// Never open arbitrary COM ports (in particular the DEBUG board).
bool isGt1CdcHardwareId(String value) => RegExp(
  r'^USB\\VID_3654&PID_4B55(?:&REV_[0-9A-F]{4})?&MI_03(?:\x00|$)',
  caseSensitive: false,
).hasMatch(value);

String? cdcPortFromName(String value) => RegExp(
  r'\((COM[0-9]+)\)$',
  caseSensitive: false,
).firstMatch(value)?.group(1)?.toUpperCase();
