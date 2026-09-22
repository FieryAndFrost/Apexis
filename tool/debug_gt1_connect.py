"""Connect an explicitly USB-powered GT1 through DEBUG; never enter BOOT/flash."""
import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEBUG = ROOT / "artifacts/firmware-source/ai_debug/jl_debug"
sys.path.insert(0, str(DEBUG / "host"))
from jl_debug import open_scsi


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-usb-powered", action="store_true", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Evidence output must not already exist")
    spec = importlib.util.spec_from_file_location("debug_boot_probe", DEBUG / "tools/target_usb_boot.py")
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    report = {"started": datetime.now().astimezone().isoformat(), "steps": [],
              "target_usb_power_confirmed": True, "boot_requested": False,
              "flash_written": False, "gt1_enumerated": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    save()
    try:
        report["pnp_before"] = probe.pnp()
        with open_scsi(timeout_ms=3000) as board:
            def checked(command, values=None):
                step = {"time": datetime.now().astimezone().isoformat(),
                        "command": command, "args": values or {}}
                report["steps"].append(step)
                save()
                reply = board.request(command, values)
                step["reply"] = reply
                save()
                print(json.dumps(step, ensure_ascii=False), flush=True)
                if reply.get("ok") is not True:
                    raise RuntimeError(f"Command rejected: {command}")
                return reply.get("result", {})

            info = checked("system.info")
            if info.get("chip") != "AC7911B8" or info.get("version") != "010" or info.get("control") != "scsi":
                raise RuntimeError("Unexpected DEBUG identity/version")
            status = checked("system.status")
            health = checked("system.health")
            key = checked("usbkey.status")
            if health.get("session_active") is not False or key.get("active") is not False:
                raise RuntimeError("DEBUG session/USBKEY is active or unknown")
            if status.get("overcurrent") is not False:
                raise RuntimeError("Overcurrent state is not clear")
            if status.get("target_power") is not False or status.get("usb_route") != "disconnect":
                raise RuntimeError("Expected target power OFF and USB disconnected; refusing to disturb existing state")
            checked("usb.route", {"route": "pc"})
            checked("target.power", {"on": True})
            time.sleep(4)
            report["final_status"] = checked("system.status")
            report["final_health"] = checked("system.health")
            if report["final_status"].get("overcurrent") or not report["final_status"].get("target_power"):
                raise RuntimeError("Target did not retain safe power-on state")
            report["pnp_after"] = probe.pnp()
            before_ids = {item["InstanceId"] for item in report["pnp_before"]}
            targets = [item for item in report["pnp_after"]
                       if item["InstanceId"] not in before_ids and probe.usb_root(item)
                       and item["InstanceId"].upper().startswith(("USB\\VID_3654&PID_4D55\\", "USB\\VID_3654&PID_4B55\\", "USB\\VID_3654&PID_4E55\\"))
                       and item.get("Status") == "OK"]
            report["target_devices"] = targets
            report["gt1_enumerated"] = len(targets) == 1
            report["outputs_left"] = "Target powered ON, USB routed to PC; no automatic power-off"
            if not report["gt1_enumerated"]:
                raise RuntimeError("Expected exactly one newly connected GT1 application USB root")
    except Exception as exc:
        report["error"] = repr(exc)
        # Never replay commands or blindly change outputs after uncertain I/O.
        raise
    finally:
        report["finished"] = datetime.now().astimezone().isoformat()
        save()
        print(json.dumps({"report": str(args.output), "gt1_enumerated": report["gt1_enumerated"]}), flush=True)


if __name__ == "__main__":
    main()
