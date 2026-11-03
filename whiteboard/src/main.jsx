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
import { validViewport, viewportFromAppState, viewportAppState } from "./viewport.js";

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
];

function bridge(message) {
  // Missing WebKit is normal in a browser; a present bridge failing is not.
  window.webkit?.messageHandlers?.fwb?.postMessage(message);
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

function sceneSignature(scene) {
  // Foundation may reorder object keys in the save acknowledgement.
  return JSON.stringify([scene.elements, scene.appState, scene.files], (_key, value) =>
    value && typeof value === "object" && !Array.isArray(value)
      ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, value[key]]))
      : value);
}

function App() {
  const apiRef = useRef(null);
  const applyingUntilRef = useRef(0);
  const loadedRef = useRef(false);
  const lastSentRef = useRef("");
  const lastAcknowledgedRef = useRef("");
  const saveTimerRef = useRef(null);
  const themeRef = useRef("light");
  const documentIDRef = useRef(null);
  const baselineIDRef = useRef(null);
  const loadGenerationRef = useRef(0);
  const conversationIDRef = useRef(null);
  const viewGenerationRef = useRef(null);
  const viewportRef = useRef(null);
  const viewportSizeRef = useRef(null);
  const lastSentViewportRef = useRef("");

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
      const signature = sceneSignature(scene);
      const viewport = viewportFromAppState(appState);
      const viewportSignature = JSON.stringify(viewport);
      const sceneChanged = signature !== lastSentRef.current;
      if (!sceneChanged && viewportSignature === lastSentViewportRef.current) return;
      lastSentRef.current = signature;
      lastSentViewportRef.current = viewportSignature;
      if (documentIDRef.current) bridge({ type: sceneChanged ? "change" : "viewport",
        documentID: documentIDRef.current, baselineID: baselineIDRef.current,
        conversationID: conversationIDRef.current, viewGeneration: viewGenerationRef.current,
        viewport, ...(sceneChanged ? { scene: JSON.stringify(scene) } : {}) });
    }, 180);
  }, []);

  const handleChange = useCallback(
    (elements, appState) => {
      setActiveTool((previous) => previous === appState.activeTool.type ? previous : appState.activeTool.type);
      setLibraryOpen(appState.openSidebar?.name === "default" && appState.openSidebar?.tab === "library");
      setZoom(appState.zoom.value);
      const size = { width: appState.width, height: appState.height };
      const previousSize = viewportSizeRef.current;
      viewportSizeRef.current = size;
      if (viewportRef.current && previousSize &&
          (size.width !== previousSize.width || size.height !== previousSize.height)) {
        const resized = viewportAppState(viewportRef.current, appState);
        if (resized) {
          apiRef.current?.updateScene({ appState: resized, captureUpdate: CaptureUpdateAction.NEVER });
          return;
        }
      }
      viewportRef.current = viewportFromAppState(appState) || viewportRef.current;
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
      if (documentIDRef.current) bridge({ type: "change", documentID: documentIDRef.current,
        baselineID: baselineIDRef.current, conversationID: conversationIDRef.current,
        viewGeneration: viewGenerationRef.current, viewport: viewportFromAppState(api.getAppState()),
        scene: JSON.stringify(scene) });
    };
    window.addEventListener("pagehide", flush);
    window.addEventListener("beforeunload", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      window.removeEventListener("beforeunload", flush);
    };
  }, []);

  const fit = useCallback((animate = true) => {
    const api = apiRef.current;
    if (!api) return;
    const elements = api.getSceneElements();
    if (!elements.length) return;
    api.scrollToContent(elements, {
      fitToContent: true,
      viewportZoomFactor: 0.84,
      animate: Boolean(animate),
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
      const documentID = options.documentID ?? documentIDRef.current;
      // Legacy callers replace the current scene without passing view identity.
      // Inherit only within the same document; explicit null still clears identity.
      const sameDocument = documentID === documentIDRef.current;
      const conversationID = options.conversationID !== undefined ? options.conversationID
        : sameDocument ? conversationIDRef.current : null;
      const viewGeneration = options.viewGeneration !== undefined ? options.viewGeneration
        : sameDocument ? viewGenerationRef.current : null;
      if (Number.isInteger(viewGeneration) && Number.isInteger(viewGenerationRef.current) &&
          viewGeneration < viewGenerationRef.current) return;
      const sameView = documentID === documentIDRef.current &&
        conversationID === conversationIDRef.current && viewGeneration === viewGenerationRef.current;
      // Native polling can arrive before the 180ms save debounce, or while a
      // bridge message is still in flight. Preserve those edits through the
      // native three-way writer before accepting the newer disk snapshot.
      if (options.baselineID && sameView && loadedRef.current) {
        const localScene = makeScene(api.getSceneElementsIncludingDeleted(), api.getAppState(), api.getFiles());
        const signature = sceneSignature(localScene);
        if (signature !== lastAcknowledgedRef.current) {
          if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
          saveTimerRef.current = null;
          lastSentRef.current = signature;
          bridge({ type: "change", documentID, baselineID: baselineIDRef.current,
            conversationID, viewGeneration, viewport: viewportFromAppState(api.getAppState()),
            scene: JSON.stringify(localScene), reloadAfterSave: true });
          return;
        }
      }
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
      // 立刻停止保存：此刻画布上还是上一个项目的内容。文档 id 只在场景
      // 真正应用成功后才切换，加载失败时旧内容不会被写进新项目的画板。
      loadedRef.current = false;
      applyingUntilRef.current = performance.now() + 700;
      const generation = ++loadGenerationRef.current;

      // Polling and merged reloads preserve the current view. A new conversation
      // prefers its private center, then usable legacy scene offsets, then fit.
      const currentState = api.getAppState();
      const preservedViewport = sameView && options.fit === false
        ? viewportRef.current || viewportFromAppState(currentState) : null;
      const privateViewport = validViewport(options.viewport) ? options.viewport : null;
      const targetViewport = preservedViewport || privateViewport;
      const targetAppState = viewportAppState(targetViewport, currentState);
      const legacyViewport = Number.isFinite(data.appState?.scrollX) &&
        Number.isFinite(data.appState?.scrollY) && Number.isFinite(data.appState?.zoom?.value) &&
        data.appState.zoom.value >= 0.1 && data.appState.zoom.value <= 30;
      const sceneAppState = { ...(data.appState || {}) };
      if (!legacyViewport) {
        delete sceneAppState.scrollX; delete sceneAppState.scrollY; delete sceneAppState.zoom;
      }
      const local = {
        theme: themeRef.current,
        viewBackgroundColor: "transparent",
        currentItemFontFamily: DEFAULT_FONT_FAMILY,
      };
      let restored;
      try {
        restored = restore(
          {
            elements: data.elements,
            appState: { ...sceneAppState, theme: themeRef.current },
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
      const appliedAppState = { ...restored.appState, ...(targetAppState || {}) };
      viewportSizeRef.current = { width: currentState.width, height: currentState.height };
      viewportRef.current = targetViewport || viewportFromAppState({ ...currentState, ...appliedAppState });
      api.updateScene({
        elements: restored.elements,
        appState: {
          ...appliedAppState,
          theme: themeRef.current,
          viewBackgroundColor: "transparent",
          currentItemFontFamily: DEFAULT_FONT_FAMILY,
        },
        captureUpdate: CaptureUpdateAction.NEVER,
      });
      documentIDRef.current = documentID;
      conversationIDRef.current = conversationID;
      viewGenerationRef.current = viewGeneration;
      // Persist a legacy/default viewport into this conversation after the load.
      lastSentViewportRef.current = "";
      baselineIDRef.current = options.baselineID !== undefined ? options.baselineID
        : sameView ? baselineIDRef.current : null;

      const scene = makeScene(restored.elements, restored.appState, restored.files);
      lastSentRef.current = sceneSignature(scene);
      lastAcknowledgedRef.current = lastSentRef.current;
      const count = restored.elements.filter((element) => !element.isDeleted).length;
      const savedViewport = Boolean(targetViewport || legacyViewport);

      window.setTimeout(() => {
        if (generation !== loadGenerationRef.current) return;
        loadedRef.current = true;
        applyingUntilRef.current = 0;
        scheduleSave();
        if (options.fit !== false && count > 0 && !savedViewport) {
          window.setTimeout(() => {
            // No animation may continue moving a subsequently selected conversation.
            if (generation === loadGenerationRef.current) fit(false);
          }, 80);
        }
      }, 160);
    },
    [fit, scheduleSave],
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
      acknowledgeSave: ({ documentID, baselineID, scene }) => {
        if (documentID === documentIDRef.current && baselineID === baselineIDRef.current) {
          lastAcknowledgedRef.current = sceneSignature(scene);
        }
      },
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
        ? { documentID: documentIDRef.current, baselineID: baselineIDRef.current,
            conversationID: conversationIDRef.current, viewGeneration: viewGenerationRef.current,
            viewport: viewportFromAppState(apiRef.current?.getAppState()), scene: window.FWB.getSceneJSON() }
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
