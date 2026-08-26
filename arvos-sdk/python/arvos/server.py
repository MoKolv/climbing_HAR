"""
Arvos WebSocket server for receiving connections from iPhone app
"""

import asyncio
import websockets
import json
import qrcode
from typing import Set, Optional, Callable
from datetime import datetime
import socket


class ArvosServer:
    """
    WebSocket server that accepts connections from Arvos iPhone app.

    Example:
        >>> server = ArvosServer(port=9090)
        >>> server.print_qr_code()  # Display QR code for iPhone to scan
        >>>
        >>> @server.on_connect
        ... async def handle_connect(client_id: str):
        ...     print(f"Client connected: {client_id}")
        >>>
        >>> await server.start()
    """

    def __init__(self, host: str = "0.0.0.0",alt_host: Optional[str] = None, port: int = 9090):
        self.host = host
        self.alt_host = alt_host
        self.port = port
        self.clients: Set[websockets.WebSocketServerProtocol] = set()
        self.latest_handshake: Optional[str] = None
        self.handshake_sender: Optional[websockets.WebSocketServerProtocol] = None

        # Callbacks - users can assign these
        self.on_connect: Optional[Callable[[str], None]] = None
        self.on_disconnect: Optional[Callable[[str], None]] = None
        self.on_message: Optional[Callable[[str, any], None]] = None

        # Message handlers (same as ArvosClient)
        self.on_handshake = None
        self.on_imu = None
        self.on_gps = None
        self.on_pose = None
        self.on_camera = None
        self.on_depth = None
        self.on_status = None
        self.on_error = None

        # Apple Watch handlers
        self.on_watch_imu = None
        self.on_watch_attitude = None
        self.on_watch_activity = None
        self.on_watch_sync_result = None

    def get_local_ip(self) -> str:
        """
        Returns Ip adress for clients to connect to the server
        
        Case 1: explicitly passed host ip to use routing via local sub network
        Case 2: no host ip passed, gets host ip via socket
        """

        if self.alt_host:
            return self.alt_host

        try:
            # Create a socket to determine local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except OSError as exc:
            raise RuntimeError(
                "Could not determine client-facing ip adress"
                "Pass explicit host ip"
            ) from exc

    def get_websocket_url(self) -> str:
        """Get WebSocket URL for connection"""
        ip = self.get_local_ip()
        return f"ws://{ip}:{self.port}"

    def print_qr_code(self):
        """Print QR code to terminal for iPhone to scan"""
        url = self.get_websocket_url()
        qr = qrcode.QRCode()
        qr.add_data(url)
        qr.make()

        print("\n" + "="*50)
        print("ARVOS SERVER - Scan this QR code with your iPhone:")
        print("="*50)
        qr.print_ascii()
        print("="*50)
        print(f"Or manually enter: {url}")
        print("="*50 + "\n")

    async def start(self):
        """Start the WebSocket server"""
        print(f"Starting Arvos server on {self.host}:{self.port}")
        self.print_qr_code()

        async with websockets.serve(self._handle_client, self.host, self.port):
            print(f"Server listening...")
            await asyncio.Future()  # Run forever

    async def _handle_client(
        self,
        websocket: websockets.WebSocketServerProtocol,
        path: Optional[str] = None,
    ):
        """Handle new client connection"""
        client_id = f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
        self.clients.add(websocket)

        print(f"[{datetime.now().strftime('%H:%M:%S')}] Client connected: {client_id}")

        if self.on_connect:
            await self.on_connect(client_id)

        # Send cached handshake so late joiners know device capabilities
        if self.latest_handshake and websocket is not self.handshake_sender:
            try:
                await websocket.send(self.latest_handshake)
            except websockets.exceptions.ConnectionClosed:
                pass

        try:
            async for message in websocket:
                if isinstance(message, str):
                    self._cache_handshake(message, websocket)

                if self.on_message:
                    await self.on_message(client_id, message)

                # Delegate to specific handlers
                await self._delegate_message(message)

                await self._broadcast(message, exclude=websocket)

        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            self.clients.remove(websocket)
            print(f"[{datetime.now().strftime('%H:%M:%S')}] Client disconnected: {client_id}")

            if self.on_disconnect:
                await self.on_disconnect(client_id)

            if websocket is self.handshake_sender:
                self.handshake_sender = None
                self.latest_handshake = None

    async def _delegate_message(self, message):

        """Handle time_sync message"""
        if isinstance(message, str):
            try:
                data = json.loads(message)
            except json.JSONDecodeError:
                data = None

            if isinstance(data, dict):
                message_type = (
                    data.get("type")
                    or data.get("sensorType")
                )

                if message_type == "watch_sync_result":

                    print("SERVER RECEIVED watch_sync_result", data)

                    if self.on_watch_sync_result is None:
                        print("ERROR: on_watch_sync_result not registered")
                        return

                    try:
                        result = self.on_watch_sync_result(data)
                        if asyncio.iscoroutine(result):
                            await result
                    except Exception as exc:
                        print("watch_sync_result callback failed:", repr(exc))
                    else:
                        print("SERVER watch_sync_result callback completed")

                    return

        """Delegate message to appropriate handler"""
        # Import client handlers to reuse parsing logic
        from .client import ArvosClient

        # Create temporary client instance just for parsing
        temp_client = ArvosClient()

        # Copy handlers from server
        temp_client.on_handshake = self.on_handshake
        temp_client.on_imu = self.on_imu
        temp_client.on_gps = self.on_gps
        temp_client.on_pose = self.on_pose
        temp_client.on_camera = self.on_camera
        temp_client.on_depth = self.on_depth
        temp_client.on_status = self.on_status
        temp_client.on_error = self.on_error
        temp_client.on_watch_imu = self.on_watch_imu
        temp_client.on_watch_attitude = self.on_watch_attitude
        temp_client.on_watch_activity = self.on_watch_activity

        # Handle message using client's parsing logic
        await temp_client._handle_message(message)

    async def broadcast(self, message: str):
        """Broadcast message to all connected clients"""

        if not self.clients:
            print("broadcast: no connected clients")
            return

        clients = list(self.clients)

        print(f"Broadcasting to {len(clients)} clients")

        resuslts = await asyncio.gather(
            *[client.send(message) for client in clients],
            return_exceptions=True
        )

        for client, result in zip(clients, resuslts):
            if isinstance(result, Exception):
                print("Websocket send failed:", client.remote_address, repr(result))
            else:
                print("Websocket send succeeded:", client.remote_address)

    async def send_command(self, command: str, **parameters):
        """Send a command to connected Arvos clients"""

        message = {
            "type": "command",
            "command": command,
            **parameters,
        }

        if not self.clients:
            raise RuntimeError(
                "Cannot send command: "
                "no Arvos client connected"
            )

        print("SERVER SEND COMAND:", message)

        await self.broadcast(json.dumps(message))

        print("SERVER COMMAND SENT:", message)

    async def send_to_client(self, websocket: websockets.WebSocketServerProtocol, message: str):
        """Send message to specific client"""
        try:
            await websocket.send(message)
        except websockets.exceptions.ConnectionClosed:
            pass

    def get_client_count(self) -> int:
        """Get number of connected clients"""
        return len(self.clients)

    async def _broadcast(self, message, exclude: Optional[websockets.WebSocketServerProtocol] = None):
        """Broadcast message to all clients except the sender"""
        if not self.clients:
            return

        targets = [client for client in self.clients if client is not exclude]
        if not targets:
            return

        await asyncio.gather(
            *[client.send(message) for client in targets],
            return_exceptions=True
        )

    def _cache_handshake(self, message: str, websocket: websockets.WebSocketServerProtocol):
        try:
            data = json.loads(message)
        except json.JSONDecodeError:
            return

        msg_type = data.get("type") or data.get("sensorType")
        if msg_type == "handshake":
            self.latest_handshake = message
            self.handshake_sender = websocket
