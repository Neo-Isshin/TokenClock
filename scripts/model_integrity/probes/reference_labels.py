"""Explicit names for the six bundled reference labels, not backend attestation."""

MODEL_FAMILIES = {
    'anthropic': ('claude-sonnet-5', 'claude-opus-5', 'claude-fable-5'),
    'openai': ('gpt-5.5', 'gpt-5.6-sol', 'gpt-6-astra'),
}
REFERENCE_NAMES = {name: name for values in MODEL_FAMILIES.values() for name in values}
REFERENCE_NAMES.update({namespace + '/' + name: name for namespace, values in MODEL_FAMILIES.items() for name in values})


def reference_label(value):
    """Select a comparison reference; never rewrite the recorded request label.

    No fuzzy matching, arbitrary namespace stripping, suffix/version removal,
    provider alias inference, or claim that a declared label proves its backend.
    """
    return REFERENCE_NAMES.get(value) if isinstance(value, str) else None
