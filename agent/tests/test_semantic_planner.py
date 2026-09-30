from companion_agent.semantic_planner import (
    RequestMode,
    SemanticOperation,
    SemanticTaskPlanner,
    classify_request_mode,
)


def test_email_paraphrases_share_bounded_semantics_and_literal():
    planner = SemanticTaskPlanner()
    utterances = [
        "Open Outlook and draft an email to example@gmail.com",
        "Could you bring Outlook up and start an email addressed to example@gmail.com for me?",
        "I need an email draft for example@gmail.com in Outlook.",
    ]
    plans = [planner.plan(text) for text in utterances]
    drafts = [
        next(step for step in plan.steps if step.operation == SemanticOperation.CREATE)
        for plan in plans
    ]
    recipients = [
        next(step for step in plan.steps if step.parameters.get("field") == "recipient")
        for plan in plans
    ]
    assert all(step.object_type == "EMAIL_DRAFT" for step in drafts)
    assert {step.parameters["text"] for step in recipients} == {"example@gmail.com"}
    assert all("do_not_send" in step.constraints for step in drafts)
    assert all(
        plan.steps.index(field) > plan.steps.index(draft)
        for plan, draft, field in zip(plans, drafts, recipients, strict=True)
    )


def test_new_tab_precedes_generic_open_and_media_desired_state_is_semantic():
    planner = SemanticTaskPlanner()
    assert planner.plan("open a new tab").steps[0].operation == SemanticOperation.NEW_TAB
    assert planner.plan("pause whatever is playing").steps[0].desired_state == "PAUSED"
    assert planner.plan("play it again").steps[0].desired_state == "PLAYING"


def test_compound_app_launch_keeps_the_requested_operation_as_a_second_step():
    plan = SemanticTaskPlanner().plan("Open Spotify and play a song")
    assert [step.operation for step in plan.steps] == [
        SemanticOperation.OPEN,
        SemanticOperation.SET_STATE,
    ]
    assert plan.steps[0].application_hint == "Spotify"
    assert plan.steps[1].application_hint == "Spotify"
    assert plan.steps[1].object_type == "MEDIA_PLAYBACK"
    assert plan.steps[1].desired_state == "PLAYING"
    assert plan.steps[1].source_clause == "play a song"


def test_pressing_play_is_one_shot_while_playing_a_song_sets_state():
    pressed = SemanticTaskPlanner().plan("Press the Play button").steps[0]
    played = SemanticTaskPlanner().plan("Play the song").steps[0]
    assert pressed.operation == SemanticOperation.ACTIVATE_CONTROL_ONCE
    assert pressed.object_label.casefold() == "play"
    assert played.operation == SemanticOperation.SET_STATE
    assert played.desired_state == "PLAYING"


def test_open_youtube_search_is_site_scoped_with_step_specific_clause():
    plan = SemanticTaskPlanner().plan("Open YouTube and search Minecraft")
    search = next(step for step in plan.steps if step.operation == SemanticOperation.SEARCH)
    assert search.application_hint.casefold() == "youtube"
    assert search.parameters["query"].casefold() == "minecraft"
    assert search.parameters["search_scope"] == "CURRENT_SITE"
    assert search.source_clause.casefold() == "search minecraft"


def test_named_site_search_and_global_search_keep_distinct_scopes():
    planner = SemanticTaskPlanner()
    site_first = planner.plan("Search YouTube for Minecraft").steps[0]
    query_first = planner.plan("Search for Minecraft on YouTube").steps[0]
    global_search = planner.plan("Search Minecraft").steps[0]
    google_search = planner.plan("Search Google for Minecraft").steps[0]

    assert site_first.operation == SemanticOperation.SEARCH
    assert site_first.application_hint == "YouTube"
    assert site_first.parameters == {"query": "Minecraft", "search_scope": "NAMED_SITE"}
    assert query_first.parameters == {"query": "Minecraft", "search_scope": "NAMED_SITE"}
    assert global_search.parameters["search_scope"] == "GLOBAL_WEB"
    assert google_search.application_hint == ""
    assert google_search.parameters == {"query": "Minecraft", "search_scope": "GLOBAL_WEB"}


