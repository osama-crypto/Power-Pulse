import http from 'http';
import url from 'url';
import WebSocket from 'ws';
import mqtt from 'mqtt';
import { MongoClient, ObjectId } from 'mongodb';
import dotenv from 'dotenv';
import jwt from 'jsonwebtoken';

dotenv.config();

// --- MongoDB Connection ---
const mongoClient = new MongoClient(process.env.MONGO_URI_CLOUD);
let db;
const DAILY_CONSUMPTION_COLLECTION = 'daily_device_consumptions'; // New collection name for daily summaries
const NOTIFICATIONS_COLLECTION = 'notifications'; // For writing notifications

const JWT_SECRET = process.env.JWT_SECRET || 'fallback-secret-key-please-set-in-env';
if (JWT_SECRET === 'fallback-secret-key-please-set-in-env') {
  console.warn("[SECURITY WARNING] JWT_SECRET is using a fallback value. Please set a strong, unique secret in your .env file.");
}

// --- MQTT Client (for subscribing to Shelly device data) ---
const mqttClient = mqtt.connect(process.env.MQTT_BROKER_URL, {
  username: process.env.MQTT_USERNAME,
  password: process.env.MQTT_PASSWORD,
  keepalive: 60,
  clientId: `mqtt_subscriber_${Math.random().toString(16).substr(2, 8)}`,
  reconnectPeriod: 5000,
  connectTimeout: 10000
});

// --- WebSocket Server ---
const wss = new WebSocket.Server({ noServer: true });
const activeWsConnections = new Map(); // Map: userId -> Set of WebSocket clients

