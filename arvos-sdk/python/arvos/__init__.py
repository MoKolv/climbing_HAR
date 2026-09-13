"""
Arvos SDK - Python client library for receiving iPhone sensor data
"""

from .client import ArvosClient
from .data_types import (
    IMUData, GPSData, PoseData, CameraFrame, DepthFrame, AttitudeData,
    HandshakeMessage, DeviceCapabilities, WatchMotionActivityData
)
from .server import ArvosServer

# Protocol servers
try:
    from .servers import (
        BaseArvosServer,
        HTTPArvosServer,
        GRPCArvosServer,
        MQTTArvosServer,
        MCAPStreamServer,
        QUICArvosServer,
    )
    SERVERS_AVAILABLE = True
except ImportError:
    SERVERS_AVAILABLE = False
    BaseArvosServer = None
    HTTPArvosServer = None
    GRPCArvosServer = None
    MQTTArvosServer = None
    MCAPStreamServer = None
    QUICArvosServer = None

__version__ = "1.0.0"
__all__ = [
    "ArvosClient",
    "ArvosServer",
    "IMUData",
    "AttitudeData",
    "GPSData",
    "PoseData",
    "CameraFrame",
    "DepthFrame",
    "HandshakeMessage",
    "DeviceCapabilities",
    "WatchMotionActivityData",
]

if SERVERS_AVAILABLE:
    __all__.extend([
        "BaseArvosServer",
        "HTTPArvosServer",
        "GRPCArvosServer",
        "MQTTArvosServer",
        "MCAPStreamServer",
        "QUICArvosServer",
    ])