def test_chrome_youtube_compound_request_has_precise_current_site_steps():
    from companion_agent.goal_compiler import GoalCompiler, IntentKind
    from companion_agent.runtime import _semantic_execution_plan

    plan = SemanticTaskPlanner().plan(
        "open a new tab in Chrome, go to youtube.com, and search minecraft"
    )
    assert [step.operation for step in plan.steps] == [
        SemanticOperation.OPEN,
        SemanticOperation.NEW_TAB,
        SemanticOperation.NAVIGATE,
        SemanticOperation.SEARCH,
    ]
    assert [step.source_clause.casefold() for step in plan.steps] == [
        "open chrome",
        "open a new tab",
        "go to youtube.com",
        "search minecraft",
    ]
    search = plan.steps[-1]
    assert search.parameters == {"query": "minecraft", "search_scope": "CURRENT_SITE"}
    execution = _semantic_execution_plan(
        plan.original_text, plan, GoalCompiler().compile(plan.original_text)
    )
    assert [step.kind for step in execution.steps] == [
        IntentKind.ENSURE_APP,
        IntentKind.NEW_TAB,
        IntentKind.OPEN_URL,
        IntentKind.CONTINUE_UI_GOAL,
    ]
    assert execution.steps[-1].semantic_step.parameters == search.parameters


def test_search_scope_selects_page_ui_or_global_browser_route():
    from companion_agent.goal_compiler import GoalCompiler, IntentKind
    from companion_agent.runtime import _semantic_execution_plan

    planner = SemanticTaskPlanner()
    current_text = "Open YouTube and search Minecraft"
    current = planner.plan(current_text)
    named_text = "Search YouTube for Minecraft"
    named = planner.plan(named_text)
    global_text = "Search Minecraft"
    global_search = planner.plan(global_text)

    current_plan = _semantic_execution_plan(
        current_text, current, GoalCompiler().compile(current_text)
    )
    named_plan = _semantic_execution_plan(named_text, named, GoalCompiler().compile(named_text))
    global_plan = _semantic_execution_plan(
        global_text, global_search, GoalCompiler().compile(global_text)
    )

    assert current_plan.steps[-1].kind == IntentKind.CONTINUE_UI_GOAL
    assert named_plan.steps[-1].kind == IntentKind.CONTINUE_UI_GOAL
    assert global_plan.steps[-1].kind == IntentKind.WEB_SEARCH


def test_conversational_open_up_with_app_suffix_is_only_an_app_step():
    variants = (
        "Open Notes.",
        "Open up Notes.",
        "Open the Notes app.",
        "Can you open Notes?",
        "Can you open up Notes for me?",
        "Alright, can you open up the Notes app for me?",
        "Bring Notes up.",
        "Launch Notes.",
        "Show me Notes.",
    )
    for utterance in variants:
        plan = SemanticTaskPlanner().plan(utterance)
        assert len(plan.steps) == 1, utterance
        assert plan.steps[0].operation == SemanticOperation.OPEN, utterance
        assert plan.steps[0].application_hint == "Notes", utterance


def test_unquoted_title_assignment_in_a_created_note_is_literal_and_actionable():
    plan = SemanticTaskPlanner().plan("Inside this new note, let's make the title say Hello.")
    assert plan.request_mode == RequestMode.ACT
    assert len(plan.steps) == 1
    step = plan.steps[0]
    assert step.operation == SemanticOperation.SET_FIELD
    assert step.object_type == "FIELD"
    assert step.object_label == "current_object"
    assert step.parameters == {"field": "title", "text": "Hello"}
    assert step.completion_conditions == ("title=Hello",)


def test_natural_search_variants_preserve_query_text():
    utterances = (
        "Search Google for Norbert Wiener",
        "Google search Norbert Wiener",
        "Can you Google search Norbert Wiener?",
        "Look up Norbert Wiener",
        "Search for Norbert Wiener",
        "Can you search Norbert Wiener for me?",
    )
    for utterance in utterances:
        plan = SemanticTaskPlanner().plan(utterance)
        assert len(plan.steps) == 1, utterance
        assert plan.steps[0].operation == SemanticOperation.SEARCH, utterance
        assert plan.steps[0].parameters["query"] == "Norbert Wiener", utterance


def test_spoken_web_destinations_normalize_only_in_destination_context():
    planner = SemanticTaskPlanner()
    destination = planner.plan("Open up GitHub dot com slash OpenAI")
    assert destination.steps[0].operation == SemanticOperation.NAVIGATE
    assert destination.steps[0].parameters["url"] == "https://github.com/OpenAI"
    assert not any(
        step.operation == SemanticOperation.NAVIGATE
        for step in planner.plan("The decimal point is one dot five").steps
    )


