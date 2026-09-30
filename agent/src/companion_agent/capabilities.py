"""Conservative transport capabilities, separate from per-surface authority.

A supported tool contract does not prove that a target, extension, permission or
capture is available. Every operation still needs a fresh successful observation.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class DriverCapabilities:
    accessibility_tokens: bool = False
    structured_browser: bool = False
    capture_bound_pixels: bool = False
    visual_regions: bool = False
    visual_regions_contract: bool = False
    desktop_capture: bool = False
    background_actions: bool = False
    background_type: bool = False
    native_menu: bool = False
    screenshot: bool = False
    bounded_observation: bool = False

    @classmethod
    def from_tools(cls, tools: list[dict]):
        # Duplicate names or malformed contracts cannot confer capabilities.
        schemas = {}
        for tool in tools:
            name = tool.get("name")
            schema = tool.get("inputSchema")
            if not isinstance(name, str) or name in schemas or not isinstance(schema, dict):
                return cls()
            properties = schema.get("properties", {})
            if not isinstance(properties, dict):
                return cls()
            schemas[name] = properties

        def accepts(name, **fields):
            props = schemas.get(name, {})
            return (
                all(
                    isinstance(props.get(field), dict) and props[field].get("type") == kind
                    for field, kind in fields.items()
                )
                and name in schemas
            )

        native = accepts("get_window_state", pid="integer", window_id="integer")
        click = accepts("click", pid="integer", window_id="integer", element_token="string")
        delivery = schemas.get("click", {}).get("delivery_mode", {})
        return cls(
            accessibility_tokens=native and click,
            structured_browser=accepts("get_browser_state", pid="integer", window_id="integer")
            and accepts("browser_click", target_id="string", tab_id="string", ref="string")
            and accepts("browser_type", target_id="string", tab_id="string", ref="string"),
            capture_bound_pixels=native
            and accepts("get_window_state", include_screenshot="boolean")
            and accepts("click", capture_id="string", x="number", y="number"),
            # Tool schemas only prove API availability; the separately licensed optional
            # extension must pass a live exact-capture parse before this becomes true.
            visual_regions=False,
            visual_regions_contract=accepts("parse_visual_regions", capture_id="string"),
            desktop_capture="get_desktop_state" in schemas,
            background_actions=click and "background" in delivery.get("enum", []),
            background_type=accepts(
                "type_text", pid="integer", window_id="integer", element_token="string"
            )
            and "type_text" in schemas,
            native_menu=click
            and "pick" in schemas.get("click", {}).get("action", {}).get("enum", []),
            screenshot=accepts("get_window_state", include_screenshot="boolean"),
            bounded_observation=native
            and accepts("get_window_state", max_elements="integer", max_depth="integer"),
        )
