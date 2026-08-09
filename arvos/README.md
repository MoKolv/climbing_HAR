# Arvos - Professional Sensor Streaming for iOS

**Stream iPhone sensors (LiDAR, Camera, IMU, GPS, ARKit) to your computer for AR/VR, robotics research, and computer vision development.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![iOS](https://img.shields.io/badge/iOS-16.0+-black.svg)](https://www.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![Python SDK](https://img.shields.io/badge/Python%20SDK-PyPI-blue.svg)](https://pypi.org/project/arvos-sdk/)

---

## 🚀 Quick Start

### 1. Download the App
- Clone this repository
- Open `arvos.xcodeproj` in Xcode
- Build and run on your iPhone 12 Pro or newer

### 2. Connect to Web Studio
Visit the web interface at:
**[https://arvos-studio.vercel.app/](https://arvos-studio.vercel.app/)**

The web studio provides:
- Real-time 3D point cloud visualization
- Live camera feed
- Sensor data monitoring (IMU, GPS, Pose)
- Recording controls
- Statistics and diagnostics

### 3. Start Streaming
1. Open Arvos app on iPhone
2. Tap **"START"** to begin the embedded WebSocket server
3. Your iPhone will display connection URLs (WiFi and hotspot)
4. In Web Studio, enter your iPhone's IP address
5. Click **"Connect"** and watch your sensor data stream in real-time!

---

## 📱 Supported Sensors

| Sensor | Rate | Description |
|--------|------|-------------|
| **Camera** | 5-30 FPS | 1920×1080 RGB, JPEG compressed |
| **LiDAR Depth** | 1-5 FPS | Point clouds with confidence maps |
| **IMU** | 50-200 Hz | Accelerometer, gyroscope, gravity |
| **ARKit Pose** | 30-60 Hz | 6DOF tracking with transforms |
| **GPS** | 1 Hz | Location and altitude (outdoor) |
| **Apple Watch** | 50-100 Hz | Wearable IMU and motion activity *(optional)* |

All sensors are **nanosecond-synchronized** for research-grade data collection.

---

## 🎯 Streaming Modes

Choose the best mode for your use case:

| Mode | Sensors Enabled | Use Case |
|------|----------------|----------|
| **Full Sensor** | All sensors | Maximum data collection |
| **RGBD** | Camera + Depth + Pose | 3D reconstruction, SLAM |
| **Visual-Inertial** | Camera + IMU + Pose | VIO algorithm development |
| **LiDAR** | Depth only | Point cloud mapping |
| **Camera** | RGB camera only | Computer vision |
| **Telemetry** | IMU + GPS only | Motion tracking |
| **Custom** | User-selected | Flexible configuration |

---

## 🌐 Web Studio Features

The web studio ([link here](https://arvos-studio.vercel.app/)) provides:

✅ **Real-time Visualization**
- 3D point cloud viewer with orbit controls
- Live camera feed display
- IMU and GPS data charts

✅ **Recording & Export**
- MCAP format recording
- H.264 video compression
- Synchronized sensor timestamps

✅ **Connection Modes**
- Direct WiFi connection (same network)
- iPhone hotspot support
- Cloud relay for internet streaming

✅ **Diagnostics**
- FPS monitoring
- Network statistics
- Sensor status indicators

---

## 🔧 Requirements

**iPhone:**
- iPhone 12 Pro or newer (LiDAR required)
- iOS 16.0 or later
- WiFi or Personal Hotspot enabled

**Computer:**
- Modern web browser (Chrome, Safari, Firefox, Edge)
- Same WiFi network as iPhone (or connect to iPhone's hotspot)

**Apple Watch (optional):**
- Apple Watch Series 6 or newer
- watchOS 9.0 or later
- Paired with iPhone

---

## ⌚ Apple Watch Companion

Stream wearable sensor data in sync with iPhone sensors:

**Features:**
- 50-100 Hz IMU (accelerometer, gyroscope, gravity)
- Attitude tracking (quaternion, pitch, roll, yaw)
- Motion activity classification (walking, running, cycling, vehicle, stationary)
- Live UI showing sample count and frequency

**Setup:**
1. Build and run the iOS app with watch target
2. Watch app installs automatically on paired watch
3. Toggle "Apple Watch" in Sensor Test to verify connection
4. Watch data streams through WebSocket alongside iPhone sensors

---

## 🏗️ Architecture

Arvos uses a **Foxglove-style server architecture**:

```
┌─────────────┐         ┌──────────────┐         ┌─────────────┐
│   iPhone    │ ◄─────► │  WebSocket   │ ◄─────► │ Web Studio  │
│  (Server)   │   WiFi  │  Server      │  WiFi   │  (Client)   │
│             │         │  Port 8765   │         │             │
└─────────────┘         └──────────────┘         └─────────────┘
      │
      │ Watch Connectivity
      ▼
┌─────────────┐
│ Apple Watch │
│  (Companion)│
└─────────────┘
```

**Key Components:**

- **NetworkManager.swift**: Coordinates streaming and server/client modes
- **SensorManager.swift**: Manages all sensor services and modes
- **WebSocketServer.swift**: Embedded server running on iPhone
- **ARKitService.swift**: LiDAR depth and pose tracking
- **CameraService.swift**: RGB camera capture
- **IMUService.swift**: Motion sensor data
- **GPSService.swift**: Location tracking
- **WatchSensorManager.swift**: Apple Watch integration
- **RecordingManager.swift**: MCAP file recording

---

## 📊 Data Format

All sensor data uses **nanosecond timestamps** and standard coordinate systems:

**IMU Data:**
```json
{
  "type": "imu",
  "timestamp_ns": 1234567890123456789,
  "angular_velocity": {"x": 0.1, "y": 0.2, "z": 0.3},
  "linear_acceleration": {"x": 0.5, "y": 9.8, "z": 0.1},
  "gravity": {"x": 0.0, "y": 9.81, "z": 0.0}
}
```

**Depth Data:**
- PLY point cloud format
- Binary WebSocket messages
- Confidence map included

**Camera Data:**
- JPEG compressed images
- Binary WebSocket messages
- Intrinsic calibration metadata

---

## 🐍 Python SDK

Process and visualize Arvos data streams with the official Python SDK:

**Installation:**
```bash
pip install arvos-sdk
```

**Features:**
- Connect to Arvos WebSocket streams
- Real-time data processing
- Rerun visualization integration
- MCAP file recording and playback
- Easy-to-use Python API

**Quick Example:**
```python
from arvos_sdk import ArvosClient

client = ArvosClient("192.168.1.100:8765")
client.connect()

# Process sensor data
for data in client.stream():
    if data["type"] == "imu":
        print(f"IMU: {data}")
```

**Documentation:** [https://pypi.org/project/arvos-sdk/](https://pypi.org/project/arvos-sdk/)

---

## 🛠️ Building from Source

1. **Clone the repository:**
```bash
git clone https://github.com/jaskirat1616/arvos.git
cd arvos
```

2. **Open in Xcode:**
```bash
open arvos.xcodeproj
```

3. **Select your iPhone as target**

4. **Build and Run** (⌘R)

---

## 🎓 Use Cases

**For Researchers:**
- SLAM algorithm development with ARKit ground truth
- Sensor fusion experiments
- ML dataset collection
- Real-time 3D reconstruction

**For Robotics Engineers:**
- Mobile sensor platform testing
- Algorithm prototyping with real sensor data
- Live demos and presentations
- Multi-sensor calibration

**For Developers:**
- AR/VR application development
- Computer vision experiments
- iOS sensor API learning
- Real-time data streaming projects

**For Students:**
- Computer vision coursework
- Robotics projects
- Sensor data analysis
- AR research projects

---

## 🐛 Troubleshooting

**Connection Issues:**
- Ensure iPhone and computer are on the same WiFi network
- Check firewall settings (allow port 8765)
- Try using iPhone's Personal Hotspot instead

**Performance Issues:**
- Reduce sensor rates in Custom mode
- Lower camera resolution if needed
- Close background apps on iPhone

**ARFrame Retention Warnings:**
- Normal during startup (should clear within 10 seconds)
- Persistent warnings indicate memory pressure - try lower FPS

**Web Studio Not Loading Data:**
- Check browser console for WebSocket errors
- Verify IP address is correct
- Try restarting both app and web studio

---

## 📜 License

This project is licensed under the **GNU General Public License v3.0**.

See [LICENSE](LICENSE) for full details.

**Key Points:**
- ✅ Free to use, modify, and distribute
- ✅ Must share source code modifications
- ✅ Must use GPL for derivative works
- ✅ Commercial use allowed
- ⚠️ No warranty provided

---

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

**Areas where help is needed:**
- Additional sensor support (magnetometer, barometer)
- New streaming protocols (ROS 2 native, RTSP)
- Performance optimizations
- Bug fixes and testing
- Documentation improvements

---

## 🙏 Acknowledgments

Built for the robotics, AR, and computer vision research community.

**Technologies used:**
- ARKit for depth and pose tracking
- AVFoundation for camera capture
- CoreMotion for IMU data
- Network framework for WebSocket server
- Watch Connectivity for wearable integration

---

## 📧 Contact

**Issues:** [GitHub Issues](https://github.com/jaskirat1616/arvos/issues)

**Web Studio:** [https://arvos-studio.vercel.app/](https://arvos-studio.vercel.app/)

---

**Made with ❤️ for researchers and developers**
