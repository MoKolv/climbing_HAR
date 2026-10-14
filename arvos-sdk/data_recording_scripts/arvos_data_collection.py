"""
Python script to control data collection while climbing using arvos
"""

import asyncio
from typing import Any
from functools import partial

from pathlib import Path
from time import monotonic, monotonic_ns
from timeline_sync import add_nearest_imu_to_video, add_server_timestamps, clock_model, add_watch_server_timestamps, watch_clock_model
from trial_upload_server import TrialUploadServer


from arvos import (
    ArvosServer,
    IMUData,
    WatchMotionActivityData,
)
from participant_metadata import ParticipantMetadataStore, TrialMetadata, TrialReservation
from participant_profile import ParticipantProfile
from recording_state import RecordingState
from terminal_controls import PromptInput, TimedKeyHandler, listen_for_keys
from trial_output import TrialOutput
from trial_labels import TrialLabels

# Experiment settings
TRIALS_PER_PARTICIPANT = 4
RPE_MIN = 0
RPE_MAX = 10

# Keys for labeling extremities
MARKER_KEYS = {
    "f": "left_hand",
    "k": "right_hand",
    "v": "left_foot",
    "m": "right_foot",
}

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
    watch_experiment_session_event = asyncio.Event()
    phone_sync_events = {"pre": asyncio.Event(), "post": asyncio.Event()}
    video_armed_event = asyncio.Event()
    video_capture_stopped_event = asyncio.Event()


    pre_sync_result: dict | None = None
    post_sync_result: dict | None = None
    watch_drain_result: dict | None = None
    phone_sync_results: dict[str, dict[str, dict]] = {"pre": {}, "post": {}}

    last_sensor_arrival = monotonic()

    active_trial: TrialOutput | None = None
    active_reservation: TrialReservation | None = None

    active_labels: TrialLabels | None = None
    label_write_failed = False

    debug_mode = False
    active_trial_roles: set [str] = set()
    active_watch_expected = False
    watch_experiment_session_state = "inactive"

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

    async def confirm_yes_no(prompt_input: PromptInput, question: str) -> bool:
        while True:
            answer = (await prompt_input(f"{question} [y/n]")).lower()
            if answer == "y":
                return True
            if answer == "n":
                return False
            print("Confirm or cancel with [y/n]")

    async def collect_missing_participant_fields(participant_id: str, prompt_input: PromptInput) -> None:
        metadata = metadata_store.load(participant_id)
        profile = ParticipantProfile(metadata.get("participant", {}))

        for field in profile.missing_fields():
            while True:
                answer = await prompt_input(f"{field.label}: ")
                try:
                    value = profile.set_answer(field, answer)
                except ValueError as error:
                    print(error)
                    continue

                metadata_store.update_participant(participant_id, {field.key: value})
                break

    async def prompt_trial_metadata(prompt_input: PromptInput, boulder_id: str | None ) -> TrialMetadata:
        subject = (
            f"boulder {boulder_id}"
            if boulder_id
            else "this_trial"
        )

        accepted_hands = {
            "l": "left",
            "left": "left",
            "r": "right",
            "right": "right",
            "n": "not_worn",
            "not_worn": "not_worn",
            "not worn": "not_worn",
        }

        # require watch_placement
        while True:
            answer = await prompt_input(
                "Watch worn on which hand?"
                "[l=left, r=right, n=not_worn]"
            )

            watch_hand = accepted_hands.get(answer.strip().lower())

            if watch_hand is not None:
                break

            print("Enter l, r, or n, then press Enter.")

        # RPE optional
        rpe: int | None = None

        while True:
            answer = await prompt_input(
                f"RPE for {subject} "
                f"({RPE_MIN} - {RPE_MAX}, Enter to skip): "
            )

            answer = answer.strip()

            if not answer:
                break

            try:
                entered_rpe = int(answer)
            except ValueError:
                print("Enter a whole number, or press Enter to skip.")
                continue

            if RPE_MIN <= entered_rpe <= RPE_MAX:
                rpe = entered_rpe
                break

            print(f"RPE must be between {RPE_MIN} and {RPE_MAX}.")

        return TrialMetadata(
            watch_worn_on = watch_hand,
            rpe = rpe,
            rpe_scale= f"{RPE_MIN}-{RPE_MAX}",
        )

    async def fail_active_trial(reason: str) -> None:
        nonlocal active_trial, active_reservation, active_upload_token
        nonlocal active_trial_roles, active_watch_expected
        nonlocal active_labels

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

        if active_labels is not None:
            try:
                active_labels.close()
            except OSError as err:
                print("Could not close labels.csv:", repr(err))

            active_labels = None

        if active_trial is not None:
            try:
                active_trial.close()
            except Exception as err:
                print("Failed to close trial files:", repr(err))

        if active_reservation is not None:
            try:
                metadata_store.mark_trial_failed(active_reservation, reason)
            except Exception as err:
                print("Failed to update trial metadata:", repr(err))

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

    async def ensure_watch_experiment_session() -> bool:
        nonlocal watch_experiment_session_state

        if watch_experiment_session_state == "running":
            return True

        if not server.has_role(IMU_WATCH_ROLE):
            print("Cannot start watch workout session: IMU phone is not connected")
            return False

        watch_experiment_session_event.clear()
        watch_experiment_session_state = "starting"

        await server.send_command_to_role(IMU_WATCH_ROLE, "start_watch_experiment_session")

        try:
            await asyncio.wait_for(
                watch_experiment_session_event.wait(),
                timeout= 15.0,
            )
        except asyncio.TimeoutError:
            watch_experiment_session_state = "unknown"
            print("Timed out waiting for the watch workout session to start")
            return False

        if watch_experiment_session_state != "running":
            print("Watch workout session did not start; state:", watch_experiment_session_state)
            return False

        print("Watch workout session started")
        return True


    async def _start_stop_recording(prompt_input: PromptInput) -> None:
        nonlocal pre_sync_result, post_sync_result, watch_drain_result
        nonlocal active_trial, active_reservation, active_upload_token
        nonlocal active_trial_roles, active_watch_expected
        nonlocal active_labels, label_write_failed

        if not state.recording:
            participant_id = state.participant_id
            if not participant_id:
                print("Set a participant_id with 'p' before starting a trial")
                return

            selected_roles = select_trial_roles()
            if selected_roles is None:
                return

            if not debug_mode:
                await collect_missing_participant_fields(participant_id, prompt_input)
                next_trial = metadata_store.next_trial_number(participant_id)

                if next_trial > TRIALS_PER_PARTICIPANT:
                    confirmed = await confirm_yes_no(
                        prompt_input,
                        f"Trial {next_trial} exceeds the target of "
                        f"{TRIALS_PER_PARTICIPANT} for participant "
                        f"{participant_id}. Start it anyway?",
                    )
                    if not confirmed:
                        print("Trial start cancelled.")
                        return

            active_trial_roles = selected_roles
            active_watch_expected = False

            has_imu = IMU_WATCH_ROLE in active_trial_roles
            has_video = VIDEO_ROLE in active_trial_roles

            if has_imu and not await ensure_watch_experiment_session():
                active_trial_roles.clear()
                return

            try:
                active_reservation = metadata_store.begin_trial(
                    participant_id,
                    state.boulder_id,
                )


                active_trial = TrialOutput(
                    active_reservation.trial_directory,
                    active_reservation.trial_number,
                )

                active_labels = TrialLabels(
                    active_reservation.trial_directory,
                    active_reservation.trial_number,
                )

                label_write_failed = False
            except Exception as err:
                print("Could not create trial output:", repr(err))
                await fail_active_trial("trial_setup_failed")
                return

            pre_sync_result = None
            post_sync_result = None
            watch_drain_result = None
            active_upload_token = None

            pre_sync_event.clear()
            post_sync_event.clear()
            watch_drain_event.clear()
            video_armed_event.clear()
            video_capture_stopped_event.clear()

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

            if active_labels is None:
                raise RuntimeError("Trial has no label writer")

            active_labels.arm(start_at_server_ns)

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
        print("Stopping capture at a shared timestamp")

        post_sync_result = None
        watch_drain_result = None

        post_sync_event.clear()
        watch_drain_event.clear()
        phone_sync_results["post"].clear()
        phone_sync_events["post"].clear()

        stop_at_server_ns = monotonic_ns() + 1_000_000_000

        capture_stop_commands = []

        if has_video:
            capture_stop_commands.append(
                server.send_command_to_role(
                    VIDEO_ROLE,
                    "stop_video_capture",
                    stopAtServerNs = stop_at_server_ns,
                )
            )

        if has_imu:
            capture_stop_commands.append(
                server.send_command_to_role(
                    IMU_WATCH_ROLE,
                    "stop_imu_watch_streaming",
                    stopAtServerNs = stop_at_server_ns,
                )
            )

        await asyncio.gather(*capture_stop_commands)

        if active_labels is not None:
            active_labels.close()
            active_labels = None

        capture_stop_waits = []

        if has_video:
            capture_stop_waits.append(
                asyncio.wait_for(
                    video_capture_stopped_event.wait(),
                    timeout = 15.0,
                )
            )

        if active_watch_expected:
            capture_stop_waits.append(
                asyncio.wait_for(
                    watch_drain_event.wait(),
                    timeout = 60.0,
                )
            )

        if capture_stop_waits:
            await asyncio.gather(*capture_stop_waits)

        if has_imu:
            await wait_for_sensor_drain()

        print("Capture stopped; measuring post-trial clock offsets 🕐")

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
            asyncio.wait_for(
                phone_sync_events["post"].wait(),
                timeout = 30.0,
            )
        ]

        if active_watch_expected:
            post_sync_waits.append(
                asyncio.wait_for(
                    post_sync_event.wait(),
                    timeout = 30.0,
                )
            )

        await asyncio.gather(*post_sync_waits)

        if active_watch_expected and post_sync_result is None:
            if not debug_mode:
                await fail_active_trial("post_sync_failed")
                return

            print("Debug mode: Watch post-sync failed, using the existing adjusted timestamps")

        if has_imu:
            imu_post_offset = int(
                phone_sync_results["post"][IMU_WATCH_ROLE]["serverMinusPhoneOffsetNs"]
            )
            staging_stop_ns = stop_at_server_ns - imu_post_offset
        else:
            staging_stop_ns = stop_at_server_ns

        upload_token = active_upload_token if has_video else None

        if has_video:
            if upload_token is None:
                raise RuntimeError("Video trial has no upload token")

            await server.send_command_to_role(
                VIDEO_ROLE,
                "finalize_video_recording",
            )

        reservation = active_reservation
        if reservation is None:
            raise RuntimeError("Trial has no metadata reservation")

        trial_metadata = await prompt_trial_metadata(prompt_input, state.boulder_id)

        metadata_store.set_trial_metadata(reservation, trial_metadata
                                          )
        if upload_token is not None:
            await upload_server.wait_for_trial_files(
                upload_token,
                timeout = 300.0,
            )

        summary = active_trial.finalize(staging_stop_ns)

        summary["labels"] = {
            "file": "labels.csv",
            "status": ("write_failed" if label_write_failed else "ok"),
            "labeling_ended_at_server_ns": trial_stop_requested_server_ns,
        }

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


                add_watch_server_timestamps(
                    active_trial.trial_directory / "watch_imu.csv",
                    watch_phone_model,
                    imu_phone_model,
                )
            else:
                # Debug fallback: timestamps were already adjusted
                # by the IMU phone using its available watch offset
                add_server_timestamps(
                    active_trial.trial_directory / "watch_imu.csv",
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

        requested_id = await prompt_input("\nParticipant ID: ")

        try:
            participant_id = metadata_store.validate_participant_id(requested_id)
        except ValueError as error:
            print(f"❌ Invalid participant ID: {error}")
            return

        previous_id = state.participant_id

        if not debug_mode and previous_id is not None and previous_id != participant_id:
            completed = metadata_store.completed_trial_count(previous_id)
            if completed < TRIALS_PER_PARTICIPANT:
                confirmed = await confirm_yes_no(
                    prompt_input,
                    f"Participant {previous_id} has {completed}/"
                    f"{TRIALS_PER_PARTICIPANT} completed trials. "
                    f"Switch to {participant_id} anyway?",
                )
                if not confirmed:
                    print("Participant unchanged.")
                    return

        directory = metadata_store.ensure_participant(participant_id)
        if not debug_mode:
            await collect_missing_participant_fields(participant_id, prompt_input)

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

    async def request_watch_workout_end(*, timeout: float = 15.0, stop_capture: bool = False) -> bool:
        nonlocal watch_experiment_session_state

        if not server.has_role(IMU_WATCH_ROLE):
            print("Cannot confirm end of watch workout session while IMU phone is not connected")
            return False

        deadline = monotonic() + timeout

        while monotonic() < deadline:
            watch_experiment_session_event.clear()
            watch_experiment_session_state = "ending"

            try:
                if stop_capture:
                    await server.send_command_to_role(IMU_WATCH_ROLE, "stop_streaming")

                await server.send_command_to_role(IMU_WATCH_ROLE, "end_watch_experiment_session")

            except Exception as err:
                watch_experiment_session_state = "unknown"
                print("Could not send watch shutdown request:", repr(err))
                return False

            remaining = deadline - monotonic()
            if remaining <= 0:
                break

            try:
                await asyncio.wait_for(watch_experiment_session_event.wait(), timeout=min(5.0, remaining))
            except asyncio.TimeoutError:
                pass

            if watch_experiment_session_state == "ended":
                print("Watch workout session ended.")
                return True
            remaining = deadline - monotonic()
            if remaining > 0:
                await asyncio.sleep(min(1.0, remaining))

        watch_experiment_session_state = "unknown"
        print("Watch workout shutdown was not confirmed before the timeout.")

        return False

    async def end_watch_experiment_session(_: PromptInput) -> None:
        if state.recording or active_trial is not None:
            print("Stop the trial before ending the watch workout session.")
            return

        await request_watch_workout_end()

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
        print("Watch workout session:", watch_experiment_session_state)

        print(recording_message(state.recording))
        print("Participant ID:", state.participant_id or 'not set')
        if state.participant_id:
            completed = metadata_store.completed_trial_count(state.participant_id)
            next_trial = metadata_store.next_trial_number(state.participant_id)
            print(f"Completed trials: {completed} / {TRIALS_PER_PARTICIPANT}")
            print(f"Next trial number:", next_trial)

        print("Boulder ID:", state.boulder_id or 'not set')
        print(
            "Trial directory:",
            active_trial.trial_directory if active_trial else "none",
        )

        if active_labels is not None:
            print("Extremity marker states:")

            for extremity, current_state in active_labels.states.items():
                displayed_state = (current_state if current_state is not None else "awaiting_first_press")

                print(f"{extremity}: {displayed_state}")

            if label_write_failed:
                print("Warning: at least one marker could not be saved")

    async def on_imu(data: IMUData) -> None:
        nonlocal last_sensor_arrival

        if data.source == "phone":
            stream_name = "imu"
            state_source = "phone_imu"
        elif data.source == "watch":
            stream_name = "watch_imu"
            state_source = "watch_imu"
        else:
            raise ValueError(f"Unknown stream {data.source}")

        state.mark_received(state_source)
        last_sensor_arrival = monotonic()

        if active_trial is None:
            return

        attitude = data.attitude
        quaternion = attitude.quaternion if attitude else (None, None, None, None)
        roll = attitude.roll if attitude else None
        pitch = attitude.pitch if attitude else None
        yaw = attitude.yaw if attitude else None
        reference_frame = attitude.reference_frame if attitude else ""
        source_timestamp_ns = data.source_timestamp_ns or data.timestamp_ns
        phone_received_timestamp_ns = data.phone_received_timestamp_ns if data.phone_received_timestamp_ns is not None else ""

        active_trial.stage_row(
            stream_name,
            data.timestamp_ns,
            [
                data.sequence_id,
                data.timestamp_ns,
                data.timestamp_s,
                data.source,
                source_timestamp_ns,
                phone_received_timestamp_ns,
                *data.angular_velocity,
                *data.linear_acceleration,
                *(data.gravity if data.gravity else (None, None, None)),
                *quaternion,
                roll,
                pitch,
                yaw,
                reference_frame,
            ]
        )
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
        nonlocal watch_experiment_session_state
        print(f"Phone error: {error}")

        if details: print(details)

        if error == "pre_sync_failed":
            pre_sync_event.set()
        elif error == "post_sync_failed":
            post_sync_event.set()
        elif error in {
            "watch_runtime_error",
            "watch_experiment_session_start_failed",
            "watch_experiment_session_end_failed",
        }:
            watch_experiment_session_state = "error"
            watch_experiment_session_event.set()

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

    async def on_watch_experiment_session_state(data: dict) -> None:
        nonlocal watch_experiment_session_state

        reported_state = data.get("state")

        if reported_state not in {"running", "ended"}:
            print("Ignoring invalid watch experiment-session state:", data)
            return

        watch_experiment_session_state = reported_state
        watch_experiment_session_event.set()

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

    async def on_video_capture_stopped(role: str, data: dict) -> None:
        if role == VIDEO_ROLE:
            video_capture_stopped_event.set()

    def record_marker(key: str, extremity: str, pressed_ns: int) -> None:
        nonlocal label_write_failed

        if not state.recording or active_labels is None:
            print(f"Marker {key} ignored: no active label window")
            return

        try:
            new_state = active_labels.record(key, extremity, pressed_ns)
        except (OSError, RuntimeError, ValueError) as err:
            label_write_failed = True
            print(f"Marker {key} was NOT saved: {err}")
            return

        if new_state is None:
            print(f"Marker {key} ignored: scheduled trial start as not arrived")
            return

        print(f"{extremity}: {new_state} at server_ns {pressed_ns}")

    timed_key_handlers: dict[str, TimedKeyHandler] = {
        key: partial(record_marker, key, extremity)
        for key, extremity in MARKER_KEYS.items()
    }

    server.on_imu = on_imu
    server.on_watch_activity = on_watch_activity
    server.on_connect = on_connect
    server.on_disconnect = on_disconnect
    server.on_watch_sync_result = on_watch_sync_result
    server.on_watch_stream_drained = on_watch_stream_drained
    server.on_watch_experiment_session_state = on_watch_experiment_session_state
    server.on_error = on_error
    server.on_client_role = on_client_role
    server.on_client_role_disconnect = on_client_role_disconnect
    server.on_phone_clock_sync_result = on_phone_clock_sync_result
    server.on_video_recording_armed = on_video_recording_armed
    server.on_video_capture_stopped = on_video_capture_stopped

    key_handlers = {
        "q": quit_program,
        "r": start_stop_recording,
        "s": status,
        "d": toggle_debug_mode,
        "p": set_participant_id,
        "b": set_boulder_id,
        "e": end_watch_experiment_session,
    }

    await upload_server.start()

    server_task = asyncio.create_task(server.start())
    keyboard_task = asyncio.create_task(
        listen_for_keys(
            key_handlers,
            stop_event,
            timed_key_handlers,
            timed_key_labels = {
                key: extremity.replace("_", " ")
                for key, extremity in MARKER_KEYS.items()
            },
        ))

    try:
        await stop_event.wait()
    finally:
        keyboard_task.cancel()
        await asyncio.gather(keyboard_task, return_exceptions=True)

        try:
            wait_for_watch_drain = (
                active_trial is not None
                and active_watch_expected
                and server.has_role(IMU_WATCH_ROLE)
            )

            if wait_for_watch_drain:
                watch_drain_event.clear()

            if active_trial is not None:
                await fail_active_trial("program_stopped")

            if wait_for_watch_drain:
                try:
                    await asyncio.wait_for(watch_drain_event.wait(), timeout=15.0)
                except asyncio.TimeoutError:
                    print("Watch drain was not confirmed, continuing with with workout shutdown")

            await request_watch_workout_end(timeout= 45.0, stop_capture=True)
        finally:
            server_task.cancel()
            await asyncio.gather(server_task, return_exceptions=True)

            await upload_server.stop()


if __name__ == "__main__":
    asyncio.run(main())
