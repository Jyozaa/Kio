from dataclasses import replace

import pytest

from companion_agent.candidates import (
    CandidateAction,
    CandidateTable,
    Operation,
    build_candidates,
    normalize,
)
from companion_agent.driver import DriverError, normalize_window


def observation(rows):
    data = {
        "elements": [
            {
                "element_index": i,
                "element_token": f"s12345678:{i}",
                "role": "AXButton",
                "label": "Search",
                "enabled": True,
                "frame": {"x": i * 50, "y": 0, "w": 40, "h": 30},
                **row,
            }
            for i, row in enumerate(rows)
        ]
    }
    return normalize(normalize_window(data, 1, 2))


def test_bounded_and_relevance():
    obs = observation([{"label": "other"}] * 999 + [{"label": "Settings"}])
    choices = build_candidates(obs, "open Settings").public_choices(Operation.CLICK)
    assert len(choices) <= 8
    assert len(build_candidates(obs, "find a control").public_choices(Operation.CLICK)) == 8
    assert "Settings" in next(iter(choices.values()))


@pytest.mark.parametrize("raw,expected", [(0, False), (1, True), ("0", False), ("1", True)])
def test_ax_checkbox_value_becomes_explicit_checked_state(raw, expected):
    normalized = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXCheckBox",
                        "label": "Mute",
                        "value": raw,
                        "enabled": True,
                        "visible": True,
                        "frame": {"x": 10, "y": 10, "w": 20, "h": 20},
                    }
                ]
            },
            1,
            2,
        )
    )
    assert normalized.elements[0].checked is expected


def test_semantic_toggle_candidate_is_relevant_and_exposes_state_description():
    from companion_agent.candidates import Element, Observation

    items = tuple(
        Element(
            f"e{index}",
            "obs",
            label,
            role,
            value,
            True,
            True,
            "AX",
            checked=checked,
            native={"frame": {"x": index * 30, "y": 20, "w": 25, "h": 25}},
        )
        for index, (label, role, value, checked) in enumerate(
            [("Settings", "AXButton", None, None), ("Mute", "AXCheckBox", "0", False)]
        )
    )
    table = build_candidates(Observation("obs", 1, 2, items), "Mute the microphone")
    choices = list(table.public_choices(Operation.CLICK).values())
    assert choices[0].startswith("Mute")
    assert "checked=unchecked" in choices[0]


def test_photo_capture_candidates_exclude_mode_selectors_and_keep_shutter_control():
    from companion_agent.candidates import Element, Observation
    from companion_agent.semantic_planner import SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Take a picture").steps[0]
    obs = Observation(
        "obs",
        1,
        2,
        (
            Element("mode", "obs", "four pictures", "AXRadioButton", "0", True, True, "AX"),
            Element("photo", "obs", "take photo", "AXButton", None, True, True, "AX"),
            Element("effects", "obs", "Effects", "AXButton", None, True, True, "AX"),
        ),
    )
    table = build_candidates(obs, "Take a picture", semantic_step=step)
    choices = table.public_choices(Operation.CLICK)
    assert len(choices) == 1
    assert next(iter(choices.values())).startswith("take photo")


def test_semantic_operation_filters_incompatible_executable_candidates():
    from companion_agent.candidates import Element, Observation

    obs = Observation(
        "obs",
        1,
        2,
        (
            Element("mute", "obs", "Mute", "AXCheckBox", "0", True, True, "AX"),
            Element("field", "obs", "Search", "AXTextField", "", True, True, "AX"),
            Element("select", "obs", "Mode", "AXPopUpButton", "A", True, True, "AX"),
        ),
    )
    table = build_candidates(obs, "Mute the microphone", allowed_operations={Operation.CLICK})
    assert {action.operation for action in table.actions.values()} <= {
        Operation.CLICK,
        Operation.WAIT,
        Operation.DONE,
        Operation.BLOCKED,
        Operation.REOBSERVE,
    }
    with pytest.raises(ValueError, match="allowed_operations"):
        build_candidates(obs, "goal", allowed_operations={"CLICK"})


def test_play_intent_ranks_generic_media_controls_before_navigation_noise():
    obs = observation(
        [
            {"label": "Settings", "frame": {"x": 10, "y": 0, "w": 40, "h": 30}},
            {"label": "Search", "frame": {"x": 60, "y": 0, "w": 40, "h": 30}},
            {"label": "Play", "frame": {"x": 110, "y": 0, "w": 40, "h": 30}},
            {"label": "Profile", "frame": {"x": 160, "y": 0, "w": 40, "h": 30}},
        ]
    )
    choices = list(build_candidates(obs, "Play the song").public_choices(Operation.CLICK).values())
    assert choices[0].startswith("Play ")


