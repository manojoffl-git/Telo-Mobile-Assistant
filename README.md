# Telo Agent — LiveKit + Gemini Live + Android "Open YouTube" MVP

This MVP does exactly two things:

1. Gives the Flutter Android app a ChatGPT-style voice connection through LiveKit.
2. Lets you say **"open YouTube"** and have the Gemini Live agent call an Android tool that launches the YouTube app.

## Architecture

```text
Flutter Android
   │ microphone + speaker
   ▼
LiveKit Cloud
   ▲
   │ WebRTC
Python LiveKit Agent
   │
   ▼
Gemini Live API
   │
   └── function tool: open_youtube()
             │
             ▼
      LiveKit data packet
             │
             ▼
      Flutter Android
             │
             ▼
       Android Intent
             │
             ▼
          YouTube
```

The Gemini API key and LiveKit API secret stay on the backend. Do NOT put them in the Flutter app.

## Prerequisites

- Windows 10/11
- Flutter SDK
- Android Studio + Android SDK
- Python 3.11+
- A Google Gemini API key with Gemini Live API access
- A LiveKit Cloud project with URL/API key/API secret

LiveKit's current Gemini Live integration uses the Python Google plugin and `GOOGLE_API_KEY`.
See:
- https://docs.livekit.io/agents/models/realtime/plugins/gemini/
- https://docs.livekit.io/transport/sdk-platforms/flutter/
- https://docs.livekit.io/agents/server/agent-dispatch/

## 1. Create the Flutter shell

From the `mobile` folder:

```powershell
flutter create .
```

Then replace the generated `lib/main.dart` with the one in this package and add the Android MainActivity/Manifest changes included here.

Install packages:

```powershell
flutter pub get
```

## 2. Backend

Open a terminal in `backend`:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env
```

Edit `.env`:

```env
LIVEKIT_URL=wss://YOUR_PROJECT.livekit.cloud
LIVEKIT_API_KEY=YOUR_LIVEKIT_API_KEY
LIVEKIT_API_SECRET=YOUR_LIVEKIT_API_SECRET
GOOGLE_API_KEY=YOUR_GEMINI_API_KEY
```

Run the token server:

```powershell
python token_server.py
```

It listens on `0.0.0.0:8787`.

In another terminal, with the venv active:

```powershell
python agent.py dev
```

If your installed LiveKit CLI is available, you can also use the LiveKit agent development command documented by LiveKit.

## 3. Set the phone's token-server URL

Open:

```text
mobile/lib/main.dart
```

Find:

```dart
const tokenServerUrl = 'http://10.0.2.2:8787';
```

### Android emulator

Keep `10.0.2.2`.

### Physical Android phone

Your phone and PC must be on the same Wi-Fi network.

Find the PC's LAN IPv4 address:

```powershell
ipconfig
```

For example:

```text
192.168.1.20
```

Then use:

```dart
const tokenServerUrl = 'http://192.168.1.20:8787';
```

Allow Python through Windows Firewall if Windows asks.

## 4. Run the app

```powershell
cd mobile
flutter run
```

Tap **Connect**.

You should hear the Gemini Live agent.

Say:

> Hello

Then:

> Open YouTube.

The agent should call the `open_youtube` tool and the phone will launch YouTube.

## Important

This is deliberately NOT the full phone-control agent yet.

There is only one Android action:

```text
open_youtube
```

The next layer will add:

```text
observe_screen
tap
type_text
scroll
back
home
wait
```

and then the real observe → act → observe loop.
