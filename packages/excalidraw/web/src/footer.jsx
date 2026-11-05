import React, { useEffect, useState } from "react";

export function CanvasFooter({ apiRef, zoom }) {
  const [history, setHistory] = useState({ undo: false, redo: false });
  useEffect(() => {
    const sync = () => {
      const undo = Boolean(document.querySelector('.excalidraw [data-testid="button-undo"]:not(:disabled)'));
      const redo = Boolean(document.querySelector('.excalidraw [data-testid="button-redo"]:not(:disabled)'));
      setHistory((previous) => previous.undo === undo && previous.redo === redo ? previous : { undo, redo });
    };
    const observer = new MutationObserver(sync);
    observer.observe(document.body, {
      childList: true, subtree: true, attributes: true, attributeFilter: ["disabled"],
    });
    sync();
    return () => observer.disconnect();
  }, []);

  function changeZoom(value) {
    const api = apiRef.current;
    if (!api) return;
    const state = api.getAppState();
    const next = Math.max(0.1, Math.min(30, value));
    const delta = 1 / next - 1 / state.zoom.value;
    api.updateScene({ appState: {
      zoom: { value: next },
      scrollX: state.scrollX + state.width / 2 * delta,
      scrollY: state.scrollY + state.height / 2 * delta,
    } });
  }

  return <div className="fwb-footer" aria-label="画布操作">
    <div className="fwb-zoom">
      <button type="button" aria-label="缩小" title="缩小" onClick={() => changeZoom(zoom / 1.2)}>−</button>
      <button type="button" aria-label="重置缩放" title="重置缩放" onClick={() => changeZoom(1)}>{Math.round(zoom * 100)}%</button>
      <button type="button" aria-label="放大" title="放大" onClick={() => changeZoom(zoom * 1.2)}>+</button>
    </div>
    <div className="fwb-history">
      {["undo", "redo"].map((action) => <button key={action} type="button"
        aria-label={action === "undo" ? "撤销" : "重做"} title={action === "undo" ? "撤销" : "重做"}
        disabled={!history[action]} onClick={() => {
          // Delegate to Excalidraw's history rather than keeping a second undo stack.
          document.querySelector(`.excalidraw [data-testid="button-${action}"]`)?.click();
        }}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"
          style={action === "redo" ? { transform: "scaleX(-1)" } : undefined}>
          <path d="m9 6-5 5 5 5M4 11h10a5 5 0 0 1 0 10" />
        </svg></button>)}
    </div>
  </div>;
}
