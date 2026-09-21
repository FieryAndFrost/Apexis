"""Read DEBUG's existing UART0 control buffer; never configure/power/write GT1."""
import argparse
import base64
from datetime import datetime
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'artifacts/firmware-source/ai_debug/jl_debug/host'))
from jl_debug import open_scsi


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = {'time': datetime.now().astimezone().isoformat(), 'steps': []}
    with args.output.open('x', encoding='utf-8') as output:
        try:
            with open_scsi(timeout_ms=3000) as board:
                def read(command, values=None):
                    reply = board.request(command, values)
                    report['steps'].append({'cmd': command, 'reply': reply})
                    if reply.get('ok') is not True:
                        raise RuntimeError(reply)
                    return reply['result']
                report['status'] = read('system.status')
                report['before'] = read('uart.stats', {'uart': 'UART0'})
                raw = bytearray()
                for _ in range(32):
                    packet = read('uart.read', {'uart': 'UART0', 'max_bytes': 512})
                    data = base64.b64decode(packet['data_base64'], validate=True)
                    raw.extend(data)
                    if not data:
                        break
                report['after'] = read('uart.stats', {'uart': 'UART0'})
                report['bytes'] = len(raw)
                report['text'] = raw.decode('utf-8', errors='replace')
        except Exception as error:
            report['error'] = repr(error)
        finally:
            json.dump(report, output, ensure_ascii=False, indent=2)
        print(json.dumps({k: v for k, v in report.items() if k != 'steps'},
                         ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
