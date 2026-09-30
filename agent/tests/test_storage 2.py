from companion_agent.storage import application_support


def test_support_root_is_minimal_and_idempotent(tmp_path):
    root = application_support(tmp_path)
    assert root == tmp_path / "Kio" and list(root.iterdir()) == []
    assert application_support(tmp_path) == root


def test_legacy_copied_without_deletion(tmp_path):
    old = tmp_path / "LocalCompanion"
    old.mkdir()
    (old / "settings.json").write_text('{"keep":true}')
    root = application_support(tmp_path)
    assert (root / "settings.json").read_bytes() == (old / "settings.json").read_bytes()
    assert old.is_dir()


def test_current_state_wins(tmp_path):
    for name, value in (("Kio", "new"), ("LocalCompanion", "old")):
        (tmp_path / name).mkdir()
        (tmp_path / name / "settings").write_text(value)
    assert (application_support(tmp_path) / "settings").read_text() == "new"
    assert (tmp_path / "LocalCompanion" / "settings").read_text() == "old"
