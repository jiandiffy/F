// Store a scene-space center, independent of the previous window dimensions.
export function validViewport(value) {
  return Boolean(value && Number.isFinite(value.centerX) && Number.isFinite(value.centerY) &&
    Number.isFinite(value.zoom) && value.zoom >= 0.1 && value.zoom <= 30);
}

export function viewportFromAppState(state) {
  const zoom = state?.zoom?.value;
  if (!Number.isFinite(state?.width) || !Number.isFinite(state?.height) ||
      state.width <= 0 || state.height <= 0 || !Number.isFinite(state.scrollX) ||
      !Number.isFinite(state.scrollY) || !Number.isFinite(zoom) || zoom <= 0) return null;
  const viewport = { version: 1, centerX: state.width / (2 * zoom) - state.scrollX,
    centerY: state.height / (2 * zoom) - state.scrollY, zoom };
  return validViewport(viewport) ? viewport : null;
}

export function viewportAppState(viewport, state) {
  if (!validViewport(viewport) || !Number.isFinite(state?.width) ||
      !Number.isFinite(state?.height) || state.width <= 0 || state.height <= 0) return null;
  return { scrollX: state.width / (2 * viewport.zoom) - viewport.centerX,
    scrollY: state.height / (2 * viewport.zoom) - viewport.centerY,
    zoom: { value: viewport.zoom } };
}
