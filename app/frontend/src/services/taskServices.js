/**
 * taskServices.js — HTTP Client Layer (Service / API Abstraction Layer)
 *
 * WHAT THIS FILE DOES:
 * --------------------
 * This file is the ONLY place in the frontend that knows about the backend URL.
 * It exports four functions that map directly to the four CRUD operations:
 *   - getTasks()    → GET    /api/tasks       (Read all tasks)
 *   - addTask()     → POST   /api/tasks       (Create a task)
 *   - updateTask()  → PUT    /api/tasks/:id   (Update a task)
 *   - deleteTask()  → DELETE /api/tasks/:id   (Delete a task)
 *
 * WHY ABSTRACT API CALLS INTO A SERVICE FILE?
 * -------------------------------------------
 * 1. Single Responsibility: Components (App.js, Tasks.js) only handle UI logic.
 *    They should NOT know about HTTP methods, URLs, or headers.
 * 2. DRY (Don't Repeat Yourself): If the backend URL changes, you change it in
 *    ONE place (here), not in every component.
 * 3. Testability: This service can be mocked in unit tests independently.
 * 4. Kubernetes/Docker portability: The API URL is injected via environment
 *    variable, so the same Docker image works in dev, staging, and production.
 *
 * HOW THE ENVIRONMENT VARIABLE WORKS IN REACT:
 * ---------------------------------------------
 * React (Create React App) reads variables prefixed with REACT_APP_ at BUILD TIME.
 * This means the value is BAKED INTO the JavaScript bundle during `npm run build`.
 *
 * For Kubernetes, we use a ConfigMap to set REACT_APP_BACKEND_URL:
 *   - In development: http://localhost:5000/api/tasks
 *   - In Docker Compose: http://backend:5000/api/tasks
 *   - In EKS: http://<ALB-DNS>/api/tasks  (injected via K8s ConfigMap)
 *
 * IMPORTANT: process.env.REACT_APP_BACKEND_URL is UNDEFINED at runtime if the
 * variable wasn't set during build. This is a common K8s debugging gotcha!
 */

import axios from "axios";

// ─────────────────────────────────────────────────────────────────────────────
// API BASE URL CONFIGURATION
// ─────────────────────────────────────────────────────────────────────────────
// REACT_APP_BACKEND_URL is set in .env (local), docker-compose env_file,
// or Kubernetes ConfigMap. Never hardcode this URL!
//
// Reference repo uses: process.env.REACT_APP_BACKEND_URL
// We keep this pattern and document it clearly.
const apiUrl = process.env.REACT_APP_BACKEND_URL;

// Development safety check — warns if URL is missing, helpful during debugging
if (!apiUrl) {
  console.warn(
    "[taskServices] WARNING: REACT_APP_BACKEND_URL is not set. " +
    "API calls will fail. Set this in .env or your K8s ConfigMap."
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// CRUD SERVICE FUNCTIONS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * getTasks — Fetches all tasks from the backend.
 *
 * HTTP Method: GET
 * Endpoint:    {apiUrl}  (e.g., http://localhost:5000/api/tasks)
 * Response:    { data: [{ _id, title, completed, createdAt }, ...] }
 *
 * Called by: Tasks.js → componentDidMount() lifecycle method
 * When: Immediately after the component mounts (page load)
 *
 * @returns {Promise<AxiosResponse>} Axios response with tasks array in .data
 */
export function getTasks() {
  return axios.get(apiUrl);
}

/**
 * addTask — Creates a new task in the backend/database.
 *
 * HTTP Method: POST
 * Endpoint:    {apiUrl}
 * Body:        { title: string }
 * Response:    { data: { _id, title, completed: false, createdAt } }
 *
 * Called by: Tasks.js → handleSubmit() when the form is submitted
 *
 * @param {Object} task - Task object, e.g., { title: "Buy groceries" }
 * @returns {Promise<AxiosResponse>} Axios response with the created task in .data
 */
export function addTask(task) {
  return axios.post(apiUrl, task);
}

/**
 * updateTask — Toggles the completed status of an existing task.
 *
 * HTTP Method: PUT
 * Endpoint:    {apiUrl}/{taskId}
 * Body:        { completed: boolean } (toggled value)
 * Response:    { data: { _id, title, completed, updatedAt } }
 *
 * Called by: Tasks.js → handleUpdate() when a checkbox is clicked
 *
 * @param {string} taskId - MongoDB ObjectId of the task to update
 * @param {Object} task   - Updated task object with new 'completed' value
 * @returns {Promise<AxiosResponse>}
 */
export function updateTask(taskId, task) {
  return axios.put(`${apiUrl}/${taskId}`, task);
}

/**
 * deleteTask — Permanently deletes a task from the database.
 *
 * HTTP Method: DELETE
 * Endpoint:    {apiUrl}/{taskId}
 * Response:    204 No Content (or 200 with confirmation message)
 *
 * Called by: Tasks.js → handleDelete() when the delete button is clicked
 *
 * @param {string} taskId - MongoDB ObjectId of the task to delete
 * @returns {Promise<AxiosResponse>}
 */
export function deleteTask(taskId) {
  return axios.delete(`${apiUrl}/${taskId}`);
}
