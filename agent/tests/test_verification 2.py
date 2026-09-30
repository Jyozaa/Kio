import asyncio
from dataclasses import replace

import pytest

from companion_agent.candidates import Element, Observation
from companion_agent.verification import (
    Expectation,
    GoalVerifier,
    VerificationState,
    VerificationStatus,
)


def element(label, role="AXStaticText", value=None, checked=None):
    return Element(label, "obs", label, role, value, True, True, "AX", checked=checked)


def state(*elements):
    return Observation("obs", 1, 2, elements)


def verify(expectations, initial, current):
    return asyncio.run(GoalVerifier(expectations).verify("goal", initial, current, []))


@pytest.mark.parametrize(
    "requirement,elements",
    [
        (Expectation("field", "Message", "hello"), [element("Message", "AXTextField", "wrong")]),
        (
            Expectation("option", "Delivery", "Option B"),
            [element("Delivery", "AXPopUpButton", "Option A")],
        ),
        (Expectation("marker", "Success", "Success"), [element("Not Success")]),
        (
            Expectation("checked", "Enabled", True),
            [element("Enabled", "AXCheckBox", checked=False)],
        ),
    ],
)
def test_false_done_is_not_verified(requirement, elements):
    result = verify([requirement], state(), state(*elements))
    assert result.status == VerificationStatus.NOT_VERIFIED
    assert result.evidence[0].expected == requirement.expected


def test_wrong_url_and_transition():
    initial = VerificationState(state(), url="https://example.com/start")
    current = VerificationState(state(), url="https://example.com/wrong")
    assert (
        verify([Expectation("url", expected="https://example.com/right")], initial, current).status
        == VerificationStatus.NOT_VERIFIED
    )
    assert (
        verify([Expectation("transition")], initial, current).status == VerificationStatus.VERIFIED
    )
    assert (
        verify(
            [Expectation("url", expected="https://example.com/right")],
            initial,
            VerificationState(state()),
        ).status
        == VerificationStatus.UNKNOWN
    )


def test_partial_compound_goal_is_rejected():
    goal = 'Enter "hello" in Message field, choose Option B, then click Reach success'
    observed = state(
        element("Message", "AXTextField", "hello"),
        element("Delivery", "AXPopUpButton", "Option A"),
        element("Success"),
    )
    assert (
        GoalVerifier().check(goal, state(), observed, []).status == VerificationStatus.NOT_VERIFIED
    )
    observed = replace(
        observed,
        elements=(
            observed.elements[0],
            replace(observed.elements[1], value="Option B"),
            observed.elements[2],
        ),
    )
    assert GoalVerifier().check(goal, state(), observed, []).status == VerificationStatus.VERIFIED
    assert (
        GoalVerifier()
        .check('Enter "hello" in Message field then click Next', state(), observed, [])
        .status
        == VerificationStatus.UNKNOWN
    )


def test_field_identity_and_ambiguous_fields():
    current = state(
        element("Message", "AXTextField", "wrong"), element("Other", "AXTextField", "hello")
    )
    assert (
        GoalVerifier().check('Enter "hello" in Message field', state(), current, []).status
        == VerificationStatus.NOT_VERIFIED
    )
    assert (
        GoalVerifier().check('Enter "hello" in field', state(), current, []).status
        == VerificationStatus.UNKNOWN
    )


def test_appeared_and_disappeared_are_transitions():
    before = state(element("Loading"))
    after = state(element("Ready"))
    assert (
        verify(
            [Expectation("appeared", "Ready"), Expectation("disappeared", "Loading")], before, after
        ).status
        == VerificationStatus.VERIFIED
    )
    assert (
        verify([Expectation("appeared", "Ready")], after, after).status
        == VerificationStatus.NOT_VERIFIED
    )


def test_mute_goal_requires_fresh_checkbox_state():
    initial = state()
    unmuted = state(element("Mute", "AXCheckBox", value="0", checked=False))
    muted = state(element("Mute", "AXCheckBox", value="1", checked=True))
    assert (
        GoalVerifier().check("Mute the microphone", initial, unmuted, []).status
        == VerificationStatus.NOT_VERIFIED
    )
    verified = GoalVerifier().check("Mute the microphone", initial, muted, [])
    assert verified.status == VerificationStatus.VERIFIED
    assert verified.evidence[0].observed is True


def test_semantic_mute_verifier_accepts_button_label_transition():
    from companion_agent.semantic_planner import SemanticTaskPlanner
    from companion_agent.verification import semantic_expectations

    step = SemanticTaskPlanner().plan("Mute me").steps[0]
    verifier = GoalVerifier(semantic_expectations(step))
    before = state(element("Mute", "AXButton"))
    after = state(element("Unmute", "AXButton"))
    assert verifier.check("Mute me", before, after, []).status == VerificationStatus.VERIFIED


