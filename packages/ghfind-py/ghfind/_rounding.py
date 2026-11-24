"""Rounding used by the TypeScript and Go scoring implementations."""

import math


def round_half_even(value: float, digits: int = 0) -> float:
    """Match the reference's scaled half-even rule, including its tolerance."""
    factor = 10.0 ** digits
    scaled = value * factor
    # Python's round(value, digits) preserves large finite values and passes
    # through NaN/Infinity even when scaling cannot remain finite.
    if not math.isfinite(scaled):
        return value
    lower = math.floor(scaled)
    if abs(scaled - lower - 0.5) < 1e-9:
        rounded = lower if lower % 2 == 0 else lower + 1
    else:
        # Compare the fraction instead of adding 0.5: that addition can
        # round an already-integral binary64 value at or above 2**52.
        rounded = lower + (1 if scaled - lower >= 0.5 else 0)
        # Math.round retains negative zero; the half-even branch above can
        # instead produce positive zero, including for an exact negative half.
        if rounded == 0 and math.copysign(1.0, scaled) < 0:
            return -0.0
    return rounded / factor
