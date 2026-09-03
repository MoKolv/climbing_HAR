"""
Python script to control data collection while climbing using arvos
"""

import asyncio
from typing import Any
import io
from pathlib import Path
from time import monotonic

import cv2
import numpy as np
from PIL import Image

from arvos import (
    ArvosServer,
    CameraFrame,
    IMUData,
    WatchAttitudeData,
    WatchIMUData,
    WatchMotionActivityData,
)
from participant_metadata import ParticipantMetadataStore, TrialReservation
from recording_state import RecordingState
from terminal_controls import PromptInput, listen_for_keys
from trial_output import TrialOutput

async def main() -> None:
    project_root = Path(__file__).resolve().parents[2]
    data_root = project_root / "Data"
    metadata_store = ParticipantMetadataStore(data_root)

    """
    pass  alt_host= "192.168.178.2" when hosting over fritz box network
    otherwise omit host/alt_host argument
    """
    server = ArvosServer(port=9090)
    #server = ArvosServer(alt_host= "192.168.178.2", port=9090)

    IMU_WATCH_ROLE = "imu_watch"
    VIDEO_ROLE = "video"
    REQUIRED_ROLES = {IMU_WATCH_ROLE, VIDEO_ROLE}

    state = RecordingState()
    stop_event = asyncio.Event()
    pre_sync_event = asyncio.Event()
    post_sync_event = asyncio.Event()
    watch_drain_event = asyncio.Event()

    pre_sync_result: dict | None = None
    post_sync_result: dict | None = None
    watch_drain_result: dict | None = None
    video_writer: Any | None = None
    frame_count = 0
    last_sensor_arrival = monotonic()

    active_trial: TrialOutput | None = None
    active_reservation: TrialReservation | None = None

    def require_experiment_clients() -> bool:
        missing = server.missing_roles(REQUIRED_ROLES)

        if not missing:
            return True

        print(
            "Cannot start trial; missing client role(s)",
            ", ".join(sorted(missing)),
        )

        return False

    def close_video_writer() -> None:
        nonlocal video_writer

        writer = video_writer
        video_writer = None

        if writer is not None:
            writer.release()

    def fail_active_trial(reason: str) -> None:
        nonlocal active_trial, active_reservation

        close_video_writer()
        state.recording = False

        if active_trial is not None:
            active_trial.close()

        if active_reservation is not None:
            try:
                metadata_store.mark_trial_failed(active_reservation, reason)
            except Exception as error:
                print("Failed to update trial metadata:", repr(error))

        active_trial = None
        active_reservation = None

    async def wait_for_sensor_drain(quiet_seconds: float = 0.5, maximum_wait_seconds: float = 5.0) -> None:
        deadline = monotonic() + maximum_wait_seconds

        while monotonic() < deadline:
            if monotonic() - last_sensor_arrival >= quiet_seconds:
                return
            await asyncio.sleep(0.05)

    async def quit_program(_: PromptInput) -> None:
        print("\n🚫 Stopping program")
        stop_event.set()

    async def start_stop_recording(_: PromptInput) -> None:
        nonlocal pre_sync_result, post_sync_result, watch_drain_result
        nonlocal active_trial, active_reservation, video_writer, frame_count

        if not state.recording:
            if not state.participant_id:
                print("Set a participant_id with 'p' before starting a trial")
                return

            if not require_experiment_clients():
                print("Cannot start trial; Not all required client role(s) are set")
                return

            try:
                prepared_reservation = metadata_store.begin_trial(
                    state.participant_id,
                    state.boulder_id,
                )

                prepared_trial = TrialOutput(
                    prepared_reservation.trial_directory,
                    prepared_reservation.trial_number,
                )

            except Exception as error:
                print("Could not create trial output:", repr(error))
                active_trial = None
                active_reservation = None
                return

            active_reservation = prepared_reservation
            active_trial = prepared_trial

            video_writer = None
            frame_count = 0
            pre_sync_result = None
            post_sync_result = None
            pre_sync_event.clear()
            post_sync_event.clear()

            print (
                f"\nPreparing trial {prepared_reservation.trial_number}:"
                f"{prepared_trial.trial_directory}"
            )

            await server.send_command_to_role(IMU_WATCH_ROLE,"prepare_trial_sync")

            try:
                await asyncio.wait_for(pre_sync_event.wait(), timeout=30.0)
            except asyncio.TimeoutError:
                print("Pre-sync timed out")
                fail_active_trial(reason="pre_sync_timed_out")
                return

            if pre_sync_result is None:
                print("Pre-sync failed")
                fail_active_trial(reason="pre_sync_failed")
                return

            prepared_trial.begin_staging(int(pre_sync_result["boundaryPhoneNs"]))

            state.recording = True

            try:
                # send correct command to separate clients
                await asyncio.gather(
                    server.send_command_to_role(
                        IMU_WATCH_ROLE,
                        "start_imu_watch_streaming",
                        imuHz=100,
                        watchHz=100,
                    ),
                    server.send_command_to_role(
                        VIDEO_ROLE,
                        "start_video_streaming",
                        videoFps=30,
                    ),
                )

            except Exception as error:
                print("Could not start streaming:", repr(error))
                fail_active_trial(reason="streaming_failed")
                return

            print("\n🔴 Started recording")
            return

        print("\n🟥 Stopped recording")
        state.recording = False
        post_sync_result = None
        watch_drain_result = None
        post_sync_event.clear()
        watch_drain_event.clear()

        await server.send_command_to_role(VIDEO_ROLE,"stop_streaming")
        await server.send_command_to_role(IMU_WATCH_ROLE,"post_trial_sync")

        try:
            await asyncio.wait_for(post_sync_event.wait(), timeout=30.0)
        except asyncio.TimeoutError:
            print("Post-sync timed out")
            fail_active_trial(reason="post_sync_timed_out")
            return

        if post_sync_result is None:
            print("Post-sync failed")
            await server.send_command_to_role(IMU_WATCH_ROLE, "stop_streaming")
            fail_active_trial(reason="post_sync_failed")
            return

        await server.send_command_to_role(IMU_WATCH_ROLE, "stop_streaming")

        try:
            await asyncio.wait_for(watch_drain_event.wait(), timeout=60.0)
        except asyncio.TimeoutError:
            print("Watch drain timed out")
            await server.send_command_to_role(IMU_WATCH_ROLE, "stop_streaming")
            fail_active_trial(reason="watch_drain_timed_out")
            return

        if (
            watch_drain_result is None
            or active_trial is None
            or active_reservation is None
        ):
            print("Trial finalisation stat is incomplete")
            fail_active_trial(reason="trial_finalization_state_missing")
            return

        finalizing_trial = active_trial
        finalizing_reservation = active_reservation
        finalizing_post_sync = post_sync_result
        finalizing_drain = watch_drain_result

        await wait_for_sensor_drain()

        try:
            close_video_writer()
            summary = finalizing_trial.finalize(
                int(finalizing_post_sync["boundaryPhoneNs"])
            )
            summary["watch_transport"] = {
                "captured_motion_samples": finalizing_drain["capturedSampleCount"],
            }
            finalizing_trial.close()
            metadata_store.mark_trial_complete(finalizing_reservation, summary)
        except Exception as error:
            print("Trial finalization failed:", repr(error))
            fail_active_trial(reason="trial_finalization_failed")
            return

        completed_directory = finalizing_reservation.trial_directory
        active_trial = None
        active_reservation = None
        print(f"\n✅ Trial complete: {completed_directory}")

    async def set_participant_id(prompt_input: PromptInput) -> None:
        if active_trial is not None:
            print("❌ Cannot change participant while a trial is active")
            return

        requested_id = await prompt_input("\nParticipant ID: ")#

        try:
            participant_id = metadata_store.validate_participant_id(requested_id)
            directory = metadata_store.ensure_participant(participant_id)
        except ValueError as error:
            print(f"❌ Invalid participant ID: {error}")
            return

        state.participant_id = participant_id
        print(f"✅ Participant selected: {directory}")

    async def set_boulder_id(prompt_input: PromptInput) -> None:
        if active_trial is not None:
            print("❌ Cannot change boulder ID while a trial is active")
            return

        state.boulder_id = (await prompt_input("\nBoulder ID: ")).strip() or None
        print(f"Boulder ID set to: {state.boulder_id} or 'not set'")

    async def status(_: PromptInput) -> None:
        def connection_message(device: str, connected: bool) -> str:
            return (
                f"✅ {device}: connected"
                if connected else f"❌ {device} not connected"
            )

        def recording_message(is_recording: bool) -> str:
            if is_recording:
                return "🔴 Recording active"
            return "⏸️ Recording paused"

        print("\n Status")
        print(connection_message("IMU_Phone", state.imu_phone_connected))
        print(connection_message("VIDEO_Phone", state.video_phone_connected))
        print(connection_message("Watch", state.watch_connected))

        print(recording_message(state.recording))
        print("Participant ID:", state.participant_id or 'not set')
        print("Boulder ID:", state.boulder_id or 'not set')
        print(
            "Trial directory:",
            active_trial.trial_directory if active_trial else "none",
        )

    async def on_imu(data: IMUData) -> None:
        nonlocal last_sensor_arrival
        state.mark_received("phone_imu")
        last_sensor_arrival = monotonic()

        if active_trial is not None:
            active_trial.stage_row("imu", data.timestamp_ns,[
                data.sequence_id,
                data.timestamp_ns,
                data.timestamp_s,
                *data.angular_velocity,
                *data.linear_acceleration,
                *(data.gravity if data.gravity else (0, 0 ,0)),
            ])

    async def on_watch_imu(data: WatchIMUData) -> None:
        nonlocal last_sensor_arrival
        state.mark_received("watch_imu")
        last_sensor_arrival = monotonic()

        if active_trial is not None:
            active_trial.stage_row("watch_imu", data.timestamp_ns,[
                data.sequence_id,
                data.timestamp_ns,
                data.timestamp_s,
                data.watch_timestamp_ns,
                data.phone_received_timestamp_ns,
                *data.angular_velocity,
                *data.linear_acceleration,
            ])

    async def on_watch_attitude(data: WatchAttitudeData) -> None:
        nonlocal last_sensor_arrival
        state.mark_received("watch_attitude")
        last_sensor_arrival = monotonic()

        if active_trial is not None:
            active_trial.stage_row("watch_attitude", data.timestamp_ns,[
                data.sequence_id,
                data.timestamp_ns,
                data.timestamp_s,
                data.watch_timestamp_ns,
                data.phone_received_timestamp_ns,
                *data.quaternion,
                data.roll,
                data.pitch,
                data.yaw,
                data.reference_frame,
            ])

    async def on_watch_activity(_: WatchMotionActivityData) -> None:
        return

    async def on_camera(frame: CameraFrame) -> None:
        nonlocal video_writer, frame_count
        state.mark_received("video")
        writer = video_writer

        if not state.recording or active_trial is None:
            return

        frame_count += 1
        active_trial.record_video_metadata(
            frame.timestamp_ns,
            frame.timestamp_s,
            frame_count,
        )

        image = Image.open(io.BytesIO(frame.data))
        image_array = np.array(image)

        if writer is None:
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            writer = cv2.VideoWriter(
                str(active_trial.video_path),
                fourcc,
                10,
                (frame.width, frame.height),
            )
            video_writer = writer
        writer.write(cv2.cvtColor(image_array, cv2.COLOR_RGB2BGR))

    async def on_connect(client_id: str) -> None:
        print(f"Client connected; awaiting role handshake: {client_id}")

    async def on_client_role(client_id: str, role: str, _handshake: dict[str, Any]) -> None:
        if role == IMU_WATCH_ROLE:
            state.imu_phone_connected = True
        elif role == VIDEO_ROLE:
            state.video_phone_connected = True

        print(f"Client ready: {role} ({client_id})")

    async def on_client_role_disconnect(client_id: str, role: str) -> None:
        if role == IMU_WATCH_ROLE:
            state.imu_phone_connected = False
        elif role == VIDEO_ROLE:
            state.video_phone_connected = False

        print(f"Client disconnected: {role} ({client_id})")

    async def on_disconnect(client_id: str) -> None:
        print(f"Client disconnected: {client_id}")

    async def on_error(error: str, details: str | None) -> None:
        print(f"Phone error: {error}")

        if details: print(details)

        if error == "pre_sync_failed":
            pre_sync_event.set()
        elif error == "post_sync_failed":
            post_sync_event.set()

    async def on_watch_sync_result(data: dict) -> None:
        nonlocal pre_sync_result, post_sync_result
        phase = data["phase"]

        if active_trial is not None:
            active_trial.record_sync_result(data)

        if phase == "pre":
            pre_sync_result = data
            pre_sync_event.set()
        elif phase == "post":
            post_sync_result = data
            post_sync_event.set()

    async def on_watch_stream_drained(data: dict) -> None:
        nonlocal watch_drain_result
        watch_drain_result = data
        watch_drain_event.set()

    server.on_imu = on_imu
    server.on_watch_imu = on_watch_imu
    server.on_watch_attitude = on_watch_attitude
    server.on_watch_activity = on_watch_activity
    server.on_camera = on_camera
    server.on_connect = on_connect
    server.on_disconnect = on_disconnect
    server.on_watch_sync_result = on_watch_sync_result
    server.on_watch_stream_drained = on_watch_stream_drained
    server.on_error = on_error
    server.on_client_role = on_client_role
    server.on_client_role_disconnect = on_client_role_disconnect

    key_handlers = {
        "q": quit_program,
        "r": start_stop_recording,
        "s": status,
        "p": set_participant_id,
        "b": set_boulder_id,
    }

    server_task = asyncio.create_task(server.start())
    keyboard_task = asyncio.create_task(listen_for_keys(key_handlers, stop_event))

    try:
        await stop_event.wait()
    finally:
        if active_trial is not None:
            fail_active_trial("program_stopped")

        keyboard_task.cancel()
        server_task.cancel()
        await asyncio.gather(server_task, keyboard_task, return_exceptions=True)

if __name__ == "__main__":
    asyncio.run(main())
