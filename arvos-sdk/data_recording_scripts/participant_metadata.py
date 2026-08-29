from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")

@dataclass(frozen=True)
class TrialReservation:
    participant_id: str
    trial_number: int
    participant_directory: Path
    trial_directory: Path
    started_at: str


class ParticipantMetadataStore:
    """ Owns Participant metadata and reserves one output dir per trial."""

    _PARTICIPANT_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")

    def __init__(self, data_root: Path) -> None:
        self.data_root = Path(data_root)
        self.data_root.mkdir(parents=True, exist_ok=True)

    def validate_participant_id(self, participant_id: str) -> str:
        normalized = participant_id.strip()

        if not self._PARTICIPANT_ID.fullmatch(normalized):
            raise ValueError("Participant ID must use 1-64 letters, digits '_' or '-'.")

        return normalized

    def participant_directory(self, participant_id: str) -> Path:
        participant_id = self.validate_participant_id(participant_id)
        return self.data_root / f"participant_{participant_id}"

    def metadata_path(self, participant_id: str) -> Path:
        return self.participant_directory(participant_id) / "metadata.json"

    def ensure_participant(self, participant_id: str) -> Path:
        participant_id = self.validate_participant_id(participant_id)
        directory = self.participant_directory(participant_id)
        directory.mkdir(parents=True, exist_ok=True)

        if not self.metadata_path(participant_id).exists():
            self._write(
                participant_id,
                {
                    "schema_version": 1,
                    "participant_id": participant_id,
                    "created": now_iso(),
                    "participant": {},
                    "trials": []
                },
            )

        return directory

    def load(self, participant_id: str) -> dict[str, Any]:
        self.ensure_participant(participant_id)

        with self.metadata_path(participant_id).open(encoding="utf-8") as file:
            return json.load(file)

    def update_participant(self, participant_id: str, fields: dict[str, Any]) -> None:
        metadata = self.load(participant_id)
        metadata["participant"].update(fields)
        self._write(participant_id, metadata)

    def begin_trial(self, participant_id: str, boulder_id: str | None) -> TrialReservation:
        participant_id = self.validate_participant_id(participant_id)
        participant_directory = self.participant_directory(participant_id)
        metadata = self.load(participant_id)

        trial_numbers = [
            int(trial["trial_number"])
            for trial in metadata["trials"]
        ]
        trial_number = max(trial_numbers, default=0) + 1
        trial_directory = participant_directory / f"trial_{trial_number:03d}"

        #don't overwrite existing directories
        while trial_directory.exists():
            trial_number += 1
            trial_directory = participant_directory / f"trial_{trial_number:03d}"

        trial_directory.mkdir(parents=True)
        started_at = now_iso()

        metadata["trials"].append(
            {
                "trial_number": trial_number,
                "directory": trial_directory.name,
                "started_at": started_at,
                "boulder_id": boulder_id,
                "status": "preparing"
            }
        )

        self._write(participant_id, metadata)

        return TrialReservation(
            participant_id=participant_id,
            trial_number=trial_number,
            participant_directory=participant_directory,
            trial_directory=trial_directory,
            started_at=started_at,
        )

    def mark_trial_complete(
            self,
            reservation: TrialReservation,
            summary: dict[str, Any],
    ) -> None:
        metadata = self.load(reservation.participant_id)
        trial = self._find_trial(metadata, reservation.trial_number)

        trial.update(summary)
        trial["status"] = "failed"
        trial["finished_at"] = now_iso()

        self._write(reservation.participant_id, metadata)

    def mark_trial_failed(self, reservation: TrialReservation, reason: str) -> None:
        metadata = self.load(reservation.participant_id)
        trial = self._find_trial(metadata, reservation.trial_number)

        trial["status"] = "failed"
        trial["failure_reason"] = reason
        trial["finished_at"] = now_iso()

        self._write(reservation.participant_id, metadata)

    @staticmethod
    def _find_trial(
            metadata: dict[str, Any],
            trial_number: int
    ) -> dict[str, Any]:
        for trial in metadata["trials"]:
            if trial["trial_number"] == trial_number:
                return trial

        raise KeyError(f"Trial {trial_number} not in present metadata")

    def _write(self, participant_id: str, metadata: dict[str, Any]) -> None:
        path = self.metadata_path(participant_id)
        temporary_path = path.with_name(f"{path.name}.tmp")

        with temporary_path.open("w",encoding="utf-8") as file:
            json.dump(metadata, file, indent =2, sort_keys=True)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())

        os.replace(temporary_path, path)

