import express from 'express';
import cors from 'cors';
import { MongoClient, ObjectId } from 'mongodb';
import dotenv from 'dotenv';
import mqtt from 'mqtt';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';

dotenv.config();

const app = express();

// --- Global Express Logger Middleware ---
app.use((req, res, next) => {
  console.log(`[GLOBAL EXPRESS LOGGER] Incoming Request: ${req.method} ${req.originalUrl} from ${req.ip}`);
  if (req.body && Object.keys(req.body).length > 0) {
    console.log(`[GLOBAL EXPRESS LOGGER] Request Body: ${JSON.stringify(req.body)}`);
  }
  next();
});

// --- Middleware ---
app.use(cors());
app.use(express.json());

// --- Database Connection ---
const mongoClient = new MongoClient(process.env.MONGO_URI_CLOUD);
const JWT_SECRET = process.env.JWT_SECRET || 'fallback-secret-key-please-set-in-env';
if (JWT_SECRET === 'fallback-secret-key-please-set-in-env') {
  console.warn("[SECURITY WARNING] JWT_SECRET is using a fallback value. Please set a strong, unique secret in your .env file.");
}
let db;
const DAILY_CONSUMPTION_COLLECTION = 'daily_device_consumptions'; // Collection for daily summaries
const NOTIFICATIONS_COLLECTION = 'notifications';

// --- MQTT Client (for publishing commands from the backend to Shelly devices) ---
const serverMqttClient = mqtt.connect(process.env.MQTT_BROKER_URL, {
  username: process.env.MQTT_USERNAME,
  password: process.env.MQTT_PASSWORD,
  keepalive: 60,
  clientId: `server_js_publisher_${Math.random().toString(16).substr(2, 8)}`,
  reconnectPeriod: 5000,
  connectTimeout: 10000
});

serverMqttClient.on('connect', () => {
  console.log('[Server.js MQTT] Connected to MQTT broker for publishing.');
});

serverMqttClient.on('error', (err) => {
  console.error('[Server.js MQTT Client Error]', err);
});

// --- Authentication Middleware ---
const authenticateToken = (req, res, next) => {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];

  if (token == null) {
    console.log('[Auth Middleware] No token provided.');
    return res.status(401).json({ error: 'No token provided' });
  }

  jwt.verify(token, JWT_SECRET, (err, userPayload) => {
    if (err) {
      console.log('[Auth Middleware] Token verification failed:', err.message);
      return res.status(403).json({ error: 'Token is not valid' });
    }
    req.user = userPayload;
    console.log(`[Auth Middleware] Token verified for user ID: ${req.user.id}`);
    next();
  });
};

