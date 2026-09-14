"""Telo's LiveKit agent: cautious, observable Android accessibility control."""
import asyncio
import json
import logging
import time
import uuid
from typing import Any

from dotenv import load_dotenv
from livekit import rtc
from livekit.agents import Agent, AgentServer, AgentSession, JobContext, RunContext, cli, function_tool
from livekit.plugins import google

load_dotenv(".env")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("telo-agent")
server = AgentServer()


class TeloAgent(Agent):
    """Maps small semantic tools to the Android JSON action protocol."""

    def __init__(self, room: rtc.Room):
        self.room = room
        self.screen_queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=12)
        self.result_queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=24)
        self.latest_screen: dict[str, Any] | None = None
        self._screen_received_at = 0.0

        @room.on("data_received")
        def on_data_received(data: rtc.DataPacket):
            try:
                payload = json.loads(data.data.decode("utf-8"))
                if data.topic == "telo.screen":
                    self.latest_screen = payload
                    self._screen_received_at = time.monotonic()
                    self._put_latest(self.screen_queue, payload)
                    logger.info("[TeloAgent] Screen: package=%s nodes=%s", payload.get("package"), payload.get("node_count"))
                    logger.info("[TeloPerf] screen_received=%.3f", self._screen_received_at)
                elif data.topic == "telo.action_result":
                    self._put_latest(self.result_queue, payload)
                    logger.info("[TeloAgent] Result: %s success=%s", payload.get("action"), payload.get("success"))
            except Exception as error:
                logger.warning("[TeloAgent] Invalid phone data packet: %s", error)

        super().__init__(instructions="""
You are Telo, a fast, careful real-time assistant controlling a real Android phone.
Execute Android tools promptly. For obvious commands (such as opening an app or going home), call the tool immediately instead of giving a long verbal explanation first. Keep spoken responses concise while actions are underway.

Workflow:
1. For opening apps: call open_app(package="com.google.android.youtube") for YouTube. Only describe an app as opened when open_app returns success=true and verified=true.
2. For interacting with UI: inspect the latest returned screen snapshot or call read_screen / find_element. Only use node IDs from that latest snapshot.
3. For multi-step tasks (e.g. YouTube search): observe -> act -> observe -> verify, with at most three recovery tries.
4. Never claim an action succeeded or say "Done" without Android confirmation.
5. On a stale-node error, observe the screen and select a current node.
""")

    @staticmethod
    def _put_latest(queue: asyncio.Queue, value: dict[str, Any]) -> None:
        if queue.full():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
        queue.put_nowait(value)

    async def _publish_status(self, state: str, message: str, action: str | None = None) -> None:
        """Send immediate, user-facing progress separately from Android results."""
        payload = {
            "type": "telo_status",
            "state": state,
            "message": message,
            "action": action,
            "timestamp": int(time.time() * 1000),
        }
        try:
            await self.room.local_participant.publish_data(
                json.dumps(payload).encode(), reliable=True, topic="telo.status"
            )
        except Exception as err:
            logger.warning("[TeloAgent] Failed to publish status: %s", err)

    @staticmethod
    def _status_for_action(action: str, **fields: Any) -> tuple[str, str]:
        if action == "open_app":
            pkg = fields.get("package", "")
            if "youtube" in pkg.lower():
                return ("opening_app", "Opening YouTube...")
            elif pkg:
                name = pkg.split(".")[-1].capitalize()
                return ("opening_app", f"Opening {name}...")
            return ("opening_app", "Opening the app...")
        elif action == "read_screen":
            return ("reading_screen", "Checking the screen...")
        elif action in {"click", "long_click"}:
            return ("tapping", "Opening it...")
        elif action in {"type_text", "clear_text"}:
            text = fields.get("text")
            if text:
                return ("typing", f'Typing "{text}"...')
            return ("typing", "Typing...")
        elif action in {"scroll", "swipe"}:
            return ("swiping", "Scrolling...")
        elif action == "back":
            return ("executing", "Going back...")
        elif action == "home":
            return ("executing", "Going home...")
        elif action == "press_key":
            return ("executing", f"Pressing {fields.get('key', 'key')}...")
        return ("executing", "Working on it...")

    async def _command(self, action: str, *, observe_after: bool = True, **fields: Any) -> dict[str, Any]:
        while not self.screen_queue.empty():
            try:
                self.screen_queue.get_nowait()
            except asyncio.QueueEmpty:
                break
        state, message = self._status_for_action(action, **fields)
        await self._publish_status(state, message, action)
        started = time.monotonic()
        logger.info("[TeloPerf] action=%s stage=tool_start", action)

        request_id = uuid.uuid4().hex
        command = {"type": "android_action", "action": action, "request_id": request_id, **fields}
        await self.room.local_participant.publish_data(json.dumps(command).encode(), reliable=True, topic="telo.android")
        logger.info("[TeloPerf] action=%s stage=android_send elapsed_ms=%.1f", action, (time.monotonic() - started) * 1000)
        logger.info("[TeloAgent] Tool: %s node=%s", action, fields.get("node_id", ""))

        try:
            result = await self._wait_for_result(request_id, timeout=7.0)
        except asyncio.TimeoutError:
            error = "Timed out waiting for Android action result"
            await self._publish_status("error", error, action)
            logger.warning("[TeloPerf] action=%s stage=timeout elapsed_ms=%.1f", action, (time.monotonic() - started) * 1000)
            return {"success": False, "action": action, "error": error, "refresh_required": True}

        logger.info("[TeloPerf] action=%s stage=android_result elapsed_ms=%.1f", action, (time.monotonic() - started) * 1000)
        if not result.get("success"):
            await self._publish_status("error", result.get("error", "Android could not complete that action."), action)
            return result

        # Special optimization for open_app: if verified by Android, avoid redundant blocking wait
        if action == "open_app":
            if result.get("verified") is True:
                logger.info("[TeloPerf] action=%s stage=verified elapsed_ms=%.1f", action, (time.monotonic() - started) * 1000)
                if self.latest_screen:
                    result["screen"] = self._compact_screen(self.latest_screen)
                await self._publish_status("success", "Done", action)
                logger.info("[TeloPerf] action=%s stage=tool_complete total_ms=%.1f", action, (time.monotonic() - started) * 1000)
                return result

        # Event-driven screen snapshot for actions needing UI observation
        needs_screen = observe_after and action not in {"read_screen"}
        if needs_screen:
            await self._publish_status("verifying", "Checking that it worked...", action)
            screen = await self._next_screen(timeout=2.0)
            if screen:
                result["screen"] = self._compact_screen(screen)
                logger.info("[TeloPerf] action=%s stage=screen_received elapsed_ms=%.1f", action, (time.monotonic() - started) * 1000)

        if action != "open_app" or result.get("verified") is True:
            await self._publish_status("success", "Done", action)
        logger.info("[TeloPerf] action=%s stage=tool_complete total_ms=%.1f", action, (time.monotonic() - started) * 1000)
        return result

    async def _wait_for_result(self, request_id: str, timeout: float) -> dict[str, Any]:
        held: list[dict[str, Any]] = []
        try:
            while True:
                candidate = await asyncio.wait_for(self.result_queue.get(), timeout=timeout)
                if candidate.get("request_id") == request_id:
                    return candidate
                held.append(candidate)
        finally:
            for candidate in held:
                self._put_latest(self.result_queue, candidate)

    async def _next_screen(self, timeout: float) -> dict[str, Any] | None:
        try:
            return await asyncio.wait_for(self.screen_queue.get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None

    @staticmethod
    def _compact_screen(screen: dict[str, Any]) -> dict[str, Any]:
        # Android already applies a node cap; keep tool payloads readable for Gemini.
        return {key: screen.get(key) for key in ("snapshot_id", "package", "reason", "truncated", "node_count", "nodes")}

    async def _node_action(self, action: str, node_id: str, **fields: Any) -> str:
        if not node_id.strip():
            return json.dumps({"success": False, "action": action, "error": "node_id is required"})
        snapshot_id = (self.latest_screen or {}).get("snapshot_id", "")
        result = await self._command(action, node_id=node_id, snapshot_id=snapshot_id, **fields)
        return json.dumps(result, ensure_ascii=False)

    @function_tool()
    async def open_app(self, context: RunContext, package: str) -> str:
        """Open an installed Android app by its package name."""
        return json.dumps(await self._command("open_app", package=package), ensure_ascii=False)

    @function_tool()
    async def read_screen(self, context: RunContext) -> str:
        """Request a fresh compact accessibility snapshot before choosing a node."""
        result = await self._command("read_screen", observe_after=False)
        screen = await self._next_screen(timeout=2.0) if result.get("success") else None
        if screen:
            result["screen"] = self._compact_screen(screen)
        return json.dumps(result, ensure_ascii=False)

    @function_tool()
    async def find_element(self, context: RunContext, query: str) -> str:
        """Find visible current-screen nodes by text, description, hint, or resource ID."""
        needle = query.strip()
        msg = f'Finding "{needle}"...' if needle else "Finding what you asked for..."
        await self._publish_status("finding_element", msg, "find_element")
        if not self.latest_screen:
            await self.read_screen(context)
        screen = self.latest_screen or {}
        needle_lower = needle.lower()
        matches = []
        for node in screen.get("nodes", []):
            haystack = " ".join(str(node.get(key, "")) for key in ("text", "content_description", "hint_text", "view_id")).lower()
            if needle_lower and needle_lower in haystack and node.get("visible", True):
                matches.append(node)
        if not matches:
            await self._publish_status("error", "I could not find that on the screen.", "find_element")
        return json.dumps({"success": True, "snapshot_id": screen.get("snapshot_id"), "matches": matches[:12]}, ensure_ascii=False)

    @function_tool()
    async def click(self, context: RunContext, node_id: str) -> str: return await self._node_action("click", node_id)
    @function_tool()
    async def long_click(self, context: RunContext, node_id: str) -> str: return await self._node_action("long_click", node_id)
    @function_tool()
    async def focus(self, context: RunContext, node_id: str) -> str: return await self._node_action("focus", node_id)
    @function_tool()
    async def type_text(self, context: RunContext, node_id: str, text: str) -> str: return await self._node_action("type_text", node_id, text=text)
    @function_tool()
    async def clear_text(self, context: RunContext, node_id: str) -> str: return await self._node_action("clear_text", node_id)
    @function_tool()
    async def scroll(self, context: RunContext, node_id: str, direction: str = "down") -> str: return await self._node_action("scroll", node_id, direction=direction)
    @function_tool()
    async def select(self, context: RunContext, node_id: str) -> str: return await self._node_action("select", node_id)
    @function_tool()
    async def expand(self, context: RunContext, node_id: str) -> str: return await self._node_action("expand", node_id)
    @function_tool()
    async def collapse(self, context: RunContext, node_id: str) -> str: return await self._node_action("collapse", node_id)
    @function_tool()
    async def dismiss(self, context: RunContext, node_id: str) -> str: return await self._node_action("dismiss", node_id)

    @function_tool()
    async def back(self, context: RunContext) -> str: return json.dumps(await self._command("back"), ensure_ascii=False)
    @function_tool()
    async def home(self, context: RunContext) -> str: return json.dumps(await self._command("home"), ensure_ascii=False)
    @function_tool()
    async def swipe(self, context: RunContext, from_x: int, from_y: int, to_x: int, to_y: int) -> str:
        """Fallback gesture only when no semantic accessibility action exists."""
        return json.dumps(await self._command("swipe", **{"from": [from_x, from_y], "to": [to_x, to_y]}), ensure_ascii=False)
    @function_tool()
    async def play(self, context: RunContext, node_id: str) -> str: return await self._node_action("play", node_id)
    @function_tool()
    async def pause(self, context: RunContext, node_id: str) -> str: return await self._node_action("pause", node_id)
    @function_tool()
    async def next(self, context: RunContext, node_id: str) -> str: return await self._node_action("next", node_id)
    @function_tool()
    async def previous(self, context: RunContext, node_id: str) -> str: return await self._node_action("previous", node_id)
    @function_tool()
    async def seek(self, context: RunContext, node_id: str, percent: float) -> str:
        """Seek a media/progress control to an approximate percentage when it exposes SET_PROGRESS."""
        return await self._node_action("seek", node_id, percent=percent)
    @function_tool()
    async def press_key(self, context: RunContext, key: str) -> str:
        """Safely press only Android's back or home global keys."""
        return json.dumps(await self._command("press_key", key=key), ensure_ascii=False)
    @function_tool()
    async def wait_for_ui(self, context: RunContext, milliseconds: int = 800) -> str:
        """Wait briefly for an Android UI transition, then return a fresh event snapshot if available."""
        await asyncio.sleep(max(100, min(milliseconds, 3000)) / 1000)
        screen = await self._next_screen(timeout=1.0)
        return json.dumps({"success": True, "screen": self._compact_screen(screen) if screen else None}, ensure_ascii=False)


@server.rtc_session(agent_name="telo-agent")
async def entrypoint(ctx: JobContext):
    logger.info("Telo agent joining room %s", ctx.room.name)
    session = AgentSession(llm=google.realtime.RealtimeModel(
        model="gemini-2.5-flash-native-audio-preview-12-2025", voice="Puck", temperature=0.5,
        instructions="You control Android using Telo's tools. Execute obvious tools immediately without long explanations. For YouTube use package com.google.android.youtube. Observe before acting, use only latest node IDs, verify after action, and never claim success without Android confirmation."))
    await session.start(room=ctx.room, agent=TeloAgent(ctx.room))
    await ctx.connect()
    await session.generate_reply(instructions="Greet the user briefly and say you are ready to control the phone.")


if __name__ == "__main__":
    cli.run_app(server)
