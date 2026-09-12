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

    debug_mode = False
    active_trial_roles: set [str] = set()
    active_watch_expected = False

    def select_trial_roles() -> set[str] | None:
        missing_roles = server.missing_roles(REQUIRED_ROLES)
        connected_roles = REQUIRED_ROLES - missing_roles

        if not missing_roles:
            return set(REQUIRED_ROLES)

        connected_text = (
            ", ".join(sorted(connected_roles))
            if connected_roles
            else "none"
        )

        missing_text = ", ".join(sorted(missing_roles))

        if not debug_mode:
            print("\n❌ Cannot start trial: required clients are missing.")
            print(f"Connected roles: {connected_text}")
            print(f"Missing roles: {missing_text}")
            print(
                "Connect missing clients, or pres 'd' to enable "
                "debug mode for partial trial recording."
            )

            return None

        if not connected_roles:
            print("\nCannot start debug trial: no clients connected.")
            print(f"Required roles: {', '.join(sorted(REQUIRED_ROLES))}")
            return None

        print(
            "\nDebug mode: recording a partial trial with roles:"
            f"{connected_text}"
        )

        print(f"Missing roles: {missing_text}")
        return connected_roles

    async def fail_active_trial(reason: str) -> None:
        nonlocal active_trial, active_reservation, active_upload_token
        nonlocal active_trial_roles, active_watch_expected

        state.recording = False

        abort_commands = []

        if IMU_WATCH_ROLE in active_trial_roles:
            abort_commands.append(
                server.send_command_to_role(IMU_WATCH_ROLE, "stop_streaming")
            )

        if VIDEO_ROLE in active_trial_roles:
            abort_commands.append(
                server.send_command_to_role(VIDEO_ROLE, "cancel_video_recording")
            )

        results = await asyncio.gather(
            *abort_commands,
            return_exceptions=True,
        )

        for result in results:
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
        active_watch_expected = False
        active_trial_roles.clear()

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
        nonlocal active_trial, active_reservation, active_upload_token
        nonlocal active_trial_roles, active_watch_expected

        if not state.recording:
            if not state.participant_id:
                print("Set a participant_id with 'p' before starting a trial")
                return

            selected_roles = select_trial_roles()
            if selected_roles is None:
                return

            active_trial_roles = selected_roles
            active_watch_expected = False

            has_imu = IMU_WATCH_ROLE in active_trial_roles
            has_video = VIDEO_ROLE in active_trial_roles


            try:
                active_reservation = metadata_store.begin_trial(
                    state.participant_id,
                    state.boulder_id,
                )

                active_trial = TrialOutput(
                    active_reservation.trial_directory,
                    active_reservation.trial_number,
                )
            except Exception as error:
                active_trial_roles.clear()
                print("Could not create trial output:", repr(error))
                return

            pre_sync_result = None
            post_sync_result = None
            watch_drain_result = None
            active_upload_token = None

            pre_sync_event.clear()
            post_sync_event.clear()
            watch_drain_event.clear()
            video_armed_event.clear()

            for phase in ("pre", "post"):
                phone_sync_results[phase].clear()
                phone_sync_events[phase].clear()

            if has_video:
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

                await asyncio.wait_for(
                    video_armed_event.wait(),
                    timeout = 15.0,
                )

            pre_sync_commands = []

            if has_imu:
                pre_sync_commands.extend([
                    server.send_command_to_role(
                        IMU_WATCH_ROLE,
                        "prepare_trial_sync",
                    ),
                    server.send_command_to_role(
                        IMU_WATCH_ROLE,
                        "synchronize_phone_clock",
                        phase = "pre",
                    )
                ])

            if has_video:
                pre_sync_commands.append(
                    server.send_command_to_role(
                        VIDEO_ROLE,
                        "synchronize_phone_clock",
                        phase = "pre"
                    )
                )

            await asyncio.gather(*pre_sync_commands)

            pre_sync_waits = [
                asyncio.wait_for(
                    phone_sync_events["pre"].wait(),
                    timeout = 30.0,
                )
            ]

            if has_imu:
                pre_sync_waits.append(
                    asyncio.wait_for(
                        pre_sync_event.wait(),
                        timeout = 30.0,
                    )
                )

            await asyncio.gather(*pre_sync_waits)

            if has_imu:
                if pre_sync_result is None:
                    if not debug_mode:
                        await fail_active_trial("pre_sync_failed")
                        return

                    print(
                        "Debug mode: Watch synchronization unavailable;"
                        "continuing with phone IMU only"
                    )
                else:
                    active_watch_expected = True

            start_at_server_ns = monotonic_ns() + 2_000_000_000

            if has_imu:
                imu_pre_offset = int(
                    phone_sync_results["pre"][IMU_WATCH_ROLE]["serverMinusPhoneOffsetNs"]
                )

                staging_start_ns = start_at_server_ns - imu_pre_offset
            else:
                #Video only trials not staging IMU rows
                staging_start_ns = start_at_server_ns

            active_trial.begin_staging(staging_start_ns)

            start_commands = []

            if has_imu:
                start_commands.append(
                    server.send_command_to_role(
                        IMU_WATCH_ROLE,
                        "start_imu_watch_streaming",
                        startAtServerNs =  start_at_server_ns,
                        imuHz = 100,
                        watchHz = 100,
                    )
                )

            if has_video:
                start_commands.append(
                    server.send_command_to_role(
                        VIDEO_ROLE,
                        "start_video_recording",
                        startAtServerNs = start_at_server_ns,
                    )
                )

            await asyncio.gather(*start_commands)

            state.recording = True
            print(
                "\n🔴 Started recording role(s):",
                ", ".join(sorted(active_trial_roles)),
            )
            return

        has_imu = IMU_WATCH_ROLE in active_trial_roles
        has_video = VIDEO_ROLE in active_trial_roles

        trial_stop_requested_server_ns = monotonic_ns()

        print("\n🟥 Stopping recording")
        print("Finalizing trial")

        post_sync_result = None
        watch_drain_result = None

        post_sync_event.clear()
        watch_drain_event.clear()
        phone_sync_results["post"].clear()
        phone_sync_events["post"].clear()

        post_sync_commands = []

        if has_imu:
            if active_watch_expected:
                post_sync_commands.append(
                    server.send_command_to_role(
                        IMU_WATCH_ROLE,
                        "post_trial_sync",
                    )
                )

            post_sync_commands.append(
                server.send_command_to_role(
                    IMU_WATCH_ROLE,
                    "synchronize_phone_clock",
                    phase = "post",
                )
            )

        if has_video:
            post_sync_commands.append(
                server.send_command_to_role(
                    VIDEO_ROLE,
                    "synchronize_phone_clock",
                    phase = "post",
                )
            )

        await asyncio.gather(*post_sync_commands)

        post_sync_waits = [
            asyncio.wait_for(phone_sync_events["post"].wait(), timeout=30.0),
        ]

        if active_watch_expected:
            post_sync_waits.append(
                asyncio.wait_for(post_sync_event.wait(), timeout=30.0)
            )

        await asyncio.gather(*post_sync_waits)

        if active_watch_expected and post_sync_result is None:
            if not debug_mode:
                await fail_active_trial("post_sync_failed")
                return

            print(
                "Debug mode: Watch post-sync failed;"
                "using the existing adjusted timestamps"
            )

        stop_at_server_ns = monotonic_ns() + 1_000_000_000

        if has_imu:
            imu_post_offset = int(
                phone_sync_results["post"][IMU_WATCH_ROLE]["serverMinusPhoneOffsetNs"]
            )
            staging_stop_ns = trial_stop_requested_server_ns - imu_post_offset
        else:
            staging_stop_ns = trial_stop_requested_server_ns

        stop_commands = []

        if has_video:
            stop_commands.append(
                server.send_command_to_role(
                    VIDEO_ROLE,
                    "stop_video_recording",
                    stopAtServerNs = stop_at_server_ns,
                )
            )

        if has_imu:
            stop_commands.append(
                server.send_command_to_role(
                    IMU_WATCH_ROLE,
                    "stop_imu_watch_streaming",
                    stopAtServerNs = stop_at_server_ns,
                )
            )

        await asyncio.gather(*stop_commands)

        if has_video:
            if active_upload_token is None:
                raise RuntimeError("Video trial has no upload token")

            await upload_server.wait_for_trial_files(
                active_upload_token,
                timeout = 300.0,
            )

        if active_watch_expected:
            await asyncio.wait_for(watch_drain_event.wait(), timeout=60.0)

        if has_imu:
            await wait_for_sensor_drain()


        summary = active_trial.finalize(staging_stop_ns)

        summary["debug_mode"] = debug_mode
        summary["recorded_roles"] = sorted(active_trial_roles)
        summary["partial_trial"] = active_trial_roles != REQUIRED_ROLES

        if watch_drain_result is not None:
            summary["watch_transport"] = {
                "captured_motion_samples": (
                    watch_drain_result["capturedSampleCount"]
                ),
            }

        active_trial.close()

        if has_imu:
            imu_phone_model = clock_model({
                "pre": phone_sync_results["pre"][IMU_WATCH_ROLE],
                "post": phone_sync_results["post"][IMU_WATCH_ROLE],
            })

            add_server_timestamps(
                active_trial.trial_directory / "imu.csv",
                imu_phone_model,
            )

            if pre_sync_result is not None and post_sync_result is not None:
                watch_phone_model = watch_clock_model({
                    "pre": pre_sync_result,
                    "post": post_sync_result,
                })

                for filename in ("watch_imu.csv", "watch_attitude.csv"):
                    add_watch_server_timestamps(
                        active_trial.trial_directory / filename,
                        watch_phone_model,
                        imu_phone_model,
                    )
            else:
                # Debug fallback: timestamps were already adjusted
                # by the IMU phone using its available watch offset
                for filename in ("watch_imu.csv", "watch_attitude.csv"):
                    add_server_timestamps(
                        active_trial.trial_directory / filename,
                        imu_phone_model
                    )

        if has_imu and has_video:
            try:
                add_nearest_imu_to_video(
                    active_trial.trial_directory / "video_timestamps.csv", active_trial.trial_directory / "imu.csv",
                )
            except ValueError:
                if not debug_mode:
                    raise
                print(
                    "Debug mode: no IMU samples available for"
                    "video-frame matching"
                )


        completed_directory = active_reservation.trial_directory

        metadata_store.mark_trial_complete(active_reservation, summary)

        if active_upload_token is not None:
            upload_server.revoke(active_upload_token)

        active_trial = None
        active_reservation = None
        active_upload_token = None
        active_watch_expected = False
        active_trial_roles.clear()
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

    async def toggle_debug_mode(_: PromptInput) -> None:
        nonlocal debug_mode

        if active_trial is not None:
            print("Cannot change debug mode while a trial is active")
            return

        debug_mode = not debug_mode

        print(
            "Debug mode:",
            "✅ ON - partial one-phone trials allowed"
            if debug_mode
            else "❌ OFF - both phone roles required"
        )

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
        print("🔧 Debug mode:", "✅ ON" if debug_mode else "❌ OFF")

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
        expected_roles = active_trial_roles or REQUIRED_ROLES

        if active_trial is not None:
            active_trial.record_phone_sync_result(role, data)

        if expected_roles <= phone_sync_results[phase].keys():
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
        "d": toggle_debug_mode,
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
