import "dotenv/config";
import express from "express";
import { ensureIndexes } from "./mongo.js";
import { runAgentTurn } from "./agentService.js";

const app = express();
app.use(express.json({ limit: "1mb" }));

app.get("/health", async (_request, response) => {
  response.json({ ok: true });
});

app.post("/agent", async (request, response) => {
  try {
    const result = await runAgentTurn(request.body);
    response.json(result);
  } catch (error) {
    response.status(400).json({
      error: error instanceof Error ? error.message : "Unknown backend error."
    });
  }
});

const port = Number(process.env.PORT || 8787);

ensureIndexes()
  .then(() => {
    app.listen(port, () => {
      console.log(`Meet AI agent backend listening on http://127.0.0.1:${port}`);
    });
  })
  .catch((error) => {
    console.error("Failed to start backend:", error);
    process.exit(1);
  });
