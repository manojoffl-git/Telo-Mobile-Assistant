import os
import asyncio
from dotenv import load_dotenv
from livekit import api

load_dotenv(".env")

async def main():
    print("URL:", os.getenv("LIVEKIT_URL"))
    print("KEY:", (os.getenv("LIVEKIT_API_KEY") or "")[:8] + "...")
    
    async with api.LiveKitAPI(
        url=os.getenv("LIVEKIT_URL"),
        api_key=os.getenv("LIVEKIT_API_KEY"),
        api_secret=os.getenv("LIVEKIT_API_SECRET"),
    ) as lk:
        rooms = await lk.room.list_rooms(api.ListRoomsRequest())
        print("SUCCESS!")
        print("LiveKit connection works.")
        print("Rooms:", [r.name for r in rooms.rooms])

asyncio.run(main())