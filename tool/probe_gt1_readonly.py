"""Bounded GT1 GET-only probe. No subscription, ACK, WRITE, reset or BOOT."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
import sys
import time


def worker(output):
    import mido
    report = {'started': datetime.now().astimezone().isoformat(), 'queries': []}
    def save():
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    if output.exists():
        raise RuntimeError('Refusing to overwrite evidence')
    save()
    try:
        inputs = [n for n in mido.get_input_names() if n.startswith('SINCO-MIDI ')]
        outputs = [n for n in mido.get_output_names() if n.startswith('SINCO-MIDI ')]
        report.update(inputs=inputs, outputs=outputs)
        if len(inputs) != 1 or len(outputs) != 1:
            raise RuntimeError('Expected exactly one directly connected SINCO-MIDI input/output')
        with mido.open_input(inputs[0]) as incoming, mido.open_output(outputs[0]) as outgoing:
            for component, selector in [(9, 0x22), (9, 0x40), (9, 0x22)]:
                list(incoming.iter_pending())
                body = [0, 0x59, 1, component, 1, selector]
                checksum = 0
                for byte in body:
                    checksum ^= byte
                item = {'time': datetime.now().astimezone().isoformat(), 'tx': [0xf0, *body, checksum, 0xf7]}
                report['queries'].append(item)
                save()
                outgoing.send(mido.Message('sysex', data=body + [checksum]))
                start = time.monotonic()
                while time.monotonic() - start < 2:
                    for message in incoming.iter_pending():
                        if message.type != 'sysex':
                            continue
                        data = list(message.data)
                        if len(data) >= 8 and data[:6] == body:
                            check = 0
                            for byte in data[:-1]:
                                check ^= byte
                            item.update(rx=[0xf0,*data,0xf7], checksum_ok=check == data[-1],
                                        error=data[6], elapsed_ms=round((time.monotonic()-start)*1000))
                            break
                    if 'rx' in item:
                        break
                    time.sleep(.01)
                if 'rx' not in item:
                    item['timeout'] = True
                print(json.dumps(item), flush=True)
                save()
    except Exception as error:
        report['error'] = repr(error)
        print(report['error'], flush=True)
    finally:
        report['finished'] = datetime.now().astimezone().isoformat()
        save()
    return 0 if len(report['queries']) == 3 and all(q.get('checksum_ok') and q.get('error') == 0 for q in report['queries']) else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    args = parser.parse_args()
    if args.worker:
        raise SystemExit(worker(args.output))
    try:
        raise SystemExit(subprocess.run([sys.executable, '-X', 'utf8', '-u', __file__,
            '--worker', '--output', str(args.output)], timeout=15).returncode)
    except subprocess.TimeoutExpired:
        print('Probe process timed out; only its child was terminated.', flush=True)
        raise SystemExit(2)
