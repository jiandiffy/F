import React, { useEffect, useRef, useState } from "react";

const TOOLS = [
  ["hand", "抓手", "H"],
  ["selection", "选择", "V"],
  ["rectangle", "矩形", "R"],
  ["diamond", "菱形", "D"],
  ["ellipse", "椭圆", "O"],
  ["arrow", "箭头", "A"],
  ["line", "线条", "L"],
  ["freedraw", "自由书写", "P"],
  ["text", "文字", "T"],
  ["image", "插入图像", "9"],
  ["eraser", "橡皮", "E"],
  ["library", "素材库", "0"],
];
const EXTRA_TOOLS = [["frame", "画框", "F"], ["embeddable", "嵌入内容", ""], ["laser", "激光笔", "K"]];

export function ToolIcon({ type }) {
  const paths = {
    hand: <path d="M8 12V6a1.5 1.5 0 0 1 3 0v5-7a1.5 1.5 0 0 1 3 0v7-5a1.5 1.5 0 0 1 3 0v6-3a1.5 1.5 0 0 1 3 0v5c0 5-2 7-6 7h-1c-2 0-3-1-4-3l-4-5a1.5 1.5 0 0 1 2-2l3 2" />,
    selection: <path d="m5 3 14 8-7 2-3 7z" />,
    rectangle: <rect x="4" y="4" width="16" height="16" rx="2" />,
    diamond: <path d="m12 3 9 9-9 9-9-9z" />,
    ellipse: <circle cx="12" cy="12" r="8" />,
    arrow: <path d="M3 12h17m-6-6 6 6-6 6" />,
    line: <path d="M4 12h16" />,
    freedraw: <><path d="m5 16-1 4 4-1L20 7l-3-3zM14 7l3 3" /></>,
    text: <path d="M4 5h16M12 5v15M8 20h8M4 5v3m16-3v3" />,
    image: <><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="8" cy="9" r="1.5" /><path d="m3 17 5-5 4 4 4-6 5 7" /></>,
    eraser: <><path d="m4 14 9-10 8 7-9 10H9zM8 10l8 7M12 21h9" /></>,
    library: <><path d="M3 5c3-1 6-1 9 1 3-2 6-2 9-1v14c-3-1-6-1-9 1-3-2-6-2-9-1zM12 6v14" /></>,
    frame: <path d="M5 2v20M19 2v20M2 5h20M2 19h20" />,
    embeddable: <><rect x="3" y="5" width="18" height="14" rx="2" /><path d="m9 9-3 3 3 3m6-6 3 3-3 3" /></>,
    laser: <><path d="m4 20 9-9m-2-7 1 3m6-4-2 4m5 3-4 1m0 5 3 2" /><circle cx="14" cy="10" r="2" /></>,
    more: <><circle cx="6" cy="7" r="2" /><path d="m16 4 3 6h-6z" /><rect x="8" y="14" width="7" height="7" rx="1" /></>,
  };
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.55" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[type]}</svg>;
}

export function Toolbar({ apiRef, activeTool, libraryOpen, controls }) {
  const hostRef = useRef(null);
  const controlsRef = useRef(null);
  const moreRef = useRef(null);
  const [visibleCount, setVisibleCount] = useState(12);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    // The entire row stays centered. Only drawing tools collapse; controls keep their size.
    const observer = new ResizeObserver(() => {
      const available = hostRef.current.clientWidth - controlsRef.current.offsetWidth - 6;
      setVisibleCount(Math.min(12, Math.max(0, Math.floor((available - 42) / 30))));
    });
    observer.observe(hostRef.current);
    observer.observe(controlsRef.current);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!open) return;
    const dismiss = (event) => {
      if (!moreRef.current?.contains(event.target)) setOpen(false);
    };
    const escape = (event) => {
      if (event.key === "Escape") { setOpen(false); moreRef.current?.querySelector("button")?.focus(); }
    };
    document.addEventListener("pointerdown", dismiss);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("pointerdown", dismiss);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);

  function activate(type) {
    const api = apiRef.current;
    if (!api) return;
    setOpen(false);
    if (type === "library") api.toggleSidebar({ name: "default", tab: "library", force: !libraryOpen });
    else api.setActiveTool({ type, locked: false, ...(type === "image" ? { insertOnCanvasDirectly: true } : {}) });
    // Restore drawing shortcuts after clicking a toolbar control.
    document.querySelector(".excalidraw")?.focus();
  }

  function toolButton([type, label, shortcut], inMenu = false) {
    const selected = type === "library" ? libraryOpen : activeTool === type;
    return <button key={type} type="button" data-tool={type}
      className={`fwb-tool${selected ? " selected" : ""}`}
      title={`${label}${shortcut ? ` — ${shortcut}` : ""}`} aria-label={label}
      aria-pressed={selected} onClick={() => activate(type)}>
      <ToolIcon type={type} />
      {inMenu && <><span>{label}</span><kbd>{shortcut}</kbd></>}
    </button>;
  }

  const overflow = [...TOOLS.slice(visibleCount), ...EXTRA_TOOLS];
  return <div className="fwb-toolbar-slot" ref={hostRef}>
    <div className="fwb-topbar">
    <div className="fwb-toolbar" role="toolbar" aria-label="画板工具">
      {TOOLS.slice(0, visibleCount).map((tool) => toolButton(tool))}
      <div className="fwb-more" ref={moreRef}>
        <button type="button" className={`fwb-tool${open ? " selected" : ""}`}
          aria-label="更多工具" title="更多工具" aria-expanded={open}
          aria-controls="fwb-overflow" onClick={() => setOpen(!open)}><ToolIcon type="more" /></button>
        {open && <div className="fwb-overflow" id="fwb-overflow" role="group" aria-label="收纳的工具">
          {overflow.map((tool) => toolButton(tool, true))}
        </div>}
      </div>
    </div>
    <div className="fwb-controls-slot" ref={controlsRef}>{controls}</div>
    </div>
  </div>;
}
