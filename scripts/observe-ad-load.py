"""Observe the real Google demo-ad callback on a clean Simulator.

Raw device/SDK output stays in memory. Only fixed diagnostic events are printed;
no screenshots, device identifiers, response IDs or credentials are retained.
Network-dependent ad delivery is an observation, not a deterministic unit test.
"""
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import threading
import time


def simctl(*arguments, timeout=120):
    return subprocess.run(
        ["xcrun", "simctl", *arguments], check=True, capture_output=True,
        text=True, timeout=timeout,
    ).stdout


devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
phones = [device for runtime, values in devices.items() if ".iOS-" in runtime
          for device in values if device["name"].startswith("iPhone")]
if not phones:
    raise SystemExit("No available iPhone Simulator")
device = phones[0]
udid = device["udid"]
if device["state"] != "Booted":
    simctl("boot", udid)
simctl("bootstatus", udid, "-b", timeout=180)
app = Path(os.environ["RUNNER_TEMP"]) / "verify-debug/Build/Products/Debug-iphonesimulator/ナンプレ.app"
if not app.is_dir():
    raise SystemExit("Debug Simulator application not found")
simctl("install", udid, str(app))
events = queue.Queue()
pattern = re.compile(r"NANPURE_DIAGNOSTICS (?:web|banner|rewarded)=(?:loaded|failed)(?: domain=[A-Za-z0-9._-]+ code=-?\d+)?")
process = subprocess.Popen(
    ["xcrun", "simctl", "launch", "--terminate-running-process", "--console-pty",
     udid, "io.github.tsekimoto.nanpure"], stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, text=True, errors="replace",
)


def collect():
    for line in process.stdout:
        match = pattern.search(line)
        if match:
            events.put(match.group(0))


threading.Thread(target=collect, daemon=True).start()
observed = set()
deadline = time.monotonic() + 90
try:
    while time.monotonic() < deadline:
        try:
            event = events.get(timeout=min(1, max(0.01, deadline - time.monotonic())))
        except queue.Empty:
            if process.poll() is not None:
                break
            continue
        if event not in observed:
            observed.add(event)
            print(event, flush=True)
        # All three callbacks observed; hidden banners may not complete on home.
        if all(any(f"{kind}=" in event for event in observed)
               for kind in ("web", "banner", "rewarded")):
            break
finally:
    subprocess.run(["xcrun", "simctl", "terminate", udid, "io.github.tsekimoto.nanpure"],
                   capture_output=True, timeout=20)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)

for kind in ("web", "banner", "rewarded"):
    status = "loaded" if f"NANPURE_DIAGNOSTICS {kind}=loaded" in observed else (
        "failed" if any(f"{kind}=failed" in event for event in observed) else "no callback within 90s")
    print(f"Simulator observation: {kind}: {status}")
print("This observation does not establish iPhone ad visibility or offline launch support.")
