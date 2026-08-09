"""
I/O class for handling terminal input and experiment control for arvos_data_collector
"""

import asyncio
import sys
import termios
import tty
from collections.abc import Awaitable, Callable

PromptInput = Callable[[str], Awaitable[str]]
KeyHandler = Callable[[PromptInput], Awaitable[None] | None]

async def listen_for_keys(key_handlers: dict[str, KeyHandler], stop_event: asyncio.Event) -> None:
    """
    Listen for single key commands in terminal
    :param keys_handler: handles keyboard input, expects PromptInput as input
    :param stop_event: global event to stop listening/ cancel program
    :return: None
    """
    # output keyboard controls
    print("Keyboard controls:")
    for key, val in key_handlers.items():
        print(f"{key}: {val.__name__}")

    # read input
    def read_key_blocking() -> str:
        fd = sys.stdin.fileno()
        return sys.stdin.read(1)

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)

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
            key = await asyncio.to_thread(read_key_blocking)
            key = key.lower()

            handler = key_handlers.get(key)
            if handler is None:
                continue

            result = handler(prompt_input)
            if asyncio.iscoroutine(result):
                await result

    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

