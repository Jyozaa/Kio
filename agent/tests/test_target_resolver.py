from companion_agent.semantic_planner import SemanticTaskPlanner
from companion_agent.session_context import RecentAppRef, RecentObjectRef, SessionContext
from companion_agent.target_resolver import TargetResolver, TaskExecutionContext


def test_explicit_semantic_app_precedes_a_different_frontmost_app():
    plan = SemanticTaskPlanner().plan("Open Notes")
    apps = [
        {
            "name": "Notes",
            "bundle_id": "com.apple.Notes",
            "running": True,
            "pid": 42,
        },
        {
            "name": "Chrome",
            "bundle_id": "com.google.Chrome",
            "running": True,
            "active": True,
            "pid": 90,
            "is_browser": True,
        },
    ]

    result = TargetResolver().resolve(plan, apps)

    assert result.source == "semantic_app"
    assert result.app["bundle_id"] == "com.apple.Notes"


def test_current_semantic_object_precedes_unrelated_frontmost_app():
    plan = SemanticTaskPlanner().plan("Inside this new note, let's make the title say Hello")
    app_ref = RecentAppRef("Notes", "com.apple.Notes", 42, 77)
    context = SessionContext(
        current_app="Notes",
        current_bundle_id="com.apple.Notes",
        current_pid=42,
        current_window=77,
        recent_object=RecentObjectRef("NOTE", app_ref, 77, creation_step_id="create-note"),
    )
    apps = [
        {
            "name": "Notes",
            "bundle_id": "com.apple.Notes",
            "running": True,
            "pid": 42,
            "windows": [{"window_id": 77}],
        },
        {
            "name": "Chrome",
            "bundle_id": "com.google.Chrome",
            "running": True,
            "active": True,
            "pid": 90,
            "is_browser": True,
        },
    ]

    result = TargetResolver().resolve(plan, apps, session_context=context)

    assert result.source == "recent_object"
    assert result.app["bundle_id"] == "com.apple.Notes"


def test_untargeted_action_uses_unique_frontmost_usable_app():
    plan = SemanticTaskPlanner().plan("Mute me")
    apps = [
        {
            "name": "Discord",
            "bundle_id": "com.example.chat",
            "running": True,
            "active": True,
            "pid": 23,
        },
        {
            "name": "Finder",
            "bundle_id": "com.apple.finder",
            "running": True,
            "active": False,
            "pid": 24,
        },
    ]

    result = TargetResolver().resolve(plan, apps)

    assert result.source == "frontmost"
    assert result.app["name"] == "Discord"


def test_browser_intent_uses_frontmost_browser_from_live_inventory():
    plan = SemanticTaskPlanner().plan("Search for Norbert Wiener")
    apps = [
        {
            "name": "Chrome",
            "bundle_id": "com.google.Chrome",
            "running": True,
            "active": True,
            "pid": 9,
            "is_browser": True,
        },
        {
            "name": "Notes",
            "bundle_id": "com.apple.Notes",
            "running": True,
            "active": False,
            "pid": 10,
        },
    ]

    result = TargetResolver().resolve(plan, apps)

    assert result.source == "frontmost"
    assert result.app["name"] == "Chrome"


def test_task_context_prefers_exact_process_and_window_identity():
    plan = SemanticTaskPlanner().plan("Play the song")
    selected = {
        "name": "Music",
        "bundle_id": "com.example.music",
        "running": True,
        "active": False,
        "pid": 42,
        "windows": [{"window_id": 7}],
    }
    other = {
        "name": "Music",
        "bundle_id": "com.example.music",
        "running": True,
        "active": True,
        "pid": 43,
        "windows": [{"window_id": 8}],
    }
    context = TaskExecutionContext()
    context.bind_app(selected, window_id=7)

    result = TargetResolver().resolve(
        plan, [other, selected], execution_context=context, semantic_step=plan.steps[0]
    )

    assert result.app["pid"] == 42
    assert result.app["windows"][0]["window_id"] == 7


