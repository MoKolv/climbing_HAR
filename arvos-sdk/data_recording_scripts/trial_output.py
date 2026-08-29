from __future__ import annotations

import csv
from pathlib import Path
from statistics import median
from time import monotonic
from typing import Any, TextIO

class TrialOutput:
    """Writer class for a given trial's output"""

    def __init__(self, trial_directory: Path, trial_number: int) -> None:
        self.trial_directory = trial_directory
        self.trial_number = trial_number
        self.pending_directory = trial_directory / ".pending_trials"
        self.pending_directory.mkdir(exist_ok= True)

        self._closed = False
        self._pre_boundary_ns: int | None = None
        self._spools: dict[str, tuple[Path, TextIO, Any]] = {}
        self.validation_summary: dict[str, dict[str, Any]] = {}
        self.sync_summary:dict[str, dict[str, Any]] = {}

        self._files: dict[str, TextIO] = {
            "imu": (trial_directory / "imu.csv").open("w", newline=""),
            "watch_imu": (trial_directory / "watch_imu.csv").open("w", newline=""),
            "watch_attitude": (trial_directory / "watch_attitude.csv").open("w", newline=""),
            "video_metadata": (trial_directory / "video_metadata.csv").open("w", newline=""),
            "watch_sync": (trial_directory / "watch_sync.csv").open("w", newline=""),
            "stream_validation": (trial_directory / "stream_validation.csv").open("w", newline=""),
        }


        self._writers: dict[str, Any] = {
            name: csv.writer(file, delimiter=";")
            for name, file in self._files.items()
        }

        self._final_writers: dict[str, Any] = {
            name: self._writers[name]
            for name in ("imu", "watch_imu", "watch_attitude")
        }

        self._flush_rows: dict[str, int] = {
            name: 0
            for name in ("imu", "watch_imu", "watch_attitude", "video_metadata")
        }

        self._last_flush: dict[str, float] = {
            name: monotonic()
            for name in self._flush_rows
        }

        self._write_headers()

    @property
    def video_path(self) -> Path:
        return self.trial_directory / "camera_video.mp4"

    def _write_headers(self) -> None:
        self._writers["imu"].writerow([
            "trial_id", "sequence_id", "timestamp_ns", "timestamp_s",
            "ang_vel_x", "ang_vel_y", "ang_vel_z",
            "lin_acc_x", "lin_acc_y", "lin_acc_z",
            "gravity_x", "gravity_y", "gravity_z",
        ])

        self._writers["watch_imu"].writerow([
            "trial_id", "sequence_id", "timestamp_ns", "timestamp_s",
            "watch_timestamp_ns", "phone_received_timestamp_ns",
            "ang_vel_x", "ang_vel_y", "ang_vel_z",
            "lin_acc_x", "lin_acc_y", "lin_acc_z",
        ])

        self._writers["watch_attitude"].writerow([
            "trial_id", "sequence_id", "timestamp_ns", "timestamp_s",
            "watch_timestamp_ns", "phone_received_timestamp_ns",
            "quaternion_x", "quaternion_y", "quaternion_z", "quaternion_w",
            "roll", "pitch", "yaw", "reference_frame",
        ])

        self._writers["video_metadata"].writerow([
            "timestamp_ns", "timestamp_s", "frame_count",
        ])

        self._writers["watch_sync"].writerow([
            "trial_id", "phase", "offset_ns", "phone_anchor_ns",
            "watch_anchor_ns", "min_rtt_ns", "median_selected_rtt_ns",
            "offset_spred_ns", "valid_sample_count", "selected_sample_count",
            "boundary_phone_ns"
        ])

        self._writers["stream_validation"].writerow([
            "trial_id", "stream", "pre_boundary_ns", "post_boundary_ns",
            "stored_rows", "first_squence_id", "last_squence_id",
            "missing_internal_sequences", "duplicate_sequences",
            "non_monotonic_timestamps", "median_dt_ns", "max_dt_ns",
            "min_dt_ns", "max_gap_multiple"
        ])

    def begin_staging(self, pre_boundary_ns: int) -> None:
        if self._pre_boundary_ns is not None:
            raise RuntimeError("Staging is already active for this trial.")

        self._pre_boundary_ns = pre_boundary_ns

        for stream_name in self._final_writers:
            path = self.pending_directory / f"{stream_name}.csv"
            file = path.open("w", newline="")
            self._spools[stream_name] = (
                path,
                file,
                csv.writer(file, delimiter=";"),
            )

    def stage_row(self, stream_name: str, timestamp_ns: int, row: list[Any]) -> None:
        if self._pre_boundary_ns is None or self._closed:
            return

        if timestamp_ns < self._pre_boundary_ns:
            return

        _, _, writer = self._spools[stream_name]
        writer.writerow([self.trial_number, *row])

    def record_video_metadata(self, timestamp_ns: int, timestamp_s: float, frame_count: int) -> None:
        self._writers["video_metadata"].writerow([
            timestamp_ns, timestamp_s, frame_count,
        ])
        self._flush("video_metadata")

    def record_sync_result(self, data: dict[str, Any]) -> None:
        phase = data["phase"]
        self._writers["watch_sync"].writerow([
            self.trial_number,
            phase,
            data["offsetNs"],
            data["phoneAnchorNs"],
            data["watchAnchorNs"],
            data["minRTTNs"],
            data["medianSelectedRTTNs"],
            data["offsetSpreadNs"],
            data["validSampleCount"],
            data["selectedSampleCount"],
            data["boundaryPhoneNs"],
        ])

        self._files["watch_sync"].flush()

        self.sync_summary[phase] = {
            "offset_ns": data["offsetNs"],
            "phone_anchor_ns": data["phoneAnchorNs"],
            "watch_anchor_ns": data["watchAnchorNs"],
            "min_rtt_ns": data["minRTTNs"],
            "median_selected_rtt_ns": data["medianSelectedRTTNs"],
            "offset_spread_ns": data["offsetSpreadNs"],
            "valid_sample_count": data["validSampleCount"],
            "selected_sample_count": data["selectedSampleCount"],
            "boundary_phone_ns": data["boundaryPhoneNs"],
        }

    def finalize(self, post_boundary_ns: int) -> dict[str, Any]:
        if self._pre_boundary_ns is None:
            raise RuntimeError("Cannot finalize before begin_staging().")

        pre_boundary_ns = self._pre_boundary_ns

        for stream_name, (path, file, _) in self._spools.items():
            file.flush()
            file.close()

            accepted_rows: list[list[str]] = []
            with path.open(newline="") as staged_file:
                for row in csv.reader(staged_file, delimiter=";"):
                    timestamp_ns = int(row[2])

                    if pre_boundary_ns <= timestamp_ns <= post_boundary_ns:
                        self._final_writers[stream_name].writerow(row)
                        self._flush(stream_name)
                        accepted_rows.append(row)

            self._write_validation(
                stream_name,
                pre_boundary_ns,
                post_boundary_ns,
                accepted_rows,
            )

            path.unlink(missing_ok=True)
        self._spools.clear()
        self._pre_boundary_ns = None
        self.force_flush()

        return {
            "recording_boundaries": {
                "pre_boundary_phone_ns": pre_boundary_ns,
                "post_boundary_phone_ns": post_boundary_ns,
            },
            "packet_validation": self.validation_summary,
            "watch_time_sync": self.sync_summary,
        }

    def _write_validation(
            self,
            stream_name: str,
            pre_boundary_ns: int,
            post_boundary_ns: int,
            rows: list[list[str]],
    ) -> None:
        sequence_and_time = sorted(
            (int(row[1]), int(row[2]))
            for row in rows
        )

        if not sequence_and_time:
            metrics: dict[str, Any] = {
                "stored_rows": 0,
                "first_squence_id": None,
                "last_squence_id": None,
                "missing_internal_sequences": 0,
                "duplicate_sequences": 0,
                "non_monotonic_timestamps": 0,
                "median_dt_ns": None,
                "max_dt_ns": None,
                "min_dt_ns": None,
                "max_gap_multiple": None,
            }
        else:
            sequence_ids = [item[0] for item in sequence_and_time]
            timestamps = [item[1] for item in sequence_and_time]
            unique_ids = sorted(set(sequence_ids))
            deltas = [
                right - left
                for left, right in zip(timestamps, timestamps[1:])
                if right > left
            ]
            median_dt = median(deltas) if deltas else 0

            metrics = {
                "stored_rows": len(rows),
                "first_squence_id": sequence_ids[0],
                "last_squence_id": sequence_ids[-1],
                "missing_internal_sequences": sum(
                    right - left - 1
                    for left, right in zip(unique_ids, unique_ids[1:])
                ),
                "duplicate_sequences": len(sequence_ids) - len(unique_ids),
                "non_monotonic_timestamps": sum(
                    right <= left
                    for left, right in zip(timestamps, timestamps[1:])
                ),
                "median_dt_ns": int(median_dt) if deltas else None,
                "max_dt_ns": max(deltas) if deltas else None,
                "min_dt_ns": min(deltas) if deltas else None,
                "max_gap_multiple": (
                    round(max(deltas) / median_dt, 3) if deltas and median_dt else None
                ),
            }

        self.validation_summary[stream_name] = metrics

        def csv_value(value: Any) -> Any:
            return "" if value is None else value

        self._writers["stream_validation"].writerow([
            self.trial_number,
            stream_name,
            pre_boundary_ns,
            post_boundary_ns,
            metrics["stored_rows"],
            csv_value(metrics["first_squence_id"]),
            csv_value(metrics["last_squence_id"]),
            metrics["missing_internal_sequences"],
            metrics["duplicate_sequences"],
            metrics["non_monotonic_timestamps"],
            csv_value(metrics["median_dt_ns"]),
            csv_value(metrics["max_dt_ns"]),
            csv_value(metrics["min_dt_ns"]),
            csv_value(metrics["max_gap_multiple"]),
        ])

    def _flush(self, name: str, force: bool = False) -> None:
        now = monotonic()

        if force:
            self._files[name].flush()
            self._flush_rows[name] = 0
            self._last_flush[name] = now
            return

        self._flush_rows[name] += 1

        if (
            self._flush_rows[name] >= 100
            or now - self._last_flush[name] >= 0.5
        ):
            self._files[name].flush()
            self._flush_rows[name] = 0
            self._last_flush[name] = now

    def force_flush(self) -> None:
        for name in self._flush_rows:
            self._flush(name, force=True)

        self._files["watch_sync"].flush()
        self._files["stream_validation"].flush()

    def close(self) -> None:
        if self._closed:
            return

        for _, file, _ in self._spools.values():
            if not file.closed:
                file.close()
        self._spools.clear()

        self.force_flush()
        for file in self._files.values():
            if not file.closed:
                file.close()

        try: self.pending_directory.rmdir()
        except FileNotFoundError: pass
        except OSError as error:
            print(f"Warning: could not remove {self.pending_directory}: {error}")

        self._closed = True
