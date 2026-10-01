#!/usr/bin/env python3
"""Select and remember a stable local Kio code-signing identity.

The configuration stores only a public certificate fingerprint. This tool
selects an existing Kio local signing identity and never creates or imports a
certificate or private key.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Iterable


EXPECTED_BUNDLE_ID = "app.kio.mac"
IDENTITY_ENV = "KIO_DEV_CODESIGN_IDENTITY"
CONFIG_ENV = "KIO_DEV_SIGNING_CONFIG"
DEFAULT_CONFIG = Path.home() / ".config" / "kio" / "dev-signing.env"
IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$')
CERTIFICATE_HASH_LINE = re.compile(r'^\s*SHA-1 hash:\s*([0-9A-Fa-f]{40})\s*$', re.MULTILINE)
LOCAL_IDENTITY_NAME = "Kio Local Development"


@dataclass(frozen=True)
class Identity:
    fingerprint: str
    name: str


class IdentityError(RuntimeError):
    pass


def parse_identities(output: str) -> list[Identity]:
    identities: list[Identity] = []
    for line in output.splitlines():
        match = IDENTITY_LINE.match(line)
        if match:
            identities.append(Identity(match.group(1).upper(), match.group(2)))
    return identities


def read_saved_identity(path: Path) -> str | None:
    """Read only the identity key; never source/execute this config file."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return None
    for line in lines:
        key, separator, value = line.partition("=")
        if separator and key.strip() == IDENTITY_ENV:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value or None
    return None


def _match_configured(identities: Iterable[Identity], configured: str) -> Identity:
    normalized = configured.strip()
    matches = [item for item in identities if item.fingerprint.lower() == normalized.lower() or item.name == normalized]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise IdentityError("That identity name is ambiguous; set KIO_DEV_CODESIGN_IDENTITY to its 40-character fingerprint.")
    raise IdentityError(f"Configured signing identity was not found among valid identities: {normalized}")


def select_identity(identities: list[Identity], explicit: str | None = None, saved: str | None = None) -> Identity:
    if explicit:
        return _match_configured(identities, explicit)
    if saved:
        return _match_configured(identities, saved)

    local = [item for item in identities if item.name == LOCAL_IDENTITY_NAME]
    if len(local) == 1:
        return local[0]
    if len(local) > 1:
        choices = ", ".join(item.fingerprint for item in local)
        raise IdentityError("Multiple Kio Local Development identities are available. Choose one explicitly: " + choices)

    raise IdentityError("No existing Kio Local Development identity was found. No certificate or private key was created. The public ad-hoc build remains available through scripts/build-mac.sh.")


def identity_list() -> list[Identity]:
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise IdentityError(f"Could not inspect local code-signing identities: {detail.strip()}") from error
    identities = parse_identities(result.stdout + "\n" + result.stderr)
    # security find-identity excludes self-signed identities from its trusted
    # code-signing-policy results. Discover Kio's local certificate directly;
    # its private key remains protected by the login Keychain access list.
    try:
        certificates = subprocess.run(
            ["/usr/bin/security", "find-certificate", "-a", "-c", LOCAL_IDENTITY_NAME, "-Z"],
            capture_output=True,
            text=True,
        )
    except OSError:
        certificates = None
    if certificates is not None:
        for fingerprint in CERTIFICATE_HASH_LINE.findall(certificates.stdout + "\n" + certificates.stderr):
            identities.append(Identity(fingerprint.upper(), LOCAL_IDENTITY_NAME))
    return list({item.fingerprint: item for item in identities}.values())


def config_path() -> Path:
    configured = os.environ.get(CONFIG_ENV)
    return Path(configured).expanduser() if configured else DEFAULT_CONFIG


def resolve_identity() -> Identity:
    identities = identity_list()
    explicit = os.environ.get(IDENTITY_ENV)
    saved = None if explicit else read_saved_identity(config_path())
    return select_identity(identities, explicit=explicit, saved=saved)


def save_identity(identity: Identity, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
    temporary.write_text(f"# Non-secret SHA-1 fingerprint of the selected local signing certificate.\n{IDENTITY_ENV}={identity.fingerprint}\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def verify_bundle_identifier(bundle_id: str, expected: str = EXPECTED_BUNDLE_ID) -> None:
    if bundle_id != expected:
        raise IdentityError(f"Refusing to replace an app with bundle identifier {bundle_id!r}; expected {expected!r}.")


def canonical_app_path(home: Path | None = None) -> Path:
    return (home or Path.home()) / "Applications" / "Kio.app"


def setup(interactive: bool) -> Identity:
    identities = identity_list()
    explicit = os.environ.get(IDENTITY_ENV)
    saved = None if explicit else read_saved_identity(config_path())
    if explicit or saved:
        identity = select_identity(identities, explicit=explicit, saved=saved)
    else:
        local = [item for item in identities if item.name == LOCAL_IDENTITY_NAME]
        if len(local) == 1:
            identity = local[0]
        elif len(local) > 1 and interactive and sys.stdin.isatty():
            for number, item in enumerate(local, start=1):
                print(f"{number}) {item.name} [{item.fingerprint}]")
            choice = input("Choose an existing Kio local signing identity: ").strip()
            if not choice.isdigit() or not 1 <= int(choice) <= len(local):
                raise IdentityError("No valid existing identity was selected; no configuration was written.")
            identity = local[int(choice) - 1]
        else:
            raise IdentityError("No existing Kio Local Development identity is available. No certificate or private key was created. Use scripts/build-mac.sh for an ad-hoc build.")
    save_identity(identity, config_path())
    return identity

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("resolve", "setup", "config-path"))
    args = parser.parse_args()
    try:
        if args.command == "config-path":
            print(config_path())
            return 0
        identity = setup(interactive=True) if args.command == "setup" else resolve_identity()
        print(identity.fingerprint)
        if args.command == "setup":
            print(f"Saved selected identity in {config_path()} (fingerprint only).", file=sys.stderr)
        return 0
    except IdentityError as error:
        print(str(error), file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