// --- Date Helper Functions ---
function getCurrentDateString(date = new Date()) {
  const year = date.getFullYear();
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function getDatesForCurrentWeek(currentDate = new Date()) {
    const dates = [];
    const dayOfWeek = currentDate.getDay(); // Sunday - 0, Monday - 1, ..., Saturday - 6
    const startOfWeek = new Date(currentDate);
    startOfWeek.setDate(currentDate.getDate() - dayOfWeek); // Start of week (Sunday)
    startOfWeek.setHours(0,0,0,0);

    for (let i = 0; i < 7; i++) {
        const dateInWeek = new Date(startOfWeek);
        dateInWeek.setDate(startOfWeek.getDate() + i);
        // Only include dates up to and including the current day to reflect "this week's" consumption so far
        if (dateInWeek <= currentDate) { 
            dates.push(getCurrentDateString(dateInWeek));
        }
    }
    return dates;
}

function getDatesForCurrentMonth(currentDate = new Date()) {
    const dates = [];
    const year = currentDate.getFullYear();
    const month = currentDate.getMonth(); 
    // Only include dates up to and including the current day to reflect "this month's" consumption so far
    for (let i = 1; i <= currentDate.getDate() ; i++) {
        dates.push(getCurrentDateString(new Date(year, month, i)));
    }
    return dates;
}

// Function to get system daily consumption from the DAILY_CONSUMPTION_COLLECTION
async function getSystemDailyConsumptionForDate(userId, dateString) {
  if (!db) {
    console.error("[getSystemDailyConsumptionForDate] DB not initialized.");
    return 0;
  }
  try {
    const dailySystemTotal = await db.collection(DAILY_CONSUMPTION_COLLECTION) // Querying the correct collection
      .findOne({ userId: new ObjectId(userId), deviceId: "SYSTEM_TOTAL_DAILY", dateString: dateString }); // Specific deviceId for system total
    return dailySystemTotal?.estimatedEnergyWhToday || 0; // Use estimatedEnergyWhToday field
  } catch (error) {
    console.error(`[getSystemDailyConsumptionForDate] Error fetching daily total for ${dateString}, user ${userId}:`, error);
    return 0;
  }
}


// --- WebSocket Event Handlers ---
wss.on('connection', async (ws, request) => {
  console.log('[WebSocket] Client connected.');
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', async (message) => {
    try {
      const parsedMessage = JSON.parse(message.toString()); 
      if (parsedMessage.type === 'auth' && parsedMessage.token) {
        jwt.verify(parsedMessage.token, JWT_SECRET, async (err, userPayload) => {
          if (err) {
            console.warn('[WebSocket] Auth failed for token:', err.message);
            ws.send(JSON.stringify({ type: 'auth_error', message: 'Authentication failed' }));
            ws.close();
            return;
          }
          ws.userId = userPayload.id;
          console.log(`[WebSocket] Client authenticated. User ID: ${ws.userId}`);

          if (!activeWsConnections.has(ws.userId)) {
            activeWsConnections.set(ws.userId, new Set());
          }
          activeWsConnections.get(ws.userId).add(ws);
          ws.send(JSON.stringify({ type: 'auth_success', message: 'Authenticated' }));

          // --- Initial Data Sync after Authentication ---
          try {
            if (!db) {
              console.error("[WebSocket] DB not initialized during initial data sync for user:", ws.userId);
              return;
            }

            const userDevices = await db.collection('devices')
              .find({ userId: new ObjectId(ws.userId) })
              .toArray();

            const devicesWithStatus = userDevices.map(device => ({
                id: device.id,
                name: device.name,
                status: typeof device.status === 'boolean' ? device.status : false
            }));

            // Calculate initial system power and energy totals for initial WebSocket push
            let initialTotalSystemPower = 0;
            // Iterate through user's active devices to sum their latest power
            for (const device of userDevices) {
              if (device.status === true) { // Only consider devices that are currently ON
                const latestDevicePowerReading = await db.collection(process.env.COLLECTION_NAME)
                  .find({ userId: new ObjectId(ws.userId), deviceId: device.id, power: { $exists: true, $ne: null } })
                  .sort({ timeStamp: -1 }).limit(1).next();
                if (latestDevicePowerReading && typeof latestDevicePowerReading.power === 'number') {
                  initialTotalSystemPower += latestDevicePowerReading.power;
                }
              }
            }

            const today = new Date();
            const todayString = getCurrentDateString(today);
            let initialEnergyToday = 0;
            // Sum estimatedEnergyWhToday from all daily device consumption records for today
            const dailyDeviceConsumptions = await db.collection(DAILY_CONSUMPTION_COLLECTION)
              .find({ userId: new ObjectId(ws.userId), dateString: todayString })
              .toArray();
            for (const dailyRec of dailyDeviceConsumptions) {
              initialEnergyToday += (dailyRec.estimatedEnergyWhToday || 0);
            }
            console.log(`[WebSocket InitialSync] Calculated initial energy for today for user ${ws.userId}: ${initialEnergyToday.toFixed(3)}Wh`);
            
            let initialEnergyThisWeek = 0;
            const weekDates = getDatesForCurrentWeek(today);
            for (const dateStr of weekDates) {
              initialEnergyThisWeek += await getSystemDailyConsumptionForDate(ws.userId, dateStr); // This calls the corrected function
            }
            console.log(`[WebSocket InitialSync] Calculated initial energy for this week for user ${ws.userId}: ${initialEnergyThisWeek.toFixed(3)}Wh`);

            let initialEnergyThisMonth = 0;
            const monthDates = getDatesForCurrentMonth(today);
            for (const dateStr of monthDates) {
              initialEnergyThisMonth += await getSystemDailyConsumptionForDate(ws.userId, dateStr); // This calls the corrected function
            }
            console.log(`[WebSocket InitialSync] Calculated initial energy for this month for user ${ws.userId}: ${initialEnergyThisMonth.toFixed(3)}Wh`);

            // Send initial values in Wh
            ws.send(JSON.stringify({
              type: 'current_power_update',
              payload: {
                power: parseFloat(initialTotalSystemPower.toFixed(3)),
                energyToday: parseFloat(initialEnergyToday.toFixed(3)), // Rounded to 3 decimal places
                energyThisWeek: parseFloat(initialEnergyThisWeek.toFixed(3)), // Rounded to 3 decimal places
                energyThisMonth: parseFloat(initialEnergyThisMonth.toFixed(3)), // Rounded to 3 decimal places
                timeStamp: new Date().toISOString(),
              }
            }));
            console.log(`[WebSocket] Sent initial system power/energy for user ${ws.userId}: P=${initialTotalSystemPower.toFixed(3)}W, E(Today)=${initialEnergyToday.toFixed(3)}Wh, E(Week)=${initialEnergyThisWeek.toFixed(3)}Wh, E(Month)=${initialEnergyThisMonth.toFixed(3)}Wh`);
            
            ws.send(JSON.stringify({
              type: 'initial_devices_update',
              payload: devicesWithStatus
            }));
            console.log(`[WebSocket] Sent initial device list for user ${ws.userId} (${devicesWithStatus.length} devices)`);

          } catch (syncErr) {
            console.error(`[WebSocket] Error sending initial data to user ${ws.userId}:`, syncErr);
          }
        });
      } else {
        console.log('[WebSocket] Received non-auth message:', parsedMessage);
      }
    } catch (parseErr) {
      console.error('[WebSocket] Failed to parse message:', message.toString(), parseErr);
    }
  });

  ws.on('close', () => {
    console.log('[WebSocket] Client disconnected.');
    if (ws.userId && activeWsConnections.has(ws.userId)) {
      activeWsConnections.get(ws.userId).delete(ws);
      if (activeWsConnections.get(ws.userId).size === 0) {
        activeWsConnections.delete(ws.userId);
      }
    }
  });
  ws.on('error', (error) => { console.error('[WebSocket] Client error:', error); });
});

