import React, { useCallback, useEffect, useRef, useState } from "react";
import { exportToSvg } from "@excalidraw/excalidraw";

const BACKGROUNDS = [
  { id: "transparent", label: "透明" },
  { id: "white", label: "白色" },
  { id: "canvas", label: "画布底色" },
];
// 1K / 2K / 4K = 导出图长边的像素数
const SIZES = [
  { id: "1k", label: "1K", px: 1024 },
  { id: "2k", label: "2K", px: 2048 },
  { id: "4k", label: "4K", px: 4096 },
];
const FORMATS = [
  { id: "png", label: "PNG" },
  { id: "jpg", label: "JPG" },
  { id: "svg", label: "SVG" },
  { id: "pdf", label: "PDF" },
];
const PADDING = 0;
const MAX_SIDE = 12000;

function fileName(ext) {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `board-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}.${ext}`;
}

function svgSize(svg) {
  const box = svg.viewBox?.baseVal;
  return {
    width: Number(svg.getAttribute("width")) || box?.width || 1,
    height: Number(svg.getAttribute("height")) || box?.height || 1,
  };
}

/// 把 SVG 渲染成位图；按“长边 = targetPx”计算倍率（可放大也可缩小）。
async function rasterize(svg, targetPx, opaque) {
  const { width, height } = svgSize(svg);
  let scale = targetPx / Math.max(width, height);
  scale = Math.min(scale, MAX_SIDE / Math.max(width, height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));

  const url = URL.createObjectURL(
    new Blob([new XMLSerializer().serializeToString(svg)], { type: "image/svg+xml;charset=utf-8" }),
  );
  try {
    const image = new Image();
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = () => reject(new Error("SVG 渲染失败"));
      image.src = url;
    });
    const ctx = canvas.getContext("2d");
    if (opaque) {
      ctx.fillStyle = "#ffffff"; // JPG 不支持透明，先铺白
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    }
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
  } finally {
    URL.revokeObjectURL(url);
  }

  const mime = opaque ? "image/jpeg" : "image/png";
  const blob = await new Promise((resolve, reject) => {
    canvas.toBlob(
      (result) => (result ? resolve(result) : reject(new Error("编码失败"))),
      mime,
      opaque ? 0.92 : undefined,
    );
  });
  return { blob, width: canvas.width, height: canvas.height };
}

