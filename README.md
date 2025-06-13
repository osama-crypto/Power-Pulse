
# ⚡ PowerPulse

Smart energy monitoring and control system powered by IoT and cloud technologies.

---

##  Frontend (Flutter)

A mobile app that allows users to:

- View real-time power usage per device
- Analyze energy statistics with charts and progress rings
- Control smart devices remotely (via smart switches)
- Get notified on unusual power usage patterns

### UI Tools:
- `fl_chart` – for usage graphs
- `percent_indicator` – for circular usage indicators

---

##  Backend (Node.js + MQTT + MongoDB)
Handles all data flow between devices and cloud.

### Features:
- Subscribes to MQTT messages from smart switches
- Saves data to **MongoDB Atlas** (cloud)
- Falls back to local `db.json` if network is down
- Syncs offline data to the cloud once the network is restored

### Main Files:
- `server.js` – Express server
- `mqttSubscriber.js` – MQTT listener
- `sync.js` – syncs offline data
- `db.json` – temporary offline storage

---

## 📁 Project Structure
powerpulse-frontend/ # Flutter mobile app
powerpulse-backend/ # Node.js backend

---

## 🧪 How to Run the Project

 Backend
```bash
cd powerpulse-backend
npm install
node server.js


 Frontend
```bash
cd powerpulse-frontend
flutter pub get
flutter run
Requires Flutter SDK installed on your machine.

---

Tech Stack
Flutter – frontend UI

Node.js + Express – backend server

MongoDB Atlas – cloud database

MQTT – data communication from smart switches

JSON – offline fallback storage




