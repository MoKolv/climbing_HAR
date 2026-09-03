"""
Arvos WebSocket server for receiving connections from iPhone app
"""

import asyncio
import websockets
import json
import qrcode
from typing import Set, Optional, Callable, Awaitable
from datetime import datetime
import socket
import inspect



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
    VALID_CLIENT_ROLES = {"imu_watch", "video"}

    def __init__(self, host: str = "0.0.0.0",alt_host: Optional[str] = None, port: int = 9090):
        self.host = host
        self.alt_host = alt_host
        self.port = port
        self.clients: Set[websockets.WebSocketServerProtocol] = set()

        self.role_by_socket: dict[websockets.WebSocketServerProtocol, str] = {}
        self.socket_by_role: dict [str, websockets.WebSocketServerProtocol] = {}
        self.client_info_by_role: dict[str, dict[str, Any]] = {}

        self.on_client_role: Optional[Callable[[str, str, dict[str, Any]], Awaitable[None] | None]] = None
        self.on_client_role_disconnect: Optional[
            Callable[[str, str], Awaitable[None]]
        ] = None

        # Callbacks - users can assign these
        self.on_connect: Optional[Callable[[str], Awaitable[None]]] = None
        self.on_disconnect: Optional[Callable[[str], Awaitable[None]]] = None
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
        self.on_watch_stream_drained = None

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

    async def _invoke_callback(self, callback, *args) -> None:
        if callback is None:
            return

        result = callback(*args)
        if inspect.isawaitable(result):
            await result

    def has_role(self, role: str) -> bool:
        return role in self.socket_by_role

    def missing_roles(self, roles: set[str]) -> set[str]:
        return roles - set(self.socket_by_role)

    def role_info(self, role: str) -> dict[str, Any] | None:
        return self.client_info_by_role.get(role)

    async def _register_client_role(
            self,
            client_id: str,
            websocket: websockets.WebSocketServerProtocol,
            message: str
    ) -> bool:
        try:
            data = json.loads(message)
        except json.JSONDecodeError:
            return False

        if not isinstance(data, dict) or data.get("type") != "handshake":
            return False

        role = data.get("clientRole")
        installation_id = (data.get("installationId") or data.get("installationID"))

        if (
            role not in self.VALID_CLIENT_ROLES
            or not isinstance(installation_id, str)
            or not installation_id.strip()
        ):
            print(f"Ignoring invalid client handshake from {client_id}: {data}")
            return False

        previous_socket = self.socket_by_role.get(role)

        self.role_by_socket[websocket] = role
        self.socket_by_role[role] = websocket
        self.client_info_by_role[role] = {
            "client_id": client_id,
            "installation_id": installation_id,
            "device_name": data.get("deviceName", "Unknown"),
            "device_model": data.get("deviceModel", "Unknown"),
        }

        print(
            f"registered {role}: {data.get('deviceName', 'Unknown')}"
            f"({installation_id})"
        )

        await self._invoke_callback(self.on_client_role, client_id, role, data)

        if previous_socket is not None and previous_socket is not websocket:
            await previous_socket.close(
                code=4001,
                reason = "A newer client claimed this experiment role"
            )

        return True

    async def send_command_to_role(
            self,
            role: str,
            command: str,
            **parameters: Any,
    ) -> None:

        websocket = self.socket_by_role.get(role)
        if websocket is None:
            raise RuntimeError(
                f"Cannot send {command}: {role} client is not connected"
            )

        message = {
            "type": "command",
            "command": command,
            "targetRole": role,
            **parameters,
        }

        try:
            await websocket.send(json.dumps(message))
        except websockets.exceptions.ConnectionClosed as error:
            if self.socket_by_role.get(role) is websocket:
                self.socket_by_role.pop(role, None)

            raise RuntimeError(
                f"Cannot send {command}: {role} client is not connected"
            ) from error

        print(f"Sent {command}: to {role}: {message}")

    async def _handle_client(
        self,
        websocket: websockets.WebSocketServerProtocol,
        path: Optional[str] = None,
    ):
        """ Register client's role before accepting sensor messages."""
        del path

        remote_address = websocket.remote_address

        client_id = (
            f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
            if remote_address
            else "unknown"
        )

        self.clients.add(websocket)

        print(f"[{datetime.now().strftime('%H:%M:%S')}] Client connected: {client_id}")

        await self._invoke_callback(self.on_connect, client_id)

        try:
            try:
                first_message = await asyncio.wait_for(
                    websocket.recv(),
                    timeout = 5,
                )
            except asyncio.TimeoutError:
                print(f"Role handshake timed out: {client_id}")
                await websocket.close(
                    code=4000,
                    reason = "Role handshake required"
                )
                return

            if not isinstance(first_message, str):
                print(f"Expected text role handshake from {client_id}")
                await websocket.close(
                    code=4000,
                    reason = "Text role handshake required"
                )
                return

            registered = await self._register_client_role(client_id, websocket, first_message)

            if not registered:
                print(f"Invalid role handshake from {client_id}")
                await websocket.close(
                    code=4000,
                    reason = "Invalid role handshake"
                )
                return

            await self._invoke_callback(self.on_message, client_id, first_message)

            await self._delegate_message(first_message)

            async for message in websocket:
                await self._invoke_callback(self.on_message, client_id, message)
                await self._delegate_message(message)
        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as error:
            pring(f"Client handler faild for: {client_id}: {error!r}")
        finally:
            self.clients.discard(websocket)

            role = self.role_by_socket.pop(websocket, None)

            # Don't remove a newer socket that replaced this role
            if role and self.socket_by_role.get(role) is websocket:
                self.socket_by_role.pop(role, None)
                self.client_info_by_role.pop(role, None)

                await self._invoke_callback(self.on_client_role_disconnect, client_id, role)

            print(f"[{datetime.now().strftime('%H:%M:%S')}] Client disconnected: {client_id}")
            await self._invoke_callback(self.on_disconnect, client_id)

    async def _delegate_message(self, message):

        """Handle time_sync message"""
        if isinstance(message, str):
            try:
                data = json.loads(message)
            except json.JSONDecodeError:
                data = None

            if isinstance(data, dict):
                message_type = data.get("type") or data.get("sensorType")

                match message_type:
                    case "watch_sync_result":
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

                    case "watch_stream_drained":
                        print("SERVER RECEIVED watch_stream_drained", data)

                        if self.on_watch_stream_drained is None:
                            print("ERROR: on_watch_stream_drained not registered")
                            return

                        try:
                            result = self.on_watch_stream_drained(data)
                            if asyncio.iscoroutine(result):
                                await result
                        except Exception as exc:
                            print("watch_stream_drained callback failed:", repr(exc))
                        else:
                            print("SERVER watch_stream_drained callback completed")

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

        msg_type = data.get("type") or data.get("sensorType")
        if msg_type == "handshake":
            self.latest_handshake = message
            self.handshake_sender = websocket