// Corrected WebSocket Ping
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) return ws.terminate();
    ws.isAlive = false;
    ws.ping(); // Corrected: Send ping without arguments
  });
}, 30000);

// --- Notification Helper (for mqttSubscriber) ---
async function createNotificationAndPush(userId, message, type, options = {}) {
  if (!db) {
    console.error("[MQTTSub Notification] Database not initialized.");
    return;
  }
  try {
    const { deviceId = null, deviceName = null, severity = 'info', isRead = false } = options;
    const notificationDoc = {
      userId: new ObjectId(userId),
      message,
      type,
      timestamp: new Date(),
      isRead,
      severity,
    };
    if (deviceId) notificationDoc.deviceId = deviceId;
    if (deviceName) notificationDoc.deviceName = deviceName;

    const insertResult = await db.collection(NOTIFICATIONS_COLLECTION).insertOne(notificationDoc);
    console.log(`[MQTTSub Notification Created] User: ${userId}, Type: ${type}, Msg: ${message.substring(0,50)}...`);

    // Push to WebSocket if user is connected
    if (activeWsConnections.has(userId.toString())) {
      const notificationForWs = { ...notificationDoc, _id: insertResult.insertedId }; // Include _id for client
      activeWsConnections.get(userId.toString()).forEach(wsClient => {
        if (wsClient.readyState === WebSocket.OPEN) {
          wsClient.send(JSON.stringify({ type: 'new_notification', payload: notificationForWs }));
        }
      });
    }
  } catch (error) {
    console.error(`[MQTTSub Notification Create Error] User ${userId}, Type: ${type}:`, error);
  }
}

// --- MQTT Event Handlers ---
mqttClient.on('connect', () => {
  console.log('[MQTT] Connected to MQTT broker.');
  const topicsToSubscribe = ['tele/#', 'stat/#', 'shellies/#', 'shellyplugus-a0dd6c4a81fc/#', 'shellyplugus-a0dd6c27ade0/#'];
  mqttClient.subscribe(topicsToSubscribe, { qos: 0 }, (err) => {
    if (err) console.error('[MQTT] Failed to subscribe:', err);
    else console.log('[MQTT] Subscribed to topics:', topicsToSubscribe);
  });
});
mqttClient.on('error', (err) => { console.error('[MQTT Client Error]', err); });

