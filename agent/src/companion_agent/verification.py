"""Independent deterministic outcome checks; a model's DONE is never evidence."""

import re
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from urllib.parse import parse_qs, unquote, unquote_plus, urlsplit

from .candidates import CLICK_ROLES, SELECT_ROLES, TYPE_ROLES, Observation
from .direct import destination_matches, normalize_url
from .metrics import timed
from .policy import literal_text


class VerificationStatus(StrEnum):
    VERIFIED = "VERIFIED"
    NOT_VERIFIED = "NOT_VERIFIED"
    UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class Expectation:
    kind: str
    target: str = ""
    expected: str | bool = ""


@dataclass(frozen=True)
class VerificationState:
    observation: Observation
    app_names: tuple[str, ...] = ()
    url: str | None = None
    # Only explicitly authorized local files, supplied by trusted orchestration.
    files: tuple[Path, ...] = ()


@dataclass(frozen=True)
class Evidence:
    kind: str
    expected: str | bool
    observed: str | bool | None


@dataclass(frozen=True)
class VerificationResult:
    status: VerificationStatus
    evidence: tuple[Evidence, ...] = ()
    reason: str = ""


def semantic_expectations(semantic_step) -> tuple[Expectation, ...]:
    """Turn planner completion conditions into typed observation checks."""
    if semantic_step is None:
        return ()
    operation = str(getattr(getattr(semantic_step, "operation", None), "value", ""))
    object_type = str(getattr(getattr(semantic_step, "object_type", None), "value", ""))
    parameters = getattr(semantic_step, "parameters", {}) or {}
    conditions = tuple(getattr(semantic_step, "completion_conditions", ()) or ())
    if operation == "OPEN":
        app = str(getattr(semantic_step, "application_hint", ""))
        return (Expectation("app", expected=app),) if app else ()
    if operation == "CREATE" and object_type in {"NOTE", "DOCUMENT", "EMAIL_DRAFT"}:
        return (
            Expectation(
                "created_object", object_type, str(getattr(semantic_step, "object_label", ""))
            ),
        )
    if operation in {"TYPE", "SET_FIELD"} and parameters.get("field"):
        return (Expectation("field", str(parameters["field"]), str(parameters.get("text", ""))),)
    if operation == "SET_STATE":
        desired = getattr(semantic_step, "desired_state", None)
        desired_value = str(getattr(desired, "value", desired or ""))
        if object_type == "MEDIA_PLAYBACK" and desired_value in {"PLAYING", "PAUSED"}:
            return (Expectation("media_state", "primary_transport", desired_value),)
        if object_type == "CONTROL" and desired_value in {"MUTED", "UNMUTED"}:
            return (Expectation("control_state", "microphone", desired_value),)
    if operation == "CAPTURE" and object_type == "PHOTO":
        return (Expectation("photo_capture", "photo", True),)
    if operation == "NEW_TAB":
        return (Expectation("new_tab", "", True),)
    if operation == "SEARCH" and parameters.get("query"):
        return (
            Expectation(
                "search",
                str(parameters["query"]),
                str(parameters.get("search_scope", "CURRENT_SITE")),
            ),
        )
    if operation == "NAVIGATE" and parameters.get("url"):
        return (Expectation("navigate", str(parameters["url"]), True),)
    for condition in conditions:
        if condition.startswith("media_state="):
            return (Expectation("media_state", "primary_transport", condition.split("=", 1)[1]),)
        if condition.startswith(("title=", "body=", "subject=", "recipient=")):
            field_name, value = condition.split("=", 1)
            return (Expectation("field", field_name, value),)
    return ()


