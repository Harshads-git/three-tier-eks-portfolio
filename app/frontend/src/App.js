/**
 * App.js — Presentation Layer / Root Component (View)
 *
 * WHAT THIS FILE DOES:
 * --------------------
 * App is the ROOT component of the React application. It extends Tasks (Tasks.js)
 * to inherit all CRUD state and event handlers. App's ONLY job is to render the UI.
 *
 * COMPONENT HIERARCHY:
 * --------------------
 *   index.js (entry point)
 *     └── App (this file) — Root component, rendered into #root div
 *           ├── Paper (Material UI card container)
 *           │     ├── Heading "TO-DO"
 *           │     ├── Form (input + submit button)
 *           │     └── Task List
 *           │           └── Task Item (for each task in state.tasks)
 *           │                 ├── Checkbox   → calls handleUpdate()
 *           │                 ├── Title Text → strikethrough if completed
 *           │                 └── Delete Btn → calls handleDelete()
 *
 * WHY APP EXTENDS TASKS (Inheritance Pattern):
 * -------------------------------------------
 * Tasks.js contains all state + event handler logic.
 * App.js contains only the render() method (the JSX/UI).
 * This separates concerns even within the frontend layer:
 *   - Tasks.js = Model + Controller
 *   - App.js   = View
 *
 * DEVOPS RELEVANCE:
 * -----------------
 * This is the component that gets BUILT by `npm run build` into static HTML/JS/CSS.
 * Those static files are then served by Nginx in the Docker container.
 * The REACT_APP_BACKEND_URL env var (used in taskServices.js) must be set
 * BEFORE `npm run build` runs — it gets embedded at build time by webpack.
 * In K8s, this is handled by building the image with the correct --build-arg.
 */

import React from "react";
import Tasks from "./Tasks";

// Material UI components — pre-built React UI components from Google's Material Design
// @material-ui/core v4 is used here (older API, v5 uses @mui/material)
import { Paper, TextField } from "@material-ui/core";
import { Checkbox, Button } from "@material-ui/core";

import "./App.css"; // Component-scoped styles

/**
 * App extends Tasks to inherit:
 *   - state: { tasks: [], currentTask: "" }
 *   - componentDidMount() — fetches tasks on load
 *   - handleChange()  — updates currentTask in state on input change
 *   - handleSubmit()  — POSTs new task, updates state
 *   - handleUpdate()  — PUTs task update, toggles completed
 *   - handleDelete()  — DELETEs task, filters from state
 *
 * App only adds: render() — the JSX that produces the DOM output
 */
class App extends Tasks {
  // ─────────────────────────────────────────────────────────────────────────
  // STATE (re-declared here for clarity, inherited from Tasks)
  // ─────────────────────────────────────────────────────────────────────────
  state = { tasks: [], currentTask: "" };

  // ─────────────────────────────────────────────────────────────────────────
  // RENDER METHOD — The only method App defines
  // ─────────────────────────────────────────────────────────────────────────
  /**
   * render() is called by React every time state or props change.
   * It returns JSX — a syntax extension that looks like HTML but compiles to
   * React.createElement() calls under the hood.
   *
   * React's virtual DOM diffs the output on each render and only updates
   * the real DOM nodes that actually changed — this is React's core optimization.
   */
  render() {
    // Destructure tasks array from state for cleaner JSX below
    const { tasks } = this.state;

    return (
      // Root div with flexbox layout for centering the card
      <div className="App flex">

        {/*
          Paper: Material UI card component with elevation shadow.
          elevation={3} → medium shadow depth (0-24 scale)
          className="container" → our custom CSS in App.css
        */}
        <Paper elevation={3} className="container">

          {/* App heading */}
          <div className="heading">TO-DO</div>

          {/*
            CONTROLLED FORM:
            onSubmit → calls handleSubmit() from Tasks.js
            The form wraps both the input and submit button.
            'flex' className aligns them in a row via CSS flexbox.
          */}
          <form
            onSubmit={this.handleSubmit}
            className="flex"
            style={{ margin: "15px 0" }}
          >
            {/*
              CONTROLLED INPUT (TextField):
              Material UI's TextField wraps a standard HTML <input>.
              value={this.state.currentTask}    → React controls the input value
              onChange={this.handleChange}       → called on every keystroke
              This is the "controlled component" pattern — React is the single
              source of truth for the input's value (vs "uncontrolled" using refs).
            */}
            <TextField
              variant="outlined"
              size="small"
              value={this.state.currentTask}
              onChange={this.handleChange}
              label="Add Task"
              style={{ flex: 1 }}
            />

            {/*
              SUBMIT BUTTON:
              type="submit" triggers the form's onSubmit handler.
              Disabled when input is empty to prevent blank task submissions.
            */}
            <Button
              type="submit"
              variant="outlined"
              disabled={this.state.currentTask === ""}
              style={{ marginLeft: "10px" }}
            >
              Add
            </Button>
          </form>

          {/*
            TASK LIST:
            Array.map() iterates over tasks in state and renders one item per task.
            key={task._id} is REQUIRED by React — it uses this to efficiently
            reconcile the virtual DOM when items are added/removed/reordered.
            Using MongoDB's _id (a unique ObjectId) as the key is correct.
            Never use array index as key — it causes subtle bugs on reorder/delete.
          */}
          {tasks.map((task) => (
            <div className="flex" key={task._id} style={{ margin: "10px 0" }}>

              {/*
                CHECKBOX — marks task as complete/incomplete
                checked={task.completed} → checkbox state driven by MongoDB data
                onChange → calls handleUpdate(task._id) which sends a PUT request
              */}
              <Checkbox
                checked={task.completed}
                onChange={() => this.handleUpdate(task._id)}
              />

              {/*
                TASK TITLE:
                Conditional styling: if task.completed is true, apply
                textDecoration: "line-through" to visually indicate done status.
                This purely cosmetic, driven by the 'completed' field from MongoDB.
                flex:1 makes the text take all remaining horizontal space.
              */}
              <div
                className="flex"
                style={{
                  flex: 1,
                  textDecoration: task.completed ? "line-through" : "",
                  alignItems: "center",
                }}
              >
                {task.title}
              </div>

              {/*
                DELETE BUTTON:
                onClick → calls handleDelete(task._id) which sends DELETE request.
                Note: no confirmation dialog — in production you'd add one.
              */}
              <Button
                variant="outlined"
                color="secondary"
                onClick={() => this.handleDelete(task._id)}
              >
                Delete
              </Button>
            </div>
          ))}
        </Paper>
      </div>
    );
  }
}

export default App;
