from __future__ import annotations

import asyncio
import hashlib
import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

from aiohttp import web

ALLOWED_FILES = {"camera_video.mp4", "video_timestamps.csv"}

@dataclass
class AuthorizedUpload:
    trial_directory: Path
    received: set[str] = field(default_factory=set)
    event: asyncio.Event = field(default_factory=asyncio.Event)

class TrialUploadServer:
    def __init__(self, host: str= "0.0.0.0", port: int= 9091) -> None:
        self.host = host
        self.port = port
        self._uploads: dict[str, AuthorizedUpload] = {}
        self._runner: web.AppRunner | None = None

    async def start(self) -> None:
        app = web.Application(client_max_size = 4 * 1024 ** 3)
        app.router.add_put("/upload/{token}/{filename}", self._receive_file)

        self._runner = web.AppRunner(app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, self.host, self.port)
        await site.start()
        print(f"Trial upload server listening on {self.host}:{self.port}")

    async def stop(self) -> None:
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None

    def authorize(self, trial_directory: Path) -> str:
        token = secrets.token_urlsafe(32)
        self._uploads[token] = AuthorizedUpload(Path(trial_directory))
        return token

    def revoke(self, token: str) -> None:
        self._uploads.pop(token, None)

    async def wait_for_trial_files(
            self,
            token: str,
            timeout: float = 300.0
    ) -> None:
        upload = self._uploads[token]
        if ALLOWED_FILES <= upload.received:
            return
        await asyncio.wait_for(upload.event.wait(), timeout = timeout)

    async def _receive_file(self, request: web.Request) -> web.Response:
        token = request.match_info["token"]
        filename = request.match_info["filename"]
        upload = self._uploads.get(token)

        if upload is None:
            raise web.HTTPForbidden(text="Unknown or expired upload token")
        if filename not in ALLOWED_FILES:
            raise web.HTTPForbidden(text="Unexpected trial filename")

        destination = upload.trial_directory / filename
        temporary = destination.with_suffix(destination.suffix + ".part")
        digest = hashlib.sha256()
        size = 0

        try:
            with temporary.open("wb") as output:
                async for chunk in request.content.iter_chunked(1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
        except Exception as error:
            temporary.unlink(missing_ok=True)
            raise web.HTTPInternalServerError(text = f"Failed to store uploaded file: {error}") from error

        upload.received.add(filename)
        if ALLOWED_FILES <= upload.received:
            upload.event.set()

        return web.json_response(
            {
                "filename": filename,
                "sizeBytes": size,
                "sha256": digest.hexdigest(),
            }
        )