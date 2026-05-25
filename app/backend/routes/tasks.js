/**
 * routes/tasks.js — CRUD REST API Route Handlers
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHAT THIS FILE DOES
 * ═══════════════════════════════════════════════════════════════════════════
 * Defines all HTTP route handlers for the /api/tasks endpoint.
 * Each route handler implements one CRUD operation:
 *
 *   POST   /api/tasks         → Create a new task (C)
 *   GET    /api/tasks         → Read all tasks    (R)
 *   PUT    /api/tasks/:id     → Update a task     (U)
 *   DELETE /api/tasks/:id     → Delete a task     (D)
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * EXPRESS ROUTER PATTERN
 * ═══════════════════════════════════════════════════════════════════════════
 * We use express.Router() to create a modular, mountable route handler.
 * This router is exported and mounted in index.js at:
 *   app.use("/api/tasks", taskRouter)
 *
 * This means:
 *   router.post("/")       → handles POST /api/tasks
 *   router.get("/")        → handles GET  /api/tasks
 *   router.put("/:id")     → handles PUT  /api/tasks/<mongoId>
 *   router.delete("/:id")  → handles DELETE /api/tasks/<mongoId>
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * KUBERNETES TRAFFIC FLOW TO THIS FILE
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Browser/Frontend
 *     │ POST http://<ALB>/api/tasks
 *     ▼
 * ALB Ingress (routes /api/* to backend-service)
 *     │
 *     ▼
 * backend-service (ClusterIP → round-robin to backend pods)
 *     │
 *     ▼
 * Backend Pod (Node.js process)
 *     │
 *     ▼ express app receives request
 * index.js middleware chain:
 *   1. express.json()   → parses JSON body
 *   2. cors()           → adds CORS headers
 *   3. /api/tasks router → reaches THIS file
 *     │
 *     ▼
 * Task.save() → mongoose → MongoDB pod (via mongo-service ClusterIP:27017)
 *     │
 *     ▼
 * MongoDB writes to /data/db → EBS PersistentVolume (survives pod restarts)
 */

"use strict";

const Task = require("../models/task");
const express = require("express");

// express.Router() creates a mini Express application that can handle routes.
// It's like a sub-application, which can be mounted at a specific path in index.js.
const router = express.Router();

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/tasks — Create a new Task
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Request Body (JSON):
 *   { "task": "Deploy Prometheus to EKS" }
 *
 * Success Response (201 Created):
 *   {
 *     "_id":       "64a3f1b2c0e789...",
 *     "task":      "Deploy Prometheus to EKS",
 *     "completed": false,
 *     "createdAt": "2026-05-25T14:00:00.000Z",
 *     "updatedAt": "2026-05-25T14:00:00.000Z"
 *   }
 *
 * Error Response (400 Bad Request — Mongoose ValidationError):
 *   { "message": "Task description is required" }
 *
 * WHAT new Task(req.body).save() DOES:
 *   1. new Task(req.body)  → Creates a Mongoose document instance from the body
 *   2. Mongoose validates the document against taskSchema
 *   3. .save()             → INSERT into MongoDB "tasks" collection
 *   4. Returns the saved document with _id, timestamps populated
 */
