import { MongoClient, ObjectId } from "mongodb";

let clientPromise;

function getClient() {
  if (!clientPromise) {
    const uri = process.env.MONGODB_URI;
    if (!uri) {
      throw new Error("MONGODB_URI is not configured.");
    }
    clientPromise = MongoClient.connect(uri);
  }
  return clientPromise;
}

export async function getDatabase() {
  const client = await getClient();
  const databaseName = process.env.MONGODB_DB || "meet_ai";
  return client.db(databaseName);
}

export async function ensureIndexes() {
  const db = await getDatabase();
  await db.collection("conversations").createIndex({ updatedAt: -1 });
  await db.collection("action_history").createIndex({ conversationId: 1, createdAt: 1 });
}

export function toObjectId(value) {
  return value ? new ObjectId(value) : new ObjectId();
}