def requirements(goal, observation, text=None):
    result = []
    text = literal_text(goal) if text is None else text
    fields = [e for e in observation.elements if e.visible and e.role in TYPE_ROLES]
    mentioned = [e for e in fields if e.label and e.label.casefold() in goal.casefold()]
    if text is not None:
        matched = mentioned if mentioned else fields if len(fields) == 1 else []
        result.append(
            Expectation("field", matched[0].label if len(matched) == 1 else "\0unknown", text)
        )
    option = re.search(r"\b(?:choose|select)\s+option\s+([\w-]+)", goal, re.IGNORECASE)
    if option:
        result.append(Expectation("option", "", "option " + option[1]))
    if "success" in goal.casefold():
        result.append(Expectation("marker", "Success", "Success"))
    if re.search(r"\bpause\b", goal, re.IGNORECASE):
        result.append(Expectation("media_state", "", "PAUSED"))
    elif re.search(r"\b(?:play|resume)\b", goal, re.IGNORECASE):
        result.append(Expectation("media_state", "", "PLAYING"))
    if re.search(r"\b(?:open\s+)?a?\s*new\s+tab\b", goal, re.IGNORECASE):
        result.append(Expectation("new_tab", "", True))
    toggle = re.fullmatch(
        r"(check|uncheck|turn on|turn off|mute|unmute|enable|disable)\s+(?:the\s+)?(.+?)(?:\s+(?:checkbox|toggle))?\.?",
        goal.strip(),
        re.IGNORECASE,
    )
    if toggle:
        action, target = toggle[1].casefold(), toggle[2]
        if re.search(r"\b(?:microphone|mic)\b", target, re.IGNORECASE):
            target = "microphone"
        result.append(
            Expectation("checked", target, action in {"check", "turn on", "mute", "enable"})
        )
    # Typing a field is not proof of a requested external submission.
    if "success" not in goal.casefold() and re.search(
        r"\b(send|submit|publish|post|upload|delete|download)\b", goal, re.IGNORECASE
    ):
        result.append(Expectation("unsupported"))
    # Unknown additional outcome requests must not become a partial completion.
    if re.search(
        r"\b(?:and|then)\s+(?:delete|send|download|upload|publish|install|pay|buy)\b",
        goal,
        re.IGNORECASE,
    ):
        result.append(Expectation("unsupported"))
    if re.search(r"\b(click|press)\b", goal, re.IGNORECASE) and "success" not in goal.casefold():
        result.append(Expectation("unsupported"))
    return tuple(result)


def _observation_url(observation):
    marker = "|kio_url="
    if marker not in observation.title:
        return None
    value = observation.title.split(marker, 1)[-1].split("|", 1)[0]
    value = unquote(value)
    return value if normalize_url(value) else None


def _address_field_url(observation):
    address_labels = re.compile(
        r"\b(?:address|smart search|search or enter|location bar|website address)\b",
        re.IGNORECASE,
    )
    values = [
        element.value
        for element in observation.elements
        if element.visible
        and element.role in {"AXTextField", "AXSearchField", "textbox"}
        and element.native.get("in_web_content") is not True
        and address_labels.search(element.label)
        and element.value
    ]
    return next((value for value in values if normalize_url(value)), None)


def _ax_document_url(observation):
    url_keys = {
        "url",
        "documenturl",
        "documenturi",
        "currenturl",
        "href",
        "axurl",
        "axdocumenturl",
    }
    document_roles = {"axwebarea", "axdocument", "web_area", "document"}

    def values(value, depth=0):
        if depth > 4 or not isinstance(value, dict):
            return
        for key, item in value.items():
            normalized_key = re.sub(r"[^a-z]", "", str(key).casefold())
            if normalized_key in url_keys and isinstance(item, str):
                yield item
            elif isinstance(item, dict):
                yield from values(item, depth + 1)

    for element in observation.elements:
        if element.role.casefold() not in document_roles:
            continue
        candidates = list(values(element.native))
        if element.value:
            candidates.append(element.value)
        for value in candidates:
            if normalize_url(value):
                return value
    return None


def _title_confirms_host(observation, expected_url):
    expected = normalize_url(expected_url)
    if not expected:
        return False
    host = (urlsplit(expected).hostname or "").casefold().removeprefix("www.")
    title = observation.title.split("|kio_tab_id=", 1)[0].split("|kio_url=", 1)[0]
    title = title.casefold()
    if not host:
        return False
    # Page/window titles are weaker evidence than a URL. Accept only the exact
    # host as a token, never a substring of arbitrary page content.
    return bool(re.search(rf"(?<![a-z0-9.-])(?:www\.)?{re.escape(host)}(?![a-z0-9.-])", title))


