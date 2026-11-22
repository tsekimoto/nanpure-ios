#!/usr/bin/env python3
"""Inspect the app executable, excluding third-party framework diagnostics."""
from pathlib import Path
import json
import plistlib
import sys


def check_release_app(app):
    app = Path(app)
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable:
        raise ValueError("Invalid executable name")
    binary = (app / executable).read_bytes()
    required = (
        b"ca-app-pub-7659346445516782/8870201118",
        b"ca-app-pub-7659346445516782/4139518536",
    )
    forbidden = (
        b"ca-app-pub-3940256099942544/2435281174",
        b"ca-app-pub-3940256099942544/1712485313",
        b"Ad: build=",
        b"NANPURE_DIAGNOSTICS",
        b"Rewarded ad failed to load:",
        b"Banner ad failed to load:",
    )
    if any(value not in binary for value in required):
        raise ValueError("Release app is missing its production ad units")
    if any(value in binary for value in forbidden):
        raise ValueError("Release app contains demo ad units or development diagnostics")
    if info.get("GADApplicationIdentifier") != "ca-app-pub-7659346445516782~6278596713":
        raise ValueError("Unexpected AdMob application identifier")


def print_privacy_manifests(app):
    """Static SDK declarations only; no runtime logs or user data."""
    app = Path(app)
    for manifest in sorted(app.rglob("PrivacyInfo.xcprivacy")):
        try:
            with manifest.open("rb") as stream:
                data = plistlib.load(stream)
            summary = {
                "bundle": str(manifest.parent.relative_to(app)),
                "NSPrivacyTracking": data.get("NSPrivacyTracking"),
                "NSPrivacyCollectedDataTypes": data.get("NSPrivacyCollectedDataTypes", []),
                "NSPrivacyAccessedAPITypes": data.get("NSPrivacyAccessedAPITypes", []),
            }
            print("SDK privacy manifest: " + json.dumps(summary, sort_keys=True))
        except (OSError, ValueError, plistlib.InvalidFileException):
            print("SDK privacy manifest: could not read " + str(manifest.relative_to(app)))


if __name__ == "__main__":
    check_release_app(sys.argv[1])
    print("Release app: production ads configured; development diagnostics absent")
    print_privacy_manifests(sys.argv[1])