// --- Auth Routes ---
app.post('/auth/signup', async (req, res) => {
  console.log(`[AUTH /auth/signup] Received request. Body: ${JSON.stringify(req.body)}`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const { name, email, password } = req.body;

    if (!name || !email || !password) {
      return res.status(400).json({ error: 'Name, email, and password are required' });
    }
    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters long' });
    }

    const existingUser = await db.collection('users').findOne({ email });
    if (existingUser) {
      return res.status(409).json({ error: 'User with this email already exists' });
    }

    const hashedPassword = await bcrypt.hash(password, 10);
    const newUser = {
      name,
      email,
      password: hashedPassword,
      createdAt: new Date()
    };
    await db.collection('users').insertOne(newUser);
    console.log(`[AUTH /auth/signup] User created successfully for email: ${email}`);
    res.status(201).json({ message: 'User created successfully. Please login.' });
  } catch (err) {
    console.error(`[AUTH /auth/signup] Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

app.post('/auth/login', async (req, res) => {
  console.log(`[AUTH /auth/login] Received request. Body: ${JSON.stringify(req.body)}`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }

    const user = await db.collection('users').findOne({ email });
    if (!user) {
      console.log(`[AUTH /auth/login] User not found for email: ${email}`);
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const isMatch = await bcrypt.compare(password, user.password);
    if (!isMatch) {
      console.log(`[AUTH /auth/login] Password mismatch for email: ${email}`);
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const tokenPayload = { id: user._id.toString(), email: user.email };
    const token = jwt.sign(tokenPayload, JWT_SECRET, { expiresIn: '24h' });

    console.log(`[AUTH /auth/login] Login successful for user ID: ${user._id.toString()}`);
    res.json({
      token,
      user: { id: user._id.toString(), name: user.name, email: user.email }
    });
  } catch (err) {
    console.error(`[AUTH /auth/login] Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

// --- API Endpoints (Protected by authenticateToken middleware) ---

// Helper function to get total daily consumption for a specific date string (YYYY-MM-DD)
async function getSystemDailyConsumptionForDate(userId, dateString) {
  if (!db) throw new Error("Database not initialized for getSystemDailyConsumptionForDate");
  const dailySystemTotal = await db.collection(DAILY_CONSUMPTION_COLLECTION) // Querying the correct collection
    .findOne({ userId: new ObjectId(userId), deviceId: "SYSTEM_TOTAL_DAILY", dateString: dateString });
  
  return dailySystemTotal?.estimatedEnergyWhToday || 0; // Use estimatedEnergyWhToday field
}

// GET /api/power/current
// Fetches the latest power reading and aggregated daily, weekly, monthly energy for the authenticated user.
app.get('/api/power/current', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  console.log(`[API /api/power/current] User: ${userId}. Received request.`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    let currentPower = 0;
    const userDevices = await db.collection('devices').find({ userId: new ObjectId(userId), status: true }).toArray();
    for (const device of userDevices) {
      const latestDevicePowerReading = await db.collection(process.env.COLLECTION_NAME)
        .find({ userId: new ObjectId(userId), deviceId: device.id, power: { $exists: true, $ne: null } })
        .sort({ timeStamp: -1 }).limit(1).next();
      if (latestDevicePowerReading && typeof latestDevicePowerReading.power === 'number') {
        currentPower += latestDevicePowerReading.power;
      }
    }

    const today = new Date();
    const todayString = getCurrentDateString(today);

    // Fetch daily, weekly, monthly aggregated consumption
    const energyToday = await getSystemDailyConsumptionForDate(userId, todayString);

    let energyThisWeek = 0;
    const weekDates = getDatesForCurrentWeek(today);
    for (const dateStr of weekDates) {
      energyThisWeek += await getSystemDailyConsumptionForDate(userId, dateStr);
    }

    let energyThisMonth = 0;
    const monthDates = getDatesForCurrentMonth(today);
    for (const dateStr of monthDates) {
      energyThisMonth += await getSystemDailyConsumptionForDate(userId, dateStr);
    }

    res.json({
      power: parseFloat(currentPower.toFixed(3)),
      energyToday: parseFloat(energyToday.toFixed(3)), // In Wh
      energyThisWeek: parseFloat(energyThisWeek.toFixed(3)), // In Wh
      energyThisMonth: parseFloat(energyThisMonth.toFixed(3)), // In Wh
      timeStamp: new Date().toISOString()
    });
  } catch (err) {
    console.error(`[API /api/power/current] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

// GET /api/power/consumption
// This endpoint is still valid but might be less used by the current frontend due to /api/power/current's expanded response.
app.get('/api/power/consumption', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  const period = req.query.period || 'daily';
  console.log(`[API /api/power/consumption] User: ${userId}. Period: ${period}`);

  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    let totalConsumption = 0;
    const today = new Date();

    if (period === 'daily') {
      totalConsumption = await getSystemDailyConsumptionForDate(userId, getCurrentDateString(today));
    } else if (period === 'weekly') {
      const weekDates = getDatesForCurrentWeek(today);
      for (const dateStr of weekDates) {
        totalConsumption += await getSystemDailyConsumptionForDate(userId, dateStr);
      }
    } else if (period === 'monthly') {
      const monthDates = getDatesForCurrentMonth(today);
      for (const dateStr of monthDates) {
        totalConsumption += await getSystemDailyConsumptionForDate(userId, dateStr);
      }
    } else {
      return res.status(400).json({ error: 'Invalid period specified. Use daily, weekly, or monthly.' });
    }

    res.json({ period, totalConsumption: parseFloat(totalConsumption.toFixed(3)) });
  } catch (err) {
    console.error(`[API /api/power/consumption] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to load consumption data: ${err.message}` });
  }
});

// Shared logic for fetching overall system energy history
async function getOverallSystemEnergyHistory(req, res) {
  const userId = req.user.id;
  console.log(`[API /api/power/history (shared)] User: ${userId}. Received request. Query: ${JSON.stringify(req.query)}`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const hours = parseInt(req.query.hours) || 24; // Default to 24 hours (hourly data)
    const cutoff = new Date(Date.now() - hours * 60 * 60 * 1000);

    // Fetch system-wide power readings logged by mqttSubscriber.js
    const powerReadings = await db.collection(process.env.COLLECTION_NAME)
      .find({ 
        userId: new ObjectId(userId), 
        deviceId: "SYSTEM_POWER_LOG", // Use the special deviceId for system-wide power logs
        timeStamp: { $gte: cutoff } 
      })
      .sort({ timeStamp: 1 }) // Sort by timeStamp (ascending) for chronological order
      .project({ timeStamp: 1, power: 1, _id: 0 }) // Project timeStamp and power
      .toArray();

    if (powerReadings.length === 0) {
      return res.json([]);
    }

    // Aggregate power readings into hourly energy consumption (Wh)
    const hourlyEnergy = [];
    // Ensure currentHourStart is aligned to the start of an hour from the first reading
    let currentHourStart = new Date(powerReadings[0].timeStamp);
    currentHourStart.setMinutes(0, 0, 0); // Align to the start of the hour

    // Iterate for the number of hours requested, starting from the cutoff
    const loopCutoff = new Date(Date.now() - hours * 60 * 60 * 1000);
    loopCutoff.setMinutes(0,0,0); // Align loopCutoff to the start of an hour

    for (let i = 0; i < hours; i++) {
      const hourEnd = new Date(currentHourStart.getTime() + 60 * 60 * 1000);
      const readingsInHour = powerReadings.filter(r => r.timeStamp >= currentHourStart && r.timeStamp < hourEnd);

      let totalEnergyForHourWh = 0;
      if (readingsInHour.length > 0) {
        let sumPower = 0;
        readingsInHour.forEach(r => sumPower += r.power);
        const avgPower = sumPower / readingsInHour.length;
        totalEnergyForHourWh = avgPower * 1; // Avg Power (W) * 1 hour = Wh
      }
      
      hourlyEnergy.push({
        timeStamp: currentHourStart.toISOString(), 
        energy: parseFloat(totalEnergyForHourWh.toFixed(3))
      });
      currentHourStart = hourEnd;
    }
    res.json(hourlyEnergy);
  } catch (err) {
    console.error(`[API /api/power/history] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to load overall power history: ${err.message}` });
  }
}

// GET /api/power/history - Fetches historical *overall system energy consumption*
app.get('/api/power/history', authenticateToken, getOverallSystemEnergyHistory);
// GET /api/power/history/user - Alias for /api/power/history
app.get('/api/power/history/user', authenticateToken, getOverallSystemEnergyHistory);

// GET /api/devices
app.get('/api/devices', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  console.log(`[API /api/devices] User: ${userId}. Received request.`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const devices = await db.collection('devices').find({ userId: new ObjectId(userId) }).toArray();
    res.json(devices);
  } catch (err) {
    console.error(`[API /api/devices] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

// GET /api/mqtt-devices
app.get('/api/mqtt-devices', authenticateToken, async (req, res) => {
  console.log(`[API /api/mqtt-devices] Received request.`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    const onlineDevicesStatus = await db.collection('device_status')
      .find({ online: true }, { projection: { deviceId: 1, _id: 0 } })
      .toArray();

    const onlineDeviceIds = onlineDevicesStatus.map(d => d.deviceId).filter(id => id);
    console.log(`[API /api/mqtt-devices] DeviceIds from 'device_status' (online=true):`, JSON.stringify(onlineDeviceIds));

    const allRegisteredDevices = await db.collection('devices').find({}, { projection: { id: 1, _id: 0 } }).toArray();
    const allRegisteredDeviceIds = new Set(allRegisteredDevices.map(d => d.id));
    console.log(`[API /api/mqtt-devices] All registered deviceIds from 'devices':`, JSON.stringify(Array.from(allRegisteredDeviceIds)));

    const availableMqttDevices = onlineDeviceIds
      .filter(id => !allRegisteredDeviceIds.has(id))
      .map(id => ({ id }));

    console.log(`[API /api/mqtt-devices] Returning availableMqttDevices:`, JSON.stringify(availableMqttDevices));
    res.json(availableMqttDevices);
  } catch (err) {
    console.error(`[API /api/mqtt-devices] Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/devices
app.post('/api/devices', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  console.log(`[API POST /api/devices] User: ${userId}. Received request. Body: ${JSON.stringify(req.body)}`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const { deviceId, name } = req.body;
    if (!deviceId || !name) {
      return res.status(400).json({ error: 'deviceId and name are required' });
    }

    const existingDevice = await db.collection('devices').findOne({ id: deviceId });
    if (existingDevice) {
      if (existingDevice.userId.toString() !== userId) {
        return res.status(409).json({ error: `Device ID '${deviceId}' is already registered by another user.` });
      } else {
        return res.status(409).json({ error: `You have already registered device ID '${deviceId}'.` });
      }
    }

    await db.collection('devices').insertOne({
      id: deviceId,
      name,
      userId: new ObjectId(userId),
      status: false,
      createdAt: new Date()
    });
    console.log(`[API POST /api/devices] User: ${userId}. Device '${deviceId}' added successfully.`);
    res.status(201).json({ success: true, message: 'Device added successfully' });
  } catch (err) {
    console.error(`[API POST /api/devices] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

// POST /api/devices/:deviceIdParam
app.post('/api/devices/:deviceIdParam/toggle', authenticateToken, async (req, res) => {
  const deviceId = req.params.deviceIdParam;
  const newStatus = req.body.turnOn;
  const userId = req.user.id;

  console.log(`[CONTROL /api/devices/${deviceId}] User: ${userId}. Request to set status to: ${newStatus}.`);

  if (!db) return res.status(500).json({ error: 'Database not initialized' });
  if (typeof newStatus !== 'boolean') {
    return res.status(400).json({ error: 'turnOn (boolean) is required in request body' });
  }

  const device = await db.collection('devices').findOne({ id: deviceId, userId: new ObjectId(userId) });
  if (!device) {
    console.log(`[CONTROL /api/devices/${deviceId}] User: ${userId}. Device not found or not owned by user.`);
    return res.status(404).json({ error: 'Device not found or you do not have permission to control it.' });
  }

  const rpcTopic = `shellyplugus-${deviceId}/rpc`;
  const rpcPayload = JSON.stringify({
    id: Date.now(),
    src: "PowerPulseBackend",
    method: "Switch.Set",
    params: { id: 0, on: newStatus }
  });

  console.log(`[CONTROL /api/devices/${deviceId}] User: ${userId}. Publishing to MQTT. Topic: '${rpcTopic}', Payload: '${rpcPayload}'`);
  try {
    await new Promise((resolve, reject) => {
      serverMqttClient.publish(rpcTopic, rpcPayload, { qos: 1 }, (err) => {
        if (err) {
          console.error(`[CONTROL /api/devices/${deviceId}] User: ${userId}. MQTT Publish Error to ${rpcTopic}:`, err);
          return reject(new Error(`Failed to publish MQTT command: ${err.message}`));
        }
        console.log(`[CONTROL /api/devices/${deviceId}] User: ${userId}. MQTT message published to ${rpcTopic}.`);
        resolve();
      });
    });

    const dbResult = await db.collection('devices').updateOne(
      { id: deviceId, userId: new ObjectId(userId) },
      { $set: { status: newStatus } }
    );
    if (dbResult.matchedCount === 0) {
      console.warn(`[CONTROL /api/devices/${deviceId}] User: ${userId}. Device ID not found in 'devices' for status update (should not happen after ownership check).`);
    } else {
      console.log(`[CONTROL /api/devices/${deviceId}] User: ${userId}. Database status for '${deviceId}' updated to ${newStatus}.`);
    }

    res.json({ success: true, message: `Device ${deviceId} command sent.` });
  } catch (error) {
    console.error(`[CONTROL /api/devices/${deviceId}] User: ${userId}. Error: ${error.message}`, error.stack);
    res.status(500).json({ error: `Failed to control device ${deviceId}: ${error.message}` });
  }
});

// DELETE /api/devices/:deviceIdParam
app.delete('/api/devices/:deviceIdParam', authenticateToken, async (req, res) => {
  const deviceId = req.params.deviceIdParam;
  const userId = req.user.id;
  console.log(`[DELETE /api/devices/${deviceId}] User: ${userId}. Received request.`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    const device = await db.collection('devices').findOne({ id: deviceId, userId: new ObjectId(userId) });
    if (!device) {
      console.log(`[DELETE /api/devices/${deviceId}] User: ${userId}. Device not found or not owned by user.`);
      return res.status(404).json({ error: 'Device not found or you do not have permission to delete it.' });
    }

    const result = await db.collection('devices').deleteOne({ id: deviceId, userId: new ObjectId(userId) });
    // Also delete associated readings and daily consumptions for data integrity
    await db.collection(process.env.COLLECTION_NAME).deleteMany({ deviceId, userId: new ObjectId(userId) });
    await db.collection(DAILY_CONSUMPTION_COLLECTION).deleteMany({ deviceId, userId: new ObjectId(userId) }); // Delete daily summary too

    if (result.deletedCount === 0) {
      return res.status(404).json({ error: `Device with id '${deviceId}' not found for this user.` });
    }
    console.log(`[DELETE /api/devices/${deviceId}] User: ${userId}. Device deleted successfully.`);
    res.json({ success: true, message: `Device ${deviceId} deleted.` });
  } catch (error) {
    console.error(`[DELETE /api/devices/${deviceId}] User: ${userId}. Error: ${error.message}`, error.stack);
    res.status(500).json({ error: `Failed to delete device ${deviceId}: ${error.message}` });
  }
});

// PUT /api/devices/:deviceId/target - Set or update monthly consumption target for a device
app.put('/api/devices/:deviceId/target', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  const deviceId = req.params.deviceId;
  const { monthlyTargetWh: targetWh } = req.body; // Correctly destructure monthlyTargetWh

  console.log(`[TGT_PUT START] /api/devices/${deviceId}/target User: ${userId}. Body: ${JSON.stringify(req.body)}`);

  if (!db) {
    console.error("[TGT_PUT NO_DB_ERR] Database not initialized");
    return res.status(500).json({ error: 'Database not initialized' });
  }
  console.log("[TGT_PUT DB_OK] DB seems initialized.");

  if (typeof targetWh !== 'number' || targetWh < 0) {
    console.warn(`[TGT_PUT INVALID_TARGET_ERR] Invalid targetWh: ${targetWh}`);
    return res.status(400).json({ error: 'Valid targetWh (non-negative number) is required in request body' });
  }
  console.log("[TGT_PUT TARGET_VALID] targetWh is valid.");

  try {
    console.log(`[TGT_PUT TRY_ENTER] Attempting to find device: id=${deviceId}, userId=${userId}`);
    let userObjectId;
    try {
        userObjectId = new ObjectId(userId);
        console.log(`[TGT_PUT OBJECT_ID_OK] Converted userId to ObjectId: ${userObjectId}`);
    } catch (oidError) {
        console.error(`[TGT_PUT OBJECT_ID_ERR] Failed to convert userId '${userId}' to ObjectId:`, oidError);
        return res.status(400).json({ error: 'Invalid user ID format for query.' });
    }

    const device = await db.collection('devices').findOne({ id: deviceId, userId: userObjectId });
    console.log(`[TGT_PUT FIND_ONE_RESULT] Device found: ${device ? `Object(name:${device.name})` : 'null'}`);

    if (!device) {
      console.warn(`[TGT_PUT DEVICE_NOT_FOUND_WARN] User: ${userId}. Device id '${deviceId}' not found or not owned by user.`);
      return res.status(404).json({ error: 'Device not found or you do not have permission to update it.' });
    }
    console.log("[TGT_PUT DEVICE_FOUND_OK] Device found and owned by user.");

    const result = await db.collection('devices').updateOne(
      { id: deviceId, userId: userObjectId }, // Use userObjectId here too
      { $set: { monthlyTargetWh: targetWh, updatedAt: new Date() } }
    );
    console.log(`[TGT_PUT UPDATE_ONE_RESULT] Matched: ${result.matchedCount}, Modified: ${result.modifiedCount}`);

    if (result.matchedCount > 0) {
      // Successfully found the device. It might or might not have been modified
      // (e.g., if the targetWh was already the same). This is still a success.
      console.log(`[TGT_PUT SUCCESS] User: ${userId}. Monthly target processed. New target: ${targetWh}Wh.`);
      res.json({ success: true, message: `Monthly target for device ${deviceId} updated to ${targetWh}Wh.` });
    } else {
      // This case should ideally be caught by the `!device` check earlier.
      // If it reaches here, it means findOne found it, but updateOne didn't match, which is strange.
      console.error(`[TGT_PUT UPDATE_FAIL_WARN] User: ${userId}. Update matched 0 documents, though device was initially found. This is unexpected.`);
      return res.status(404).json({ error: 'Device not found for update (unexpected after initial check).' });
    }
  } catch (err) {
    console.error(`[TGT_PUT CATCH_ERR] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to update monthly target for device ${deviceId}: ${err.message}` });
  }
});
// GET /api/devices/:deviceIdParam/stats
// Fetches consumption statistics (today, yesterday, this month) for a specific device.
app.get('/api/devices/:deviceIdParam/stats', authenticateToken, async (req, res) => {
  const deviceId = req.params.deviceIdParam;
  const userId = req.user.id;
  console.log(`[API /api/devices/${deviceId}/stats] User: ${userId}. Received request.`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    const deviceDoc = await db.collection('devices').findOne({ id: deviceId, userId: new ObjectId(userId) });
    if (!deviceDoc) {
      console.log(`[API /api/devices/${deviceId}/stats] User: ${userId}. Device not found or not owned by user.`);
      return res.status(404).json({ error: 'Device not found or you do not have permission to view its stats.' });
    }

    const now = new Date();
    // Fetch daily consumption in Wh for the specific device from DAILY_CONSUMPTION_COLLECTION
    const todayConsumed = await getDeviceDailyConsumption(deviceId, userId, getCurrentDateString(now));
    const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
    const yesterdayConsumed = await getDeviceDailyConsumption(deviceId, userId, getCurrentDateString(yesterday));
    
    let thisMonthConsumed = 0;
    const monthDates = getDatesForCurrentMonth(now);
    for (const dateStr of monthDates) {
        thisMonthConsumed += await getDeviceDailyConsumption(deviceId, userId, dateStr);
    }

    // 'allTimeConsumed' is a placeholder. A robust calculation would require summing
    // all historical 'estimatedEnergyWhToday' records for this device.
    const allTimeConsumed = 0; 

    res.json({
      todayConsumed: parseFloat(todayConsumed.toFixed(3)),
      yesterdayConsumed: parseFloat(yesterdayConsumed.toFixed(3)),
      status: deviceDoc?.status || false,
      thisMonthConsumed: parseFloat(thisMonthConsumed.toFixed(3)),
      allTimeConsumed: parseFloat(Math.max(0, allTimeConsumed).toFixed(3)),
    });
  } catch (err) {
    console.error(`[API /api/devices/${deviceId}/stats] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
});

// Helper for device specific daily consumption from DAILY_CONSUMPTION_COLLECTION
async function getDeviceDailyConsumption(deviceId, userId, dateString) {
  if (!db) throw new Error("Database not initialized for getDeviceDailyConsumption");
  const dailyRec = await db.collection(DAILY_CONSUMPTION_COLLECTION)
    .findOne({ deviceId, userId: new ObjectId(userId), dateString: dateString });
  return dailyRec?.estimatedEnergyWhToday || 0; // Returns energy in Wh
}

// GET /api/devices/:deviceIdParam/daily-history
// Fetches daily consumption history for a specific device over a number of days.
async function fetchDeviceDailyHistoryLogic(req, res) {
  const deviceId = req.params.deviceIdParam || req.params.deviceId; // Handle both param names
  const userId = req.user.id;
  const daysParam = parseInt(req.query.days) || 7;
  console.log(`[API DeviceDailyHistoryLogic for ${deviceId}] User: ${userId}. Request for ${daysParam} days.`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    const deviceDoc = await db.collection('devices').findOne({ id: deviceId, userId: new ObjectId(userId) });
    if (!deviceDoc) {
      console.log(`[API /api/devices/${deviceId}/daily-history] User: ${userId}. Device not found or not owned by user.`);
      return res.status(404).json({ error: 'Device not found or you do not have permission to view its history.' });
    }

    const dailyHistory = [];
    const today = new Date();
    for (let i = 0; i < daysParam; i++) {
      const targetDate = new Date(today);
      targetDate.setDate(today.getDate() - i);
      // Fetch consumed energy in Wh for the specific device and date from DAILY_CONSUMPTION_COLLECTION
      const consumedOnDay = await getDeviceDailyConsumption(deviceId, userId, getCurrentDateString(targetDate));
      
      dailyHistory.push({
        date: targetDate.toISOString().split('T')[0], // Format date as YYYY-MM-DD
        consumed: parseFloat(Math.max(0, consumedOnDay).toFixed(3)), // Energy in Wh
      });
    }
    res.json(dailyHistory.reverse()); // Reverse to show most recent day last
  } catch (err) {
    console.error(`[API DeviceDailyHistoryLogic for ${deviceId}] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: err.message });
  }
}

app.get('/api/devices/:deviceIdParam/daily-history', authenticateToken, fetchDeviceDailyHistoryLogic);

app.get('/api/power/history/:deviceId', authenticateToken, fetchDeviceDailyHistoryLogic);

// --- Notification Helper ---
async function createNotification(userId, message, type, options = {}) {
  if (!db) {
    console.error("[Notification] Database not initialized. Cannot create notification.");
    return null;
  }
  try {
    const { deviceId = null, deviceName = null, severity = 'info', isRead = false } = options;
    const notification = {
      userId: new ObjectId(userId),
      message,
      type,
      timestamp: new Date(),
      isRead,
      severity,
    };
    if (deviceId) notification.deviceId = deviceId;
    if (deviceName) notification.deviceName = deviceName;

    const result = await db.collection(NOTIFICATIONS_COLLECTION).insertOne(notification);
    console.log(`[Notification Created] User: ${userId}, Type: ${type}, Msg: ${message.substring(0, 50)}...`);
    
    // Note: Pushing WebSocket notifications from server.js would require access to activeWsConnections
    // or a shared messaging system (e.g., Redis pub/sub) if mqttSubscriber.js owns the WebSocket connections.
    // For now, server.js generated notifications will be fetched via API.
    return result.insertedId ? { ...notification, _id: result.insertedId } : null;
  } catch (error) {
    console.error(`[Notification Create Error] User ${userId}, Type: ${type}:`, error);
    return null;
  }
}

// --- Notification API Endpoints ---

// GET /api/notifications - Fetches notifications for the user
app.get('/api/notifications', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  const limit = parseInt(req.query.limit) || 20;
  const page = parseInt(req.query.page) || 1;
  const skip = (page - 1) * limit;

  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const notifications = await db.collection(NOTIFICATIONS_COLLECTION)
      .find({ userId: new ObjectId(userId) })
      .sort({ timestamp: -1 })
      .skip(skip)
      .limit(limit)
      .toArray();
    
    const totalNotifications = await db.collection(NOTIFICATIONS_COLLECTION).countDocuments({ userId: new ObjectId(userId) });
    
    res.json({
      notifications,
      totalPages: Math.ceil(totalNotifications / limit),
      currentPage: page,
      totalCount: totalNotifications
    });
  } catch (err) {
    console.error(`[API /api/notifications] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to load notifications: ${err.message}` });
  }
});

// POST /api/notifications/:notificationId/mark-read
app.post('/api/notifications/:notificationId/mark-read', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  const notificationId = req.params.notificationId;
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });
    const result = await db.collection(NOTIFICATIONS_COLLECTION).updateOne(
      { _id: new ObjectId(notificationId), userId: new ObjectId(userId) },
      { $set: { isRead: true } }
    );
    if (result.matchedCount === 0) return res.status(404).json({ error: 'Notification not found or not owned by user.' });
    res.json({ success: true, message: 'Notification marked as read.' });
  } catch (err) {
    console.error(`[API /api/notifications/mark-read] User: ${userId}, NotifID: ${notificationId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to mark notification as read: ${err.message}` });
  }
});