class GoalVerifier:
    def __init__(self, expectations=(), *, generated_text=None):
        self.expectations = tuple(expectations)
        self.generated_text = generated_text

    @timed("goal_verifier")
    async def verify(self, goal, initial_state, current_state, action_history):
        return self.check(goal, initial_state, current_state, action_history)

    def check(self, goal, initial_state, current_state, action_history):
        initial = (
            initial_state
            if isinstance(initial_state, VerificationState)
            else VerificationState(initial_state)
        )
        current = (
            current_state
            if isinstance(current_state, VerificationState)
            else VerificationState(current_state)
        )
        expected = self.expectations or requirements(goal, current.observation, self.generated_text)
        if not expected:
            return VerificationResult(
                VerificationStatus.UNKNOWN, reason="No independent verifier for this goal."
            )
        evidence = []
        statuses = []
        for requirement in expected:
            status, observed = self._check_one(requirement, initial, current)
            statuses.append(status)
            evidence.append(Evidence(requirement.kind, requirement.expected, observed))
        status = (
            VerificationStatus.NOT_VERIFIED
            if VerificationStatus.NOT_VERIFIED in statuses
            else VerificationStatus.UNKNOWN
            if VerificationStatus.UNKNOWN in statuses
            else VerificationStatus.VERIFIED
        )
        return VerificationResult(
            status,
            tuple(evidence),
            "All requested outcomes observed."
            if status == VerificationStatus.VERIFIED
            else "Requested outcome is not independently verified.",
        )

    def _check_one(self, requirement, initial, current):
        kind, target, want = requirement.kind, requirement.target, requirement.expected
        elements = [e for e in current.observation.elements if e.visible]
        matches = [e for e in elements if e.label.casefold() == target.casefold()]
        observed = None
        if kind == "field":
            synonyms = {
                "title": ("title", "name"),
                "body": ("body", "message", "note", "content"),
                "recipient": ("to", "recipient", "email address"),
                "subject": ("subject",),
            }
            terms = synonyms.get(target.casefold(), (target.casefold(),))
            matches = [
                e
                for e in elements
                if e.role in TYPE_ROLES and any(term in e.label.casefold() for term in terms)
            ]
            if not matches:
                matches = [
                    e
                    for e in elements
                    if e.role in TYPE_ROLES and e.label.casefold() == target.casefold()
                ]
            if len(matches) != 1:
                return VerificationStatus.UNKNOWN, None
            observed = matches[0].value
        elif kind == "option":
            matches = [
                e
                for e in elements
                if e.role in SELECT_ROLES
                and (not target or e.label.casefold() == target.casefold())
            ]
            if len(matches) != 1:
                return VerificationStatus.UNKNOWN, None
            observed = (matches[0].value or "").casefold()
            want = str(want).casefold()
            if observed == want.removeprefix("option "):
                observed = want
        elif kind in {"marker", "appeared", "disappeared"}:
            found = bool(matches)
            if kind in {"appeared", "disappeared"}:
                before = any(
                    e.visible and e.label.casefold() == target.casefold()
                    for e in initial.observation.elements
                )
                observed = (not before and found) if kind == "appeared" else (before and not found)
                want = True
            else:
                # Prefer content; window titles alone can lag or be misleading.
                found = any(e.role != "AXWindow" for e in matches)
                observed = str(want) if found else None
        elif kind == "created_object":
            changed = initial.observation.fingerprint() != current.observation.fingerprint()
            editable = any(e.role in TYPE_ROLES for e in elements)
            if want == "EMAIL_DRAFT":
                labelled_composer = any(
                    e.role in TYPE_ROLES
                    and re.search(
                        r"\b(?:to|recipient|subject|message|body)\b",
                        e.label,
                        re.IGNORECASE,
                    )
                    for e in elements
                )
                added_field = sum(e.role in TYPE_ROLES for e in elements) > sum(
                    e.role in TYPE_ROLES for e in initial.observation.elements
                )
                observed = bool(changed and editable and (labelled_composer or added_field))
            else:
                observed = bool(changed and editable)
            want = True
        elif kind == "checked":
            toggle_roles = {"AXCheckBox", "checkbox", "switch", "AXSwitch"}
            if target.casefold() == "microphone":
                matches = [
                    e
                    for e in elements
                    if e.role in toggle_roles
                    and re.search(
                        r"\b(?:mute|muted|unmute|microphone|mic|audio input)\b",
                        e.label,
                        re.IGNORECASE,
                    )
                ]
            else:
                matches = [e for e in matches if e.role in toggle_roles]
            if len(matches) != 1 or matches[0].checked is None:
                return VerificationStatus.UNKNOWN, None
            observed = matches[0].checked
        elif kind == "app":
            observed = any(n.casefold() == str(want).casefold() for n in current.app_names)
            want = True
        elif kind == "url":
            if current.url is None:
                return VerificationStatus.UNKNOWN, None
            if normalize_url(str(want)) is None:
                return VerificationStatus.UNKNOWN, None
            return (
                VerificationStatus.VERIFIED
                if destination_matches(str(want), current.url)
                else VerificationStatus.NOT_VERIFIED
            ), current.url
        elif kind == "transition":
            if initial.url is None or current.url is None:
                return VerificationStatus.UNKNOWN, None
            observed = normalize_url(initial.url) != normalize_url(current.url)
            want = True
        elif kind == "media_state":
            observed = _primary_media_state(
                elements, require_transport=target == "primary_transport"
            )
            if observed is None:
                return VerificationStatus.UNKNOWN, None
        elif kind == "new_tab":
            marker = "|kio_tab_id="
            before = (
                initial.observation.title.split(marker, 1)[-1].split("|", 1)[0]
                if marker in initial.observation.title
                else None
            )
            after = (
                current.observation.title.split(marker, 1)[-1].split("|", 1)[0]
                if marker in current.observation.title
                else None
            )
            initial_tabs = {
                (e.label.casefold(), e.role.casefold())
                for e in initial.observation.elements
                if e.visible and "tab" in e.role.casefold()
            }
            current_tabs = {
                (e.label.casefold(), e.role.casefold())
                for e in elements
                if "tab" in e.role.casefold()
            }
            observed = bool((before and after and before != after) or (current_tabs - initial_tabs))
        elif kind == "navigate":
            for url in (
                current.url,
                _observation_url(current.observation),
                _address_field_url(current.observation),
                _ax_document_url(current.observation),
            ):
                if url:
                    return (
                        VerificationStatus.VERIFIED
                        if destination_matches(str(target), url)
                        else VerificationStatus.NOT_VERIFIED,
                        url,
                    )
            if _title_confirms_host(current.observation, str(target)):
                return VerificationStatus.VERIFIED, current.observation.title
            return VerificationStatus.UNKNOWN, None
        elif kind == "search":
            query = str(target).casefold().strip()
            url = current.url or _observation_url(current.observation)
            scope = str(want).split("|", 1)[0].upper()
            if scope == "CURRENT_SITE":
                initial_url = initial.url or _observation_url(initial.observation)
                if not initial_url or not url:
                    return VerificationStatus.UNKNOWN, url
                if not _same_site(initial_url, url):
                    return VerificationStatus.NOT_VERIFIED, url
            found_url_query = False
            if url:
                parts = urlsplit(url)
                values = [
                    unquote_plus(value).casefold()
                    for value in parse_qs(parts.query).values()
                    for value in value
                ]
                values.extend(
                    (unquote_plus(parts.path).casefold(), unquote_plus(parts.fragment).casefold())
                )
                found_url_query = any(query == value or query in value for value in values)
            if found_url_query:
                return VerificationStatus.VERIFIED, url
            before_content = {
                e.label.casefold()
                for e in initial.observation.elements
                if e.visible and e.role not in TYPE_ROLES and e.role != "AXWindow"
            }
            matching_result = [
                e.label
                for e in elements
                if e.role not in TYPE_ROLES
                and e.role != "AXWindow"
                and query
                and query in e.label.casefold()
            ]
            if matching_result and any(
                label.casefold() not in before_content for label in matching_result
            ):
                return VerificationStatus.VERIFIED, "search results mention the requested query"
            return VerificationStatus.UNKNOWN, url
        elif kind == "control_state":
            desired = str(want).upper()
            toggle_roles = {"AXCheckBox", "AXSwitch", "checkbox", "switch"}
            switches = [
                e
                for e in elements
                if e.role in toggle_roles
                and re.search(r"\b(?:mute|microphone|mic|audio input)\b", e.label, re.IGNORECASE)
            ]
            if len(switches) == 1 and switches[0].checked is not None:
                observed = "MUTED" if switches[0].checked else "UNMUTED"
            else:
                labels = " ".join(
                    e.label.casefold()
                    for e in elements
                    if e.role in CLICK_ROLES
                    and re.search(r"\b(?:mute|unmute|microphone|mic)\b", e.label, re.IGNORECASE)
                )
                if desired == "MUTED" and re.search(r"\bunmute\b", labels):
                    observed = "MUTED"
                elif (
                    desired == "UNMUTED"
                    and re.search(r"\bmute\b", labels)
                    and not re.search(r"\bunmute\b", labels)
                ):
                    observed = "UNMUTED"
            want = desired
        elif kind == "file":
            # Caller supplies allowed concrete paths; models cannot nominate files.
            matches = [p for p in current.files if p.name == target and not p.is_symlink()]
            if len(matches) != 1:
                return VerificationStatus.UNKNOWN, None
            observed = matches[0].is_file() and matches[0].stat().st_size > 0
            want = True
        elif kind == "photo_capture":
            before = {e.label.casefold().strip() for e in initial.observation.elements if e.visible}
            after = {e.label.casefold().strip() for e in elements if e.visible}
            result_labels = {
                "retake",
                "retake photo",
                "use photo",
                "take another photo",
                "photo captured",
                "capture complete",
            }
            observed = bool((after - before) & result_labels)
        else:
            return VerificationStatus.UNKNOWN, None
        return (
            VerificationStatus.VERIFIED if observed == want else VerificationStatus.NOT_VERIFIED
        ), observed


