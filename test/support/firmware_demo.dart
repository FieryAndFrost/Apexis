import 'package:apexis/protocol/codec.dart';
import 'package:apexis/transport/demo_transport.dart';

class FirmwareDemo extends DemoTransport {
  FirmwareDemo(this.firmwarePatch);
  final int firmwarePatch;
  bool rejectDrum = false, cue = false;
  int drumQueries = 0;
  @override
  void emitFrame(List<int> frame) {
    final m = Message.parse(frame);
    var data = m.data.toList();
    if (m.component == 9 && m.command == 1 && m.selector == 0x22) {
      data.setRange(7, 9, Gt1.u14(firmwarePatch));
    } else if (m.component == 0 &&
        m.command == 1 &&
        m.selector == 0x23 &&
        data.length > 5) {
      for (var at = 4; at < data.length;) {
        data[at] = 1;
        at += 2 + data[at + 1];
      }
    } else if (m.component == 3 && m.command == 1) {
      drumQueries++;
      if (rejectDrum) {
        super.emitFrame(Gt1.frame(m.component, m.command, m.selector, [], 1));
        return;
      }
    } else if (cue &&
        m.component == 4 &&
        m.command == 1 &&
        m.selector == 0x21) {
      data = [
        1,
        0,
        64,
        2,
        ...Gt1.u32(17),
        ...Gt1.u32(0),
        ...Gt1.u32(0),
        ...Gt1.u32(30000000),
      ];
    }
    super.emitFrame(
      Gt1.frame(m.component, m.command, m.selector, data, m.error),
    );
  }

  @override
  Future<void> send(frame) async {
    final m = Message.parse(frame, response: false);
    if (cue && m.component == 4 && m.command == 1 && m.selector == 0x24) {
      emitFrame(Gt1.frame(4, 1, 0x24, [1, 1, ...Gt1.u32(1200000)], 0));
      return;
    }
    await super.send(frame);
  }
}
