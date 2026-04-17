import { getDatabase, toObjectId } from "./mongo.js";

export async function getConversation(conversationId) {
  if (!conversationId) {
    return null;
  }

  const db = await getDatabase();
  return db.collection("conversations").findOne({ _id: toObjectId(conversationId) });
}

export async function createConversation({ conversationId, userInput }) {
  const db = await getDatabase();
  const _id = toObjectId(conversationId);
  const now = new Date();

  const document = {
    _id,
    title: userInput.slice(0, 120),
    createdAt: now,
    updatedAt: now,
    latestUserInput: userInput,
    status: "active"
  };

  await db.collection("conversations").updateOne(
    { _id },
    { $setOnInsert: document, $set: { updatedAt: now, latestUserInput: userInput } },
    { upsert: true }
  );

  return { ...document, _id };
}

export async function appendActionHistory({
  conversationId,
  iteration,
  userInput,
  agentThought,
  action,
  result,
  status
}) {
  const db = await getDatabase();
  const now = new Date();

  await db.collection("action_history").insertOne({
    conversationId: toObjectId(conversationId),
    iteration,
    userInput,
    agentThought,
    action,
    result,
    status,
    createdAt: now
  });

  await db.collection("conversations").updateOne(
    { _id: toObjectId(conversationId) },
    { $set: { updatedAt: now, status, latestUserInput: userInput } }
  );
}

export async function getRecentHistory(conversationId, limit = 12) {
  if (!conversationId) {
    return [];
  }

  const db = await getDatabase();
  return db
    .collection("action_history")
    .find({ conversationId: toObjectId(conversationId) })
    .sort({ createdAt: -1 })
    .limit(limit)
    .toArray();
}
