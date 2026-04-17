import {
  appendActionHistory,
  createConversation,
  getConversation,
  getRecentHistory
} from "./repositories.js";

const MAX_ITERATIONS = 5;

export async function runAgentTurn(payload) {
  const {
    conversationId,
    input,
    history = [],
    lastActionResult,
    iteration = 0
  } = payload;

  if (!input || !input.trim()) {
    throw new Error("`input` is required.");
  }

  if (iteration >= MAX_ITERATIONS) {
    return {
      conversationId,
      iteration,
      thought: "Reached the maximum iteration limit.",
      action: {
        type: "done",
        command: "I hit the safety limit for this task. Please refine the request or continue manually."
      }
    };
  }

  const conversation = (await getConversation(conversationId)) ?? (await createConversation({ conversationId, userInput: input }));
  const memory = await getRecentHistory(conversation._id.toString());

  const prompt = buildPrompt({
    input,
    history,
    memory,
    lastActionResult,
    iteration
  });

  const raw = await callGemini(prompt);
  const parsed = parseAgentJSON(raw);

  await appendActionHistory({
    conversationId: conversation._id.toString(),
    iteration,
    userInput: input,
    agentThought: parsed.thought,
    action: parsed.action,
    result: lastActionResult ?? null,
    status: parsed.action.type === "done" ? "completed" : "active"
  });

  return {
    conversationId: conversation._id.toString(),
    iteration: iteration + 1,
    thought: parsed.thought,
    action: parsed.action
  };
}

function buildPrompt({ input, history, memory, lastActionResult, iteration }) {
  const compactMemory = memory
    .reverse()
    .map((entry) => ({
      iteration: entry.iteration,
      userInput: entry.userInput,
      thought: entry.agentThought,
      action: entry.action,
      result: entry.result,
      status: entry.status
    }));

  return `
You are the backend agent for a macOS AI desktop assistant.

Your job:
- reason about the user's goal
- decide the next single action
- keep actions minimal and safe
- ask the user when the task is ambiguous
- stop once the task is done

Return JSON only in this exact shape:
{
  "thought": "short reasoning",
  "action": {
    "type": "shell | applescript | ask_user | done",
    "command": "the command, question, or final response"
  }
}

Rules:
- Output exactly one action.
- Prefer shell for local system operations.
- Prefer applescript for app control.
- Use ask_user if information is missing.
- Use done when no further execution is needed.
- Never emit destructive commands unless absolutely necessary; if you do, keep them explicit so the client can ask for approval.
- Do not use markdown fences.

Current iteration: ${iteration + 1} of ${MAX_ITERATIONS}
User request: ${input}
Last action result: ${JSON.stringify(lastActionResult ?? null)}
Client-provided history: ${JSON.stringify(history)}
Mongo memory: ${JSON.stringify(compactMemory)}
`.trim();
}

async function callGemini(prompt) {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) {
    throw new Error("GEMINI_API_KEY is not configured.");
  }

  const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      contents: [
        {
          parts: [{ text: prompt }]
        }
      ],
      generationConfig: {
        responseMimeType: "application/json"
      }
    })
  });

  const json = await response.json();

  if (!response.ok) {
    const message = json?.error?.message || "Unknown Gemini API error.";
    throw new Error(`Gemini request failed: ${message}`);
  }

  const text = json?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) {
    throw new Error("Gemini returned an empty agent response.");
  }

  return text;
}

function parseAgentJSON(raw) {
  let parsed;

  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Agent response was not valid JSON.");
  }

  if (!parsed?.thought || !parsed?.action?.type) {
    throw new Error("Agent response is missing required fields.");
  }

  const type = parsed.action.type;
  if (!["shell", "applescript", "ask_user", "done"].includes(type)) {
    throw new Error(`Unsupported agent action type: ${type}`);
  }

  return {
    thought: String(parsed.thought),
    action: {
      type,
      command: String(parsed.action.command ?? "")
    }
  };
}
