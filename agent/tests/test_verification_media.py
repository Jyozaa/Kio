from companion_agent.candidates import Element, Observation
from companion_agent.semantic_planner import SemanticTaskPlanner
from companion_agent.verification import (
    GoalVerifier,
    VerificationStatus,
    semantic_expectations,
)


def _state(label):
    return Observation("s", 1, 2, (Element("e", "s", label, "AXButton", None, True, True, "AX"),))


def test_media_verifier_requires_observable_desired_state():
    assert (
        GoalVerifier().check("pause the song", _state("Pause"), _state("Play"), []).status
        == VerificationStatus.VERIFIED
    )
    assert (
        GoalVerifier().check("pause the song", _state("Pause"), _state("Pause"), []).status
        != VerificationStatus.VERIFIED
    )
    assert (
        GoalVerifier().check("play it again", _state("Play"), _state("Pause"), []).status
        == VerificationStatus.VERIFIED
    )


def _transport_state(label, *, context=None):
    return Observation(
        "s",
        1,
        2,
        (
            Element(
                "e",
                "s",
                label,
                "AXButton",
                None,
                True,
                True,
                "AX",
                native={"ancestor_labels": [context]} if context else {},
            ),
        ),
    )


def test_semantic_media_verification_requires_transport_scoped_evidence():
    play_step = SemanticTaskPlanner().plan("Play the song").steps[0]
    verifier = GoalVerifier(semantic_expectations(play_step))
    assert verifier.check("Play the song", _state("Play"), _state("Pause"), []).status == (
        VerificationStatus.UNKNOWN
    )
    assert (
        verifier.check(
            "Play the song",
            _transport_state("Play", context="Now Playing transport controls"),
            _transport_state("Pause", context="Now Playing transport controls"),
            [],
        ).status
        == VerificationStatus.VERIFIED
    )


def test_primary_pause_proves_playing_and_primary_play_proves_paused():
    planner = SemanticTaskPlanner()
    playing = GoalVerifier(semantic_expectations(planner.plan("Play the song").steps[0]))
    paused = GoalVerifier(semantic_expectations(planner.plan("Pause the song").steps[0]))
    assert (
        playing.check(
            "Play the song",
            _transport_state("Play", context="Now Playing transport controls"),
            _transport_state("Pause", context="Now Playing transport controls"),
            [],
        ).status
        == VerificationStatus.VERIFIED
    )
    assert (
        paused.check(
            "Pause the song",
            _transport_state("Pause", context="Now Playing transport controls"),
            _transport_state("Play", context="Now Playing transport controls"),
            [],
        ).status
        == VerificationStatus.VERIFIED
    )


def test_conflicting_duplicate_media_controls_do_not_verify_primary_state():
    play_step = SemanticTaskPlanner().plan("Play the song").steps[0]
    verifier = GoalVerifier(semantic_expectations(play_step))
    controls = Observation(
        "s",
        1,
        2,
        (
            Element(
                "play",
                "s",
                "Pause",
                "AXButton",
                None,
                True,
                True,
                "AX",
                native={"ancestor_labels": ["Now Playing transport controls"]},
            ),
            Element(
                "preview",
                "s",
                "Play",
                "AXButton",
                None,
                True,
                True,
                "AX",
                native={"ancestor_labels": ["Now Playing transport controls"]},
            ),
        ),
    )
    assert verifier.check("Play the song", _state("Play"), controls, []).status == (
        VerificationStatus.UNKNOWN
    )