def test_media_scoring_never_boosts_the_opposite_transport_action():
    from companion_agent.candidates import Element, _semantic_candidate_score

    play = Element("play", "s", "Play", "AXButton", None, True, True, "AX")
    pause = Element("pause", "s", "Pause", "AXButton", None, True, True, "AX")
    assert _semantic_candidate_score(pause, {"play", "song"}, "Play the song")[0] < 0
    assert _semantic_candidate_score(play, {"pause", "song"}, "Pause the song")[0] < 0


def test_semantic_play_and_pause_only_expose_the_requested_media_state_control():
    from companion_agent.candidates import Element, Observation
    from companion_agent.semantic_planner import SemanticTaskPlanner

    observation = Observation(
        "obs",
        1,
        2,
        tuple(
            Element(
                label.casefold(),
                "obs",
                label,
                "AXButton",
                None,
                True,
                True,
                "AX",
                native={"ancestor_labels": ["Now Playing transport controls"]},
            )
            for label in ("Settings", "Pause", "Play", "Profile")
        ),
    )
    planner = SemanticTaskPlanner()
    play_step = planner.plan("Play the song").steps[0]
    pause_step = planner.plan("Pause the song").steps[0]
    play_choices = build_candidates(
        observation, "Play the song", semantic_step=play_step
    ).public_choices(Operation.CLICK)
    pause_choices = build_candidates(
        observation, "Pause the song", semantic_step=pause_step
    ).public_choices(Operation.CLICK)
    assert len(play_choices) == 1 and next(iter(play_choices.values())).startswith("Play ")
    assert len(pause_choices) == 1 and next(iter(pause_choices.values())).startswith("Pause ")


def test_current_site_search_prefers_page_search_field_over_browser_address_field():
    from companion_agent.candidates import Element, Observation
    from companion_agent.semantic_planner import SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Search the current site for Minecraft").steps[0]
    obs = Observation(
        "obs",
        1,
        2,
        (
            Element(
                "address", "obs", "Search or enter website", "AXTextField", "", True, True, "AX"
            ),
            Element("page-search", "obs", "Search videos", "AXTextField", "", True, True, "AX"),
        ),
    )
    table = build_candidates(
        obs,
        "Search for Minecraft on the current page",
        allowed_operations={Operation.TYPE_TEXT},
        semantic_step=step,
    )
    choices = table.public_choices(Operation.TYPE_TEXT)
    assert len(choices) == 1
    assert next(iter(choices.values())).startswith("Search videos")


def test_playback_state_does_not_offer_an_uncontextual_row_play_button():
    from companion_agent.candidates import Element, Observation
    from companion_agent.semantic_planner import SemanticTaskPlanner

    observation = Observation(
        "obs",
        1,
        2,
        (
            Element(
                "album-play",
                "obs",
                "Play",
                "AXButton",
                None,
                True,
                True,
                "AX",
                native={"row_label": "Recommended album"},
            ),
        ),
    )
    step = SemanticTaskPlanner().plan("Play the song").steps[0]
    table = build_candidates(observation, "Play the song", semantic_step=step)
    assert not table.public_choices(Operation.CLICK)


@pytest.mark.parametrize(
    ("utterance", "labels"),
    [
        ("Press the mute button", ("Mute", "Unmute")),
        ("Press the play button", ("Play", "Pause")),
    ],
)
def test_one_shot_activation_does_not_offer_the_opposite_control(utterance, labels):
    from companion_agent.candidates import Element, Observation
    from companion_agent.semantic_planner import SemanticTaskPlanner

    observation = Observation(
        "obs",
        1,
        2,
        tuple(
            Element(label.casefold(), "obs", label, "AXButton", None, True, True, "AX")
            for label in labels
        ),
    )
    step = SemanticTaskPlanner().plan(utterance).steps[0]
    table = build_candidates(observation, utterance, semantic_step=step)
    descriptions = table.public_choices(Operation.CLICK).values()
    assert len(descriptions) == 1
    assert next(iter(descriptions)).startswith(labels[0] + " ")


def test_activation_of_selected_result_uses_observed_selection_state():
    from companion_agent.candidates import Element, Observation
    from companion_agent.semantic_planner import SemanticTaskPlanner

    result = Element(
        "result", "obs", "Minecraft Wiki", "AXLink", None, True, True, "AX", selected=True
    )
    unrelated = Element("other", "obs", "News", "AXLink", None, True, True, "AX")
    observation = Observation("obs", 1, 2, (result, unrelated))
    step = SemanticTaskPlanner().plan("Click the selected result").steps[0]
    table = build_candidates(observation, "Click the selected result", semantic_step=step)
    descriptions = table.public_choices(Operation.CLICK).values()
    assert len(descriptions) == 1 and next(iter(descriptions)).startswith("Minecraft Wiki ")


