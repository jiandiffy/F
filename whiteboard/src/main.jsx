import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  CaptureUpdateAction,
  Excalidraw,
  MainMenu,
  restore,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./style.css";
import { Toolbar } from "./toolbar.jsx";
import { CanvasFooter } from "./footer.jsx";
import { ExportPanel } from "./exportPanel.jsx";

const DEFAULT_FONT_FAMILY = 5; // Excalifont; Chinese glyphs use the official Xiaolai fallback.
const SAVED_APP_STATE_KEYS = [
  "viewBackgroundColor",
  "gridSize",
  "currentItemFontFamily",
  "currentItemFontSize",
  "currentItemStrokeColor",
  "currentItemBackgroundColor",
  "currentItemFillStyle",
  "currentItemStrokeWidth",
  "currentItemStrokeStyle",
  "currentItemRoughness",
  "currentItemOpacity",
  "currentItemTextAlign",
  // 视角也要保存，重新打开项目时回到上次的位置
  "scrollX",
  "scrollY",
  "zoom",
];

function bridge(message) {
  try {
    window.webkit?.messageHandlers?.fwb?.postMessage(message);
  } catch {
    // Running the web app in a normal browser is useful for development.
  }
}

function appStateSnapshot(appState) {
  const snapshot = {};
  for (const key of SAVED_APP_STATE_KEYS) {
    if (appState[key] !== undefined) snapshot[key] = appState[key];
  }
  snapshot.viewBackgroundColor = "transparent";
  return snapshot;
}

function makeScene(elements, appState, files) {
  const visible = (elements || []).filter((element) => !element.isDeleted);
  const usedFiles = Object.fromEntries(visible
    .filter((element) => element.type === "image" && element.fileId && files?.[element.fileId])
    .map((element) => [element.fileId, files[element.fileId]]));
  return {
    type: "f-whiteboard",
    version: 1,
    updatedAt: new Date().toISOString(),
    updatedBy: "user",
    elements: visible,
    appState: appStateSnapshot(appState || {}),
    files: usedFiles,
  };
}