// This function will now update daily energy by integrating power over time
async function updateDailyDeviceEnergyByPower(userId, deviceId, currentPowerW, currentTimestamp) {
    if (!db) {
        console.error('[DailyEnergyPower] DB not initialized.');
        return;
    }
    if (typeof currentPowerW !== 'number' || isNaN(currentPowerW)) {
        // console.warn(`[DailyEnergyPower] Invalid power value for ${deviceId}: ${currentPowerW}`);
        return;
    }

    const todayString = getCurrentDateString();
    const dailyCollection = db.collection(DAILY_CONSUMPTION_COLLECTION); // Use correct collection name

    try {
        const existingDailyRecord = await dailyCollection.findOne({ userId: new ObjectId(userId), deviceId, dateString: todayString });

        if (!existingDailyRecord) {
            // First power reading for this device today
            await dailyCollection.insertOne({
                userId: new ObjectId(userId),
                deviceId,
                dateString: todayString,
                estimatedEnergyWhToday: 0, // Start with 0 energy consumed today (stores Wh)
                lastPowerReadingW: currentPowerW,
                lastPowerReadingTimestamp: currentTimestamp,
                updatedAt: new Date()
            });
            console.log(`[DailyEnergyPower DBG] Initialized daily record for ${deviceId} on ${todayString} with power ${currentPowerW}W.`);
        } else {
            const lastPower = existingDailyRecord.lastPowerReadingW || 0;
            const lastTimestamp = existingDailyRecord.lastPowerReadingTimestamp ? new Date(existingDailyRecord.lastPowerReadingTimestamp) : currentTimestamp;
            let currentEstimatedEnergyWh = existingDailyRecord.estimatedEnergyWhToday || 0; // Read existing Wh

            const timeDeltaMs = currentTimestamp.getTime() - lastTimestamp.getTime();

            if (timeDeltaMs > 0) { // Only calculate if time has passed
                const timeDeltaHours = timeDeltaMs / (1000 * 60 * 60);
                // Average power over the interval
                const averagePowerW = (lastPower + currentPowerW) / 2;
                const energySliceWh = (averagePowerW * timeDeltaHours); // Calculate slice in Wh
                
                currentEstimatedEnergyWh += energySliceWh;
                
                console.log(`[DailyEnergyPower DBG] Device: ${deviceId}, PrevP: ${lastPower}W, CurrP: ${currentPowerW}W, AvgP: ${averagePowerW.toFixed(2)}W, TimeDeltaH: ${timeDeltaHours.toFixed(4)}, SliceWh: ${energySliceWh.toFixed(3)}, NewTotalEstWh: ${currentEstimatedEnergyWh.toFixed(3)}`);
            }

            await dailyCollection.updateOne(
                { _id: existingDailyRecord._id },
                { $set: { 
                    estimatedEnergyWhToday: currentEstimatedEnergyWh, // Store updated Wh
                    lastPowerReadingW: currentPowerW,
                    lastPowerReadingTimestamp: currentTimestamp,
                    updatedAt: new Date() 
                }}
            );
        }
    } catch (error) {
        console.error(`[DailyEnergyPower] Error updating daily energy by power for ${deviceId}:`, error);
    }
}