def test_filter_and_deduplicate():
    frame = {"x": 0, "y": 0, "w": 40, "h": 30}
    obs = observation(
        [
            {"enabled": False},
            {"visible": False},
            {"label": ""},
            {"role": "AXWindow", "frame": {"x": 0, "y": 0, "w": 500, "h": 500}},
            {"frame": frame},
            {"frame": frame},
            {"frame": {**frame, "x": 200}},
            {"frame": {**frame, "h": 1}},
        ]
    )
    assert len(build_candidates(obs, "Search").public_choices(Operation.CLICK)) == 2


def test_empty_and_operation_heads():
    empty = build_candidates(observation([]), "goal")
    assert len(empty.actions) == 6
    obs = observation([{"role": "AXTextField"}, {"role": "AXPopUpButton"}, {}])
    table = build_candidates(obs, "goal")
    for op in (Operation.CLICK, Operation.TYPE_TEXT, Operation.SELECT):
        assert len(table.public_choices(op)) == 1


@pytest.mark.parametrize("mode", ["unknown", "foreign", "duplicate", "consumed", "changed"])
def test_invalid_ids_never_execute(mode):
    obs = observation([{}])
    table = build_candidates(obs, "Search")
    candidate_id = next(iter(table.actions))
    snapshot_id = obs.snapshot_id
    ids = [candidate_id]
    if mode == "unknown":
        ids = ["c_invented"]
    elif mode == "foreign":
        ids = [next(iter(build_candidates(obs, "Search").actions))]
    elif mode == "duplicate":
        ids *= 2
    elif mode == "consumed":
        table.take(ids, snapshot_id)
    else:
        snapshot_id = "another"
    with pytest.raises(DriverError):
        table.take(ids, snapshot_id)
    with pytest.raises(DriverError, match="stale_state"):
        table.take([candidate_id], obs.snapshot_id)


def test_valid_take_discards_whole_table():
    obs = observation([{}, {}])
    table = build_candidates(obs, "Search")
    ids = list(table.actions)
    assert table.take([ids[0]], obs.snapshot_id).id == ids[0]
    with pytest.raises(DriverError, match="stale_state"):
        table.take([ids[1]], obs.snapshot_id)


def test_table_rejects_duplicate_or_foreign_members():
    obs = observation([{}])
    action = CandidateAction("a", obs.snapshot_id, Operation.WAIT, "wait")
    with pytest.raises(DriverError, match="duplicate_candidate"):
        CandidateTable(obs, [action, action])
    with pytest.raises(DriverError, match="stale_state"):
        CandidateTable(obs, [replace(action, snapshot_id="foreign")])


def test_fingerprint_tracks_values_not_snapshot_tokens():
    assert observation([{}]).fingerprint() == observation([{}]).fingerprint()
    assert observation([{}]).fingerprint() != observation([{"value": "changed"}]).fingerprint()


def test_public_choices_do_not_expose_driver_tokens():
    table = build_candidates(observation([{}]), "Search")
    assert "s12345678" not in repr(table.public_choices(Operation.CLICK))
    assert "s12345678" not in repr(list(table.actions.values()))


def test_fill_subgoal_excludes_unrelated_controls():
    obs = observation([{"role": "AXTextField", "label": "Message"}, {"label": "Buy now"}])
    table = build_candidates(obs, 'Enter "hello" into Message field')
    assert not table.public_choices(Operation.CLICK)
    assert len(table.public_choices(Operation.TYPE_TEXT)) == 1


def test_visible_dropdown_options_belong_to_select_head():
    obs = observation(
        [{"role": "AXMenuItem", "label": "Option A"}, {"role": "AXMenuItem", "label": "Option B"}]
    )
    table = build_candidates(obs, "choose an option")
    assert not table.public_choices(Operation.CLICK)
    assert len(table.public_choices(Operation.SELECT)) == 2


def test_off_window_controls_are_not_candidates():
    from companion_agent.driver import normalize_window

    observation = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXWindow",
                        "label": "Fixture",
                        "frame": {"x": 0, "y": 0, "w": 500, "h": 500},
                    },
                    {
                        "element_index": 1,
                        "role": "AXButton",
                        "label": "Outside",
                        "visible": True,
                        "frame": {"x": 20, "y": 600, "w": 100, "h": 20},
                    },
                ]
            },
            1,
            2,
        )
    )
    assert not build_candidates(observation, "click Outside").public_choices(Operation.CLICK)


