# Meet AI 

**Meet AI** is a desktop companion designed to provide intelligent screen analysis. Built with **Swift** and **AppKit**, this application acts as an invisible layer over your workflow, allowing you to interact with an AI that "sees" what you see—without that interaction ever appearing in your recordings, screenshots, or shared windows.

Inspired by tools like **Parakeet** and **Cluely**, Meet AI bridges the gap between deep AI context and professional workspace privacy.

---

### 🌟 Key Features

* **Invisible to Screen Capture**: It's designed to remain completely invisible to screen recording software, screenshots, and platforms like Zoom or Google Meet.
* **Always-on-Top Overlay**: Uses high-level window layering to ensure the AI is always accessible, even in full-screen mode or when switching between Spaces.
* **Contextual Intelligence**: Designed to analyze your active windows to provide instant help, code explanations, or summaries—perfect for your AI-powered workflow.
* **Seamless Persistence**: Your AI assistant stays pinned across your entire macOS environment.

---

### 🚀 Quick Links

* **[Demo Application](https://drive.google.com/file/d/1bZ2yFu_bPauYrqdzDHNq7pn7bAUrBIzO/view?usp=sharing)**
* **[Watch the Demo Video](https://drive.google.com/file/d/1CEK0V7CB2k-jHZ3g_XKum7-zE4-nje60/view?usp=sharing)**

---

### 🛠️ Tech Stack

* **Language**: Swift (SwiftUI & AppKit)
* **Hardware**: Optimized for macOS (developed on MacBook M3)
* **AI Engine**: Ready for Gemini API integration

---

### 💻 Local Setup

1.  **Clone the repository**:
    ```bash
    git clone [https://github.com/MeetRamatri/Meet-AI.git](https://github.com/MeetRamatri/Meet-AI.git)
    ```
2.  **Configure Secrets**:
    * This project uses a `Secrets.plist` file to manage sensitive API keys.
    * Create a `Secrets.plist` in the root directory.
    * Add your `GEMINI_API_KEY` to the file.
3.  **Open in Xcode**:
    * Open `Meet AI.xcodeproj`.
    * Ensure your target is set to **My Mac**.
    * Build and Run (`Cmd + R`).

---

### 🛡️ Privacy & Invisible Mode

The core of Meet AI is the `FloatingWindow` configuration that ensures your AI usage doesn't clutter your professional output.