function App() {
  const apiRef = useRef(null);
  const applyingUntilRef = useRef(0);
  const loadedRef = useRef(false);
  const lastSentRef = useRef("");
  const saveTimerRef = useRef(null);
  const themeRef = useRef("light");
  const documentIDRef = useRef(null);
  const baselineIDRef = useRef(null);
  const loadGenerationRef = useRef(0);

  const [theme, setTheme] = useState("light");
  const [exportOpen, setExportOpen] = useState(false);
  const [context, setContext] = useState({});
  const [activeTool, setActiveTool] = useState("selection");
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [zoom, setZoom] = useState(1);
  const statusRef = useRef(null);
  const statusTextRef = useRef(null);
  const statusTimerRef = useRef(null);

  const scheduleSave = useCallback(() => {
    if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    saveTimerRef.current = setTimeout(() => {
      saveTimerRef.current = null;
      const api = apiRef.current;
      if (!api || !loadedRef.current || performance.now() < applyingUntilRef.current) return;

      const elements = api.getSceneElementsIncludingDeleted();
      const appState = api.getAppState();
      const files = api.getFiles();
      const scene = makeScene(elements, appState, files);
      const signature = JSON.stringify([scene.elements, scene.appState, scene.files]);
      if (signature === lastSentRef.current) return;
      lastSentRef.current = signature;
      if (documentIDRef.current) bridge({ type: "change", documentID: documentIDRef.current, baselineID: baselineIDRef.current, scene: JSON.stringify(scene) });
    }, 180);
  }, []);

  const handleChange = useCallback(
    (elements, appState) => {
      setActiveTool((previous) => previous === appState.activeTool.type ? previous : appState.activeTool.type);
      setLibraryOpen(appState.openSidebar?.name === "default" && appState.openSidebar?.tab === "library");
      setZoom(appState.zoom.value);
      if (!loadedRef.current || performance.now() < applyingUntilRef.current) return;
      scheduleSave();
    },
    [scheduleSave],
  );

  useEffect(() => {
    // 关闭窗口/刷新前立即落盘，避免最后 180ms 的修改丢掉
    const flush = () => {
      const api = apiRef.current;
      if (!api || !loadedRef.current) return;
      const scene = makeScene(
        api.getSceneElementsIncludingDeleted(),
        api.getAppState(),
        api.getFiles(),
      );
      if (documentIDRef.current) bridge({ type: "change", documentID: documentIDRef.current, baselineID: baselineIDRef.current, scene: JSON.stringify(scene) });
    };
    window.addEventListener("pagehide", flush);
    window.addEventListener("beforeunload", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      window.removeEventListener("beforeunload", flush);
    };
  }, []);

  const fit = useCallback(() => {
    const api = apiRef.current;
    if (!api) return;
    const elements = api.getSceneElements();
    if (!elements.length) return;
    api.scrollToContent(elements, {
      fitToContent: true,
      viewportZoomFactor: 0.84,
      animate: true,
      duration: 260,
    });
  }, []);

  const setStatus = useCallback((message, isBusy = false) => {
    const node = statusRef.current;
    const textNode = statusTextRef.current;
    if (!node || !textNode) return;
    if (statusTimerRef.current) clearTimeout(statusTimerRef.current);
    if (!message) {
      node.classList.remove("visible", "busy");
      return;
    }
    textNode.textContent = message;
    node.classList.add("visible");
    node.classList.toggle("busy", Boolean(isBusy));
    if (!isBusy) {
      statusTimerRef.current = setTimeout(() => node.classList.remove("visible"), 3200);
    }
  }, []);

  const loadScene = useCallback(
    (input, options = {}) => {
      const api = apiRef.current;
      if (!api) return;
      let data = input;
      try {
        if (typeof input === "string") data = JSON.parse(input);
      } catch {
        return;
      }
      if (!data || typeof data !== "object") return;
      // Accept both a bare scene and the `{ scene, options }` envelope the native
      // shell sends, otherwise the board renders empty.
      if (data.scene && typeof data.scene === "object") {
        options = { ...(data.options || {}), ...options };
        data = data.scene;
      }
      if (!Array.isArray(data.elements)) return;
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
      // 立刻停止保存：此刻画布上还是上一个项目的内容。文档 id 只在场景
      // 真正应用成功后才切换，加载失败时旧内容不会被写进新项目的画板。
      loadedRef.current = false;
      applyingUntilRef.current = performance.now() + 700;
      const documentID = options.documentID ?? documentIDRef.current;
      const generation = ++loadGenerationRef.current;

      const local = {
        theme: themeRef.current,
        viewBackgroundColor: "transparent",
        currentItemFontFamily: DEFAULT_FONT_FAMILY,
      };
      let restored;
      try {
        restored = restore(
          {
            elements: Array.isArray(data.elements) ? data.elements : [],
            appState: { ...(data.appState || {}), theme: themeRef.current },
            files: data.files || {},
          },
          local,
          null,
          { repairBindings: true, refreshDimensions: true },
        );
      } catch (error) {
        console.error("whiteboard restore failed", error);
        return;
      }

      // A project's undo stack and cached images must never restore another project's scene.
      if (documentID !== documentIDRef.current) api.resetScene();
      if (restored.files) api.addFiles(Object.values(restored.files));
      api.updateScene({
        elements: restored.elements,
        appState: {
          ...restored.appState,
          theme: themeRef.current,
          viewBackgroundColor: "transparent",
          currentItemFontFamily: DEFAULT_FONT_FAMILY,
        },
        captureUpdate: CaptureUpdateAction.NEVER,
      });
      documentIDRef.current = documentID;
      baselineIDRef.current = options.baselineID ?? null;

      const scene = makeScene(restored.elements, restored.appState, restored.files);
      lastSentRef.current = JSON.stringify([scene.elements, scene.appState, scene.files]);
      const count = restored.elements.filter((element) => !element.isDeleted).length;
      // 存过视角就直接用存档的视口（滚动/缩放），否则才自适应内容。
      const savedViewport =
        typeof data.appState?.scrollX === "number" &&
        typeof data.appState?.scrollY === "number" &&
        typeof data.appState?.zoom?.value === "number";

      window.setTimeout(() => {
        if (generation !== loadGenerationRef.current) return;
        loadedRef.current = true;
        applyingUntilRef.current = 0;
        if (options.fit !== false && count > 0 && !savedViewport) {
          window.setTimeout(() => {
            if (generation === loadGenerationRef.current) fit();
          }, 80);
        }
      }, 160);
    },
    [fit],
  );

  useEffect(() => {
    themeRef.current = theme;
    document.documentElement.classList.toggle("theme-dark", theme === "dark");
    document.documentElement.style.colorScheme = theme;
    if (loadedRef.current) scheduleSave();
  }, [theme, scheduleSave]);

  useEffect(() => {
    window.FWB = {
      loadScene,
      load: loadScene,
      fit,
      setStatus,
      setTheme: (next) => setTheme(next === "dark" ? "dark" : "light"),
      setContext: (value) => setContext(value && typeof value === "object" ? value : {}),
      menuAction: (action) => {
        // 所有格式共用一个导出面板。
        if (action === "image" || action === "export" || action === "save") {
          setExportOpen(true);
          return;
        }
        const ids = {
          search: "search-menu-button", help: "help-menu-item", clear: "clear-canvas-button",
        };
        if (!ids[action] || !apiRef.current) return;
        // Keep Excalidraw's own dialogs, export behavior and clear confirmation.
        apiRef.current.updateScene({ appState: { openMenu: "canvas" } });
        let attempts = 0;
        const invoke = () => {
          const item = document.querySelector(`[data-testid="${ids[action]}"]`);
          if (item) item.click();
          else if (attempts++ < 20) window.setTimeout(invoke, 16);
        };
        window.setTimeout(invoke, 0);
      },
      setBusy: (value, message) => setStatus(message || (value ? "F 正在处理…" : ""), value),
      getScene: () => (apiRef.current ? apiRef.current.getSceneElements() : []),
      getDocumentSnapshot: () => loadedRef.current
        ? { documentID: documentIDRef.current, baselineID: baselineIDRef.current, scene: window.FWB.getSceneJSON() }
        : null,
      getSceneJSON: () =>
        apiRef.current && loadedRef.current
          ? makeScene(
              apiRef.current.getSceneElementsIncludingDeleted(),
              apiRef.current.getAppState(),
              apiRef.current.getFiles(),
            )
          : null,
    };
    return () => {
      delete window.FWB;
    };
  }, [loadScene, fit, setStatus]);

  useEffect(() => {
    return () => {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
      if (statusTimerRef.current) clearTimeout(statusTimerRef.current);
    };
  }, []);

  useEffect(() => {
    let wasOpen = false;
    const observer = new MutationObserver(() => {
      const open = Boolean(document.querySelector(".Modal, .fwb-export"));
      if (open === wasOpen) return;
      wasOpen = open;
      document.documentElement.classList.toggle("fwb-modal-open", open);
      bridge({ type: "modal", open });
    });
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  return (
    <div className="fwb-shell">
      <Excalidraw
        excalidrawAPI={(api) => {
          apiRef.current = api;
          loadedRef.current = true;
          bridge({ type: "ready" });
        }}
        initialData={{
          elements: [],
          appState: {
            theme: "light",
            viewBackgroundColor: "transparent",
            currentItemFontFamily: DEFAULT_FONT_FAMILY,
          },
          scrollToContent: false,
        }}
        theme={theme}
        name="F 画板"
        langCode="zh-CN"
        autoFocus={false}
        aiEnabled={false}
        onChange={handleChange}
        UIOptions={{
          canvasActions: {
            changeViewBackgroundColor: false,
            clearCanvas: true,
            loadScene: false,
            saveToActiveFile: false,
            toggleTheme: false,
            export: false,
            saveAsImage: false,
          },
        }}
      >
        <MainMenu>
          <div className="fwb-native-menu-items">
            <MainMenu.Item onSelect={() => setExportOpen(true)}>导出…</MainMenu.Item>
            <MainMenu.DefaultItems.SearchMenu />
            <MainMenu.DefaultItems.Help />
            <MainMenu.DefaultItems.ClearCanvas />
          </div>
        </MainMenu>
      </Excalidraw>

      <Toolbar apiRef={apiRef} activeTool={activeTool} libraryOpen={libraryOpen}
        controls={<CanvasFooter apiRef={apiRef} zoom={zoom} />} />

      {exportOpen ? <ExportPanel apiRef={apiRef} onClose={() => setExportOpen(false)} /> : null}

      <div ref={statusRef} className="fwb-status" role="status" aria-live="polite">
        <span className="pulse" />
        <span ref={statusTextRef} />
      </div>

    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
