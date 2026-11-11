#!/usr/bin/env python3
"""Validate the pinned Apple toolchain, then optionally execute a build command."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def validate(expected):
    xcode = output("xcodebuild", "-version")
    swift = output("xcrun", "swift", "--version")
    actual = {
        "xcodeVersion": re.search(r"^Xcode (\S+)$", xcode, re.M)[1],
        "xcodeBuild": re.search(r"^Build version (\S+)$", xcode, re.M)[1],
        "swiftVersion": re.search(r"Apple Swift version (\S+)", swift)[1],
        "swiftBuild": re.search(r"\((swiftlang-\S+)", swift)[1],
        "macOSSDKVersion": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "macOSSDKBuild": output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
    }
    differences = [
        f"{key}: expected {value}, found {actual[key]}"
        for key, value in expected.items() if actual[key] != value
    ]
    if differences:
        raise ValueError("Toolchain mismatch; select the pinned Xcode. " + "; ".join(differences))
    return actual


def validate_selection(developer):
    default_swift = (Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc").resolve()
    selected_swift = Path(output("xcrun", "--find", "swiftc")).resolve()
    if selected_swift != default_swift:
        raise ValueError("The selected Swift compiler must belong to the pinned Xcode default toolchain.")
    override = os.environ.get("SWIFT_EXEC")
    if override and Path(override).resolve() != default_swift:
        raise ValueError("SWIFT_EXEC must use the pinned Xcode default Swift compiler.")


def main():
    root = Path(__file__).resolve().parent.parent
    expected = json.loads((root / "build-toolchain.json").read_text())
    try:
        # Select tools from the active Xcode, never a different `swift` on PATH.
        developer = output("xcode-select", "-p") if not os.environ.get("DEVELOPER_DIR") else os.environ["DEVELOPER_DIR"]
        os.environ["DEVELOPER_DIR"] = developer
        os.environ["PATH"] = os.pathsep.join([
            str(Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin"),
            str(Path(developer) / "usr/bin"), os.environ.get("PATH", ""),
        ])
        # Xcode includes its Metal toolchain alongside XcodeDefault in TOOLCHAINS.
        # Check the actual selected Swift executable, not the toolchain list.
        validate_selection(developer)
        if os.environ.get("SDKROOT") and Path(os.environ["SDKROOT"]).resolve() != Path(output("xcrun", "--sdk", "macosx", "--show-sdk-path")).resolve():
            raise ValueError("SDKROOT must match the pinned Xcode macOS SDK.")
        actual = validate(expected)
    except (ValueError, TypeError, subprocess.CalledProcessError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Build toolchain: " + json.dumps(actual, sort_keys=True), flush=True)
    arguments = sys.argv[1:]
    if not arguments or arguments == ["--check"]:
        return 0
    if arguments[0] == "--":
        arguments = arguments[1:]
    if not arguments:
        return 0
    os.execvpe(arguments[0], arguments, os.environ)


if __name__ == "__main__":
    sys.exit(main())
