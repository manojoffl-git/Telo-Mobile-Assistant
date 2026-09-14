# Telo Agent 🤖

A voice-controlled Android AI agent that can understand natural language commands and interact with Android apps using accessibility controls.

Telo combines **Gemini Live**, **LiveKit**, **Flutter**, and Android's **AccessibilityService** to create a realtime voice-based phone control system.

## ✨ Features

- 🎙️ Realtime voice interaction
- 🧠 Gemini Live native audio AI
- ⚡ LiveKit realtime communication
- 📱 Flutter Android application
- 🤖 Android AccessibilityService for phone control
- 👀 Screen/UI observation through accessibility nodes
- 🖱️ Semantic UI actions instead of relying only on fixed coordinates
- 🔄 Action → observation → verification workflow
- ▶️ Android app launching and control
- 🔐 API keys kept on the backend using environment variables

## 🏗️ Architecture

```text
┌─────────────────────────────┐
│       Android Phone         │
│                             │
│  ┌───────────────────────┐  │
│  │     Flutter App       │  │
│  │   Voice Interface     │  │
│  └───────────┬───────────┘  │
│              │              │
│         LiveKit WebRTC      │
│              │              │
│  ┌───────────▼───────────┐  │
│  │ AccessibilityService  │  │
│  │ Screen + UI Actions    │  │
│  └───────────────────────┘  │
└──────────────┬──────────────┘
               │
               │ LiveKit Cloud
               ▼
┌─────────────────────────────┐
│       Python Backend        │
│                             │
│     Telo LiveKit Agent      │
│              │              │
│              ▼              │
│        Gemini Live          │
│     Native Audio Model      │
└─────────────────────────────┘