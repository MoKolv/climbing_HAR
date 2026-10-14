"""
I/O class for handling terminal input and experiment control for arvos_data_collector
"""

import asyncio
import sys
import termios
import tty
from collections.abc import Awaitable, Callable
from time import monotonic_ns

PromptInput = Callable[[str], Awaitable[str]]
KeyHandler = Callable[[PromptInput], Awaitable[None] | None]
TimedKeyHandler = Callable[[int], Awaitable[None] | None]

async def listen_for_keys(key_handlers: dict[str, KeyHandler], stop_event: asyncio.Event, timed_key_handlers: dict[str, TimedKeyHandler] | None = None) -> None:
    """
    Listen for single key commands in terminal
    :param timed_key_handlers: handles keyboard input for extremity labels, recorded with a capture timestamp
    :param key_handlers: handles keyboard input, expects PromptInput as input
    :param stop_event: global event to stop listening/ cancel program
    :return: None
    """
    # output keyboard controls
    print("Keyboard controls:")
    for key, val in key_handlers.items():
        print(f"{key}: {val.__name__}")

    for key in timed_key_handlers or {}:
        print(f"{key}: extremity marker")

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)

    # read input
    def read_key_blocking() -> tuple[str, int]:
        return sys.stdin.read(1), monotonic_ns()

    async def prompt_input(prompt: str) -> str:
        """
        temporarily return to normal terminal mode so editing user input for metadata is possible
        """
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

        try:
            value = await asyncio.to_thread(input, prompt)
            return value.strip()
        finally:
            tty.setcbreak(fd)

    try:
        tty.setcbreak(fd)

        while not stop_event.is_set():
            key, pressed_ns = await asyncio.to_thread(read_key_blocking)
            key = key.lower()
            marker_handler = (timed_key_handlers or {}).get(key)

            if marker_handler is not None:
                result = marker_handler(pressed_ns)

                if asyncio.iscoroutine(result):
                    await result

                continue

            handler = key_handlers.get(key)

            if handler is None:
                continue

            result = handler(prompt_input)

            if asyncio.iscoroutine(result):
                await result

    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)