mqttClient.on('message', async (topic, message) => {
  try {
    if (!db) {
      console.warn(`[MQTT Message] DB not initialized. Skipping: ${topic}.`);
      return;
    }
    const msgString = message.toString();

    let deviceId = null;
    const shellyGenPattern = /(shelly(?:plus|pro)?(?:plug(?:us|s)|1pm|dimmer2|pmmini|trv|ht|dw2|button1|motionsensor2|blu|em|3em|rgbw2|uni|i4|i4dc|valve|air|gas|flood|smokeplus|motionsensor|contact|window|vintage|duo|bulb|colorbulb|vintage|dimmer|roller|switch25|plug|4pro|em|1|1l|2.5|rgbw)-([0-9a-fA-F]{6,12}|[a-zA-Z0-9\-_]+))/i;
    let match = topic.match(shellyGenPattern);
    if (match && match[2]) deviceId = match[2].toLowerCase();
    else {
      const standardShelliesPattern = /shellies\/(?:[a-zA-Z0-9\-_]+-)?([a-fA-F0-9]{6}|[a-fA-F0-9]{12})/;
      match = topic.match(standardShelliesPattern);
      if (match && match[1]) deviceId = match[1].toLowerCase();
    }
    if (!deviceId) return;

    let payload;
    try { payload = JSON.parse(msgString); } catch (e) { payload = msgString; }

    const deviceDoc = await db.collection('devices').findOne({ id: deviceId });
    if (!deviceDoc) return;
    const userId = deviceDoc.userId.toString();
    const currentTimestamp = new Date();

    if (topic.startsWith('tele/') && payload?.ENERGY) {
      // Pass the instantaneous power to handleShellyPowerData
      await handleShellyPowerData(deviceId, userId, payload.ENERGY.power, payload.ENERGY.total); // payload.ENERGY.total is the cumulative meter, not used for current power integration.
    }
    else if (topic.startsWith('stat/')) {
      const parts = topic.split('/');
      if (parts.length > 2 && (parts[2] === 'POWER' || parts[2] === 'RELAY')) {
      const newStatus = (payload === 'ON' || payload?.switch === true);
      await handleShellyStatus(deviceId, userId, newStatus);
      }
    }
    else if (payload?.method === 'NotifyStatus' && payload?.params?.['switch:0']) {
      const switchData = payload.params['switch:0'];
      const newDeviceStatus = typeof switchData.output === 'boolean' ? switchData.output : undefined;
      await handleShellyStatus(deviceId, userId, newDeviceStatus, switchData.apower, switchData.aenergy?.total);
    }
    else if (payload?.result?.on !== undefined) { // For RPC result
      await handleShellyStatus(deviceId, userId, payload.result.on);
    }
    else if (topic.includes('/status/switch:0') && typeof payload?.output === 'boolean') {
      await handleShellyStatus(deviceId, userId, payload.output, payload.apower, payload.aenergy?.total);
    }
    else if (topic.endsWith('online')) {
      const onlineStatus = msgString === 'true';
      await db.collection('device_status').updateOne(
        { deviceId: deviceId }, { $set: { online: onlineStatus, lastSeen: new Date() } }, { upsert: true }
      );
    }
  } catch (error) {
    console.error('[MQTT Message Handler Error]', error);
  }
});

async function handleShellyPowerData(deviceId, userId, powerReadingForDevice, totalEnergyWhDeviceReported) {
  try {
    if (!db) { console.error('[handleShellyPowerData] DB not initialized.'); return; }
    const powerToSave = typeof powerReadingForDevice === 'number' ? powerReadingForDevice : undefined;
    const timeStamp = new Date();

    if (powerToSave !== undefined) {
      const readingToInsert = { deviceId, userId: new ObjectId(userId), timeStamp, power: powerToSave };
      await db.collection(process.env.COLLECTION_NAME).insertOne(readingToInsert);
      console.log(`[DB Insert Telemetry] ${deviceId}, P:${powerToSave}W`);

      // Update daily energy estimate based on this power reading
      await updateDailyDeviceEnergyByPower(userId, deviceId, powerToSave, timeStamp);
    }

    await db.collection('device_status').updateOne(
      { deviceId: deviceId }, { $set: { online: true, lastSeen: timeStamp } }, { upsert: true }
    );
    await calculateAndPushTotalSystemPower(userId);
  } catch (error) {
    console.error(`[handleShellyPowerData] Error for ${deviceId}:`, error);
  }
}

