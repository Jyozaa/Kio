from companion_agent.direct import resolve_app
from companion_agent.goal_compiler import GoalCompiler, IntentKind


def test_conversational_wrappers_normalize_to_same_goal():
    for text in (
        "Open Spotify",
        "Hey Kio open Spotify up for me",
        "Can you open Spotify?",
        "Could you bring Spotify up?",
        "Please open Spotify",
    ):
        plan = GoalCompiler().compile(text)
        assert plan.steps[0].kind == IntentKind.ENSURE_APP
        assert plan.steps[0].application.casefold() == "spotify"


def test_compiler_preserves_quoted_literals_and_builds_compound_plan():
    compiler = GoalCompiler()
    plan = compiler.compile('Hey Kio, open Calculator and type "one plus one"')
    assert plan.normalized == 'open Calculator and type "one plus one"'
    assert [step.kind for step in plan.steps] == [
        IntentKind.ENSURE_APP,
        IntentKind.CONTINUE_UI_GOAL,
    ]
    assert plan.steps[0].application == "Calculator"
    assert '"one plus one"' in plan.steps[1].goal


def test_compiler_search_compound_is_generic():
    plan = GoalCompiler().compile("Open Chrome and search for Norbert Wiener")
    assert [step.kind for step in plan.steps] == [IntentKind.ENSURE_APP, IntentKind.WEB_SEARCH]
    assert plan.steps[1].goal == "search for Norbert Wiener"


def test_play_scope_is_compiled_before_candidate_generation():
    plan = GoalCompiler().compile("Play the song on Spotify")
    assert [step.kind for step in plan.steps] == [IntentKind.ENSURE_APP, IntentKind.PLAY]
    assert plan.steps[0].application == "Spotify"
    assert plan.steps[1].goal == "Play the song"


def test_dynamic_app_resolution_supports_common_display_aliases_without_whitelist():
    apps = [
        {"name": "Google Chrome", "bundle_id": "chrome", "running": True},
        {
            "name": "Visual Studio Code",
            "bundle_id": "vscode",
            "launch_path": "/Applications/Visual Studio Code.app",
        },
        {
            "name": "System Settings",
            "bundle_id": "settings",
            "launch_path": "/System/Applications/System Settings.app",
        },
    ]
    assert resolve_app("Chrome", apps)["bundle_id"] == "chrome"
    assert resolve_app("VS Code", apps)["bundle_id"] == "vscode"
    assert resolve_app("Settings", apps)["bundle_id"] == "settings"


def test_ambiguous_fuzzy_app_match_fails_closed():
    apps = [
        {"name": "Notes", "bundle_id": "one", "launch_path": "/Applications/Notes.app"},
        {"name": "Notes", "bundle_id": "two", "launch_path": "/Applications/Notes-2.app"},
    ]
    assert resolve_app("note", apps) is None


def test_url_clause_remains_a_url_command_for_runtime_direct_router():
    from companion_agent.direct import parse_direct

    plan = GoalCompiler().compile("Open https://example.com/ in Chrome")
    assert parse_direct(plan.normalized).kind == "url"
