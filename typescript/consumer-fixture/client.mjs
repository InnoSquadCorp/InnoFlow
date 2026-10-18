import { StrictMode, createElement } from "react";
import { hydrateRoot } from "react-dom/client";
import { App, makeStore } from "./feature.mjs";

const store = makeStore(JSON.parse(document.getElementById("initial-state").textContent));
// An update between receiving the server HTML and hydrating must not mismatch.
store.send({ delta: 1 });
window.hydrationErrors = [];
hydrateRoot(document.getElementById("root"), createElement(StrictMode, null, createElement(App, { store })), {
  onRecoverableError: error => window.hydrationErrors.push(String(error)),
});