async function handleShellyStatus(deviceId, userId, newStatus, currentPowerIfAvailable, cumulativeEnergyIfAvailableDeviceReported) {
  try {
    const timeStamp = new Date(); // Use a consistent timestamp for this event
    if (!db) { console.error('[handleShellyStatus] DB not initialized.'); return; }

    if (typeof newStatus === 'boolean') {
      const result = await db.collection('devices').updateOne(
        { id: deviceId, userId: new ObjectId(userId) }, { $set: { status: newStatus } }
      );
      if (result.matchedCount > 0) console.log(`[DB Update] Dev '${deviceId}' ON/OFF status: ${newStatus}.`);
    }

    let powerValueToStore = undefined;
    if (typeof currentPowerIfAvailable === 'number') powerValueToStore = currentPowerIfAvailable;
    if (newStatus === false && powerValueToStore === undefined) powerValueToStore = 0;

    if (powerValueToStore !== undefined) {
      const newReadingEntry = { deviceId, userId: new ObjectId(userId), timeStamp, power: powerValueToStore };
      await db.collection(process.env.COLLECTION_NAME).insertOne(newReadingEntry);
      console.log(`[DB Insert Status] ${deviceId}, P:${powerValueToStore}W`);
      await db.collection('device_status').updateOne(
          { deviceId: deviceId }, { $set: { online: true, lastSeen: timeStamp } }, { upsert: true }
      );
      // Update daily energy estimate based on this power reading (or 0W if turning off)
      await updateDailyDeviceEnergyByPower(userId, deviceId, powerValueToStore, timeStamp);
    }

    const deviceAfterUpdates = await db.collection('devices').findOne({ id: deviceId, userId: new ObjectId(userId) }, { projection: { name: 1, status: 1 } });
    if (deviceAfterUpdates && activeWsConnections.has(userId)) {
      const currentDeviceStatusForWS = typeof deviceAfterUpdates.status === 'boolean' ? deviceAfterUpdates.status : false;
      const statusUpdateMessage = JSON.stringify({ type: 'device_status_update', payload: { id: deviceId, name: deviceAfterUpdates.name, status: currentDeviceStatusForWS }});
      activeWsConnections.get(userId).forEach(wsClient => { 
        if (wsClient.readyState === WebSocket.OPEN) wsClient.send(statusUpdateMessage); 
      });
    }

    // Check if device came online after being offline
    const deviceStatusRecord = await db.collection('device_status').findOne({ deviceId });
    // If it was previously marked offline (or doesn't exist yet and newStatus is true) and is now online
    if (newStatus === true && (!deviceStatusRecord || !deviceStatusRecord.online)) {
        await createNotificationAndPush(
            userId,
            `${deviceAfterUpdates?.name || deviceId} came online.`,
            'device_online',
            { deviceId: deviceId, deviceName: deviceAfterUpdates?.name, severity: 'info' }
        );
    }
    // Update device_status collection (ensure it's marked as online if status is true)
    if (newStatus === true) {
        await db.collection('device_status').updateOne({ deviceId }, { $set: { online: true, lastSeen: timeStamp, lastOnlineTimestamp: timeStamp } }, { upsert: true });
    }

    await calculateAndPushTotalSystemPower(userId);
  } catch (error) {
    console.error(`[handleShellyStatus] Error for ${deviceId}:`, error);
  }
}

