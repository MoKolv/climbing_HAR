"""
Python script to control data collection while climbing using arvos
"""

import asyncio
from typing import Any

from pathlib import Path
from time import monotonic, monotonic_ns
from timeline_sync import add_nearest_imu_to_video, add_server_timestamps, clock_model, add_watch_server_timestamps, watch_clock_model
from trial_upload_server import TrialUploadServer


from arvos import (
    ArvosServer,
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
    #server = ArvosServer(port=9090)
    server = ArvosServer(alt_host= "192.168.178.2", port=9090)

    upload_server = TrialUploadServer(port=9091)
    active_upload_token: str | None = None

    IMU_WATCH_ROLE = "imu_watch"
    VIDEO_ROLE = "video"
    REQUIRED_ROLES = {IMU_WATCH_ROLE, VIDEO_ROLE}

    state = RecordingState()
    stop_event = asyncio.Event()
    pre_sync_event = asyncio.Event()
    post_sync_event = asyncio.Event()
    watch_drain_event = asyncio.Event()
    phone_sync_events = {"pre": asyncio.Event(), "post": asyncio.Event()}
    video_armed_event = asyncio.Event()


    pre_sync_result: dict | None = None
    post_sync_result: dict | None = None
    watch_drain_result: dict | None = None
    phone_sync_results: dict[str, dict[str, dict]] = {"pre": {}, "post": {}}

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

    async def fail_active_trial(reason: str) -> None:
        nonlocal active_trial, active_reservation, active_upload_token

        state.recording = False

        abort_results = await asyncio.gather(
            server.send_command_to_role(IMU_WATCH_ROLE, "stop_streaming"),
            server.send_command_to_role(VIDEO_ROLE, "cancel_video_recording"),
            return_exceptions= True,
        )

        for result in abort_results:
            if isinstance(result, Exception):
                print("Could not stop a trial client:", repr(result))

        if active_trial is not None:
            try:
                active_trial.close()
            except Exception as error:
                print("Failed to close trial files:", repr(error))

        if active_reservation is not None:
            try:
                metadata_store.mark_trial_failed(active_reservation, reason)
            except Exception as error:
                print("Failed to update trial metadata:", repr(error))

        if active_upload_token is not None:
            upload_server.revoke(active_upload_token)

        active_trial = None
        active_reservation = None
        active_upload_token = None

    async def wait_for_sensor_drain(quiet_seconds: float = 0.5, maximum_wait_seconds: float = 5.0) -> None:
        overall_deadline = monotonic() + maximum_wait_seconds
        quiet_deadline = monotonic() + quiet_seconds
        observed_arrival = last_sensor_arrival

        while monotonic() < overall_deadline:
            await asyncio.sleep(0.05)

            if last_sensor_arrival > observed_arrival:
                observed_arrival = last_sensor_arrival
                quiet_deadline = monotonic() + quiet_seconds

            if monotonic() >= quiet_deadline:
                return

        raise asyncio.TimeoutError("Sensor stream did not become quiet")

    async def quit_program(_: PromptInput) -> None:
        print("\n🚫 Stopping program")
        stop_event.set()

    async def _start_stop_recording(_: PromptInput) -> None:
        nonlocal pre_sync_result, post_sync_result, watch_drain_result
        nonlocal active_trial, active_reservation
        nonlocal active_upload_token

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

            pre_sync_result = None
            post_sync_result = None
            watch_drain_result = None

            pre_sync_event.clear()
            post_sync_event.clear()
            watch_drain_event.clear()
            video_armed_event.clear()

            for phase in ("pre", "post"):
                phone_sync_results[phase].clear()
                phone_sync_events[phase].clear()

            active_upload_token = upload_server.authorize(
                active_reservation.trial_directory
            )

            trial_id = (
                f"participant_{active_reservation.participant_id}_"
                f"trial_{active_reservation.trial_number:03d}"
            )

            upload_base_url = (
                f"http://{server.get_local_ip()}:9091/"
                f"upload/{active_upload_token}"
            )

            await server.send_command_to_role(
                VIDEO_ROLE,
                "arm_video_recording",
                trialId = trial_id,
                videoFps = 30,
                uploadBaseURL = upload_base_url,
            )
            await asyncio.wait_for(video_armed_event.wait(), timeout=15.0)

            await asyncio.gather(
                server.send_command_to_role(IMU_WATCH_ROLE, "prepare_trial_sync"),
                server.send_command_to_role(IMU_WATCH_ROLE, "synchronize_phone_clock", phase = "pre"),
                server.send_command_to_role(VIDEO_ROLE, "synchronize_phone_clock", phase = "pre"),
            )

            await asyncio.gather(
                asyncio.wait_for(pre_sync_event.wait(), timeout=30.0),
                asyncio.wait_for(phone_sync_events["pre"].wait(), timeout=30.0),
            )

            if pre_sync_result is None:
                print("Watch pre-trial synchronization failed")
                await fail_active_trial("pre_sync_failed")
                return

            start_at_server_ns = monotonic_ns() + 2_000_000_000
            imu_pre_offset = int(
                phone_sync_results["pre"][IMU_WATCH_ROLE]["serverMinusPhoneOffsetNs"]
            )

            start_at_imu_phone_ns = start_at_server_ns - imu_pre_offset
            active_trial.begin_staging(start_at_imu_phone_ns)
            await asyncio.gather(
                server.send_command_to_role(
                    IMU_WATCH_ROLE,
                    "start_imu_watch_streaming",
                    startAtServerNs = start_at_server_ns,
                    imuHz = 100,
                    watchHz = 100,
                ),

                server.send_command_to_role(
                    VIDEO_ROLE,
                    "start_video_recording",
                    startAtServerNs = start_at_server_ns,
                ),
            )

            state.recording = True
            print("\n🔴 Started recording")
            return

        print("\n🟥 Stopped recording")
        print("\nFinalizing trial")

        post_sync_result = None
        watch_drain_result = None

        post_sync_event.clear()
        watch_drain_event.clear()
        phone_sync_results["post"].clear()
        phone_sync_events["post"].clear()

        await asyncio.gather(
            server.send_command_to_role(IMU_WATCH_ROLE, "post_trial_sync"),
            server.send_command_to_role(IMU_WATCH_ROLE, "synchronize_phone_clock", phase = "post"),
            server.send_command_to_role(VIDEO_ROLE, "synchronize_phone_clock", phase = "post"),
        )

        await asyncio.gather(
            asyncio.wait_for(post_sync_event.wait(), timeout=30.0),
            asyncio.wait_for(phone_sync_events["post"].wait(), timeout=30.0),
        )

        if post_sync_result is None:
            print("Watch post-trial synchronization failed")
            await fail_active_trial("post_sync_failed")
            return

        stop_at_server_ns = monotonic_ns() + 1_000_000_000
        imu_post_offset = int(
            phone_sync_results["post"][IMU_WATCH_ROLE]["serverMinusPhoneOffsetNs"]
        )

        stop_at_imu_phone_ns = stop_at_server_ns - imu_post_offset

        await asyncio.gather(
            server.send_command_to_role(
                VIDEO_ROLE,
                "stop_video_recording",
                stopAtServerNs = stop_at_server_ns,
            ),

            server.send_command_to_role(
                IMU_WATCH_ROLE,
                "stop_imu_watch_streaming",
                stopAtServerNs = stop_at_server_ns,
            ),
        )

        await asyncio.gather(
            asyncio.wait_for(watch_drain_event.wait(), timeout=60.0),
            upload_server.wait_for_trial_files(active_upload_token, timeout=300.0),
        )

        if watch_drain_result is None:
            print("Watch did not report its final sample count")
            await fail_active_trial("watch_drain_result_missing")
            return

        await wait_for_sensor_drain()

        summary = active_trial.finalize(stop_at_imu_phone_ns)
        summary["watch_transport"] = {
            "captured_motion_samples": (
                watch_drain_result["capturedSampleCount"]
            ),
        }

        active_trial.close()

        imu_phone_model = clock_model({
            "pre": phone_sync_results["pre"][IMU_WATCH_ROLE],
            "post": phone_sync_results["post"][IMU_WATCH_ROLE],
        })

        assert pre_sync_result is not None
        assert post_sync_result is not None

        watch_phone_model = watch_clock_model({
            "pre": pre_sync_result,
            "post": post_sync_result,
        })

        add_server_timestamps(
            active_trial.trial_directory / "imu.csv",
            imu_phone_model,
        )

        for filename in ("watch_imu.csv", "watch_attitude.csv"):
            add_watch_server_timestamps(
                active_trial.trial_directory / filename,
                watch_phone_model,
                imu_phone_model,
            )

        add_nearest_imu_to_video(
            active_trial.trial_directory / "video_timestamps.csv",
            active_trial.trial_directory / "imu.csv",
        )

        completed_directory = active_reservation.trial_directory

        metadata_store.mark_trial_complete(active_reservation, summary)
        upload_server.revoke(active_upload_token)

        active_trial = None
        active_reservation = None
        active_upload_token = None
        state.recording = False

        print(f"\n✅ Trial complete: {completed_directory}")

    async def start_stop_recording(prompt_input: PromptInput) -> None:
        try:
            await _start_stop_recording(prompt_input)
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            print("Trial operation timed out")
            await fail_active_trial("trial_timeout")
        except Exception as error:
            print("Trial operation failed:", repr(error))
            await fail_active_trial(
                f"trial_error:{type(error).__name__}:{error}"
            )

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

    async def on_phone_clock_sync_result(role: str, data: dict) -> None:
        phase = data["phase"]
        phone_sync_results[phase][role] = data

        if active_trial is not None:
            active_trial.record_phone_sync_result(role, data)

        if REQUIRED_ROLES <= phone_sync_results[phase].keys():
            phone_sync_events[phase].set()

    async def on_video_recording_armed(role: str, data: dict) -> None:
        if role == VIDEO_ROLE:
            video_armed_event.set()


    server.on_imu = on_imu
    server.on_watch_imu = on_watch_imu
    server.on_watch_attitude = on_watch_attitude
    server.on_watch_activity = on_watch_activity
    server.on_connect = on_connect
    server.on_disconnect = on_disconnect
    server.on_watch_sync_result = on_watch_sync_result
    server.on_watch_stream_drained = on_watch_stream_drained
    server.on_error = on_error
    server.on_client_role = on_client_role
    server.on_client_role_disconnect = on_client_role_disconnect
    server.on_phone_clock_sync_result = on_phone_clock_sync_result
    server.on_video_recording_armed = on_video_recording_armed

    key_handlers = {
        "q": quit_program,
        "r": start_stop_recording,
        "s": status,
        "p": set_participant_id,
        "b": set_boulder_id,
    }

    await upload_server.start()

    server_task = asyncio.create_task(server.start())
    keyboard_task = asyncio.create_task(listen_for_keys(key_handlers, stop_event))

    try:
        await stop_event.wait()
    finally:
        if active_trial is not None:
            await fail_active_trial("program_stopped")

        keyboard_task.cancel()
        server_task.cancel()
        await asyncio.gather(server_task, keyboard_task, return_exceptions=True)
        await upload_server.stop()

if __name__ == "__main__":
    asyncio.run(main())