// --- New Statistics Endpoints ---

// GET /api/statistics/device-breakdown?period=<today|current_week|current_month>
// Fetches energy consumption breakdown by device for a given period.
app.get('/api/statistics/device-breakdown', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  const period = req.query.period || 'today'; // Default to today
  console.log(`[API /api/statistics/device-breakdown] User: ${userId}, Period: ${period}`);

  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    const userDevices = await db.collection('devices').find({ userId: new ObjectId(userId) }).toArray();
    if (userDevices.length === 0) {
      return res.json([]);
    }

    const breakdown = [];
    const today = new Date();
    let dateStringsForPeriod = [];

    if (period === 'today') {
      dateStringsForPeriod.push(getCurrentDateString(today));
    } else if (period === 'current_week') {
      dateStringsForPeriod = getDatesForCurrentWeek(today);
    } else if (period === 'current_month') {
      dateStringsForPeriod = getDatesForCurrentMonth(today);
    } else {
      return res.status(400).json({ error: 'Invalid period specified. Use today, current_week, or current_month.' });
    }

    for (const device of userDevices) {
      let deviceTotalConsumptionWh = 0;
      for (const dateStr of dateStringsForPeriod) {
        deviceTotalConsumptionWh += await getDeviceDailyConsumption(device.id, userId, dateStr);
      }
      if (deviceTotalConsumptionWh > 0) { // Only include devices with consumption
        breakdown.push({
          deviceId: device.id,
          deviceName: device.name,
          consumedWh: parseFloat(deviceTotalConsumptionWh.toFixed(3))
        });
      }
    }

    // Sort by consumption, descending
    breakdown.sort((a, b) => b.consumedWh - a.consumedWh);
    res.json(breakdown);

  } catch (err) {
    console.error(`[API /api/statistics/device-breakdown] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to load device breakdown: ${err.message}` });
  }
});

