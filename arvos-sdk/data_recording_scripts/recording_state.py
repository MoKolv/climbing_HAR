"""
data_class for structuring recording_states of the collectin of participant climbing-data

"""
import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

@dataclass
class RecordingState:
    recording: bool = False

    # connection states
    imu_phone_connected: bool = False
    video_phone_connected: bool = False
    watch_connected: bool = False

    # trial / participant info
    participant_id: str | None = None
    boulder_id: str | None = None

    # data-stream config
    enabled_video: bool = True
    enabled_phone_imu: bool = True
    enabled_watch_imu: bool = True
    enabled_watch_attitude: bool = True

    last_video_received: datetime | None = None
    last_phone_imu_received: datetime | None = None
    last_watch_imu_received: datetime | None = None
    last_watch_attitude_received: datetime | None = None

    video_frame_count: int = 0
    phone_imu_count: int = 0
    watch_imu_count: int = 0
    watch_attitude_count: int = 0

    def mark_received(self, source:str) -> None:
        now = datetime.now()

        if source == "video":
            self.last_video_received = now
            self.video_frame_count += 1
        elif source == "phone_imu":
            self.last_phone_imu_received = now
            self.phone_imu_count += 1
        elif source == "watch_imu":
            self.last_watch_imu_received = now
            self.watch_imu_count += 1
        elif source == "watch_attitude":
            self.last_watch_attitude_received = now
            self.watch_attitude_count += 1
        else:
            raise ValueError(f"Unknown source: {source}")

    def is_receiving(self, source:str, threshold_s:float = 2.0) -> bool:
        last = {
            "video": self.last_video_received,
            "phone_imu": self.last_phone_imu_received,
            "watch_imu": self.last_watch_imu_received,#
            "watch_attitude": self.last_watch_attitude_received,
        } [source]

        if last is None:
            return False

        return (datetime.now() - last).total_seconds() < threshold_s
