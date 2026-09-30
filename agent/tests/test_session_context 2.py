from companion_agent.session_context import SessionContext


def test_context_resolves_search_to_current_browser_and_preserves_exact_query():
    context = SessionContext(current_app="Google Chrome", current_bundle_id="chrome")
    goal, command = context.resolve("Search Norbert Wiener.")
    assert goal == "Search Norbert Wiener."
    assert command is None
    apps = [{"bundle_id": "chrome", "running": True, "pid": 42, "is_browser": True}]
    assert context.contextual_target(goal, apps) == "Google Chrome"


def test_context_resolves_there_to_last_verified_page():
    context = SessionContext(
        current_app="Safari",
        current_bundle_id="safari",
        current_page="https://example.com/page",
    )
    _, command = context.resolve("Go there")
    assert command is not None
    assert command.value == "https://example.com/page"
    assert command.application_name == "Safari"


def test_named_object_reference_resolves_only_after_completed_creation():
    context = SessionContext()
    context.record_goal("Make a new note", "needs_user")
    assert context.resolve("Call it Hello")[0] == "Call it Hello"
    context.record_goal("Make a new note", "completed")
    assert context.last_created_object_type == "note"
    assert context.resolve("Call it Hello")[0] == 'Type "Hello" into Title field'
    assert context.resolve("Open it")[0] == "Open the most recently created note"


def test_context_is_bounded_and_expiration_clears_sensitive_semantics():
    context = SessionContext(updated_at=100.0)
    for index in range(20):
        context.recent_named_entities.insert(0, f"Name {index}")
        context.recent_named_entities = context.recent_named_entities[:8]
    assert len(context.recent_named_entities) == 8
    context.last_entered_text = "private content"
    context.expire_if_stale(now=701.0)
    assert context.last_entered_text == ""
    assert context.recent_named_entities == []


def test_closed_target_invalidates_app_and_object_context():
    context = SessionContext(
        current_app="Notes",
        current_bundle_id="notes",
        current_pid=42,
        last_created_object_type="note",
        last_entered_text="private",
    )
    assert not context.validate_target([], now=context.updated_at)
    assert context.current_app == ""
    assert context.last_created_object_type == ""
    assert context.last_entered_text == ""


def test_created_object_referent_survives_app_switch_and_requests_fresh_regrounding():
    from companion_agent.semantic_planner import ObjectType, SemanticOperation, SemanticStep

    context = SessionContext()
    context.record_target({"name": "Notes", "bundle_id": "notes", "pid": 10}, 20)
    context.record_semantic_step(
        SemanticStep(SemanticOperation.CREATE, object_type=ObjectType.NOTE),
        {"name": "Notes", "bundle_id": "notes", "pid": 10},
        20,
    )
    context.record_target({"name": "Arc", "bundle_id": "arc", "pid": 11}, 21)
    resolved, _ = context.resolve("Inside this new note, make the title Hello")
    assert "most recently created note" in resolved
    assert resolved.endswith("in Notes")
    assert context.recent_object.validity == "verified"

    assert not context.validate_target([], now=context.updated_at)
    assert context.last_created_object_type == "note"
    assert context.recent_object.validity == "needs_regrounding"
    assert context.recent_object.window_id is None


def test_followup_goal_targets_the_app_just_opened():
    context = SessionContext(
        current_app="Notes",
        current_bundle_id="notes",
        current_pid=42,
        last_completed_goal="Open Notes",
    )
    apps = [{"bundle_id": "notes", "running": True, "pid": 42}]
    assert context.contextual_target("Make a new note", apps) == "Notes"


def test_topic_reset_drops_context():
    context = SessionContext(current_app="Safari", current_bundle_id="safari")
    context.resolve("Start over")
    assert not context.current_app and not context.current_bundle_id