router.post("/", async (req, res) => {
  try {
    // Mongoose validates req.body against taskSchema before saving
    // If validation fails (e.g., missing 'task' field), it throws a ValidationError
    const task = await new Task(req.body).save();

    // 201 Created is more semantically correct than 200 OK for resource creation
    res.status(201).json(task);
  } catch (error) {
    // Distinguish validation errors (client's fault) from server errors
    if (error.name === "ValidationError") {
      return res.status(400).json({ message: error.message });
    }
    // 500 for unexpected server/DB errors
    res.status(500).json({ message: "Failed to create task", error: error.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/tasks — Read all Tasks
// ─────────────────────────────────────────────────────────────────────────────
/**
 * No request body needed. Fetches all tasks from MongoDB.
 *
 * Success Response (200 OK):
 *   [
 *     { "_id": "...", "task": "...", "completed": false, "createdAt": "...", "updatedAt": "..." },
 *     { "_id": "...", "task": "...", "completed": true,  "createdAt": "...", "updatedAt": "..." }
 *   ]
 *
 * Empty DB Response (200 OK):
 *   []   ← Returns empty array, not 404
 *
 * PERFORMANCE NOTE FOR K8S SCALE:
 * Task.find({}) fetches ALL tasks with no limit. For large datasets this is
 * problematic. Production improvement: add pagination.
 *   Task.find({}).skip(offset).limit(20).sort({ createdAt: -1 })
 *
 * .lean() optimization (not in reference, worth knowing):
 *   Task.find({}).lean() returns plain JS objects instead of Mongoose documents.
 *   This is 2-3x faster for read-only operations since Mongoose skips
 *   object hydration (attaching save(), validate(), etc. methods).
 */
router.get("/", async (req, res) => {
  try {
    // {} means "match all documents" — no filter
    // Sort by createdAt ascending so oldest tasks appear first (consistent UX)
    const tasks = await Task.find({}).sort({ createdAt: 1 });
    res.status(200).json(tasks);
  } catch (error) {
    res.status(500).json({ message: "Failed to fetch tasks", error: error.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PUT /api/tasks/:id — Update a Task (toggle completed)
// ─────────────────────────────────────────────────────────────────────────────
/**
 * URL Parameter:
 *   :id → MongoDB ObjectId (e.g., "64a3f1b2c0e789...")
 *   Accessible via req.params.id
 *
 * Request Body (JSON):
 *   { "task": "Deploy Prometheus", "completed": true }
 *
 * Success Response (200 OK):
 *   { "_id": "...", "task": "...", "completed": true, "updatedAt": "..." }
 *
 * Not Found Response (404):
 *   { "message": "Task not found" }
 *
 * FINDBYIDANDUPDATE OPTIONS:
 *   new: true           → Returns the UPDATED document (not the pre-update version)
 *   runValidators: true → Runs schema validation on the update body
 *
 * WHY findByIdAndUpdate instead of task.save()?
 *   findByIdAndUpdate is a single atomic MongoDB operation.
 *   Fetching the document first and then saving is TWO operations —
 *   a race condition could occur between them in concurrent scenarios.
 */
router.put("/:id", async (req, res) => {
  try {
    const task = await Task.findByIdAndUpdate(
      req.params.id,         // MongoDB ObjectId from URL
      req.body,              // Fields to update (e.g., { completed: true })
      {
        new: true,           // Return the updated document, not the original
        runValidators: true, // Validate update body against schema
      }
    );

    // If no document matches the ID, findByIdAndUpdate returns null
    if (!task) {
      return res.status(404).json({ message: "Task not found" });
    }

    res.status(200).json(task);
  } catch (error) {
    // CastError occurs if :id is not a valid MongoDB ObjectId format
    if (error.name === "CastError") {
      return res.status(400).json({ message: "Invalid task ID format" });
    }
    res.status(500).json({ message: "Failed to update task", error: error.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DELETE /api/tasks/:id — Delete a Task permanently
// ─────────────────────────────────────────────────────────────────────────────
/**
 * URL Parameter:
 *   :id → MongoDB ObjectId of the task to delete
 *
 * Success Response (200 OK):
 *   { "message": "Task deleted successfully" }
 *
 * Not Found Response (404):
 *   { "message": "Task not found" }
 *
 * NOTE: This is a HARD DELETE — the document is permanently removed from MongoDB.
 * For production systems, consider a SOFT DELETE:
 *   Add a 'deletedAt' timestamp field. Filter deleted tasks out of GET.
 *   This preserves the audit trail and allows undo functionality.
 */
router.delete("/:id", async (req, res) => {
  try {
    const task = await Task.findByIdAndDelete(req.params.id);

    if (!task) {
      return res.status(404).json({ message: "Task not found" });
    }

    res.status(200).json({ message: "Task deleted successfully" });
  } catch (error) {
    if (error.name === "CastError") {
      return res.status(400).json({ message: "Invalid task ID format" });
    }
    res.status(500).json({ message: "Failed to delete task", error: error.message });
  }
});

module.exports = router;