// GET /api/statistics/consumption-comparison
// Fetches consumption for current period vs previous period (day, week, month)
app.get('/api/statistics/consumption-comparison', authenticateToken, async (req, res) => {
  const userId = req.user.id;
  console.log(`[API /api/statistics/consumption-comparison] User: ${userId}`);
  try {
    if (!db) return res.status(500).json({ error: 'Database not initialized' });

    const today = new Date();
    const yesterday = new Date(today); yesterday.setDate(today.getDate() - 1);
    const startOfThisWeek = new Date(today); startOfThisWeek.setDate(today.getDate() - today.getDay());
    const startOfLastWeek = new Date(startOfThisWeek); startOfLastWeek.setDate(startOfThisWeek.getDate() - 7);
    const startOfThisMonth = new Date(today.getFullYear(), today.getMonth(), 1);
    const startOfLastMonth = new Date(today.getFullYear(), today.getMonth() - 1, 1);

    const comparisons = {};

    // Daily
    comparisons.daily = {
      current: await getSystemDailyConsumptionForDate(userId, getCurrentDateString(today)),
      previous: await getSystemDailyConsumptionForDate(userId, getCurrentDateString(yesterday))
    };

    // Weekly
    let thisWeekTotal = 0;
    for (const dateStr of getDatesForCurrentWeek(today)) { thisWeekTotal += await getSystemDailyConsumptionForDate(userId, dateStr); }
    let lastWeekTotal = 0;
    for (const dateStr of getDatesForCurrentWeek(new Date(startOfLastWeek.setDate(startOfLastWeek.getDate() + 6)))) { lastWeekTotal += await getSystemDailyConsumptionForDate(userId, dateStr); } // end of last week
    comparisons.weekly = { current: thisWeekTotal, previous: lastWeekTotal };

    // Monthly
    let thisMonthTotal = 0;
    for (const dateStr of getDatesForCurrentMonth(today)) { thisMonthTotal += await getSystemDailyConsumptionForDate(userId, dateStr); }
    let lastMonthTotal = 0;
    const endOfLastMonth = new Date(startOfThisMonth.getFullYear(), startOfThisMonth.getMonth(), 0); // Last day of previous month
    for (const dateStr of getDatesForCurrentMonth(endOfLastMonth)) { lastMonthTotal += await getSystemDailyConsumptionForDate(userId, dateStr); }
    comparisons.monthly = { current: thisMonthTotal, previous: lastMonthTotal };

    res.json(comparisons);
  } catch (err) {
    console.error(`[API /api/statistics/consumption-comparison] User: ${userId}. Error: ${err.message}`, err.stack);
    res.status(500).json({ error: `Failed to load consumption comparison: ${err.message}` });
  }
});

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
    startOfWeek.setDate(currentDate.getDate() - dayOfWeek); // Adjust to start of week (Sunday)
    startOfWeek.setHours(0,0,0,0);

    for (let i = 0; i < 7; i++) {
        const dateInWeek = new Date(startOfWeek);
        dateInWeek.setDate(startOfWeek.getDate() + i);
        if (dateInWeek <= currentDate) {
            dates.push(getCurrentDateString(dateInWeek));
        }
    }
    return dates;
}

