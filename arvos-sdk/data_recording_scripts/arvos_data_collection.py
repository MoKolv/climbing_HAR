"""
python script to record data from arvos iPhone app

records IMU Data in a csv with timestamps; a video and a csv with metadata for the video mainly timestamped frames in nanoseconds

"""
import asyncio
import csv
from time import monotonic

# input management
from terminal_controls import PromptInput, listen_for_keys
from recording_state import RecordingState

from datetime import datetime
from pathlib import Path
from arvos import ArvosServer, IMUData, CameraFrame, WatchIMUData, WatchAttitudeData, WatchMotionActivityData

from PIL import Image
import io
import cv2
import numpy as np
from statistics import median

async def main():
    # create output directory

    project_root = Path(__file__).resolve().parents[2]
    data_root = project_root / "Data"
    data_root.mkdir(exist_ok=True, parents=True)

    output_dir = data_root / f"arvos_data_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    output_dir.mkdir(exist_ok=True, parents=True)

    pending_dir = output_dir / ".pending_trials"
    pending_dir.mkdir(exist_ok=True)

    print (f"saving data to: {output_dir}")

    # create csv files
    imu_file = open(output_dir / "imu.csv", "w", newline="")
    watch_imu_file = open(output_dir / "watch_imu.csv", "w", newline="")
    watch_attitude_file = open(output_dir / "watch_attitude.csv", "w", newline="")
    video_metadata_file = open(output_dir / "video_metadata.csv", "w", newline ="")
    sync_file = open(output_dir / "watch_sync.csv", "w", newline ="")
    validation_file = open(output_dir / "stream_validation.csv", "w", newline ="")

    FLUSH_EVERY_ROWS = 100
    FLUSH_EVERY_SECONDS = 0.5

    batched_files = {
        "imu": imu_file,
        "watch_imu": watch_imu_file,
        "watch_attitude": watch_attitude_file,
        "video_metadata": video_metadata_file,
    }

    pending_flush_rows = {name: 0 for name in batched_files}
    last_flush_time = {name: monotonic() for name in batched_files}

    video_writer = None
    frame_count = 0

    """
    pass opealt_host= "192.168.178.2" when hosting over fritz box network
    otherwise omitt host/alt_host argument
    """
    server = ArvosServer(port=9090)
    #server = ArvosServer(alt_host= "192.168.178.2", port=9090)
    
    # create csv writers
    imu_writer = csv.writer(imu_file, delimiter=";")
    imu_writer.writerow([
        "trial_id", "sequence_id","timestamp_ns", "timestamp_s",
        "ang_vel_x", "ang_vel_y", "ang_vel_z",
        "lin_acc_x", "lin_acc_y", "lin_acc_z",
        "gravity_x", "gravity_y", "gravity_z",
    ])

    watch_imu_writer = csv.writer(watch_imu_file, delimiter=";")
    watch_imu_writer.writerow([
        "trial_id", "sequence_id", "timestamp_ns", "timestamp_s",
        "watch_timestamp_ns", "phone_received_timestamp_ns",
        "ang_vel_x", "ang_vel_y", "ang_vel_z",
        "lin_acc_x", "lin_acc_y", "lin_acc_z",
    ])

    watch_attitude_writer = csv.writer(watch_attitude_file, delimiter=";")
    watch_attitude_writer.writerow([
        "trial_id", "sequence_id", "timestamp_ns", "timestamp_s",
        "watch_timestamp_ns", "phone_received_timestamp_ns",
        "quaternion_x", "quaternion_y", "quaternion_z", "quaternion_w",
        "roll", "pitch", "yaw",
        "referenceFrame"
    ])

    video_metadata_writer = csv.writer(video_metadata_file, delimiter=";")
    video_metadata_writer.writerow([
        "timestamp_Ns",
        "timestamp_s",
        "frame_count"
    ])

    sync_writer = csv.writer(sync_file, delimiter= ";")
    sync_writer.writerow([
        "trial_id",
        "phase",
        "offset_ns",
        "phone_anchor_ns",
        "watch_anchor_ns",
        "min_rtt_ns",
        "median_selected_rtt_ns",
        "offset_spread_ns",
        "valid_sample_count",
        "selected_sample_count",
        "boundary_phone_ns",
    ])

    validation_writer = csv.writer(validation_file, delimiter=";")
    validation_writer.writerow([
        "trial_id",
        "stream",
        "pre_boundary_ns",
        "post_boundary_ns",
        "stored_rows",
        "first_squence_id",
        "last_squence_id",
        "missing_internal_sequences",
        "duplicate_sequences",
        "non_monotonic_sequences",
        "median_dt_ns",
        "max_dt_ns",
        "min_dt_ns",
        "max_gap_multiple",
    ])

    final_writers = {
        "imu": imu_writer,
        "watch_imu": watch_imu_writer,
        "watch_attitude": watch_attitude_writer,
    }

    # create stop_event to cancle listening and program
    stop_event = asyncio.Event()

    # state booleans
    state = RecordingState()

    pre_sync_event = asyncio.Event()
    post_sync_event = asyncio.Event()
    watch_drain_event = asyncio.Event()

    pre_sync_result = None
    post_sync_result = None
    watch_drain_result = None

    trial_spools = {}
    active_pre_boundary_ns = None
    last_sensor_arrival = monotonic()

    trial_id = 0
    active_trial_id = None

    def open_trial_spools(current_trial_id: int) -> None:
        trial_spools.clear()

        for stream_name in final_writers:
            path = pending_dir / f"trial_{current_trial_id}_{stream_name}.csv"
            file = open(path, "w", newline="")
            writer = csv.writer(file, delimiter=";")
            trial_spools[stream_name] = (path, file, writer)

    def stage_row(stream_name: str, timestamp_ns: int, row: list) -> None:
        if active_trial_id is None or active_pre_boundary_ns is None:
            return

        # reject delayed packets from before trial
        if timestamp_ns < active_pre_boundary_ns:
            return

        _, _, writer = trial_spools[stream_name]
        writer.writerow([active_trial_id, *row])

    async def wait_for_sensor_drain(quiet_seconds: float = 0.25, maximum_wait_seconds: float = 2.0) -> None:
        deadline = monotonic() + maximum_wait_seconds

        while monotonic() < deadline:
            if monotonic() - last_sensor_arrival >= quiet_seconds:
                return
            await asyncio.sleep(0.05)

    def write_stream_validation(
            stream_name: str,
            pre_boundary_ns: int,
            post_boundary_ns: int,
            rows: list [list[str]]
    ) -> None:
        sequence_and_time = [
            (int(row[1]), int(row[2]))
            for row in rows
        ]

        if not sequence_and_time:
            validation_writer.writerow([
                active_trial_id, stream_name, pre_boundary_ns, post_boundary_ns, 0, "", "", 0, 0, 0, "", "", "",
            ])
            validation_writer.flush()
            return

        sequence_and_time.sort()
        sequence_ids = [item[0] for item in sequence_and_time]
        timestamps = [item[1] for item in sequence_and_time]

        unique_ids = sorted(set(sequence_ids))
        missing_internal = sum(
            right - left - 1
            for left, right, in zip(unique_ids, unique_ids[1:])
        )

        duplicates = len(sequence_ids) - len(unique_ids)

        timestamp_deltas = [
            right - left
            for left, right in zip(timestamps, timestamps[1:])
            if right > left
        ]

        non_monotonic = sum(
            right <= left
            for left, right in zip(timestamps, timestamps[1:])
        )

        median_dt = median(timestamp_deltas) if timestamp_deltas else 0
        min_dt = min(timestamp_deltas, default=0)
        max_dt = max(timestamp_deltas, default=0)
        max_gap_multiple = max_dt / median_dt if median_dt else 0

        validation_writer.writerow([
            active_trial_id,
            stream_name,
            pre_boundary_ns,
            post_boundary_ns,
            len(rows),
            unique_ids[0],
            unique_ids[-1],
            missing_internal,
            duplicates,
            non_monotonic,
            int(median_dt),
            int(max_dt),
            int(min_dt),
            f"{max_gap_multiple:.3f}",
        ])

        validation_file.flush()

    def finalize_trial(post_boundary_ns: int) -> None:
        nonlocal active_trial_id, active_pre_boundary_ns

        if active_pre_boundary_ns is None:
            return

        for stream_name, (path, file, _) in trial_spools.items():
            file.flush()
            file.close()

            accepted_rows = []
            with open(path, newline="") as staged_file:
                reader = csv.reader(staged_file, delimiter=";")

                for row in reader:
                    timestamp_ns = int(row[2])

                    if active_pre_boundary_ns <= timestamp_ns <= post_boundary_ns:
                        final_writers[stream_name].writerow(row)
                        flush_helper(stream_name)
                        accepted_rows.append(row)

            write_stream_validation(
                stream_name,
                active_pre_boundary_ns,
                post_boundary_ns,
                accepted_rows,
            )

            path.unlink(missing_ok=True)

        trial_spools.clear()
        active_trial_id = None
        active_pre_boundary_ns = None


    # terminal feedback functions
    async def quit_program(_: PromptInput):
        print("\n 🚫 Stopping program ")
        stop_event.set()
    
    async def start_stop_recording(_: PromptInput):
        nonlocal \
            trial_id, \
            pre_sync_result, \
            post_sync_result, \
            watch_drain_result, \
            active_trial_id, \
            active_pre_boundary_ns

        # Start
        if not state.recording:
            trial_id += 1

            pre_sync_result = None
            post_sync_result = None

            pre_sync_event.clear()
            post_sync_event.clear()

            print(f"\n Preparing trial {trial_id}")

            await server.send_command("prepare_trial_sync")

            try:
                await asyncio.wait_for(
                    pre_sync_event.wait(),
                    timeout=30.0
                )

            except asyncio.TimeoutError:
                print("Pre-sync timed out")
                return

            if pre_sync_result is None:
                print("Pre-sync failed")
                return


            active_trial_id = trial_id
            active_pre_boundary_ns = int(pre_sync_result["boundaryPhoneNs"])
            open_trial_spools(trial_id)

            state.recording = True
            await server.send_command("start_streaming")

            print("\n🔴 Started recording")
            return

        #STOP

        print("\n⬜ Stopping recording" )

        state.recording = False

        post_sync_result = None
        post_sync_event.clear()

        watch_drain_result = None
        watch_drain_event.clear()

        await server.send_command("post_trial_sync")
        await server.send_command("stop_streaming")

        try:
            await asyncio.wait_for(
                post_sync_event.wait(),
                timeout=30.0
            )

        except asyncio.TimeoutError:
            print("Post-sync timed out")
            return

        if post_sync_result is None:
            print("Post-sync failed")
            return

        try:
            await asyncio.wait_for(
                watch_drain_event.wait(),
                timeout=60.0,
            )
        except asyncio.TimeoutError:
            print("Watch drain timed out; trial files were not finalised")
            return

        if watch_drain_result is None:
            print("Watch drain failed; trial files were not finalised")
            return

        await wait_for_sensor_drain(
            quiet_seconds= 0.5,
            maximum_wait_seconds= 5.0
        )

        post_boundary_ns = int(post_sync_result["boundaryPhoneNs"])
        finalize_trial(post_boundary_ns)

        print("\n✅ Trial complete")



    # mark data
    async def mark_hold_change(_: PromptInput):
        print("marked")

    # connection messages
    def connection_message(is_connected: bool) -> str:
        if is_connected:
            return "✅ Phone connected"
        return "❌ Phone not connected"

    def recording_message(is_recording: bool) -> str:
        if is_recording:
            return "🔴 Recording active"
        return "⏸️ Recording paused"

    def enabled_message(is_enabled: bool) -> str:
        if is_enabled:
            return "enabled"
        return "disabled"

    def receiving_message(is_receiving_now: bool) -> str:
        if is_receiving_now:
            return "✅ receiving"
        return "⚠️ no recent data"

    async def set_participant_id(prompt_input: PromptInput) -> None:
        participant_id = await prompt_input("\nParticipant ID:")
        state.participant_id = participant_id.strip()
        print(f"✅ Participant ID set to: {state.participant_id}")

    async def set_boulder_id(prompt_input: PromptInput) -> None:
        boulder_id = await prompt_input("\nBoulder ID:")
        state.boulder_id = boulder_id.strip()
        print(f"✅ Boulder ID set to: {state.boulder_id}")

    def flush_helper(name:str, force: bool =False) -> None:
        now = monotonic()

        if force:
            batched_files[name].flush()
            pending_flush_rows[name] = 0
            last_flush_time[name] = now
            return

        pending_flush_rows[name] += 1

        if(
            pending_flush_rows[name] >= FLUSH_EVERY_ROWS
            or now - last_flush_time[name] >= FLUSH_EVERY_SECONDS
        ):
            batched_files[name].flush()
            pending_flush_rows[name] = 0
            last_flush_time[name] = now



    # print status to terminal
    async def status(_: PromptInput):
        def format_age(last_received) -> str:
            if last_received is None:
                return "never"

            age = (datetime.now() - last_received).total_seconds()
            return f"{age:2f}s ago"

        def stream_status(enabled:bool, receiving: bool, last_received, count: int) -> str:
            last = format_age(last_received)

            if not enabled:
                return f"🚫 disabled | count = {count}"

            if receiving:
                return f"✅ receiving | count = {count}"

            if last == "never":
                return f"⏳ enabled, waiting for packets | count = {count}"

            return f"⚠️ enabled, no recent data | last at = {last} | count = {count}"



        print("\n📊 Status")
        print(f"    {connection_message(state.imu_phone_connected)}")
        print(f"    {connection_message(state.watch_connected)}")
        print(f"    {recording_message(state.recording)}")

        print("\n Streams")
        print(f"    Video:      {stream_status(state.enabled_video, state.is_receiving('video'), state.last_video_received, state.video_frame_count)}")
        print(f"    Phone IMU:  {stream_status(state.enabled_phone_imu, state.is_receiving('phone_imu'), state.last_phone_imu_received, state.phone_imu_count)}")
        print(f"    Watch Attitude: {stream_status(state.enabled_watch_attitude, state.is_receiving('watch_attitude'), state.last_watch_attitude_received, state.watch_attitude_count)}")
        print(f"    Watch IMU:  {stream_status(state.enabled_watch_imu, state.is_receiving('watch_imu'), state.last_watch_imu_received, state.watch_imu_count)}")

        print("\n Trial metadata:")
        print(f"    Participant ID: {state.participant_id or 'not_set'}")
        print(f"    Boulder ID:     {state.boulder_id or 'not_set'}")


    # keyboard inputs
    key_handlers = {
        "q": quit_program,
        "r": start_stop_recording,
        "m": mark_hold_change,
        "s": status,
        "p": set_participant_id,
        "b": set_boulder_id,
    }

    # Handle IMU data
    async def on_imu(data: IMUData):
        nonlocal last_sensor_arrival

        state.mark_received("phone_imu")
        last_sensor_arrival = monotonic()

        stage_row("imu", data.timestamp_ns, [
            data.sequence_id,
            data.timestamp_ns,
            data.timestamp_s,
            *data.angular_velocity,
            *data.linear_acceleration,
            *(data.gravity if data.gravity else (0, 0, 0)),
        ])

    async def on_watch_imu(data: WatchIMUData):
        nonlocal last_sensor_arrival

        state.mark_received("watch_imu")
        last_sensor_arrival = monotonic()
        stage_row("watch_imu", data.timestamp_ns, [
            data.sequence_id,
            data.timestamp_ns,
            data.timestamp_s,
            data.watch_timestamp_ns,
            data.phone_received_timestamp_ns,
            *data.angular_velocity,
            *data.linear_acceleration,
        ])

    async def on_watch_attitude(data: WatchAttitudeData):
        nonlocal last_sensor_arrival

        state.mark_received("watch_attitude")
        last_sensor_arrival = monotonic()

        stage_row("watch_attitude", data.timestamp_ns, [
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

    async def on_watch_activity(data: WatchMotionActivityData):
        print("received watch_activity")

    # Handle camera frames
    async def on_camera(frame: CameraFrame):
        nonlocal video_writer, frame_count
        state.mark_received("video")
        
        if not state.recording:
            return

        frame_count += 1
        
        video_metadata_writer.writerow([
            frame.timestamp_ns,
            frame.timestamp_s,
            frame_count
        ])
        flush_helper("video_metadata")

        # Decode JPEG
        image = Image.open(io.BytesIO(frame.data))
        img_array = np.array(image)

#        # Save every 10th frame as JPEG
#        if frame_count % 10 == 0:
#            image_path = output_dir / f"frame_{frame_count:06d}.jpg"
#            image.save(image_path)
#            print(f"📷 Saved frame {frame_count}: {image_path.name}")

        # Initialize video writer on first frame
        if video_writer is None:
            fourcc = cv2.VideoWriter_fourcc(*'mp4v')
            video_path = str(output_dir / "camera_video.mp4")
            fps = 10  # Approximate FPS
            video_writer = cv2.VideoWriter(
                video_path,
                fourcc,
                fps,
                (frame.width, frame.height)
            )
            print(f"🎥 Starting video recording: {video_path}")

        # Write frame to video (convert RGB to BGR for OpenCV)
        img_bgr = cv2.cvtColor(img_array, cv2.COLOR_RGB2BGR)
        video_writer.write(img_bgr)

        if frame_count % 30 == 0:
            print(f"🎬 Video frames written: {frame_count}")
            
    # Handle connection/disconnection
    async def on_connect(client_id: str):
        state.imu_phone_connected = True
        state.video_phone_connected = True
        print(f"✅ Client connected: {client_id}\n")
        
    async def on_disconnect(client_id: str):
        state.imu_phone_connected = False
        state.video_phone_connected = False

    async def on_error(error:str, details:str | None):
        print(f"\nPHONE ERROR: {error}")
        if details:
            print(details)

        if error == "pre_sync_failed":
            pre_sync_event.set()
        elif error == "post_sync_failed":
            post_sync_event.set()

    async def on_watch_sync_result(data:dict):

        nonlocal pre_sync_result, post_sync_result

        phase = data["phase"]

        if phase == "pre":
            pre_sync_result = data
            pre_sync_event.set()
        elif phase == "post":
            post_sync_result = data
            post_sync_event.set()
        else:
            print(f"Unknown watch sync phase: {phase!r}")
            return

        try:
            print(f"\nWatch {phase.upper()} sync complete")
            print(f"offset: {data['offsetNs']}")
            print(f"minimum RTT: {data['minRTTNs'] / 1e6:.2f} ms")
            print(f"offset spread: {data['offsetSpreadNs'] / 1e6:.2f} ms")

            sync_writer.writerow([
                trial_id,
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
            sync_file.flush()
        except Exception as exc:
            print("Failed to record watch_sync_result:", repr(exc))


    async def on_watch_stream_drained(data:dict):
        nonlocal watch_drain_result

        watch_drain_result = data
        print("Watch drain complete:", f"{data['capturedSampleCount']} motion samples captured")

        watch_drain_event.set()

    # setup handlers
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

    print("Registered watch sync callback:", server.on_watch_sync_result)

    print("🚀 Starting server...")

    server_task = asyncio.create_task(server.start())
    keyboard_task = asyncio.create_task(listen_for_keys(key_handlers, stop_event))

    try:
        await stop_event.wait()

    except KeyboardInterrupt:
        print("\n\n👋 Stopping...")

    finally:
        print("\n 💾 Saving files...")

        keyboard_task.cancel()
        server_task.cancel()

        await asyncio.gather(server_task, keyboard_task, return_exceptions=True)

        for name in batched_files:
            flush_helper(name, force=True)

        sync_file.flush()

        imu_file.close()
        watch_attitude_file.close()
        video_metadata_file.close()
        sync_file.close()
        sync_file.close()
        validation_file.close()

        if video_writer is not None:
            video_writer.release()

if __name__ == "__main__":
    asyncio.run(main())
