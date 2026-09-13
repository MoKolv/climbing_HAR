"""
Tests for Arvos data types
"""

import pytest
import numpy as np
from arvos.data_types import IMUData, GPSData, PoseData, CameraFrame, DepthFrame, AttitudeData


def test_imu_data():
    """Test IMUData creation and properties"""
    attitude = AttitudeData(
        quaternion=(0.0, 0.0, 0.0, 1.0),
        roll=0.1,
        pitch=0.2,
        yaw=0.3,
        reference_frame="xArbitraryCorrectedZVertical",
    )
    data = IMUData(
        timestamp_ns=1_700_000_000,
        sequence_id=7,
        source="phone",
        source_timestamp_ns=1_700_000_000,
        angular_velocity=(0.1, 0.2, 0.3),
        linear_acceleration=(1.0, 2.0, 3.0),
        gravity=(0.0, 0.0, -1.0),
        magnetic_field=(10.0, 20.0, 30.0),
        attitude=attitude,
    )

    assert data.timestamp_s == 1.7
    assert data.source == "phone"
    assert data.sequence_id == 7
    assert tuple(data.attitude) == (0.1, 0.2, 0.3)
    assert isinstance(data.angular_velocity_array, np.ndarray)
    assert isinstance(data.linear_acceleration_array, np.ndarray)
    assert isinstance(data.attitude.quaternion_array, np.ndarray)


def test_gps_data():
    """Test GPSData creation and properties"""
    data = GPSData(
        timestamp_ns=1700000000000,
        latitude=37.7749,
        longitude=-122.4194,
        altitude=100.0,
        horizontal_accuracy=5.0,
        vertical_accuracy=10.0,
        speed=5.0,
        course=90.0
    )

    assert data.timestamp_s == 1.7
    assert data.coordinates == (37.7749, -122.4194)
    assert data.altitude == 100.0


def test_pose_data():
    """Test PoseData creation and properties"""
    data = PoseData(
        timestamp_ns=1700000000000,
        position=(1.0, 2.0, 3.0),
        orientation=(0.0, 0.0, 0.0, 1.0),
        tracking_state="normal"
    )

    assert data.timestamp_s == 1.7
    assert isinstance(data.position_array, np.ndarray)
    assert isinstance(data.orientation_array, np.ndarray)
    assert data.is_tracking_good() == True

    # Test bad tracking
    data2 = PoseData(
        timestamp_ns=1700000000000,
        position=(1.0, 2.0, 3.0),
        orientation=(0.0, 0.0, 0.0, 1.0),
        tracking_state="limited_initializing"
    )
    assert data2.is_tracking_good() == False


def test_camera_frame():
    """Test CameraFrame creation and properties"""
    frame = CameraFrame(
        timestamp_ns=1700000000000,
        width=1920,
        height=1080,
        format="jpeg",
        data=b"fake_jpeg_data",
        intrinsics=None
    )

    assert frame.timestamp_s == 1.7
    assert frame.width == 1920
    assert frame.height == 1080
    assert frame.size_kb == len(b"fake_jpeg_data") / 1024.0


def test_depth_frame():
    """Test DepthFrame creation and properties"""
    frame = DepthFrame(
        timestamp_ns=1700000000000,
        point_count=1000,
        min_depth=0.5,
        max_depth=5.0,
        format="point_cloud",
        data=b"fake_ply_data"
    )

    assert frame.timestamp_s == 1.7
    assert frame.point_count == 1000
    assert frame.min_depth == 0.5
    assert frame.max_depth == 5.0
    assert frame.size_kb == len(b"fake_ply_data") / 1024.0


if __name__ == "__main__":
    pytest.main([__file__])
