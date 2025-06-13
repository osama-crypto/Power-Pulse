import dotenv from 'dotenv';
dotenv.config();
import fs from 'fs';
import axios from 'axios';
import { MongoClient, ObjectId } from 'mongodb'; // Import ObjectId

const mongoUriCloud = process.env.MONGO_URI_CLOUD;
const dbName = process.env.DB_NAME;
const powerReadingsCollectionName = process.env.COLLECTION_NAME; // Collection for power/energy readings
const dbFilePath = './db.json'; // Local file for unsynced data

console.log(`[Sync Service] Using collection for power/energy readings: "${powerReadingsCollectionName}"`);

const isConnectedToInternet = async () => {
  try {
    await axios.get('https://www.google.com', { timeout: 5000 });
    return true;
  } catch {
    return false;
  }
};

const readLocalData = () => {
  if (!fs.existsSync(dbFilePath)) return [];
  try {
    const rawData = fs.readFileSync(dbFilePath, 'utf-8');
    if (rawData.trim() === "") return []; // Handle empty file
    const jsonData = JSON.parse(rawData);
    // Ensure data is an array and items have deviceId and timeStamp
    return Array.isArray(jsonData) ? jsonData.filter(item => {
        // console.log("[Sync Service] Reading item from local DB:", JSON.stringify(item)); // For debugging
        return item.deviceId && item.timeStamp; // userId is optional for old data but good to have for new
    }) : [];
  } catch (err) {
    console.error('[Sync Service] Error reading local data file:', err.message);
    return [];
  }
};

const clearLocalData = () => {
  try {
    fs.writeFileSync(dbFilePath, JSON.stringify([])); // Write an empty array
    console.log('[Sync Service] Local data file cleared.');
  } catch (err) {
    console.error('[Sync Service] Error clearing local data file:', err.message);
  }
};

const syncDataToMongoDB = async () => {
  if (!(await isConnectedToInternet())) {
    console.log('[Sync Service] Offline. Skipping sync attempt.');
    return;
  }

  const localData = readLocalData();
  if (localData.length === 0) {
    // console.log('[Sync Service] No local data to sync.');
    return;
  }

  let client;
  try {
    client = new MongoClient(mongoUriCloud);
    await client.connect();
    const db = client.db(dbName);
    const collection = db.collection(powerReadingsCollectionName);

    // Convert timeStamp strings back to Date objects and userId string to ObjectId
    const dataToSync = localData.map(item => ({
      ...item,
      timeStamp: new Date(item.timeStamp), // Crucial for MongoDB date queries
      // Convert userId string back to ObjectId if it exists and is a string
      userId: item.userId && typeof item.userId === 'string' ? new ObjectId(item.userId) : item.userId
    }));

    console.log(`[Sync Service] Attempting to sync ${dataToSync.length} records.`);
    // For debugging, log the first item to be synced
    // if (dataToSync.length > 0) {
    //   console.log("[Sync Service] First item to sync:", JSON.stringify(dataToSync[0]));
    // }

    const result = await collection.insertMany(dataToSync, { ordered: false }); // ordered:false allows partial success
    console.log(`[Sync Service] Synced ${result.insertedCount} of ${localData.length} readings to MongoDB.`);
    
    // If all were inserted, clear local data. 
    // A more robust solution for partial success would be to remove only successfully synced items.
    // For now, if any items were inserted, we assume the batch was processed and clear.
    if (result.insertedCount > 0) {
        clearLocalData();
    }

  } catch (err) {
    console.error('[Sync Service] Sync to MongoDB failed:', err.message);
    if (err.writeErrors) {
        err.writeErrors.forEach(e => console.error(`[Sync Service] Write Error Detail: Index ${e.index}, Code ${e.code}, Message: ${e.errmsg}`));
    }
    // Don't clear local data if sync failed entirely or partially in a way we can't easily reconcile
  } finally {
    if (client) {
      await client.close();
    }
  }
};

// Run sync check periodically
const syncInterval = 60000; // Sync every 60 seconds
setInterval(syncDataToMongoDB, syncInterval);
console.log(`[Sync Service] Started. Will attempt to sync every ${syncInterval / 1000} seconds.`);

// Initial sync attempt on startup after a short delay
setTimeout(syncDataToMongoDB, 5000);
