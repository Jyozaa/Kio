import hashlib
import io

import pytest

from companion_agent.models import install_model, model_path, valid_model


def test_install_checksum_reuse_and_failure_preserves(tmp_path):
    content = b"small model contract"
    manifest = {
        "name": "fixture",
        "revision": "pinned",
        "url": "https://example.invalid/model",
        "sha256": hashlib.sha256(content).hexdigest(),
        "size": len(content),
        "install_path": "models/test.bin",
    }
    calls = []
    progress = []

    def open_model(url, timeout):
        calls.append(url)
        return io.BytesIO(content)

    path = install_model(
        manifest, tmp_path, opener=open_model, progress=lambda *row: progress.append(row)
    )
    assert valid_model(path, manifest)
    assert progress == [(len(content), len(content))]
    assert install_model(manifest, tmp_path, opener=open_model) == path and len(calls) == 1
    with pytest.raises(ValueError, match="checksum"):
        install_model({**manifest, "sha256": "bad"}, tmp_path, opener=open_model)
    assert path.read_bytes() == content
    assert not list(path.parent.glob(".install-*"))


@pytest.mark.parametrize("path", ["../escape", "/tmp/escape"])
def test_model_path_rejects_escape(tmp_path, path):
    with pytest.raises(ValueError):
        model_path({"install_path": path}, tmp_path)
