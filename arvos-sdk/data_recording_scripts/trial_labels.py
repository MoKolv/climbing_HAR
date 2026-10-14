"""Records extremity labels during live recording"""

import csv
import os
from pathlib import Path
from typing import TextIO

EXTREMITIES = {
    "left_hand",
    "right_hand",
    "left_foot",
    "right_foot",
}

class TrialLabels:
    def __init__(self, trial_directory: Path, trial_number: int) -> None:
        self.path = trial_directory / "labels.csv"
        self.trial_number = trial_number

        # prevent overwriting trial labels
        self._file: TextIO = self.path.open(
            "x",
            newline="",
            encoding="utf-8",
        )

        self._writer = csv.writer(self._file, delimiter=";")

        self._writer.writerow(
            (
                "trial_id",
                "event_index",
                "key",
                "extremity",
                "state",
                "server_timestamp_ns",
                "trial_elapsed_ns",
            )
        )

        self._file.flush()

        self._start_server_ns: int | None = None
        self._states: dict[str, str | None] = {
            extremity: None
            for extremity in EXTREMITIES
        }

        self._event_index = 0
        self._closed = False

    @property
    def states(self) -> dict[str, str | None]:
        return self._states.copy()

    def arm(self, start_server_ns: int) -> None:
        if self._closed:
            raise RuntimeError("The label csv has already been closed")

        if self._start_server_ns is not None:
            raise RuntimeError("Labels are already armed")

        if start_server_ns <= 0:
            raise ValueError("start_server_ns must be positive")

        self._start_server_ns = start_server_ns

    def record(self, key: str, extremity: str, server_timestamp_ns: int) -> str | None:
        if self._closed:
            raise RuntimeError("The label csv is closed")

        if extremity not in self._states:
            raise ValueError(f"Unknown extremity: {extremity}")

        # ignore presses before scheduled trial start
        if self._start_server_ns is None or server_timestamp_ns < self._start_server_ns:
            return None

        previous_state = self._states[extremity]

        new_state = (
            "left_hold"
            if previous_state == "on_hold"
            else "on_hold"
        )

        self._writer.writerow(
            (
                self.trial_number,
                self._event_index,
                key,
                extremity,
                new_state,
                server_timestamp_ns,
                server_timestamp_ns - self._start_server_ns,
            )
        )

        # flush without syncing disk on every press
        self._file.flush()

        self._states[extremity] = new_state
        self._event_index += 1
        return new_state

    def close(self) -> None:
        if self._closed:
            return

        try:
            self._file.flush()
            os.fsync(self._file.fileno())
        finally:
            self._file.close()
            self._closed = True