def test_search_verifier_uses_submitted_url_not_text_field_value():
    from companion_agent.semantic_planner import SemanticTaskPlanner
    from companion_agent.verification import semantic_expectations

    step = SemanticTaskPlanner().plan("Search the current site for Minecraft").steps[0]
    verifier = GoalVerifier(semantic_expectations(step))
    query_field = element("Search", "AXSearchField", "Minecraft")
    assert (
        verifier.check("Search for Minecraft", state(), state(query_field), []).status
        == VerificationStatus.UNKNOWN
    )
    initial_site = Observation(
        "initial",
        1,
        2,
        (),
        "Browser|kio_tab_id=tab-1|kio_url=https://youtube.com/",
    )
    results = Observation(
        "results",
        1,
        2,
        (element("Search", "AXSearchField", "Minecraft"),),
        "Browser|kio_tab_id=tab-1|kio_url=https://youtube.com/results?search_query=Minecraft",
    )
    assert (
        verifier.check("Search for Minecraft", initial_site, results, []).status
        == VerificationStatus.VERIFIED
    )
    google_results = Observation(
        "google-results",
        1,
        2,
        (element("Search", "AXSearchField", "Minecraft"),),
        "Browser|kio_tab_id=tab-1|kio_url=https://google.com/search?q=Minecraft",
    )
    assert (
        verifier.check("Search for Minecraft", initial_site, google_results, []).status
        == VerificationStatus.NOT_VERIFIED
    )


def test_new_tab_verifier_uses_ax_tab_delta_without_structured_marker():
    from companion_agent.semantic_planner import SemanticTaskPlanner
    from companion_agent.verification import semantic_expectations

    step = SemanticTaskPlanner().plan("Open a new tab").steps[0]
    verifier = GoalVerifier(semantic_expectations(step))
    before = state(element("Current", "AXTab"))
    after = state(element("Current", "AXTab"), element("Untitled", "AXTab"))
    assert verifier.check("Open a new tab", before, after, []).status == VerificationStatus.VERIFIED


def test_navigation_verifier_uses_browser_address_field_when_structured_url_is_missing():
    address = Element(
        "address",
        "obs",
        "Address and search bar",
        "AXTextField",
        "https://youtube.com/",
        True,
        True,
        "AX",
    )
    result = GoalVerifier([Expectation("navigate", "https://youtube.com/", True)]).check(
        "Open YouTube", state(), state(address), []
    )
    assert result.status == VerificationStatus.VERIFIED
    assert result.evidence[0].observed == "https://youtube.com/"


def test_navigation_verifier_uses_ax_document_url_metadata():
    page = Element(
        "page",
        "obs",
        "Page",
        "AXWebArea",
        None,
        True,
        True,
        "AX",
        native={"document": {"document_url": "https://youtube.com/"}},
    )
    result = GoalVerifier([Expectation("navigate", "https://youtube.com/", True)]).check(
        "Open YouTube", state(), state(page), []
    )
    assert result.status == VerificationStatus.VERIFIED


def test_navigation_verifier_uses_exact_host_in_page_title_as_last_fallback():
    current = replace(state(), title="YouTube — youtube.com")
    result = GoalVerifier([Expectation("navigate", "https://youtube.com/", True)]).check(
        "Open YouTube", state(), current, []
    )
    assert result.status == VerificationStatus.VERIFIED
    assert result.evidence[0].observed == "YouTube — youtube.com"


def test_application_and_authorized_file(tmp_path):
    path = tmp_path / "sample.txt"
    path.write_text("content")
    current = VerificationState(state(), app_names=("Calculator",), files=(path,))
    assert (
        verify(
            [Expectation("app", expected="Calculator"), Expectation("file", "sample.txt")],
            state(),
            current,
        ).status
        == VerificationStatus.VERIFIED
    )
    assert (
        verify([Expectation("file", "unapproved.txt")], state(), current).status
        == VerificationStatus.UNKNOWN
    )
    path.unlink()
    assert (
        verify([Expectation("file", "sample.txt")], state(), current).status
        == VerificationStatus.NOT_VERIFIED
    )


def test_title_only_not_success_and_unknown_goals_stay_unknown():
    current = state(element("Success", "AXWindow"))
    assert (
        GoalVerifier().check("Reach Success", state(), current, []).status
        == VerificationStatus.NOT_VERIFIED
    )
    assert (
        GoalVerifier().check("Make this beautiful", state(), current, []).status
        == VerificationStatus.UNKNOWN
    )


def test_filled_form_is_not_submission_proof():
    from companion_agent.candidates import normalize
    from companion_agent.driver import normalize_window

    obs = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXTextField",
                        "label": "Message",
                        "value": "hello",
                        "visible": True,
                    }
                ]
            },
            1,
            2,
        )
    )
    result = GoalVerifier().check(
        'Enter "hello" in Message field and submit the form', obs, obs, []
    )
    assert result.status != VerificationStatus.VERIFIED