def test_held_out_question_and_action_language_stays_separate():
    observe = [
        "Where is the mute button in Discord?",
        "Can you tell me where mute is?",
        "Where do I mute myself?",
        "Which button disables my mic?",
        "Where's the microphone toggle?",
        "Am I muted in Discord?",
        "What does this warning mean?",
        "Is this checkbox enabled?",
        "What tab am I currently on?",
        "Where is the search bar?",
        "What options are visible in this window?",
    ]
    act = [
        "Mute me.",
        "Turn my mic off.",
        "Disable my microphone.",
        "Click the mute button in Discord.",
        "Can you mute me?",
    ]
    assert all(classify_request_mode(text) == RequestMode.OBSERVE_AND_ANSWER for text in observe)
    assert all(classify_request_mode(text) == RequestMode.ACT for text in act)
    assert classify_request_mode("What is 2 plus 2?") == RequestMode.ANSWER_ONLY
    assert all(
        SemanticTaskPlanner().plan(text).request_mode == RequestMode.OBSERVE_AND_ANSWER
        for text in observe
    )
    assert all(
        SemanticTaskPlanner().plan(text).steps[0].operation == SemanticOperation.SET_STATE
        for text in act[:3]
    )
    locate = [SemanticTaskPlanner().plan(text).steps[0] for text in observe[:5]]
    assert all(step.operation == SemanticOperation.LOCATE for step in locate)
    assert all(
        step.object_type == "CONTROL" and step.object_label == "microphone" for step in locate
    )


def test_literals_and_compound_draft_constraints_remain_structured():
    text = "Open Outlook, draft an email to example@gmail.com saying \"I'll be 10 minutes late\", but don't send it."
    plan = SemanticTaskPlanner().plan(text)
    draft = next(step for step in plan.steps if step.operation == SemanticOperation.CREATE)
    recipient = next(step for step in plan.steps if step.parameters.get("field") == "recipient")
    body = next(step for step in plan.steps if step.parameters.get("field") == "body")
    assert plan.request_mode == RequestMode.ACT
    assert plan.target_application == "Outlook"
    assert draft.object_type == "EMAIL_DRAFT"
    assert draft.parameters == {}
    assert recipient.parameters == {"field": "recipient", "text": "example@gmail.com"}
    assert body.parameters == {"field": "body", "text": "I'll be 10 minutes late"}
    assert "do_not_send" in draft.constraints and "do_not_send" in plan.constraints
    assert plan.literals[0].value == "example@gmail.com"
    assert plan.literals[1].value == "I'll be 10 minutes late"
    assert len({step.step_id for step in plan.steps}) == len(plan.steps)


def test_semantic_execution_adapter_preserves_separate_field_steps_and_constraints():
    from companion_agent.goal_compiler import GoalCompiler, IntentKind
    from companion_agent.runtime import _semantic_execution_plan

    text = 'Open Outlook, draft an email to example@gmail.com saying "I will be late", but do not send it.'
    semantic = SemanticTaskPlanner().plan(text)
    plan = _semantic_execution_plan(text, semantic, GoalCompiler().compile(text))
    assert [step.kind for step in plan.steps] == [
        IntentKind.ENSURE_APP,
        IntentKind.CONTINUE_UI_GOAL,
        IntentKind.CONTINUE_UI_GOAL,
        IntentKind.CONTINUE_UI_GOAL,
    ]
    assert plan.steps[1].semantic_step.operation == SemanticOperation.CREATE
    assert plan.steps[2].semantic_step.parameters["text"] == "example@gmail.com"
    assert plan.steps[3].semantic_step.parameters["text"] == "I will be late"
    assert all("do_not_send" in step.semantic_step.constraints for step in plan.steps[1:])


def test_notes_and_file_move_keep_separate_parameters_and_constraints():
    planner = SemanticTaskPlanner()
    notes = planner.plan(
        'Go into Notes, create a new note called "Project Ideas", and write "new onboarding flow" inside it.'
    )
    assert [step.operation for step in notes.steps] == [
        SemanticOperation.OPEN,
        SemanticOperation.CREATE,
        SemanticOperation.TYPE,
        SemanticOperation.TYPE,
    ]
    assert notes.steps[2].parameters == {"field": "title", "text": "Project Ideas"}
    assert notes.steps[3].parameters == {"field": "body", "text": "new onboarding flow"}
    move = planner.plan(
        'Open Finder, make a folder called "Coursework", and move report.pdf into it.'
    )
    assert [step.operation for step in move.steps] == [
        SemanticOperation.OPEN,
        SemanticOperation.CREATE,
        SemanticOperation.MOVE,
    ]
    assert move.steps[-1].parameters == {"file": "report.pdf", "destination": "Coursework"}
    assert "source_and_destination_must_be_unique" in move.steps[-1].constraints


def test_ambiguous_action_can_use_only_supplied_laya_enum():
    class BoundedReasoner:
        def __init__(self):
            self.choices = []

        def classify_semantic(self, text, field, choices):
            self.choices.append((field, tuple(choices)))
            if field == "semantic_group":
                return "OBJECT", 0.82
            if field == "semantic_operation":
                return "MOVE", 0.79
            if field == "semantic_object_group":
                return "UI", 0.78
            if field == "semantic_object_type":
                return "GENERIC_UI_OBJECT", 0.76
            return next(iter(choices)), 0.72

    reasoner = BoundedReasoner()
    plan = SemanticTaskPlanner().plan(
        "I want you to rearrange the selected item", reasoner=reasoner
    )
    assert plan.steps[-1].operation == SemanticOperation.MOVE
    assert plan.interpretation_tier == "laya_bounded"
    assert plan.confidence == 0.76
    assert all(len(choices) <= 10 for _, choices in reasoner.choices)


