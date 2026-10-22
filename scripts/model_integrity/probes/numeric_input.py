"""Deterministic numeric input checks; compliance is separate from identity."""
from __future__ import annotations

import math
import re

MAX_ANSWER_BYTES = 1024 * 1024
VALID_FINISHES = {'stop', 'end_turn', 'completed'}


def parse_upstream_js(text):
    """Match the frozen browser parser, including ASCII-only digit semantics.

The upstream parser ignores minus signs and splits decimals; callers must run
inspect_answer first. Kept separately to verify parity without hiding defects.
"""
    runs, current, previous = [], [], 0
    for match in re.finditer(r'[0-9]+', text):
        if current and any(c.isalpha() for c in text[previous:match.start()]):
            runs.append(current)
            current = []
        # Avoid arbitrary-size integer conversion on malformed pasted data.
        digits = match.group().lstrip('0') or '0'
        value = int(digits) if len(digits) <= 3 else 356
        if 1 <= value <= 355:
            current.append(value)
        previous = match.end()
    if current:
        runs.append(current)
    return max(runs, key=len, default=[])


def inspect_answer(text, expected_count, *, finish_reason=None):
    if not isinstance(text, str) or type(expected_count) is not int or not 80 <= expected_count <= 1000:
        raise ValueError('Invalid text or expected count')
    result = {'schema': 'tokenclock-numeric-input-check/v2', 'accepted': False,
              'reasons': [], 'warnings': [], 'task_compliant': False, 'formal_identity_evidence': False,
              'finish_reason': finish_reason, 'finish_reason_missing': finish_reason is None}
    if len(text.encode('utf-8')) > MAX_ANSWER_BYTES:
        result['reasons'].append('answer_too_large')
        return result
    if finish_reason is not None and finish_reason not in VALID_FINISHES:
        result['reasons'].append('incomplete_or_limited_response')
    if re.search(r'(?:[-+−][ \t]*[0-9]|[0-9]\.[0-9]|[0-9][eE][+-]?[0-9])', text):
        result['reasons'].append('signed_decimal_or_exponent_not_integer_sequence')
    if any(c.isdecimal() and c not in '0123456789' for c in text):
        result['reasons'].append('non_ascii_digits_require_explicit_protocol')
    tokens = [m.group().lstrip('0') or '0' for m in re.finditer(r'[0-9]+', text)]
    outside = sum(len(t) > 3 or not 1 <= int(t) <= 355 for t in tokens)
    result['out_of_range_tokens'] = outside
    if outside:
        # Preserve the upstream projection and report noncompliance separately.
        # An out-of-range token is not evidence of a different model and must
        # not silently erase the entire otherwise usable answer.
        result['warnings'].append('out_of_range_integer_omitted_by_upstream_parser')
    numbers = parse_upstream_js(text)
    minimum = max(80, math.ceil(expected_count * .55))
    result.update(parsed_count=len(numbers), expected_count=expected_count, minimum_count=minimum,
                  requested_count_met=len(numbers) >= expected_count)
    if len(numbers) < minimum:
        result['reasons'].append('too_few_valid_integers')
    if numbers:
        if len(set(numbers)) == 1:
            result['reasons'].append('constant_sequence')
        elif len(numbers) > 2 and len({b - a for a, b in zip(numbers, numbers[1:])}) == 1:
            result['reasons'].append('arithmetic_sequence')
        elif any(len(numbers) >= 4 * width and all(n == numbers[i % width] for i, n in enumerate(numbers))
                 for width in range(2, 17)):
            result['reasons'].append('short_repeating_block')
        if min(numbers) >= 200:
            result['reasons'].append('upstream_high_range_distribution_warning')
    result['accepted'] = not result['reasons']
    result['task_compliant'] = result['accepted'] and not result['warnings'] and result['requested_count_met']
    return result