def _primary_media_state(elements, *, require_transport=False) -> str | None:
    """Infer playback only from a grounded transport control or transport region."""
    by_index = {
        element.native.get("element_index"): element
        for element in elements
        if type(element.native.get("element_index")) is int
    }
    controls = []
    for element in elements:
        label = element.label.casefold().strip()
        if not element.visible or element.role not in CLICK_ROLES:
            continue
        state = (
            "PLAYING"
            if label in {"pause", "pause playback", "stop playing"}
            else "PAUSED"
            if label in {"play", "resume", "playback paused", "start playback"}
            else None
        )
        if state is None:
            continue
        context = [label]
        parent = element.native.get("parent_index")
        visited = set()
        while type(parent) is int and parent not in visited:
            visited.add(parent)
            ancestor = by_index.get(parent)
            if ancestor is None:
                break
            context.extend((ancestor.label.casefold(), ancestor.role.casefold()))
            parent = ancestor.native.get("parent_index")
        for key in (
            "parent_label",
            "ancestor_labels",
            "nearby_labels",
            "region_label",
            "container_label",
            "group_label",
            "row_label",
        ):
            value = element.native.get(key)
            if isinstance(value, str):
                context.append(value.casefold())
            elif isinstance(value, (list, tuple)):
                context.extend(str(item).casefold() for item in value)
        parent_id = element.native.get("parent_index")
        if type(parent_id) is int:
            context.extend(
                sibling.label.casefold()
                for sibling in elements
                if sibling.native.get("parent_index") == parent_id
            )
        joined = " ".join(context)
        relevant = bool(
            re.search(r"\b(?:transport|media|playback|now playing|player|track controls)\b", joined)
            or sum(
                bool(re.search(r"\b(?:play|pause|next|previous|shuffle|repeat|skip)\b", item))
                for item in context
            )
            >= 2
            or element.native.get("is_primary_media_control") is True
        )
        controls.append((state, relevant))
    primary = [state for state, relevant in controls if relevant]
    if require_transport:
        return primary[0] if primary and len(set(primary)) == 1 else None
    if len(set(primary)) == 1:
        return primary[0]
    if len(controls) == 1:
        return controls[0][0]
    return None


def _same_site(before: str, after: str) -> bool:
    """Accept a host and its subdomains, but never a different destination site."""
    first = (urlsplit(before).hostname or "").casefold().removeprefix("www.")
    second = (urlsplit(after).hostname or "").casefold().removeprefix("www.")
    if not first or not second:
        return False
    if first == second:
        return True
    # A site can add or remove a subdomain such as "www" or "music" while
    # retaining its base host. Require a complete DNS-label boundary.
    return second.endswith("." + first) or first.endswith("." + second)