def test_native_dialog_subtree_survives_browser_chrome_filter():
    obs = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXWindow",
                        "label": "Browser",
                        "frame": {"x": 0, "y": 0, "w": 500, "h": 500},
                    },
                    {
                        "element_index": 1,
                        "role": "AXWebArea",
                        "label": "Page",
                        "in_web_content": True,
                        "frame": {"x": 0, "y": 0, "w": 500, "h": 450},
                    },
                    {
                        "element_index": 2,
                        "role": "AXSheet",
                        "label": "Open",
                        "parent_index": 0,
                        "frame": {"x": 20, "y": 20, "w": 400, "h": 300},
                    },
                    {
                        "element_index": 3,
                        "role": "AXButton",
                        "label": "Cancel",
                        "parent_index": 2,
                        "frame": {"x": 300, "y": 260, "w": 60, "h": 24},
                    },
                    {
                        "element_index": 4,
                        "role": "AXButton",
                        "label": "Browser toolbar",
                        "frame": {"x": 0, "y": 0, "w": 40, "h": 24},
                    },
                ]
            },
            1,
            2,
        )
    )
    assert any(e.role == "AXSheet" and e.label == "Open" for e in obs.elements)
    assert any(e.role == "AXButton" and e.label == "Cancel" for e in obs.elements)
    assert not any(e.label == "Browser toolbar" for e in obs.elements)
    cancel = next(
        action
        for action in build_candidates(obs, "Click Cancel").actions.values()
        if action.element_id
    )
    assert cancel.payload["in_system_dialog"] is True


def test_explicit_option_uses_only_observed_matching_label():
    obs = observation(
        [{"role": "AXMenuItem", "label": "Option A"}, {"role": "AXMenuItem", "label": "Option B"}]
    )
    choices = build_candidates(obs, "Choose Option B").public_choices(Operation.SELECT)
    assert len(choices) == 1 and next(iter(choices.values())).startswith("Option B")
    assert len(build_candidates(obs, "Choose an option").public_choices(Operation.SELECT)) == 2


def test_compact_native_dialog_window_is_marked_for_foreground_token_action():
    from companion_agent.driver import normalize_window

    observation = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXWindow",
                        "label": "Local page says",
                        "frame": {"x": 10, "y": 10, "w": 448, "h": 144},
                    },
                    {
                        "element_index": 1,
                        "parent_index": 0,
                        "role": "AXHeading",
                        "label": "Local page says",
                        "frame": {"x": 20, "y": 20, "w": 400, "h": 24},
                    },
                    {
                        "element_index": 2,
                        "parent_index": 0,
                        "role": "AXStaticText",
                        "label": "Continue?",
                        "frame": {"x": 20, "y": 50, "w": 400, "h": 20},
                    },
                    {
                        "element_index": 3,
                        "parent_index": 0,
                        "role": "AXButton",
                        "label": "Cancel",
                        "frame": {"x": 280, "y": 90, "w": 70, "h": 32},
                    },
                    {
                        "element_index": 4,
                        "parent_index": 0,
                        "role": "AXButton",
                        "label": "OK",
                        "frame": {"x": 360, "y": 90, "w": 70, "h": 32},
                    },
                ]
            },
            1,
            3,
        )
    )
    ok = next(e for e in observation.elements if e.label == "OK")
    assert ok.native["in_system_dialog"] is True
    action = next(
        action
        for action in build_candidates(observation, "Click OK").actions.values()
        if action.element_id == ok.id
    )
    assert action.payload["in_system_dialog"] is True


def test_closed_dropdown_never_targets_its_mismatched_selected_item():
    obs = observation(
        [
            {"role": "AXPopUpButton", "label": "Delivery", "value": "Option A"},
            {"role": "AXMenuItem", "label": "Option A", "selected": True},
        ]
    )
    choices = build_candidates(obs, "Choose Option B").public_choices(Operation.SELECT)
    assert len(choices) == 1
    assert next(iter(choices.values())).startswith("Delivery")


def test_clipped_duplicate_menu_item_is_not_a_candidate():
    obs = observation(
        [
            {"role": "AXMenuItem", "label": "Option B", "frame": {"x": 0, "y": 0, "w": 90, "h": 6}},
            {
                "role": "AXMenuItem",
                "label": "Option B",
                "frame": {"x": 0, "y": 10, "w": 90, "h": 24},
            },
        ]
    )
    choices = build_candidates(obs, "Choose Option B").public_choices(Operation.SELECT)
    assert len(choices) == 1
    assert next(iter(choices.values())).startswith("Option B")
