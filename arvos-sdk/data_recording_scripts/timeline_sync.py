from __future__ import annotations

import bisect
import csv
import os
from dataclasses import dataclass
from pathlib import Path

@dataclass(frozen=True)
class ClockPoint:
    phone_ns: int
    offset_ns: int

@dataclass(frozen=True)
class ClockModel:
    pre: ClockPoint
    post: ClockPoint

    def to_server_ns(self, phone_ns: int) -> int:
        span = self.post.phone_ns - self.pre.phone_ns
        if span <= 0:
            return phone_ns + self.pre.offset_ns

        fraction = min(1.0, max(0.0, (phone_ns - self.pre.phone_ns) / span))
        offset = round(
            self.pre.offset_ns + fraction * (self.post.offset_ns - self.pre.offset_ns)
        )

        return phone_ns + offset

def clock_model(results: dict[str, dict]) -> ClockModel:
    return ClockModel(
        pre = ClockPoint(
            phone_ns = int(results["pre"]["phoneAnchorNs"]),
            offset_ns = int(results["pre"]["serverMinusPhoneOffsetNs"])
        ),
        post = ClockPoint(
            phone_ns = int(results["post"]["phoneAnchorNs"]),
            offset_ns = int(results["post"]["serverMinusPhoneOffsetNs"])
        ),
    )

def add_server_timestamps(path: Path, model: ClockModel) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")

    with path.open(newline="") as source, temporary.open("w", newline="") as target:
        reader = csv.DictReader(source, delimiter=";")
        fieldnames = list(reader.fieldnames or [])
        if "server_timestamp_ns" not in fieldnames:
            fieldnames.append("server_timestamp_ns")

        writer = csv.DictWriter(target, fieldnames = fieldnames, delimiter = ";")
        writer.writeheader()
        for row in reader:
            row["server_timestamp_ns"] = model.to_server_ns(int(row["timestamp_ns"]))
            writer.writerow(row)

    os.replace(temporary, path)

def add_nearest_imu_to_video(video_path: Path, imu_path: Path) -> None:
    with imu_path.open(newline="") as source:
        imu_rows = list(csv.DictReader(source, delimiter=";"))

    if not imu_rows:
        raise ValueError("Cannot match video frames because imu.csv has no samples")

    imu_times = [int(row["server_timestamp_ns"]) for row in imu_rows]
    temporary = video_path.with_suffix(video_path.suffix + ".tmp")

    with video_path.open(newline="") as source, temporary.open("w", newline="") as target:
        reader = csv.DictReader(source, delimiter=";")
        fieldnames = list(reader.fieldnames or []) + [
            "nearest_imu_sequence_id",
            "nearest_imu_server_timestamp_ns",
            "nearest_imu_delta_ns",
        ]
        writer = csv.DictWriter(target, fieldnames = fieldnames, delimiter = ";")
        writer.writeheader()

        for frame in reader:
            frame_time = int(frame["server_timestamp_ns"])
            right = bisect.bisect_left(imu_times, frame_time)
            candidates = [index for index in (right -1, right) if 0 <= index < len(imu_rows)]
            nearest = min(candidates, key = lambda index: abs(imu_times[index] - frame_time))

            frame["nearest_imu_sequence_id"] = imu_rows[nearest]["sequence_id"]
            frame["nearest_imu_server_timestamp_ns"] = imu_times[nearest]
            frame["nearest_imu_delta_ns"] = imu_times[nearest] - frame_time
            writer.writerow(frame)

    os.replace(temporary, video_path)

@dataclass(frozen=True)
class WatchClockPoint:
    watch_ns: int
    offset_ns: int

@dataclass(frozen=True)
class WatchClockModel:
    pre: WatchClockPoint
    post: WatchClockPoint

    def to_phone_ns(self, watch_ns: int) -> int:
        span = self.post.watch_ns - self.pre.watch_ns

        if span <= 0:
            return watch_ns + self.pre.offset_ns

        fraction = min(1.0, max(0.0, (watch_ns - self.pre.watch_ns) / span))

        offset = round(
            self.pre.offset_ns + fraction * (self.post.offset_ns - self.pre.offset_ns)
        )

        return watch_ns + offset

def watch_clock_model(results: dict[str, dict]) -> WatchClockModel:
    return WatchClockModel(
        pre = WatchClockPoint(
            watch_ns = int(results["pre"]["watchAnchorNs"]),
            offset_ns = int(results["pre"]["offsetNs"])
        ),
        post = WatchClockPoint(
            watch_ns = int(results["post"]["watchAnchorNs"]),
            offset_ns = int(results["post"]["offsetNs"]),
        ),
    )

def add_watch_server_timestamps(path: Path, watch_model: WatchClockModel, phone_model: ClockModel) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")

    with (
        path.open(newline="") as source, temporary.open("w", newline="") as target
    ):
        reader = csv.DictReader(source, delimiter=";")
        fieldnames = list(reader.fieldnames or [])

        if "server_timestamp_ns" not in fieldnames:
            fieldnames.append("server_timestamp_ns")

        writer = csv.DictWriter(target, fieldnames = fieldnames, delimiter = ";")
        writer.writeheader()

        for row in reader:
            watch_ns = int(row["source_timestamp_ns"])
            phone_ns = watch_model.to_phone_ns(watch_ns)

            row["timestamp_ns"] = phone_ns
            row["timestamp_s"] = f"{phone_ns / 1_000_000_000:.9f}"
            row["server_timestamp_ns"] = (phone_model.to_server_ns(phone_ns))

            writer.writerow(row)
    os.replace(temporary, path)