export function ExportPanel({ apiRef, onClose }) {
  const [background, setBackground] = useState("white");
  const [size, setSize] = useState("2k");
  const [format, setFormat] = useState("png");
  const [preview, setPreview] = useState("");
  const [info, setInfo] = useState("正在生成预览…");
  const [busy, setBusy] = useState(false);
  const [rendering, setRendering] = useState(true);
  const previewURL = useRef("");

  useEffect(() => {
    const escape = (event) => { if (event.key === "Escape" && !busy) onClose(); };
    document.addEventListener("keydown", escape);
    return () => document.removeEventListener("keydown", escape);
  }, [onClose, busy]);
  useEffect(() => () => { if (previewURL.current) URL.revokeObjectURL(previewURL.current); }, []);

  const render = useCallback(async () => {
    const api = apiRef.current;
    if (!api) return null;
    const elements = api.getSceneElements();
    if (!elements.length) return null;
    const app = api.getAppState();
    const withBackground = background !== "transparent";
    const canvasColor = background === "canvas" ? app.viewBackgroundColor : "#ffffff";
    const svg = await exportToSvg({
      elements,
      appState: {
        ...app,
        exportBackground: withBackground,
        viewBackgroundColor: canvasColor,
        exportWithDarkMode: false,
        exportScale: 1,
      },
      files: api.getFiles(),
      exportPadding: PADDING,
    });

    if (format === "svg") {
      const text = new XMLSerializer().serializeToString(svg);
      const { width, height } = svgSize(svg);
      return {
        blob: new Blob([text], { type: "image/svg+xml;charset=utf-8" }),
        width: Math.round(width),
        height: Math.round(height),
        vector: true,
        native: "svg",
      };
    }

    const target = SIZES.find((item) => item.id === size)?.px ?? 2048;
    // 只有 JPG 需要铺白底（JPEG 没有 alpha）；PDF 内嵌无损 PNG
    const raster = await rasterize(svg, target, format === "jpg");
    return {
      ...raster,
      vector: false,
      // PDF 由原生端用位图生成单页 PDF
      native: format === "pdf" ? "pdf" : format,
      bitmap: format === "pdf" ? "png" : format,
    };
  }, [apiRef, background, size, format]);

  useEffect(() => {
    let cancelled = false;
    setRendering(true);
    const timer = setTimeout(async () => {
      try {
        const result = await render();
        if (cancelled) return;
        if (!result) {
          setPreview("");
          setInfo("画板是空的");
          return;
        }
        const url = URL.createObjectURL(result.blob);
        if (previewURL.current) URL.revokeObjectURL(previewURL.current);
        previewURL.current = url;
        setPreview(url);
        const sizeText = `${result.width} × ${result.height}`;
        const kb = Math.max(1, Math.round(result.blob.size / 1024));
        setInfo(result.vector ? `${sizeText} · 矢量 · ${kb} KB` : `${sizeText} · ${kb} KB`);
      } catch (error) {
        if (!cancelled) {
          setPreview("");
          setInfo(`预览失败：${error?.message || error}`);
        }
      } finally {
        if (!cancelled) setRendering(false);
      }
    }, 180);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [render]);

  const save = async () => {
    if (busy || rendering || !preview) return;
    setBusy(true);
    try {
      const result = await render();
      if (!result) return;
      const bytes = new Uint8Array(await result.blob.arrayBuffer());
      let binary = "";
      const chunk = 0x8000;
      for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
      }
      const payload = btoa(binary);

      if (window.webkit?.messageHandlers?.fwb) {
        window.webkit.messageHandlers.fwb.postMessage({
          type: "saveImage",
          data: payload,
          format: result.native,
          name: fileName(result.native),
        });
        onClose();
      } else {
        if (result.native === "pdf") throw new Error("请在 F 应用内保存 PDF");
        const link = document.createElement("a");
        link.href = URL.createObjectURL(result.blob);
        link.download = fileName(result.native);
        link.click();
        window.setTimeout(() => URL.revokeObjectURL(link.href), 1000);
      }
    } catch (error) {
      setInfo(`导出失败：${error?.message || error}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      className="fwb-export-backdrop"
      onMouseDown={(event) => event.target === event.currentTarget && onClose()}
    >
      <div className="fwb-export" role="dialog" aria-label="导出">
        <div className="fwb-export-head">
          <span>导出</span>
          <button type="button" className="fwb-export-close" onClick={onClose} aria-label="关闭">×</button>
        </div>

        <div className="fwb-export-body">
          <div className="fwb-export-options">
            <div className="fwb-export-row">
              <span className="fwb-export-label">格式</span>
              <div className="fwb-export-chips">
                {FORMATS.map((item) => (
                  <button
                    key={item.id}
                    type="button"
                    className={`fwb-chip${format === item.id ? " active" : ""}`}
                    onClick={() => {
                      setFormat(item.id);
                      if (item.id === "jpg" && background === "transparent") setBackground("white");
                    }}
                    aria-label={item.label}
                  >
                    {item.label}
                  </button>
                ))}
              </div>
            </div>

            <div className="fwb-export-row">
              <span className="fwb-export-label">清晰度</span>
              <div className="fwb-export-chips">
                {SIZES.map((item) => (
                  <button
                    key={item.id}
                    type="button"
                    className={`fwb-chip${size === item.id ? " active" : ""}`}
                    onClick={() => setSize(item.id)}
                    disabled={format === "svg"}
                    aria-label={item.label}
                    title={`长边 ${item.px}px`}
                  >
                    {item.label}
                  </button>
                ))}
              </div>
            </div>

            <div className="fwb-export-row">
              <span className="fwb-export-label">背景</span>
              <div className="fwb-export-chips">
                {BACKGROUNDS.map((item) => (
                  <button
                    key={item.id}
                    type="button"
                    className={`fwb-chip${background === item.id ? " active" : ""}`}
                    onClick={() => setBackground(item.id)}
                    disabled={format === "jpg" && item.id === "transparent"}
                    aria-label={item.label}
                  >
                    {item.label}
                  </button>
                ))}
              </div>
            </div>

            {format === "svg" ? (
              <p className="fwb-export-note">SVG 保留矢量内容，不受像素清晰度限制。</p>
            ) : null}
            {format === "pdf" ? (
              <p className="fwb-export-note">PDF 为随内容比例裁切的单页，内嵌 {size.toUpperCase()} 无损图像。</p>
            ) : null}
          </div>

          <div className={`fwb-export-preview${background === "transparent" ? " transparent" : ""}`}>
            {preview
              ? <img src={preview} alt="导出预览" />
              : <span className="fwb-export-empty">{info}</span>}
          </div>
        </div>

        <div className="fwb-export-foot">
          <span className="fwb-export-info">{info}</span>
          <button type="button" className="fwb-chip primary" onClick={save} disabled={busy || rendering || !preview}>
            保存 {format.toUpperCase()}…
          </button>
        </div>
      </div>
    </div>
  );
}