def test_equal_frontmost_candidates_remain_ambiguous():
    plan = SemanticTaskPlanner().plan("Click Start")
    apps = [
        {"name": "One", "bundle_id": "one", "running": True, "active": True, "pid": 1},
        {"name": "Two", "bundle_id": "two", "running": True, "active": True, "pid": 2},
    ]

    result = TargetResolver().resolve(plan, apps)

    assert result.app is None
    assert result.reason == "multiple_active_apps"


def test_lowercase_multiword_hint_matches_installed_application_inventory():
    plan = SemanticTaskPlanner().plan("open visual studio code")
    app = {
        "name": "Visual Studio Code",
        "bundle_id": "com.microsoft.VSCode",
        "running": False,
        "launch_path": "/Applications/Visual Studio Code.app",
    }
    result = TargetResolver().resolve(plan, [app])
    assert result.app == app and result.source == "semantic_app"


def test_named_site_hint_falls_back_to_browser_inventory():
    plan = SemanticTaskPlanner().plan("Open YouTube and search Minecraft")
    browser = {
        "name": "Chrome",
        "bundle_id": "com.google.Chrome",
        "running": True,
        "active": True,
        "pid": 8,
        "is_browser": True,
    }
    result = TargetResolver().resolve(plan, [browser], semantic_step=plan.steps[0])
    assert result.app == browser and result.source == "named_site_browser"


def test_browser_detection_rejects_link_handlers_without_html_viewing(tmp_path):
    import plistlib

    app_path = tmp_path / "Link Handler.app"
    contents = app_path / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleURLTypes": [{"CFBundleURLSchemes": ["http", "https", "example"]}],
                "CFBundleDocumentTypes": [
                    {"LSItemContentTypes": ["public.json"], "CFBundleTypeRole": "Viewer"}
                ],
            }
        )
    )
    assert not TargetResolver.is_browser({"launch_path": str(app_path)})


def test_browser_detection_uses_http_metadata_and_html_document_support(tmp_path):
    import plistlib

    app_path = tmp_path / "Generic Web Viewer.app"
    contents = app_path / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleURLTypes": [{"CFBundleURLSchemes": ["https", "file"]}],
                "CFBundleDocumentTypes": [
                    {"LSItemContentTypes": ["public.html"], "CFBundleTypeRole": "Viewer"}
                ],
            }
        )
    )
    assert TargetResolver.is_browser({"launch_path": str(app_path)})


def test_recently_opened_session_app_resolves_a_targetless_followup():
    context = SessionContext(
        current_app="Notes",
        current_bundle_id="com.apple.Notes",
        current_pid=42,
        current_window=77,
        last_completed_goal="Open Notes",
    )
    plan = SemanticTaskPlanner().plan("Create a new note")
    apps = [
        {
            "name": "Notes",
            "bundle_id": "com.apple.Notes",
            "running": True,
            "active": False,
            "pid": 42,
            "windows": [{"window_id": 77}],
        }
    ]

    result = TargetResolver().resolve(plan, apps, session_context=context)

    assert result.source == "session_app"
    assert result.app["bundle_id"] == "com.apple.Notes"


def test_current_browser_session_resolves_search_when_another_app_is_frontmost():
    context = SessionContext(
        current_app="Safari",
        current_bundle_id="com.apple.Safari",
        current_pid=42,
        current_window=77,
    )
    plan = SemanticTaskPlanner().plan("Google search Norbert Wiener")
    apps = [
        {
            "name": "Safari",
            "bundle_id": "com.apple.Safari",
            "running": True,
            "active": False,
            "pid": 42,
            "is_browser": True,
            "windows": [{"window_id": 77}],
        },
        {
            "name": "Finder",
            "bundle_id": "com.apple.finder",
            "running": True,
            "active": True,
            "pid": 90,
        },
    ]

    result = TargetResolver().resolve(plan, apps, session_context=context)

    assert result.source == "session_app"
    assert result.app["name"] == "Safari"
