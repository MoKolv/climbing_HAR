"""
python script to record data from arvos iPhone app

records IMU Data in a csv with timestamps; a video and a csv with metadata for the video mainly timestamped frames in nanoseconds

"""
import asyncio
import csv

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

async def main():
    # create output directory
    output_dir = Path(f"../Data/arvos_data_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
    output_dir.mkdir(exist_ok=True)

    print (f"saving data to: {output_dir}")

    # create csv files
    imu_file = open(output_dir / "imu.csv", "w", newline="")
    watch_imu_file = open(output_dir / "watch_imu.csv", "w", newline="")
    watch_attitude_file = open(output_dir / "watch_attitude.csv", "w", newline="")
    video_metadata_file = open(output_dir / "video_metadata.csv", "w", newline ="")
    sync_file = open(output_dir / "watch_sync.csv", "w", newline ="")

    # video writer
    video_writer = None
    frame_count = 0

    """
    pass opealt_host= "192.168.178.2" when hosting over fritz box network
    otherwise omitt host/alt_host argument
    """
    server = ArvosServer(alt_host= "192.168.178.2", port=9090)
    
    # create csv writers
    imu_writer = csv.writer(imu_file, delimiter=";")
    imu_writer.writerow([
        "timestamp_ns", "timestamp_s",
        "ang_vel_x", "ang_vel_y", "ang_vel_z",
        "lin_acc_x", "lin_acc_y", "lin_acc_z",
        "gravity_x", "gravity_y", "gravity_z",
    ])

    watch_imu_writer = csv.writer(watch_imu_file, delimiter=";")
    watch_imu_writer.writerow([
        "timestamp_ns", "timestamp_s",
        "watch_timestamp_ns", "phone_received_timestamp_ns",
        "ang_vel_x", "ang_vel_y", "ang_vel_z",
        "lin_acc_x", "lin_acc_y", "lin_acc_z",
    ])

    watch_attitude_writer = csv.writer(watch_attitude_file, delimiter=";")
    watch_attitude_writer.writerow([
        "timestamp_ns", "timestamp_s",
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
    
    # create stop_event to cancle listening and program
    stop_event = asyncio.Event()

    # state booleans
    state = RecordingState()

    pre_sync_event = asyncio.Event()
    post_sync_event = asyncio.Event()

    pre_sync_result = None
    post_sync_result = None

    trial_id = 0

    # terminal feedback functions
    async def quit_program(_: PromptInput):
        print("\n 🚫 Stopping program ")
        stop_event.set()
    
    async def start_stop_recording(_: PromptInput):
        nonlocal \
            trial_id, \
            pre_sync_result, \
            post_sync_result

        # Start
        if not state.recording:
            trial_id += 1

            pre_sync_result = None
            post_sync_result = None

            pre_sync_event.clear()
            post_sync_event.clear()

            print(
                f"\n Preparing trial"
                f"{trial_id}"
            )

            await server.send_command("prepare_trial_sync")

            try:
                await asyncio.wait_for(
                    pre_sync_event.wait(),
                    timeout=15.0
                )
            except asyncio.TimeoutError:
                print("Pre-sync timed out")
                return

            state.recording = True

            print("\n🔴 Started recording")

            #STOP

            print("\n⬜ Stopping recording" )

            post_sync_event.clear()

            await server.send_command("post_trial_sync")

            try:
                await asyncio.wait_for(
                    post_sync_event.wait(),
                    timeout=15.0
                )

            except asyncio.TimeoutError:
                print("Post-sync timed out")
                return

            state.recording = False

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
        print(f"    {connection_message(state.video_phone_connected)}")
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
        state.mark_received("phone_imu")
        if not state.recording:
            return
        imu_writer.writerow([
            data.timestamp_ns, data.timestamp_s,
            *data.angular_velocity,
            *data.linear_acceleration,
            *(data.gravity if data.gravity else (0, 0, 0)),
        ])
        imu_file.flush()

    async def on_watch_imu(data: WatchIMUData):
        state.mark_received("watch_imu")
        if not state.recording:
            return

        watch_imu_writer.writerow([
            data.timestamp_ns, data.timestamp_s,
            data.watch_timestamp_ns, data.phone_received_timestamp_ns,
            *data.angular_velocity,
            *data.linear_acceleration,
        ])
        watch_imu_file.flush()


    async def on_watch_attitude(data: WatchAttitudeData):
        state.mark_received("watch_attitude")
        if not state.recording:
            return

        watch_attitude_writer.writerow([
            data.timestamp_ns, data.timestamp_s,
            data.watch_timestamp_ns, data.phone_received_timestamp_ns,
            *data.quaternion,
            data.roll,
            data.pitch,
            data.yaw,
            data.reference_frame
            #*(data.attitude if data.attitude else (0, 0, 0)),
        ])
        watch_attitude_file.flush()

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
        video_metadata_file.flush()

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

    async def on_watch_sync_result(data:dict):

        nonlocal \
            pre_sync_result, \
            post_sync_result

        phase = data["phase"]

        print(
            f"\n Watch {phase.upper()}"
            f"sync complete"
        )

        print(
            f"offset: "
            f"{data['offset_ns']}"
        )

        print(
            f"minimum RTT: "
            f"{data['min_rtt_ns'] / 1e6:.2f} ms"
        )

        print(
            f"offset spread: "
            f"{data['offset_spread_ns'] / 1e6:.2f} ms"
        )

        sync_writer.writerow([
            trial_id,

            phase,
            data["offset_ns"],
            data["phone_anchor_ns"],
            data["watch_anchor_ns"],

            data["min_rtt_ns"],
            data["median_selected_rtt_ns"],
            data["offset_spread_ns"],

            data["valid_sample_count"],
            data["selected_sample_count"],

            data["boundary_phone_ns"],
        ])

        sync_file.flush()

        if phase == "pre":
            pre_sync_result = data
            pre_sync_event.set()

        elif phase == "post":
            post_sync_result = data
            post_sync_event.set()


    # setup handlers
    server.on_imu = on_imu
    server.on_watch_imu = on_watch_imu
    server.on_watch_attitude = on_watch_attitude
    server.on_watch_activity = on_watch_activity
    server.on_camera = on_camera
    server.on_connect = on_connect
    server.on_disconnect = on_disconnect
    server.on_watch_sync_result = on_watch_sync_result

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

        imu_file.close()
        video_metadata_file.close()
        sync_file.close()

        if video_writer is not None:
            video_writer.release()

if __name__ == "__main__":
    asyncio.run(main())