function getDatesForCurrentMonth(currentDate = new Date()) {
    const dates = [];
    const daysInMonth = new Date(currentDate.getFullYear(), currentDate.getMonth() + 1, 0).getDate();
    for (let i = 1; i <= Math.min(daysInMonth, currentDate.getDate()) ; i++) {
        dates.push(getCurrentDateString(new Date(currentDate.getFullYear(), currentDate.getMonth(), i)));
    }
    return dates;
}

// --- Interval job to update device_status (mark as offline) ---
setInterval(async () => {
  if (db) {
    const offlineThresholdMinutes = 2; // Configurable: e.g., 2 minutes
    const offlineThreshold = new Date(Date.now() - (offlineThresholdMinutes * 60 * 1000));
    try {
      // Find devices that were online but haven't been seen recently
      const devicesToMarkOffline = await db.collection('device_status').find(
        { lastSeen: { $lt: offlineThreshold }, online: true }
      ).project({ deviceId: 1, _id: 0 }).toArray();

      if (devicesToMarkOffline.length > 0) {
        const deviceIdsToUpdate = devicesToMarkOffline.map(d => d.deviceId);
        const updateResult = await db.collection('device_status').updateMany(
          { deviceId: { $in: deviceIdsToUpdate }, online: true }, // Ensure we only update those currently marked online
          { $set: { online: false, lastOfflineTimestamp: new Date() } }
        );

        if (updateResult.modifiedCount > 0) {
          console.log(`[Interval DB] Marked ${updateResult.modifiedCount} devices as offline.`);
          for (const dev of devicesToMarkOffline) {
            const deviceDetails = await db.collection('devices').findOne({ id: dev.deviceId });
            if (deviceDetails) {
              await createNotification(
                deviceDetails.userId.toString(), // Ensure userId is a string if createNotification expects it
                `${deviceDetails.name || dev.deviceId} went offline. Last seen over ${offlineThresholdMinutes} minutes ago.`,
                'device_offline',
                { deviceId: dev.deviceId, deviceName: deviceDetails.name, severity: 'warning' }
              );
            }
          }
        }
      }
    } catch (err) {
      console.error('[Interval DB] Error updating device_status for offline devices:', err.message);
    }
  }
}, 60000); // Runs every minute

