import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch


SCRIPT_ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("build_toolchain", SCRIPT_ROOT / "build-toolchain.py")
TOOLCHAIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOLCHAIN)
PIN = json.loads((SCRIPT_ROOT.parent / "build-toolchain.json").read_text())


class BuildToolchainTests(unittest.TestCase):
    def validate(self, **overrides):
        values = {**PIN, **overrides}
        results = [
            f"Xcode {values['xcodeVersion']}\nBuild version {values['xcodeBuild']}",
            f"Apple Swift version {values['swiftVersion']} ({values['swiftBuild']} clang-2100.3.34.1)",
            values["macOSSDKVersion"], values["macOSSDKBuild"],
        ]
        with patch.object(TOOLCHAIN, "output", side_effect=results):
            return TOOLCHAIN.validate(PIN)

    def test_exact_toolchain_is_accepted(self):
        self.assertEqual(self.validate(), PIN)

    def test_older_release_compiler_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "xcodeVersion.*swiftVersion"):
            self.validate(xcodeVersion="26.3", swiftVersion="6.2")

    def test_different_compiler_build_in_same_swift_release_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "swiftBuild"):
            self.validate(swiftBuild="swiftlang-6.4.0.1.1")

    def test_different_xcode_build_in_same_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "xcodeBuild"):
            self.validate(xcodeBuild="27A0000")

    def test_different_sdk_build_in_same_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "macOSSDKBuild"):
            self.validate(macOSSDKBuild="26A000")

    def test_xcode_metal_and_default_toolchain_combination_is_accepted(self):
        developer = "/Applications/Xcode.app/Contents/Developer"
        swift = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        with patch.dict(os.environ, {"TOOLCHAINS": "com.apple.dt.toolchain.Metal.32023.921.5 com.apple.dt.toolchain.XcodeDefault", "SWIFT_EXEC": swift}):
            with patch.object(TOOLCHAIN, "output", return_value=swift):
                TOOLCHAIN.validate_selection(developer)

    def test_swift_selected_from_a_different_toolchain_is_rejected(self):
        with patch.object(TOOLCHAIN, "output", return_value="/Library/Developer/Toolchains/custom/usr/bin/swiftc"):
            with self.assertRaisesRegex(ValueError, "selected Swift compiler"):
                TOOLCHAIN.validate_selection("/Applications/Xcode.app/Contents/Developer")

    def test_xcode_swift_exec_override_is_rejected(self):
        developer = "/Applications/Xcode.app/Contents/Developer"
        swift = developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        with patch.dict(os.environ, {"SWIFT_EXEC": "/tmp/custom-swiftc"}):
            with patch.object(TOOLCHAIN, "output", return_value=swift):
                with self.assertRaisesRegex(ValueError, "SWIFT_EXEC"):
                    TOOLCHAIN.validate_selection(developer)


if __name__ == "__main__":
    unittest.main()
