import hashlib

from companion_agent.setup import install_manifest, model_ready, voice_model_self_test


def test_manifest_reuse_and_corruption(tmp_path, monkeypatch):
    payload = b"model"
    item = {
        "name": "fixture",
        "size": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "install_path": "models/fixture.bin",
        "revision": "pinned",
        "url": "https://example.invalid/model",
    }
    manifest = {"name": "fixture", "files": [item]}
    target = tmp_path / item["install_path"]
    target.parent.mkdir()
    target.write_bytes(payload)
    monkeypatch.setattr(
        "companion_agent.setup.install_model",
        lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("unexpected download")),
    )
    assert model_ready(manifest, tmp_path)
    install_manifest(manifest, tmp_path)
    assert (tmp_path / "models/fixture.manifest.json").is_file()
    target.write_bytes(b"wrong")
    assert not model_ready(manifest, tmp_path)


def test_setup_install_reports_cached_bytes(tmp_path):
    payload = b"model"
    item = {
        "name": "fixture",
        "size": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "install_path": "models/fixture.bin",
        "revision": "pinned",
        "url": "https://example.invalid/model",
    }
    target = tmp_path / item["install_path"]
    target.parent.mkdir()
    target.write_bytes(payload)
    events = []
    install_manifest({"name": "Fixture", "files": [item]}, tmp_path, progress=events.append)
    assert events == [
        {
            "event": "progress",
            "model": "Fixture",
            "file": "fixture",
            "downloaded": len(payload),
            "total": len(payload),
        }
    ]


def test_optional_voice_self_test_skips_when_model_is_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("KIO_STT_EXECUTABLE", "/missing/whisper-cli")
    manifest = {
        "name": "voice",
        "files": [
            {
                "name": "voice.bin",
                "size": 1,
                "sha256": hashlib.sha256(b"x").hexdigest(),
                "install_path": "models/voice.bin",
                "url": "https://example.invalid/voice",
            }
        ],
    }
    assert voice_model_self_test(manifest, tmp_path) == "skipped"
