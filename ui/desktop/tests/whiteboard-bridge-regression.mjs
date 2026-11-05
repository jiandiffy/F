import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

const source = readFileSync(new URL("../../../packages/excalidraw/web/src/main.jsx", import.meta.url), "utf8");
const bridge = source.match(/^function bridge\(message\) \{[\s\S]*?^\}/m)?.[0];
assert.ok(bridge, "test exercises the real bridge implementation");
const invoke = (window, message) => runInNewContext(`${bridge}\nbridge(message);`, { window, message });
assert.doesNotThrow(() => invoke({}, {}), "normal browser without WebKit remains supported");
assert.doesNotThrow(() => invoke({ webkit: { messageHandlers: {} } }, {}), "absent native handler is optional");
const message = { type: "viewport", viewport: { centerX: 2, centerY: 3, zoom: 1 } };
const received = [];
invoke({ webkit: { messageHandlers: { fwb: { postMessage: value => received.push(value) } } } }, message);
assert.deepEqual(received, [message], "native messages are forwarded once without mutation");
const failure = new Error("native bridge failed");
assert.throws(() => invoke({ webkit: { messageHandlers: { fwb: { postMessage() { throw failure; } } } } }, message),
  error => error === failure, "native bridge failures must not be silently swallowed");
const identity = source.match(/      const documentID = options\.documentID[\s\S]*?const sameView =[\s\S]*?;/)?.[0];
assert.ok(identity, "test exercises loadScene identity resolution");
const resolve = options => JSON.parse(JSON.stringify(runInNewContext(`(() => {
  ${identity}
  return {documentID, conversationID, viewGeneration, sameView};
})()`, { options, documentIDRef: {current: "project-a"}, conversationIDRef: {current: "chat-a"},
  viewGenerationRef: {current: 7} })) || "null");
assert.deepEqual(resolve({fit: false}), {documentID: "project-a", conversationID: "chat-a", viewGeneration: 7, sameView: true},
  "legacy same-document load retains native identity");
assert.deepEqual(resolve({documentID: "project-b"}), {documentID: "project-b", conversationID: null, viewGeneration: null, sameView: false},
  "another document never inherits the prior conversation");
assert.equal(resolve({conversationID: null, viewGeneration: null}).sameView, false, "explicit null clears identity");
assert.equal(resolve({viewGeneration: 6}), null, "late view generation remains rejected");
console.log("SUCCESS: whiteboard bridge and legacy load identity regression (10 assertions)");
