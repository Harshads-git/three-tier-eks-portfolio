# Frontend Application — Component Tree & Architecture

## Overview

The frontend is a **React 17 SPA (Single Page Application)** that provides a To-Do task manager UI. It is served by **Nginx** in a Docker container running on Kubernetes. All data is fetched from and persisted to the **Node.js backend** via REST API calls.

---

## Component Hierarchy

```
public/index.html  ← Static HTML shell (Nginx serves this file)
  └── <div id="root">
        └── index.js (Entry point — ReactDOM.render)
              └── <App /> (App.js — extends Tasks.js)
                    ├── <Paper>       Material UI card container
                    │     ├── <div.heading>   "TO-DO" title
                    │     ├── <form>          New task input form
                    │     │     ├── <TextField>   Controlled text input
                    │     │     └── <Button>      Add task submit button
                    │     └── {tasks.map()}    Task list (dynamic)
                    │           └── <div>      One row per task
                    │                 ├── <Checkbox>  Toggle complete
                    │                 ├── <div>       Task title text
                    │                 └── <Button>    Delete button
```

---

## File Inventory

| File | Role | Key Responsibility |
|---|---|---|
| `public/index.html` | HTML Shell | Mount point for React (`<div id="root">`) |
| `src/index.js` | Entry Point | `ReactDOM.render(<App />)` into `#root` |
| `src/App.js` | View (UI) | Renders JSX; extends Tasks for state + handlers |
| `src/Tasks.js` | Controller | State management + all CRUD event handlers |
| `src/services/taskServices.js` | Service / HTTP Client | All `axios` API calls to backend |
| `src/App.css` | Component Styles | Card layout, heading, flexbox utilities |
| `src/index.css` | Global Styles | Browser resets, font, box-sizing |
| `package.json` | Dependencies | npm packages list and build scripts |
| `.env.example` | Config Template | Documents environment variable requirements |

---

## State Management

The application uses **React class component state** (pre-hooks pattern):

```javascript
// Defined in Tasks.js, inherited by App.js
state = {
  tasks:       Task[],   // All tasks fetched from MongoDB via backend
  currentTask: string    // Current text input value (controlled input)
};
```

### State Transitions

```
App mounts
    │
    ▼
componentDidMount() ──► GET /api/tasks ──► setState({ tasks: data })
                                                │
                                                ▼ Re-render: task list appears

User types in TextField
    │
    ▼
handleChange() ──► setState({ currentTask: input.value })
                        │
                        ▼ Re-render: TextField value updates

User submits form
    │
    ▼
handleSubmit() ──► POST /api/tasks { title } ──► setState({ tasks: [...tasks, newTask], currentTask: "" })
                                                        │
                                                        ▼ Re-render: new task appears in list

User clicks checkbox
    │
    ▼
handleUpdate(id) ──► PUT /api/tasks/:id { completed: !current } ──► setState({ tasks: updatedList })
                                                                          │
                                                                          ▼ Re-render: strikethrough toggles

User clicks Delete
    │
    ▼
handleDelete(id) ──► DELETE /api/tasks/:id ──► setState({ tasks: filtered })
                                                    │
                                                    ▼ Re-render: task removed from list
```

---

## API Contract (Frontend's Perspective)

The frontend communicates **exclusively** with the backend via these four operations:

### Base URL
```
process.env.REACT_APP_BACKEND_URL
e.g., http://localhost:5000/api/tasks
```

### Operations

| Operation | HTTP Method | URL | Request Body | Response |
|---|---|---|---|---|
| **Read All** | `GET` | `{apiUrl}` | None | `[{ _id, title, completed, createdAt }]` |
| **Create** | `POST` | `{apiUrl}` | `{ title: string }` | `{ _id, title, completed: false, createdAt }` |
| **Update** | `PUT` | `{apiUrl}/{id}` | `{ title, completed: boolean }` | `{ _id, title, completed, updatedAt }` |
| **Delete** | `DELETE` | `{apiUrl}/{id}` | None | `204 No Content` |

### Example Data Shapes

**Task Object (received from backend):**
```json
{
  "_id": "64a3f1b2c0e7891234567890",
  "title": "Set up EKS cluster with Terraform",
  "completed": false,
  "createdAt": "2026-05-23T16:00:00.000Z",
  "updatedAt": "2026-05-23T16:00:00.000Z"
}
```

**POST Request Body:**
```json
{ "title": "Deploy Prometheus stack" }
```

**PUT Request Body:**
```json
{
  "_id": "64a3f1b2...",
  "title": "Deploy Prometheus stack",
  "completed": true
}
```

---

## Environment Variable Flow

```
Environment           Variable                          Used In
─────────────────────────────────────────────────────────────────────
Local (.env)          REACT_APP_BACKEND_URL=http://localhost:5000/api/tasks
Docker Compose        REACT_APP_BACKEND_URL=http://backend:5000/api/tasks
GitHub Actions CI     --build-arg REACT_APP_BACKEND_URL=${{ secrets.API_URL }}
Kubernetes (EKS)      REACT_APP_BACKEND_URL=http://<ALB-DNS>/api/tasks
```

> ⚠️ **Build-Time Variable**: This value is baked into the JavaScript bundle by webpack at `npm run build` time. Changing it requires a rebuild and redeployment.

---

## Dependencies Explained

| Package | Version | Purpose |
|---|---|---|
| `react` | 17.0.2 | Core React library |
| `react-dom` | 17.0.2 | React renderer for the browser DOM |
| `react-scripts` | 4.0.3 | CRA build toolchain (webpack, Babel, ESLint) |
| `axios` | 0.21.1 | HTTP client for API calls (simpler than `fetch`) |
| `@material-ui/core` | 4.11.4 | Google Material Design React components |
| `@testing-library/react` | 11.2.7 | React component testing utilities |
| `web-vitals` | 1.1.2 | Core Web Vitals performance measurement |

---

## Kubernetes Deployment Context

When deployed on EKS:

```
Browser ──HTTPS──► ALB (aws-load-balancer-controller)
                     │
            ┌────────┴────────┐
            │                 │
         /*               /api/*
            │                 │
     Frontend Service    Backend Service
     (ClusterIP:80)      (ClusterIP:5000)
            │                 │
     Nginx Pod           Node.js Pod
     (serves build/)     (REST API)
```

The frontend Nginx container serves the static React build (`build/` directory).
No Node.js runs at runtime — only Nginx. This is why the Docker image is tiny (~30MB).

---

## Known Limitations & Production Improvements

| Current State | Production Improvement |
|---|---|
| No error boundary | Add React `ErrorBoundary` component |
| `console.log(error)` only | Add proper error state + user-facing toast notifications |
| No loading state | Add spinner while API calls are pending |
| No confirmation on delete | Add confirmation dialog before `handleDelete()` |
| React 17 (legacy) | Upgrade to React 18 with `createRoot()` |
| Class components | Refactor to functional components with hooks |
| `@material-ui/core` v4 | Upgrade to `@mui/material` v5+ |
| No unit tests | Add Jest + React Testing Library tests for all handlers |
