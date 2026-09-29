from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Any, Mapping

@dataclass(frozen=True)
class ParticipantField:
    key: str
    label: str
    value_type: type[str] | type[int] | type[float]
    minimum: float | None = None


class ParticipantProfile:
    """Defines required participant fields and validates entered answers"""

    # Edit this to add, remove, reorder required fields
    # New key becomes property inside metadata.json's participant object
    FIELDS: tuple[ParticipantField, ...] = (
        ParticipantField("age", "Age (years)", int, minimum = 1),
        ParticipantField("height", "Height (cm)", float, minimum = 1),
        ParticipantField("weight", "Weight (kg)", float, minimum = 1),
        ParticipantField("wingspan", "Wingspan (cm)", float, minimum = 1),
        ParticipantField("handedness", "Handedness (left/right)", str),
        ParticipantField("climbing_experience", "Climbing experience (years)", int, minimum = 1),
        ParticipantField("climbing_frequency", "Climbing frequency (times/week)", int, minimum = 1),
        ParticipantField("climbing_competence", "Climbing competence (highest achieved grade)", str),

    )

    def __init__(self,values: Mapping[str, Any] | None = None) -> None:
        self.values: dict[str, Any] = dict(values or {})

    def missing_fields(self) -> tuple[ParticipantField, ...]:
        def is_missing(field: ParticipantField) -> bool:
            value = self.values.get(field.key)
            return value is None or (isinstance(value, str) and not value.strip())

        return tuple(field for field in self.FIELDS if is_missing(field))

    def set_answer(self, field: ParticipantField, answer: str) -> str | int | float:
        raw = answer.strip()
        if not raw:
            raise ValueError(f"{field.label} is required")

        try:
            value = field.value_type(raw)
        except ValueError as error:
            raise ValueError(f"{field.label} must be a valid {field.value_type.__name__}") from error

        if isinstance(value,float) and not isfinite(value):
            raise ValueError(f"{field.label} must be a finite number")

        if field.minimum is not None:
            if not isinstance(value, (int, float)):
                raise ValueError(f"{field.label} has a nonnumeric minimum")
            if value < field.minimum:
                raise ValueError(f"{field.label} must be at least {field.minimum}")

            self.values[field.key] = value
            return value