async function calculateAndPushTotalSystemPower(userId) {
  if (!db || !activeWsConnections.has(userId)) {
    return;
  }

  let totalSystemPower = 0;
  const userDevices = await db.collection('devices').find({ userId: new ObjectId(userId) }).toArray();

  for (const deviceDoc of userDevices) {
    if (deviceDoc.status === true) {
      const latestPowerReading = await db.collection(process.env.COLLECTION_NAME)
        .find({ deviceId: deviceDoc.id, userId: new ObjectId(userId), power: { $exists: true, $ne: null } })
        .sort({ timeStamp: -1 }).limit(1).next();
      if (latestPowerReading && typeof latestPowerReading.power === 'number') {
        totalSystemPower += latestPowerReading.power;
      }
    }
  }

  const today = new Date();
  const todayString = getCurrentDateString(today);
  let totalEnergyToday = 0;
  if (userDevices.length > 0) {
    const dailyDeviceConsumptions = await db.collection(DAILY_CONSUMPTION_COLLECTION)
        .find({ userId: new ObjectId(userId), dateString: todayString })
        .toArray();
    for (const dailyRec of dailyDeviceConsumptions) {
        totalEnergyToday += (dailyRec.estimatedEnergyWhToday || 0);
    }
  }
  console.log(`[EnergyCalc DBG - Daily Sum from Estimated] User ${userId} on ${todayString}: ${totalEnergyToday.toFixed(3)}Wh`);

  // Store/Update the user's total daily consumption for the system in DAILY_CONSUMPTION_COLLECTION
  try {
      await db.collection(DAILY_CONSUMPTION_COLLECTION).updateOne( // Changed collection to DAILY_CONSUMPTION_COLLECTION
        { userId: new ObjectId(userId), deviceId: "SYSTEM_TOTAL_DAILY", dateString: todayString }, // Unique key for system total
        { $set: {
            estimatedEnergyWhToday: totalEnergyToday, // Consistent field name for energy in Wh
            lastUpdated: new Date()
        }},
        { upsert: true }
      );
      console.log(`[DB Upsert DBG] User: ${userId}, Date: ${todayString}, DailyEnergy (from Estimated): ${totalEnergyToday.toFixed(3)}Wh`);
  } catch (error) {
      console.error(`[DB Upsert DailyTotal] Error saving daily system total for user ${userId}:`, error);
  }


  let totalEnergyThisWeek = 0;
  const weekDates = getDatesForCurrentWeek(today);
  for (const dateStr of weekDates) {
    totalEnergyThisWeek += await getSystemDailyConsumptionForDate(userId, dateStr); // This calls the corrected function
  }
  console.log(`[EnergyCalc DBG - Weekly Sum from Estimated] User ${userId} for current week: ${totalEnergyThisWeek.toFixed(3)}Wh`);
  
  let totalEnergyThisMonth = 0;
  const monthDates = getDatesForCurrentMonth(today);
  for (const dateStr of monthDates) {
    totalEnergyThisMonth += await getSystemDailyConsumptionForDate(userId, dateStr); // This calls the corrected function
  }
  console.log(`[EnergyCalc DBG - Monthly Sum from Estimated] User ${userId} for current month: ${totalEnergyThisMonth.toFixed(3)}Wh`);

  const messageToClients = JSON.stringify({
    type: 'current_power_update', // This type is handled by ApiService to update PowerDataProvider
    payload: { // Ensure payload matches what PowerDataProvider expects
      power: parseFloat(totalSystemPower.toFixed(3)), // Current total system power in Watts
      energyToday: parseFloat(totalEnergyToday.toFixed(3)), // Total system energy for today in Wh
      energyThisWeek: parseFloat(totalEnergyThisWeek.toFixed(3)), // Total system energy for this week in Wh
      energyThisMonth: parseFloat(totalEnergyThisMonth.toFixed(3)), // Total system energy for this month in Wh
      timeStamp: new Date().toISOString() // Timestamp of this update
    }
  });

  // Log the current total system power for historical aggregation by the API
  try {
    await db.collection(process.env.COLLECTION_NAME).insertOne({
      userId: new ObjectId(userId),
      deviceId: "SYSTEM_POWER_LOG", // Special deviceId for system-wide power readings
      power: parseFloat(totalSystemPower.toFixed(3)), // Current total system power
      timeStamp: new Date() // Timestamp of this power reading
    });
  } catch (logError) {
    console.error(`[calculateAndPushTotalSystemPower] Error logging system power for user ${userId}:`, logError);
  }

  if (activeWsConnections.has(userId)) {
    activeWsConnections.get(userId).forEach(wsClient => {
      if (wsClient.readyState === WebSocket.OPEN) wsClient.send(messageToClients);
    });
    console.log(`[WS Push DBG] User ${userId}: P=${totalSystemPower.toFixed(3)}W, E(Today)=${totalEnergyToday.toFixed(3)}Wh, E(Week)=${totalEnergyThisWeek.toFixed(3)}Wh, E(Month)=${totalEnergyThisMonth.toFixed(3)}Wh`);
  }
}

