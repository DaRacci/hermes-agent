"""Wall-clock and output budgets for the auxiliary vision LLM.

A ``vision_analyze`` call is one long RPC to the aux vision model: nothing between the tool and
the provider bounds it, and the provider can retry internally. Measured over 30h of worker
sessions (t_81c23360), 14 of 82 calls hit the concurrent-batch cap at exactly 420s and two
answers came back as 522 KB / 466 KB of chain-of-thought — the model never emitted content, so
the reasoning fallback *became* the tool result. Every analysis therefore gets

* a wall-clock ``deadline`` for the whole call (download + encode + every provider attempt),
  enforced by :func:`agent.deadline.run_bounded_async` so it fires even when the loop is busy;
* a ``max_analysis_chars`` ceiling on the returned text, with the truncation stated inline;
* a ``max_reasoning_chars`` ceiling on the reasoning fallback.

Config lives under ``auxiliary.vision`` (``deadline``, ``video_deadline``, ``max_analysis_chars``,
``max_reasoning_chars``). No ``max_tokens`` is forwarded to the provider — the max-tokens-knob
policy keeps provider output budgets out of user config.
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

# Image median 30s / p95 91s in the measured sample; 240s only cuts the 346s and 366s outliers,
# both of which were reasoning dumps. Kept well under the 420s concurrent-batch cap so the typed
# deadline error reaches the worker instead of the batch guard's opaque "timed out after 420.0s".
DEFAULT_DEADLINE_S = 240.0
# Video shares the aux client but legitimately runs longer (its own per-attempt floor is 180s).
DEFAULT_VIDEO_DEADLINE_S = 360.0
# An open-ended visual request must not return more than ~100 KB; 80_000 chars of UTF-8 prose is
# ~78 KB and matches the ceiling the tool-result budget already assumes for one tool call.
DEFAULT_MAX_ANALYSIS_CHARS = 80_000
# A reasoning-only response is a failed answer, not an analysis; enough of it to diagnose the
# route, nowhere near the 500 KB a stalled reasoning model produced.
DEFAULT_MAX_REASONING_CHARS = 8_000

_MIN_ANALYSIS_CHARS = 1_000


def _cfg_vision(key: str, default=None):
    """``auxiliary.vision.<key>`` from config.yaml; ``default`` when config is unavailable."""
    try:
        from hermes_cli.config import cfg_get, load_config
        return cfg_get(load_config(), "auxiliary", "vision", key, default=default)
    except Exception:
        # Config reads fail open: an unreadable config must not take the vision tool down with it.
        logger.debug("vision budget: config read failed for %s", key, exc_info=True)
        return default


def _positive_float(raw, default: float) -> float | None:
    """Config value → seconds; ``None`` means unbounded (0/negative), invalid falls back."""
    if isinstance(raw, bool):
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return default
    if value != value:  # NaN
        return default
    return value if value > 0 else None


def resolve_deadline(kind: str) -> float | None:
    """Wall-clock budget for one ``kind`` analysis; ``None`` disables it.

    ``auxiliary.vision.video_deadline`` applies to video, ``auxiliary.vision.deadline`` to images;
    video falls back to the image deadline when its own key is unset.
    """
    key = "video_deadline" if kind == "video" else "deadline"
    default = DEFAULT_VIDEO_DEADLINE_S if kind == "video" else DEFAULT_DEADLINE_S
    raw = _cfg_vision(key)
    if raw is None and kind == "video":
        raw = _cfg_vision("deadline")
    return _positive_float(raw, default)


def resolve_max_analysis_chars() -> int:
    """Character ceiling for the returned analysis (``auxiliary.vision.max_analysis_chars``)."""
    raw = _cfg_vision("max_analysis_chars")
    if raw is None or isinstance(raw, bool):
        return DEFAULT_MAX_ANALYSIS_CHARS
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_MAX_ANALYSIS_CHARS
    return max(value, _MIN_ANALYSIS_CHARS)


def resolve_max_reasoning_chars() -> int:
    """Character ceiling for a reasoning-only fallback (``auxiliary.vision.max_reasoning_chars``)."""
    raw = _cfg_vision("max_reasoning_chars")
    if raw is None or isinstance(raw, bool):
        return DEFAULT_MAX_REASONING_CHARS
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_MAX_REASONING_CHARS
    return value if value > 0 else DEFAULT_MAX_REASONING_CHARS


def _truncation_note(original_chars: int, kept_chars: int) -> str:
    return (
        f"\n\n[output truncated: the vision model returned {original_chars:,} characters "
        f"({original_chars / 1024.0:.0f} KB); the first {kept_chars:,} are shown. Ask a narrower "
        f"question, or pass a `region` crop, to get the rest.]"
    )


def cap_analysis(kind: str, analysis: str | None) -> tuple[str, int, bool]:
    """Bound an analysis to ``auxiliary.vision.max_analysis_chars``.

    Returns ``(text, original_chars, truncated)``. The note appended on truncation is part of the
    tool result on purpose: a worker must be able to tell a complete answer from a clipped one
    without paging a spillover file back in.
    """
    if not analysis:
        return analysis or "", 0, False
    original_chars = len(analysis)
    ceiling = resolve_max_analysis_chars()
    if original_chars <= ceiling:
        return analysis, original_chars, False
    logger.warning("%s analysis truncated: %d chars > %d", kind, original_chars, ceiling)
    kept = analysis[:ceiling].rstrip()
    return kept + _truncation_note(original_chars, len(kept)), original_chars, True


def deadline_result(kind: str, timeout_s: float | None) -> dict:
    """Typed tool result for a deadline that fired, with what the worker should do next."""
    seconds = f"{timeout_s:.0f}s" if timeout_s else "the configured deadline"
    return {
        "success": False,
        "error_type": "vision_deadline_exceeded",
        "retryable": True,
        "timeout_s": timeout_s,
        "error": f"Vision {kind} analysis exceeded {seconds}.",
        "analysis": (
            f"The vision model did not finish within {seconds}, so the call was abandoned instead "
            f"of blocking the turn. Retry once with a narrower question, a smaller image, or a "
            f"`region` crop; if it times out again, stop calling vision on this image and report "
            f"the blocker (the aux route under `auxiliary.vision` is stalling)."
        ),
    }


def is_timeout_error(exc: BaseException) -> bool:
    """True when a provider error is a timeout (SDK classes do not share ``TimeoutError``)."""
    return type(exc).__name__.endswith("TimeoutError") or isinstance(exc, TimeoutError) or "timed out" in str(exc).lower()