def test_shared_laya_interpreter_classifies_unknown_mode_operation_and_typed_state():
    class Reasoner:
        def __init__(self):
            self.selected = {
                "semantic_request_mode": "ACT",
                "semantic_group": "STATE",
                "semantic_operation": "SET_STATE",
                "semantic_object_group": "UI",
                "semantic_object_type": "CONTROL",
                "semantic_state_group": "TOGGLE",
                "semantic_desired_state": "MUTED",
            }

        def classify_semantic(self, text, field, choices):
            assert self.selected[field] in choices
            return self.selected[field], 0.91

    plan = SemanticTaskPlanner().plan(
        "Could you keep my microphone quiet while recording?", Reasoner()
    )
    assert plan.request_mode == RequestMode.ACT
    assert plan.interpretation_tier == "laya_bounded"
    assert len(plan.steps) == 1
    assert plan.steps[0].operation == SemanticOperation.SET_STATE
    assert plan.steps[0].object_type == "CONTROL"
    assert plan.steps[0].desired_state == "MUTED"
    assert plan.original_text == "Could you keep my microphone quiet while recording?"
    assert (
        plan.steps[0].parameters["request"] == "Could you keep my microphone quiet while recording?"
    )


def test_clear_microphone_transmission_prevention_maps_to_mute_locally():
    plan = SemanticTaskPlanner().plan("Could you prevent my microphone from transmitting audio?")
    assert plan.request_mode == RequestMode.ACT
    assert plan.interpretation_tier == "deterministic"
    assert not plan.unresolved
    assert plan.steps[0].operation == SemanticOperation.SET_STATE
    assert plan.steps[0].desired_state.value == "MUTED"

    negated = SemanticTaskPlanner().plan("Don't prevent my microphone from transmitting audio.")
    assert negated.request_mode == RequestMode.ANSWER_ONLY
    assert not any(
        step.operation == SemanticOperation.SET_STATE and step.desired_state
        for step in negated.steps
    )


def test_laya_unknown_question_stays_read_only_and_low_confidence_fails_closed():
    class ObserveReasoner:
        def classify_semantic(self, text, field, choices):
            answer = "OBSERVE_AND_ANSWER" if field == "semantic_request_mode" else "READ"
            return answer, 0.88

    observed = SemanticTaskPlanner().plan(
        "Could you describe how the microphone is configured?", ObserveReasoner()
    )
    assert observed.request_mode == RequestMode.OBSERVE_AND_ANSWER
    assert observed.steps[0].operation == SemanticOperation.DESCRIBE
    assert "question" in observed.steps[0].parameters

    class UncertainReasoner:
        def classify_semantic(self, text, field, choices):
            choice = next(iter(choices))
            return choice, 0.4

    uncertain = SemanticTaskPlanner().plan("Could you do the thing?", UncertainReasoner())
    assert uncertain.request_mode == RequestMode.ANSWER_ONLY
    assert not uncertain.steps


def test_quoted_instruction_text_is_not_an_action_and_prohibitions_survive_planning():
    assert classify_request_mode('What does "delete the account" mean?') == RequestMode.ANSWER_ONLY
    plan = SemanticTaskPlanner().plan(
        'Open Outlook and draft an email to example@gmail.com saying "send the file", but do not send it.'
    )
    assert plan.request_mode == RequestMode.ACT
    assert "do_not_send" in plan.constraints
    assert all(
        "do_not_send" in step.constraints
        for step in plan.steps
        if step.operation
        in {
            SemanticOperation.CREATE,
            SemanticOperation.TYPE,
        }
    )


def test_application_name_stops_before_the_requested_action_clause():
    from companion_agent.semantic_planner import _application_hint

    text = "Please bring Spotify's sound down."
    assert _application_hint(text) == "Spotify"
    plan = SemanticTaskPlanner().plan(text)
    assert plan.target_application == "Spotify"
    assert [step.operation for step in plan.steps] == [
        SemanticOperation.OPEN,
        SemanticOperation.CUSTOM,
    ]
    assert plan.steps[-1].parameters["request"] == "sound down"
    assert plan.unresolved


def test_lowercase_multiword_app_hint_is_preserved_for_inventory_resolution():
    from companion_agent.semantic_planner import _application_hint

    assert _application_hint("open visual studio code") == "visual studio code"
