from companion_agent.candidates import Element, Observation
from companion_agent.ui_inspector import SpatialReasoner, UIInspector, UIQuestionAnswerer


def control(identifier, role, label, frame, *, value=None, selected=None, checked=None, **native):
    return Element(
        id=identifier,
        snapshot_id="obs-1",
        label=label,
        role=role,
        value=value,
        enabled=True,
        visible=True,
        source="AX",
        selected=selected,
        checked=checked,
        native={"frame": frame, **native},
    )


def inspection(elements):
    observation = Observation("obs-1", 10, 20, tuple(elements), "Discord")
    return UIInspector().inspect(
        observation,
        app="Discord",
        window={
            "title": "Discord",
            "bounds": {"x": 0, "y": 0, "width": 1000, "height": 800},
        },
    )


def test_read_only_location_uses_spatial_position_and_nearby_labels():
    view = inspection(
        [
            control("mute", "AXButton", "Mute", {"x": 24, "y": 720, "w": 48, "h": 40}),
            control("deafen", "AXButton", "Deafen", {"x": 82, "y": 720, "w": 50, "h": 40}),
            control(
                "settings", "AXButton", "User Settings", {"x": 144, "y": 720, "w": 60, "h": 40}
            ),
        ]
    )
    answer = UIQuestionAnswerer().answer("Where is the mute button in Discord?", view)
    assert answer is not None
    assert "bottom-left" in answer.answer
    assert "Deafen" in answer.answer
    assert answer.source_app == "Discord"
    assert answer.evidence[0] == "control=Mute"
    assert not hasattr(view.controls[0], "payload")


def test_state_question_uses_observed_toggle_and_unknown_stays_unknown():
    checkbox = control(
        "mic", "AXCheckbox", "Microphone", {"x": 400, "y": 300, "w": 24, "h": 24}, checked=True
    )
    answer = UIQuestionAnswerer().answer("Am I muted?", inspection([checkbox]))
    assert answer is not None and answer.answer == "Microphone is muted."

    button = control("mute", "AXButton", "Mute", {"x": 400, "y": 300, "w": 60, "h": 24})
    answer = UIQuestionAnswerer().answer("Am I muted?", inspection([button]))
    assert answer is not None
    assert "isn't exposed clearly" in answer.answer


def test_inspection_redacts_password_and_rejects_invalid_geometry():
    secret = control(
        "password",
        "AXTextField",
        "Password",
        {"x": 10, "y": 10, "w": 100, "h": 20},
        value="not-to-leak",
        input_type="password",
    )
    bad = control(
        "bad", "AXButton", "Invisible geometry", {"x": 0, "y": 0, "w": float("nan"), "h": 20}
    )
    view = inspection([secret, bad])
    password = next(item for item in view.controls if item.label == "Password")
    assert password.value is None
    assert "not-to-leak" not in repr(view)
    assert (
        next(item for item in view.controls if item.label == "Invisible geometry").bounding_box
        is None
    )


def test_visible_options_and_selected_tab_are_read_only_answers():
    options = inspection(
        [
            control("one", "AXButton", "Continue", {"x": 200, "y": 200, "w": 100, "h": 40}),
            control("two", "AXButton", "Cancel", {"x": 350, "y": 200, "w": 100, "h": 40}),
        ]
    )
    answer = UIQuestionAnswerer().answer("What options are visible?", options)
    assert answer is not None and "Continue, Cancel" in answer.answer

    tab = control("tab", "AXTab", "Messages", {"x": 300, "y": 20, "w": 100, "h": 32}, selected=True)
    answer = UIQuestionAnswerer().answer("What tab am I currently on?", inspection([tab]))
    assert answer is not None and "Messages" in answer.answer


def test_spatial_reasoner_returns_region_without_raw_coordinates():
    view = inspection(
        [control("settings", "AXButton", "Settings", {"x": 900, "y": 5, "w": 80, "h": 36})]
    )
    control_view = view.controls[0]
    assert SpatialReasoner().location(control_view, view.window_bounds) == "top-right"
