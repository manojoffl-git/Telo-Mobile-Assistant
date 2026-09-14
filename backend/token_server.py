import os
import uuid

from dotenv import load_dotenv
from fastapi import FastAPI
from livekit import api
from fastapi.middleware.cors import CORSMiddleware

load_dotenv()

app = FastAPI(title="Telo Agent Token Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

AGENT_NAME = "telo-agent"


@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/token")
async def token():
    room_name = f"telo-{uuid.uuid4().hex[:12]}"
    identity = f"phone-{uuid.uuid4().hex[:8]}"

    token = (
        api.AccessToken()
        .with_identity(identity)
        .with_name("Telo Phone")
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=True,
                can_subscribe=True,
                can_publish_data=True,
            )
        )
        .to_jwt()
    )

    # Explicitly dispatch the named agent to this new room.
    async with api.LiveKitAPI() as lkapi:
        await lkapi.agent_dispatch.create_dispatch(
            api.CreateAgentDispatchRequest(
                agent_name=AGENT_NAME,
                room=room_name,
            )
        )

    return {
        "serverUrl": os.environ["LIVEKIT_URL"],
        "token": token,
        "room": room_name,
        "identity": identity,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("token_server:app", host="0.0.0.0", port=8787, reload=False)