// --- HTTP Server & Start ---
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', mongo: db ? 'connected' : 'disconnected', mqtt: mqttClient.connected ? 'connected' : 'disconnected', websockets: wss.clients.size }));
  } else {
    res.writeHead(404); res.end('Not Found');
  }
});
server.on('upgrade', (request, socket, head) => {
  const pathname = url.parse(request.url).pathname;
  if (pathname === '/ws') {
    wss.handleUpgrade(request, socket, head, (ws) => wss.emit('connection', ws, request));
  } else socket.destroy();
});

const startServer = async () => {
  try {
    await mongoClient.connect();
    db = mongoClient.db(process.env.DB_NAME);
    console.log('[mqttSubscriber.js] Connected to MongoDB.');

    // Ensure necessary indexes
    try {
      const deviceStatusIndexes = await db.collection('device_status').listIndexes().toArray();
      const conflictingIndex = deviceStatusIndexes.find(idx => idx.name === "deviceId_1" && !idx.unique);
      if (conflictingIndex) {
        console.log("[mqttSubscriber.js] Dropping conflicting non-unique 'deviceId_1' index from 'device_status'.");
        await db.collection('device_status').dropIndex("deviceId_1");
      }
    } catch (e) {
      console.warn("[mqttSubscriber.js] Error checking or dropping index on 'device_status':", e.message);
    }

    try { await db.collection('devices').createIndex({ id: 1, userId: 1 }, { unique: true }); } catch (e) { console.warn("Index error on 'devices':", e.message); }
    try { await db.collection('device_status').createIndex({ deviceId: 1 }, { unique: true }); } catch (e) { console.warn("Index error on 'device_status':", e.message); }
    try { await db.collection(process.env.COLLECTION_NAME).createIndex({ userId: 1, deviceId: 1, timeStamp: -1 }); } catch (e) { console.warn("Index error on 'readings':", e.message); }
    
    // Index for SYSTEM_TOTAL_DAILY in DAILY_CONSUMPTION_COLLECTION (unique)
    try { await db.collection(DAILY_CONSUMPTION_COLLECTION).createIndex({ userId: 1, deviceId: 1, dateString: 1 }, { unique: true }); } catch (e) { console.warn("Index error on 'daily_device_consumptions' (now stores Wh):", e.message); }
    
    // Indexes for notifications collection
    try {
      await db.collection(NOTIFICATIONS_COLLECTION).createIndex({ userId: 1, timestamp: -1 });
      await db.collection(NOTIFICATIONS_COLLECTION).createIndex({ userId: 1, isRead: 1, timestamp: -1 });
    } catch (e) { console.warn("Index error on 'notifications':", e.message); }

    console.log(`[mqttSubscriber.js] Attempted to ensure all necessary indexes.`);

    const PORT = process.env.MQTT_SUBSCRIBER_PORT || 3002;
    server.listen(PORT, '0.0.0.0', () => {
      console.log(`[mqttSubscriber.js] Server running on port ${PORT}. WS endpoint: ws://<your-ip>:${PORT}/ws`);
    });
  } catch (err) {
    console.error('[mqttSubscriber.js] Startup Error:', err.message, err.stack);
    process.exit(1);
  }
};
startServer();