// --- Interval job for advanced notifications (goals, comparisons) ---
const ADVANCED_NOTIFICATIONS_CHECK_INTERVAL = 6 * 60 * 60 * 1000; // Every 6 hours

async function checkAdvancedNotifications() {
  if (!db) {
    console.log('[AdvancedNotif Check] DB not initialized. Skipping.');
    return;
  }
  console.log('[AdvancedNotif Check] Starting check for advanced notifications.');

  try {
    const users = await db.collection('users').find({}, { projection: { _id: 1, name: 1 } }).toArray();

    for (const user of users) {
      const userIdString = user._id.toString();

      // 1. Daily Consumption Goal Exceeded (System-Wide)
      const yesterday = new Date();
      yesterday.setDate(yesterday.getDate() - 1);
      const yesterdayString = getCurrentDateString(yesterday);
      const systemConsumptionYesterday = await getSystemDailyConsumptionForDate(userIdString, yesterdayString);
      
      // Placeholder: Assume a user-defined goal or a default.
      // In a real app, this would come from user settings.
      const dailySystemGoalWh = 5000; // Example: 5 kWh

      if (systemConsumptionYesterday > dailySystemGoalWh) {
        // Check if a similar notification was sent recently to avoid spam
        const recentNotif = await db.collection(NOTIFICATIONS_COLLECTION).findOne({
          userId: user._id,
          type: 'goal_exceeded_system_daily',
          timestamp: { $gte: new Date(Date.now() - 24 * 60 * 60 * 1000) } // Within last 24h
        });
        if (!recentNotif) {
          await createNotification(
            userIdString,
            `Heads up! Yesterday's total energy use (${(systemConsumptionYesterday / 1000).toFixed(2)} kWh) exceeded your daily goal of ${(dailySystemGoalWh / 1000).toFixed(1)} kWh.`,
            'goal_exceeded_system_daily',
            { severity: 'warning' }
          );
        }
      }

      // 2. Weekly Savings Achieved (System-Wide)
      const today = new Date();
      const startOfThisWeek = new Date(today); startOfThisWeek.setDate(today.getDate() - today.getDay()); startOfThisWeek.setHours(0,0,0,0);
      const startOfLastWeek = new Date(startOfThisWeek); startOfLastWeek.setDate(startOfThisWeek.getDate() - 7);
      
      let thisWeekSoFarWh = 0;
      for (const dateStr of getDatesForCurrentWeek(today)) { thisWeekSoFarWh += await getSystemDailyConsumptionForDate(userIdString, dateStr); }
      
      let lastFullWeekWh = 0;
      const lastWeekDates = [];
      for (let i=0; i<7; i++) { const d = new Date(startOfLastWeek); d.setDate(startOfLastWeek.getDate() + i); lastWeekDates.push(getCurrentDateString(d));}
      for (const dateStr of lastWeekDates) { lastFullWeekWh += await getSystemDailyConsumptionForDate(userIdString, dateStr); }

      if (lastFullWeekWh > 0 && thisWeekSoFarWh < lastFullWeekWh * (today.getDay() + 1) / 7 * 0.9) { // If current usage is <90% of pro-rated last week
        // Add similar spam prevention as above if needed
        // For simplicity, we'll skip it here for this example
        // await createNotification(userIdString, `Energy Saver! You're on track to use less energy this week compared to last. Keep it up!`, 'weekly_savings_achieved_system', { severity: 'success' });
      }
    }
  } catch (err) {
    console.error('[AdvancedNotif Check] Error during advanced notification check:', err.message, err.stack);
  }
}

