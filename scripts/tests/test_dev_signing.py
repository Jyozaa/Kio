import tempfile
import unittest
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev_signing


FINGERPRINT_A = "0123456789ABCDEF0123456789ABCDEF01234567"
FINGERPRINT_B = "89ABCDEF0123456789ABCDEF0123456789ABCDEF"


class DevSigningTests(unittest.TestCase):
    def test_parse_valid_identities_ignores_invalid_and_summary_lines(self):
        parsed = dev_signing.parse_identities(
            f'  1) {FINGERPRINT_A} "Apple Development: Dev (ABCDE12345)"\n'
            '  2) FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "Not Valid"\n'
            '     1 valid identity found\n'
        )
        self.assertEqual(parsed, [dev_signing.Identity(FINGERPRINT_A, "Apple Development: Dev (ABCDE12345)")])

    def test_explicit_identity_overrides_saved_identity(self):
        identities = [dev_signing.Identity(FINGERPRINT_A, "Apple Development: A (TEAM1)"),
                      dev_signing.Identity(FINGERPRINT_B, "Apple Development: B (TEAM2)")]
        chosen = dev_signing.select_identity(identities, explicit=FINGERPRINT_B, saved=FINGERPRINT_A)
        self.assertEqual(chosen.fingerprint, FINGERPRINT_B)

    def test_saved_choice_precedes_automatic_apple_development_choice(self):
        identities = [dev_signing.Identity(FINGERPRINT_A, "Apple Development: A (TEAM1)"),
                      dev_signing.Identity(FINGERPRINT_B, "Apple Development: B (TEAM2)")]
        chosen = dev_signing.select_identity(identities, saved=FINGERPRINT_B)
        self.assertEqual(chosen.fingerprint, FINGERPRINT_B)

    def test_local_identity_is_preferred_when_apple_identity_is_also_present(self):
        apple = dev_signing.Identity(FINGERPRINT_A, "Apple Development: Dev (ABCDE12345)")
        local = dev_signing.Identity(FINGERPRINT_B, "Kio Local Development")
        self.assertEqual(dev_signing.select_identity([apple, local]), local)

    def test_local_kio_identity_is_fallback(self):
        identity = dev_signing.Identity(FINGERPRINT_A, "Kio Local Development")
        self.assertEqual(dev_signing.select_identity([identity]), identity)

    def test_apple_identities_are_not_automatically_used(self):
        identities = [dev_signing.Identity(FINGERPRINT_A, "Apple Development: A (TEAM1)"),
                      dev_signing.Identity(FINGERPRINT_B, "Apple Development: B (TEAM2)")]
        with self.assertRaisesRegex(dev_signing.IdentityError, "Kio Local Development"):
            dev_signing.select_identity(identities)

    def test_setup_does_not_create_a_certificate_when_no_existing_identity_is_found(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "dev-signing.env"
            with mock.patch.object(dev_signing, "identity_list", return_value=[]), \
                 mock.patch.dict("os.environ", {dev_signing.CONFIG_ENV: str(config), dev_signing.IDENTITY_ENV: ""}):
                with self.assertRaisesRegex(dev_signing.IdentityError, "No certificate or private key was created"):
                    dev_signing.setup(interactive=False)
            self.assertFalse(config.exists())

    def test_unrecognized_saved_identity_is_not_silently_replaced(self):
        identities = [dev_signing.Identity(FINGERPRINT_A, "Apple Development: Dev (TEAM1)")]
        with self.assertRaisesRegex(dev_signing.IdentityError, "was not found"):
            dev_signing.select_identity(identities, saved="DEADBEEF")

    def test_config_parser_does_not_execute_shell_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "executed"
            config = Path(temporary) / "dev-signing.env"
            config.write_text(f"# config\nOTHER=$(touch {marker})\n{dev_signing.IDENTITY_ENV}='{FINGERPRINT_A}'\n", encoding="utf-8")
            self.assertEqual(dev_signing.read_saved_identity(config), FINGERPRINT_A)
            self.assertFalse(marker.exists())

    def test_config_is_written_atomically_with_fingerprint_only_and_private_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / ".config/kio/dev-signing.env"
            dev_signing.save_identity(dev_signing.Identity(FINGERPRINT_A, "Apple Development: Private Name (TEAM)"), config)
            self.assertIn(FINGERPRINT_A, config.read_text(encoding="utf-8"))
            self.assertNotIn("Private Name", config.read_text(encoding="utf-8"))
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_bundle_identity_must_match_new_kio_not_legacy_kio(self):
        dev_signing.verify_bundle_identifier("app.kio.mac")
        with self.assertRaisesRegex(dev_signing.IdentityError, "Refusing to replace"):
            dev_signing.verify_bundle_identifier("local.companion.dev")

    def test_canonical_development_path_is_user_applications(self):
        self.assertEqual(dev_signing.canonical_app_path(Path("/tmp/home")), Path("/tmp/home/Applications/Kio.app"))

    def test_public_build_ignores_a_configured_private_development_identity(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            bin_dir = temp / "bin"
            bin_dir.mkdir()
            log = temp / "commands.log"
            derived = temp / "DerivedData"
            stubs = {
                "xcodebuild": '''#!/bin/bash
printf 'xcodebuild %s\\n' "$*" >> "$KIO_TEST_LOG"
derived=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then derived="$2"; shift 2; else shift; fi
done
app="$derived/Build/Products/${CONFIGURATION:-Release}/Kio.app"
mkdir -p "$app/Contents/Resources/Reel/ffmpeg/bin" "$app/Contents/Resources/Reel/streamlink/python/bin"
for helper in yt-dlp deno ffmpeg/bin/ffmpeg streamlink/python/bin/python3.12; do
  : > "$app/Contents/Resources/Reel/$helper"
  chmod +x "$app/Contents/Resources/Reel/$helper"
done
''',
                "codesign": '''#!/bin/bash
printf 'codesign %s\\n' "$*" >> "$KIO_TEST_LOG"
''',
                "xattr": '''#!/bin/bash
printf 'xattr %s\\n' "$*" >> "$KIO_TEST_LOG"
''',
            }
            for name, content in stubs.items():
                path = bin_dir / name
                path.write_text(content, encoding="utf-8")
                path.chmod(0o755)

            environment = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "KIO_TEST_LOG": str(log),
                "KIO_DERIVED_DATA_PATH": str(derived),
                "KIO_BUILD_SIGNING_MODE": "public",
                "KIO_DEV_CODESIGN_IDENTITY": "Private Kio Local Development Identity",
                "CONFIGURATION": "Release",
            }
            subprocess.run([str(root / "scripts/build-mac.sh")], env=environment, check=True, capture_output=True, text=True)
            commands = log.read_text(encoding="utf-8")
            self.assertIn("CODE_SIGN_IDENTITY=-", commands)
            self.assertIn("--sign -", commands)
            self.assertNotIn("Private Kio Local Development Identity", commands)

    @unittest.skipUnless(sys.platform == "darwin", "atomic app replacement uses macOS renameatx_np")
    def test_atomic_helper_replaces_app_bundle_without_losing_destination_path(self):
        helper = Path(__file__).resolve().parents[1] / "atomic-replace-app.swift"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / ".staged-app"
            destination = root / "Kio.app"
            staged.mkdir()
            destination.mkdir()
            (staged / "version").write_text("new", encoding="utf-8")
            (destination / "version").write_text("old", encoding="utf-8")
            subprocess.run(["/usr/bin/swift", str(helper), str(staged), str(destination)], check=True, capture_output=True, text=True)
            self.assertEqual((destination / "version").read_text(encoding="utf-8"), "new")
            self.assertFalse(staged.exists())


if __name__ == "__main__":
    unittest.main()
