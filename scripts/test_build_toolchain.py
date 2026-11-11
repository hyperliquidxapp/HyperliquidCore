import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main()