// --- Start Server ---
const startServer = async () => {
  try {
    await mongoClient.connect();
    db = mongoClient.db(process.env.DB_NAME);
    console.log('[Server.js] Connected to MongoDB.');
    console.log(`[Server.js] Using collection for power/energy readings: "${process.env.COLLECTION_NAME}"`);

    // Ensure necessary indexes for performance and data integrity
    try {
      await db.collection('users').createIndex({ email: 1 }, { unique: true });
      console.log("[Server.js] Index created/ensured on 'users.email'.");
    } catch (indexError) { console.warn("[Server.js] Could not create index on 'users.email' (may already exist):", indexError.message); }

    try {
      await db.collection('devices').createIndex({ id: 1 }, { unique: true });
      console.log("[Server.js] Index created/ensured on 'devices.id' (globally unique).");
    } catch (indexError) {
      console.warn("[Server.js] Could not create unique index on 'devices.id' (may already exist):", indexError.message);
    }
    try {
      await db.collection('devices').createIndex({ userId: 1 });
      console.log("[Server.js] Index created/ensured on 'devices.userId'.");
    } catch (indexError) { console.warn("[Server.js] Could not create index on 'devices.userId':", indexError.message); }

    try {
      // Removed: mqttSubscriber.js already creates a unique index on device_status.deviceId
      // await db.collection('device_status').createIndex({ deviceId: 1 });
      console.log("[Server.js] Skipping index creation for 'device_status.deviceId' as mqttSubscriber handles it.");
    } catch (indexError) { console.warn("[Server.js] Could not create index on 'device_status.deviceId':", indexError.message); }
    try {
      await db.collection(process.env.COLLECTION_NAME).createIndex({ userId: 1, deviceId: 1, timeStamp: -1 });
      console.log(`[Server.js] Index created/ensured on '${process.env.COLLECTION_NAME}' for userId, deviceId, and timeStamp.`);
    } catch (indexError) {
      console.warn(`[Server.js] Could not create compound index on '${process.env.COLLECTION_NAME}' (may already exist):`, indexError.message);
    }

    try {
      await db.collection(DAILY_CONSUMPTION_COLLECTION).createIndex({ userId: 1, deviceId: 1, dateString: 1 }, { unique: true });
      console.log("[Server.js] Index created/ensured on 'daily_device_consumptions'.");
    } catch (indexError) {
      console.warn("[Server.js] Could not create unique index on 'daily_device_consumptions' (may already exist):", indexError.message);
    }

    try {
      await db.collection(NOTIFICATIONS_COLLECTION).createIndex({ userId: 1, timestamp: -1 });
      await db.collection(NOTIFICATIONS_COLLECTION).createIndex({ userId: 1, isRead: 1, timestamp: -1 });
      console.log("[Server.js] Indexes created/ensured on 'notifications'.");
    } catch (indexError) {
      console.warn("[Server.js] Could not create indexes on 'notifications' (may already exist):", indexError.message);
    }

    const PORT = process.env.PORT || 3001;
    app.listen(PORT, '0.0.0.0', () => {
      console.log(`[Server.js] API running on port ${PORT} and accessible externally.`);
    });

    // Start the advanced notification check interval
    setInterval(checkAdvancedNotifications, ADVANCED_NOTIFICATIONS_CHECK_INTERVAL);
    checkAdvancedNotifications(); // Run once on startup after a delay
  } catch (err) {
    console.error('[Server.js] Failed to connect to MongoDB or start server:', err.message, err.stack);
    process.exit(1);
  }
};
startServer();
