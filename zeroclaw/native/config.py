#!/usr/bin/env python3
"""Render the options-owned native ZeroClaw configuration.

The daemon owns `config.toml` after bootstrap. This helper only replaces that
file when the Supervisor options fingerprint changes, so native pairing and
session edits survive ordinary restarts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import tomllib
from typing import Any
import urllib.parse


MAX_OPTIONS_BYTES = 1_048_576
MAX_CONFIG_BYTES = 2_097_152
OPENROUTER_URI = "https://openrouter.ai/api/v1"
HA_READONLY_TOOLS = {"ha__homeassistant__GetLiveContext", "ha__llm__GetDateTime"}
HA_MUTATING_TOOLS = {"ha__homeassistant__call_action"}


class ConfigError(Exception):
    """A safe-to-display configuration validation or lifecycle error."""


def _lstat(path: Path) -> os.stat_result | None:
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def _check_no_symlink_components(path: Path, label: str) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise ConfigError(f"{label} path is not absolute and normalized")
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        info = _lstat(current)
        if info is not None and stat.S_ISLNK(info.st_mode):
            raise ConfigError(f"{label} path contains a symlink")


def _require_directory(path: Path, label: str) -> None:
    _check_no_symlink_components(path, label)
    info = _lstat(path)
    if info is None or not stat.S_ISDIR(info.st_mode):
        raise ConfigError(f"{label} parent is not a real directory")


def _read_regular(path: Path, label: str, maximum: int) -> bytes:
    _check_no_symlink_components(path, label)
    info = _lstat(path)
    if info is None or not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
        raise ConfigError(f"{label} is missing, unsafe, or too large")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            data = source.read(maximum + 1)
    except OSError:
        raise ConfigError(f"{label} could not be read safely") from None
    if len(data) > maximum:
        raise ConfigError(f"{label} is too large")
    return data


def _fsync_directory(path: Path) -> None:
    if os.name != "posix":
        return
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_private_write(path: Path, content: bytes) -> None:
    _require_directory(path.parent, "output")
    info = _lstat(path)
    if info is not None and (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
        raise ConfigError("output file is not a regular file")
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}-{secrets.token_hex(5)}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(temporary, flags, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def _quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _string_array(values: list[str]) -> str:
    return "[" + ", ".join(_quote(value) for value in values) + "]"


def _bool(value: bool) -> str:
    return "true" if value else "false"


def _positive_number(options: dict[str, Any], key: str, default: float) -> float:
    value = options.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(f"{key} must be a number")
    if (isinstance(value, float) and not math.isfinite(value)) or value <= 0 or value > 1_000_000:
        raise ConfigError(f"{key} is outside the supported range")
    # The supported bound above is checked before conversion so an enormous
    # JSON integer cannot trigger OverflowError while being cast to float.
    return float(value)


def _bounded_int(options: dict[str, Any], key: str, default: int, low: int, high: int) -> int:
    value = options.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ConfigError(f"{key} is outside the supported range")
    return value


def _safe_text(options: dict[str, Any], key: str, default: str = "", *, required: bool = False,
               maximum: int = 4096) -> str:
    value = options.get(key, default)
    if not isinstance(value, str) or len(value) > maximum:
        raise ConfigError(f"{key} must be a string")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise ConfigError(f"{key} contains invalid Unicode") from None
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ConfigError(f"{key} contains a control character")
    if required and not value:
        raise ConfigError(f"{key} is required")
    return value


def _model_id(options: dict[str, Any], key: str, default: str) -> str:
    value = _safe_text(options, key, default, required=True, maximum=200)
    if not re.fullmatch(r"[A-Za-z0-9._:/+~-]+", value):
        raise ConfigError(f"{key} has an invalid model identifier")
    return value


def _owner_id(options: dict[str, Any]) -> str | None:
    selected = options.get("telegram_owner_id", "")
    if selected not in (None, ""):
        if not isinstance(selected, (str, int)) or isinstance(selected, bool):
            raise ConfigError("telegram_owner_id must be a numeric Telegram user ID")
        candidate = str(selected)
    else:
        legacy = _safe_text(options, "telegram_allowed_users", "", maximum=4096)
        candidate = legacy.split(",", 1)[0].strip() if legacy else ""
    if not candidate:
        return None
    if not re.fullmatch(r"[1-9][0-9]{0,19}", candidate):
        raise ConfigError("Telegram owner must be a positive numeric user ID")
    return candidate


def _ha_mcp(options: dict[str, Any]) -> tuple[str, str] | None:
    enabled = options.get("ha_mcp_enabled", False)
    if not isinstance(enabled, bool):
        raise ConfigError("ha_mcp_enabled must be a boolean")
    if not enabled:
        return None
    url = _safe_text(options, "ha_mcp_url", required=True, maximum=2048)
    token = _safe_text(options, "ha_mcp_token", required=True, maximum=8192)
    if not token or any(char.isspace() for char in token):
        raise ConfigError("ha_mcp_token must be a nonempty bearer credential")
    parsed = urllib.parse.urlsplit(url)
    try:
        port = parsed.port
    except ValueError:
        raise ConfigError("ha_mcp_url must identify the Home Assistant MCP endpoint") from None
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or (port is not None and not 1 <= port <= 65535)
            or parsed.username is not None or parsed.password is not None
            or parsed.path != "/api/mcp" or parsed.query or parsed.fragment):
        raise ConfigError("ha_mcp_url must be the main /api/mcp URL without URL credentials")
    return url, token


def _automatic_model_routing(options: dict[str, Any]) -> bool:
    enabled = options.get("automatic_model_routing", False)
    if not isinstance(enabled, bool):
        raise ConfigError("automatic_model_routing must be a boolean")
    return enabled


def _telegram_options(options: dict[str, Any]) -> tuple[str, str] | None:
    token = _safe_text(options, "telegram_bot_token", maximum=8192)
    owner = _owner_id(options)
    if not token:
        return None
    if any(char.isspace() for char in token):
        raise ConfigError("telegram_bot_token is malformed")
    if owner is None:
        raise ConfigError("telegram_bot_token requires a numeric Telegram owner ID")
    return token, owner


def _option_values(options: dict[str, Any]) -> dict[str, Any]:
    key = _safe_text(options, "openrouter_api_key", required=True, maximum=8192)
    if any(char.isspace() for char in key):
        raise ConfigError("openrouter_api_key is malformed")
    default_model = _model_id(options, "default_model", "~deepseek/deepseek-v4-flash-latest")
    complex_model = _model_id(options, "complex_model", "openrouter/fusion")
    fusion_preset = _safe_text(options, "openrouter_fusion_preset", "general-budget", maximum=32)
    if fusion_preset not in {"general-high", "general-budget", "general-fast"}:
        raise ConfigError("openrouter_fusion_preset is unsupported")
    return {
        "api_key": key,
        "default_model": default_model,
        "complex_model": complex_model,
        "fusion_preset": fusion_preset,
        "max_tokens": _bounded_int(options, "provider_max_tokens", 2048, 512, 8192),
        "max_tool_iterations": _bounded_int(options, "max_tool_iterations", 8, 2, 20),
        "max_actions_per_hour": _bounded_int(options, "max_actions_per_hour", 200, 50, 1000),
        "max_history_messages": _bounded_int(options, "max_history_messages", 30, 5, 100),
        "max_context_tokens": _bounded_int(options, "max_context_tokens", 16000, 2000, 128000),
        "daily_limit_usd": _positive_number(options, "daily_cost_limit_usd", 10.0),
        "monthly_limit_usd": _positive_number(options, "monthly_cost_limit_usd", 40.0),
        "response_cache_ttl_minutes": _bounded_int(options, "response_cache_ttl_minutes", 2, 0, 60),
        "conversation_retention_days": _bounded_int(options, "conversation_retention_days", 30, 1, 365),
        "telegram": _telegram_options(options),
        "ha_mcp": _ha_mcp(options),
        "automatic_model_routing": _automatic_model_routing(options),
    }


def render(options: dict[str, Any]) -> str:
    if not isinstance(options, dict):
        raise ConfigError("app options must be an object")
    values = _option_values(options)
    model_ids = list(dict.fromkeys((values["default_model"], values["complex_model"])))
    lines = [
        "schema_version = 3",
        "",
        "[secrets]",
        "encrypt = false",
        "",
        "[providers.models.openrouter.default]",
        f"uri = {_quote(OPENROUTER_URI)}",
        f"model = {_quote(values['default_model'])}",
        f"api_key = {_quote(values['api_key'])}",
        'wire_api = "chat_completions"',
        "native_tools = true",
        f"max_tokens = {values['max_tokens']}",
        "timeout_secs = 80",
        "",
        "[providers.models.openrouter.reasoning]",
        f"uri = {_quote(OPENROUTER_URI)}",
        f"model = {_quote(values['complex_model'])}",
        f"api_key = {_quote(values['api_key'])}",
        'wire_api = "chat_completions"',
        "native_tools = true",
        f"max_tokens = {values['max_tokens']}",
        "timeout_secs = 80",
    ]
    if values["complex_model"] == "openrouter/fusion":
        lines += [
            'provider_extra = { plugins = [{ id = "fusion", preset = '
            + _quote(values["fusion_preset"]) + " }] }",
        ]
    lines += [
        "",
        "[[model_routes]]",
        'hint = "fast"',
        'model_provider = "openrouter.default"',
        f"model = {_quote(values['default_model'])}",
        "",
        "[[model_routes]]",
        'hint = "reasoning"',
        'model_provider = "openrouter.reasoning"',
        f"model = {_quote(values['complex_model'])}",
        "",
        "[agents.default]",
        "enabled = true",
        f"channels = {_string_array(['telegram.home'] if values['telegram'] else [])}",
        'model_provider = "openrouter.default"',
        'risk_profile = "default"',
        'runtime_profile = "default"',
        "skill_bundles = []",
        "knowledge_bundles = []",
        f"mcp_bundles = {_string_array(['ha'] if values['ha_mcp'] else [])}",
        "",
        "[agents.default.memory]",
        'backend = "sqlite"',
        "",
        "[risk_profiles.default]",
        'level = "supervised"',
        "workspace_only = true",
        'allowed_tools = ["memory_recall"]',
        f"auto_approve = {_string_array(['memory_recall'] + (sorted(HA_READONLY_TOOLS) if values['ha_mcp'] else []))}",
        f"excluded_tools = {_string_array(sorted(HA_MUTATING_TOOLS) if values['ha_mcp'] else [])}",
        "",
        "[risk_profiles.default.delegation_policy]",
        'mode = "forbidden"',
        "",
        "[runtime_profiles.default]",
        "agentic = true",
        f"max_tool_iterations = {values['max_tool_iterations']}",
        f"max_actions_per_hour = {values['max_actions_per_hour']}",
        "max_cost_per_day_cents = 0",
        f"max_history_messages = {values['max_history_messages']}",
        f"max_context_tokens = {values['max_context_tokens']}",
        "compact_context = true",
        "parallel_tools = false",
        "strict_tool_parsing = true",
    ]
    if values["automatic_model_routing"]:
        lines += [
            "",
            "[runtime_profiles.default.effort_routing]",
            'local_hint = "fast"',
            'cloud_hint = "reasoning"',
            'cloud_escalation = "auto"',
        ]
    lines += [
        "",
        "[tools]",
        "optional = []",
        "",
        "[channels]",
        "cli = false",
        "session_persistence = true",
        'session_backend = "sqlite"',
        "",
        "[memory]",
        'backend = "sqlite"',
        "auto_save = true",
        "hygiene_enabled = true",
        'search_mode = "bm25"',
        "response_cache_enabled = true",
        f"response_cache_ttl_minutes = {values['response_cache_ttl_minutes']}",
        "snapshot_enabled = true",
        "auto_hydrate = true",
        f"conversation_retention_days = {values['conversation_retention_days']}",
        "",
        "[gateway]",
        'host = "127.0.0.1"',
        "port = 42617",
        "require_pairing = true",
        "session_persistence = true",
        "",
        "[cost]",
        "enabled = true",
        f"daily_limit_usd = {values['daily_limit_usd']!r}",
        f"monthly_limit_usd = {values['monthly_limit_usd']!r}",
        "warn_at_percent = 80",
        "",
        "[cost.enforcement]",
        'mode = "block"',
        "",
    ]
    for model in model_ids:
        lines += [
            f"[cost.rates.providers.models.openrouter.{_quote(model)}]",
            "input_per_mtok = 100.0",
            "output_per_mtok = 100.0",
            "",
        ]
    lines += [
        "[mcp]",
        f"enabled = {_bool(values['ha_mcp'] is not None)}",
        "deferred_loading = false",
    ]
    if values["ha_mcp"]:
        url, token = values["ha_mcp"]
        lines += [
            "",
            "[[mcp.servers]]",
            'name = "ha"',
            'transport = "http"',
            f"url = {_quote(url)}",
            f"headers = {{ Authorization = {_quote('Bearer ' + token)} }}",
            "tool_timeout_secs = 15",
            "max_response_bytes = 262144",
            "",
            "[mcp_bundles.ha]",
            'servers = ["ha"]',
            "exclude = []",
        ]
    if values["telegram"]:
        token, owner = values["telegram"]
        lines += [
            "",
            "[channels.telegram.home]",
            "enabled = true",
            f"bot_token = {_quote(token)}",
            "mention_only = true",
            "per_user_session = true",
            "passive_group_context = false",
            "",
            "[peer_groups.telegram_owner]",
            'channel = "telegram.home"',
            'agents = ["default"]',
            f"external_peers = [{_quote(owner)}]",
            "admin_for_agent_scope = false",
        ]
    return "\n".join(lines).rstrip() + "\n"


def _existing_config_status(path: Path) -> tuple[bool, bytes | None]:
    _check_no_symlink_components(path, "output")
    info = _lstat(path)
    if info is None:
        return False, None
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_size > MAX_CONFIG_BYTES:
        raise ConfigError("existing config is unsafe or too large")
    content = _read_regular(path, "existing config", MAX_CONFIG_BYTES)
    try:
        parsed = tomllib.loads(content.decode("utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeError):
        raise ConfigError("existing native config is malformed; refusing to replace it") from None
    if (type(parsed.get("schema_version")) is not int or parsed["schema_version"] != 3
            or not isinstance(parsed.get("agents"), dict)
            or not isinstance(parsed["agents"].get("default"), dict)):
        raise ConfigError("existing native config has no supported default agent; refusing to replace it")
    return True, content


def update(options_path: Path, output_path: Path) -> str:
    options_path = Path(os.path.abspath(options_path))
    output_path = Path(os.path.abspath(output_path))
    _require_directory(options_path.parent, "options")
    _require_directory(output_path.parent, "output")
    options_bytes = _read_regular(options_path, "app options", MAX_OPTIONS_BYTES)
    try:
        options = json.loads(options_bytes)
    except (json.JSONDecodeError, UnicodeError):
        raise ConfigError("app options are not valid JSON") from None
    if not isinstance(options, dict):
        raise ConfigError("app options must be an object")
    # Validate before consulting the lifecycle marker so malformed changes are
    # never hidden by a same-fingerprint skip.
    rendered = render(options).encode("utf-8")
    fingerprint = hashlib.sha256(options_bytes).hexdigest().encode("ascii") + b"\n"
    marker_path = options_path.parent / ".native-options.sha256"
    _check_no_symlink_components(marker_path, "options marker")
    marker_info = _lstat(marker_path)
    if marker_info is not None:
        if not stat.S_ISREG(marker_info.st_mode) or stat.S_ISLNK(marker_info.st_mode):
            raise ConfigError("options marker is unsafe")
        marker = _read_regular(marker_path, "options marker", 128)
        if not re.fullmatch(rb"[0-9a-f]{64}\n?", marker):
            raise ConfigError("options marker is malformed")
        marker = marker.rstrip(b"\n")
    else:
        marker = None

    exists, existing = _existing_config_status(output_path)
    if marker is None and exists:
        # A pre-existing native config may contain pairing and session state.
        # Preserve it on the first run and establish options ownership only
        # after the current file has been parsed successfully.
        _atomic_private_write(marker_path, fingerprint)
        return "NATIVE_CONFIG_PRESERVED"
    if marker == fingerprint.rstrip(b"\n") and exists:
        return "NATIVE_CONFIG_UNCHANGED"

    _atomic_private_write(output_path, rendered)
    _atomic_private_write(marker_path, fingerprint)
    return "NATIVE_CONFIG_GENERATED"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--options", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        print(update(args.options, args.output))
        return 0
    except (ConfigError, OSError) as exc:
        # Never print parser internals, paths, source values, or secret-bearing
        # exception representations.
        message = str(exc) if isinstance(exc, ConfigError) else "native config files could not be safely updated"
        print(f"ERROR: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
