/**
 * F Whiteboard bridge.
 *
 * The F desktop app stores one editable Excalidraw scene per conversation at:
 *   F_BOARD_DIR/scene.json (the GUI's centralized, conversation-bound storage).
 * Standalone CLI sessions without F_BOARD_DIR use <project>/.f/whiteboard/scene.json.
 *
 * These tools are the agent-side control surface. They only create and mutate
 * real Excalidraw elements (never screenshots or flattened images), so every
 * result stays editable by hand and by later agent turns.
 */

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, withFileMutationQueue, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SCENE_RELATIVE_PATH = path.join(".f", "whiteboard", "scene.json");
const DEFAULT_FONT_FAMILY = 5; // Excalifont + bundled Xiaolai CJK fallback
const DEFAULT_FONT_SIZE = 20;
const NODE_GAP = 86;
const MARGIN = 80;

const SHAPES = ["rectangle", "ellipse", "diamond"] as const;
const LAYOUTS = ["vertical", "horizontal", "mindmap", "grid"] as const;
const STROKE_STYLES = ["solid", "dashed", "dotted"] as const;

type Shape = (typeof SHAPES)[number];
type Layout = (typeof LAYOUTS)[number];
type StrokeStyle = (typeof STROKE_STYLES)[number];

interface NodeInput {
	id?: string;
	label: string;
	shape?: Shape;
	x?: number;
	y?: number;
	width?: number;
	height?: number;
	fill?: string;
	stroke?: string;
	fontSize?: number;
}

interface EdgeInput {
	from: string;
	to: string;
	label?: string;
	style?: StrokeStyle;
	color?: string;
	bidirectional?: boolean;
}

interface TextInput {
	text: string;
	x?: number;
	y?: number;
	width?: number;
	fontSize?: number;
	color?: string;
}

interface SceneElement {
	id: string;
	type: string;
	x: number;
	y: number;
	width: number;
	height: number;
	[key: string]: unknown;
}

interface Scene {
	type?: string;
	version?: number;
	revision?: number;
	updatedAt?: string;
	updatedBy?: string;
	elements: SceneElement[];
	appState?: Record<string, unknown>;
	files?: Record<string, unknown>;
}

interface FwbMeta {
	id: string;
	kind: "node" | "edge" | "edgeLabel" | "text" | "label";
	label?: string;
	shape?: Shape;
	from?: string;
	to?: string;
}

interface NodeBox {
	metaId: string;
	elementId: string;
	textId?: string;
	x: number;
	y: number;
	width: number;
	height: number;
	label: string;
}

const PALETTE = {
	start: { fill: "#d3f9d8", stroke: "#2f9e44" },
	end: { fill: "#ffe3e3", stroke: "#c92a2a" },
	decision: { fill: "#fff3bf", stroke: "#e67700" },
	process: { fill: "#e7f5ff", stroke: "#1971c2" },
	neutral: { fill: "#f1f3f5", stroke: "#495057" },
	violet: { fill: "#f3f0ff", stroke: "#6741d9" },
};

const NodeParams = Type.Object({
	id: Type.Optional(Type.String({ description: "Stable semantic id used by later edits, e.g. api, db, decision_1." })),
	label: Type.String({ description: "Visible text. Keep it short; use \\n for a second line." }),
	shape: Type.Optional(Type.Union(SHAPES.map((shape) => Type.Literal(shape)))),
	x: Type.Optional(Type.Number({ description: "Canvas x. Omit to let the tool lay the graph out automatically." })),
	y: Type.Optional(Type.Number({ description: "Canvas y. Omit to let the tool lay the graph out automatically." })),
	width: Type.Optional(Type.Number()),
	height: Type.Optional(Type.Number()),
	fill: Type.Optional(Type.String({ description: "CSS hex fill color." })),
	stroke: Type.Optional(Type.String({ description: "CSS hex stroke color." })),
	fontSize: Type.Optional(Type.Number()),
});

const EdgeParams = Type.Object({
	from: Type.String({ description: "Source node id." }),
	to: Type.String({ description: "Target node id." }),
	label: Type.Optional(Type.String()),
	style: Type.Optional(Type.Union(STROKE_STYLES.map((style) => Type.Literal(style)))),
	color: Type.Optional(Type.String()),
	bidirectional: Type.Optional(Type.Boolean()),
});

const TextParams = Type.Object({
	text: Type.String(),
	x: Type.Optional(Type.Number()),
	y: Type.Optional(Type.Number()),
	width: Type.Optional(Type.Number({ description: "Wrap width in canvas units. Defaults to 520." })),
	fontSize: Type.Optional(Type.Number()),
	color: Type.Optional(Type.String()),
});

const LeaseParams = {
	lease_id: Type.String({ description: "Owned rectangle lease returned by resource_scope claim." }),
	expected_revision: Type.Optional(Type.Number({ description: "Revision from whiteboard_read; stale edits are rejected." })),
};

const CreateParams = Type.Object({
	...LeaseParams,
	title: Type.Optional(Type.String({ description: "Optional board title shown as a text label." })),
	layout: Type.Optional(Type.Union(LAYOUTS.map((layout) => Type.Literal(layout)))),
	mode: Type.Optional(Type.Union([Type.Literal("replace"), Type.Literal("append")])),
	nodes: Type.Array(NodeParams, { minItems: 1 }),
	edges: Type.Optional(Type.Array(EdgeParams)),
	texts: Type.Optional(Type.Array(TextParams)),
});

const OperationParams = Type.Object({
	op: Type.Union([
		Type.Literal("add_node"),
		Type.Literal("add_edge"),
		Type.Literal("add_text"),
		Type.Literal("update_node"),
		Type.Literal("update_edge"),
		Type.Literal("move_node"),
		Type.Literal("delete"),
		Type.Literal("clear"),
	]),
	id: Type.Optional(Type.String({ description: "Semantic node/edge id (as returned by whiteboard_read)." })),
	label: Type.Optional(Type.String()),
	shape: Type.Optional(Type.Union(SHAPES.map((shape) => Type.Literal(shape)))),
	x: Type.Optional(Type.Number()),
	y: Type.Optional(Type.Number()),
	width: Type.Optional(Type.Number()),
	height: Type.Optional(Type.Number()),
	fill: Type.Optional(Type.String()),
	stroke: Type.Optional(Type.String()),
	fontSize: Type.Optional(Type.Number()),
	from: Type.Optional(Type.String()),
	to: Type.Optional(Type.String()),
	style: Type.Optional(Type.Union(STROKE_STYLES.map((style) => Type.Literal(style)))),
	color: Type.Optional(Type.String()),
	bidirectional: Type.Optional(Type.Boolean()),
	text: Type.Optional(Type.String()),
});

const EditParams = Type.Object({
	...LeaseParams,
	operations: Type.Array(OperationParams, { minItems: 1 }),
});

function randomInt(): number {
	return Math.floor(Math.random() * 2_000_000_000);
}

function now(): number {
	return Date.now();
}

function safeId(prefix: string, seed: string, used: Set<string>): string {
	const base = (seed || prefix)
		.trim()
		.replace(/[^a-zA-Z0-9_\-\u4e00-\u9fff]/g, "_")
		.slice(0, 48) || prefix;
	let candidate = base;
	let index = 2;
	while (used.has(candidate)) {
		candidate = `${base}_${index++}`;
	}
	used.add(candidate);
	return candidate;
}

function elementId(prefix: string, used: Set<string>): string {
	let candidate = `${prefix}_${randomInt().toString(36)}${randomInt().toString(36)}`;
	while (used.has(candidate)) {
		candidate = `${prefix}_${randomInt().toString(36)}${randomInt().toString(36)}`;
	}
	used.add(candidate);
	return candidate;
}

function color(value: string | undefined, fallback: string): string {
	if (!value) return fallback;
	const trimmed = value.trim();
	if (/^#[0-9a-fA-F]{3,8}$/.test(trimmed)) return trimmed;
	if (/^(transparent|none)$/i.test(trimmed)) return "transparent";
	return fallback;
}

function visualUnits(text: string): number {
	let units = 0;
	for (const char of text) {
		if (/[\u2e80-\u9fff\uf900-\ufaff\uff01-\uff60]/.test(char)) units += 1;
		else if (/\s/.test(char)) units += 0.32;
		else units += 0.57;
	}
	return units;
}

function charWidth(char: string, fontSize: number): number {
	if (/[\u2e80-\u9fff\uf900-\ufaff\uff01-\uff60]/.test(char)) return fontSize;
	if (/\s/.test(char)) return fontSize * 0.33;
	return fontSize * 0.58;
}

function measureText(text: string, fontSize: number, maxWidth: number): { width: number; height: number; lines: number } {
	const paragraphs = text.split("\n");
	const lineLimit = Math.max(40, maxWidth - 16);
	let lines = 0;
	let widest = 0;
	for (const paragraph of paragraphs) {
		let current = 0;
		let paragraphLines = 1;
		for (const char of paragraph) {
			const width = charWidth(char, fontSize);
			if (current > 0 && current + width > lineLimit) {
				widest = Math.max(widest, current);
				paragraphLines += 1;
				current = 0;
			}
			current += width;
		}
		widest = Math.max(widest, current);
		lines += paragraphLines;
	}
	const lineHeight = fontSize * 1.28;
	return {
		width: Math.max(80, Math.min(maxWidth, Math.ceil(widest) + 32)),
		height: Math.max(48, Math.ceil(lines * lineHeight) + 26),
		lines,
	};
}

function nodeSize(node: NodeInput): { width: number; height: number } {
	const fontSize = node.fontSize || DEFAULT_FONT_SIZE;
	const measured = measureText(node.label, fontSize, 300);
	const minWidth = node.shape === "diamond" ? 190 : 156;
	const minHeight = node.shape === "diamond" ? 100 : 70;
	return {
		width: Math.round(node.width || Math.max(minWidth, measured.width)),
		height: Math.round(node.height || Math.max(minHeight, measured.height)),
	};
}

function baseElement(
	type: string,
	x: number,
	y: number,
	width: number,
	height: number,
	overrides: Record<string, unknown> = {},
): SceneElement {
	return {
		id: "",
		type,
		x,
		y,
		width,
		height,
		angle: 0,
		strokeColor: "#1e1e1e",
		backgroundColor: "transparent",
		fillStyle: "solid",
		strokeWidth: 2,
		strokeStyle: "solid",
		roughness: 1,
		opacity: 100,
		groupIds: [],
		frameId: null,
		index: null,
		roundness: null,
		seed: randomInt(),
		version: 1,
		versionNonce: randomInt(),
		isDeleted: false,
		boundElements: [],
		updated: now(),
		link: null,
		locked: false,
		...overrides,
	};
}

function metaOf(element: SceneElement): FwbMeta | undefined {
	const custom = element.customData as { fwb?: FwbMeta } | undefined;
	return custom?.fwb;
}

function nodeIdOf(element: SceneElement): string | undefined {
	const meta = metaOf(element);
	return meta?.kind === "node" ? meta.id : undefined;
}

function findNodes(scene: Scene): NodeBox[] {
	const elements = scene.elements || [];
	const boxes: NodeBox[] = [];
	for (const element of elements) {
		if (element.isDeleted) continue;
		const meta = metaOf(element);
		if (meta?.kind !== "node") continue;
		const text = elements.find((candidate) => {
			const textMeta = metaOf(candidate);
			return candidate.type === "text" && textMeta?.kind === "label" && textMeta.id === meta.id;
		});
		boxes.push({
			metaId: meta.id,
			elementId: element.id,
			textId: text?.id,
			x: element.x,
			y: element.y,
			width: element.width,
			height: element.height,
			label: meta.label || (typeof text?.text === "string" ? text.text : ""),
		});
	}
	return boxes;
}

function findElementBySemanticId(scene: Scene, semanticId: string): SceneElement | undefined {
	return scene.elements.find((element) => {
		if (element.isDeleted) return false;
		const meta = metaOf(element);
		return element.id === semanticId || meta?.id === semanticId;
	});
}

function findEdge(scene: Scene, semanticId: string): SceneElement | undefined {
	return scene.elements.find((element) => {
		if (element.isDeleted) return false;
		const meta = metaOf(element);
		return meta?.kind === "edge" && (meta.id === semanticId || element.id === semanticId);
	});
}

function nodeBoxBySemanticId(scene: Scene, id: string): NodeBox | undefined {
	return findNodes(scene).find((node) => node.metaId === id || node.elementId === id);
}

function nodeElement(scene: Scene, id: string): SceneElement | undefined {
	const box = nodeBoxBySemanticId(scene, id);
	return box ? scene.elements.find((element) => element.id === box.elementId) : undefined;
}

function addNodeElements(
	scene: Scene,
	usedSemanticIds: Set<string>,
	usedElementIds: Set<string>,
	input: NodeInput,
	x: number,
	y: number,
): { node: SceneElement; text: SceneElement; metaId: string } {
	const shape = input.shape || "rectangle";
	const size = nodeSize(input);
	const seedId = input.id || `node_${usedSemanticIds.size + 1}`;
	const metaId = safeId("node", seedId, usedSemanticIds);
	const id = elementId("node", usedElementIds);
	const textId = elementId("text", usedElementIds);
	const fontSize = input.fontSize || DEFAULT_FONT_SIZE;
	const palette = shape === "diamond" ? PALETTE.decision : PALETTE.process;
	const fill = color(input.fill, palette.fill);
	const stroke = color(input.stroke, palette.stroke);
	const roundness =
		shape === "rectangle" ? { type: 3 } : shape === "ellipse" ? { type: 2 } : null;

	const node = {
		...baseElement(shape, x, y, size.width, size.height, {
			id,
			strokeColor: stroke,
			backgroundColor: fill,
			roundness,
			customData: {
				fwb: { id: metaId, kind: "node", label: input.label, shape } satisfies FwbMeta,
			},
		}),
		boundElements: [{ type: "text", id: textId }],
	} as SceneElement;

	const textWidth = Math.max(60, size.width - 32);
	const textHeight = Math.max(28, Math.min(size.height - 16, measureText(input.label, fontSize, textWidth).height));
	const text = baseElement(
		"text",
		x + (size.width - textWidth) / 2,
		y + (size.height - textHeight) / 2,
		textWidth,
		textHeight,
		{
			id: textId,
			text: input.label,
			originalText: input.label,
			rawText: input.label,
			fontSize,
			fontFamily: DEFAULT_FONT_FAMILY,
			textAlign: "center",
			verticalAlign: "middle",
			containerId: id,
			autoResize: false,
			lineHeight: 1.28,
			strokeColor: color(input.stroke, "#1e1e1e"),
			customData: {
				fwb: { id: metaId, kind: "label", label: input.label } satisfies FwbMeta,
			},
		},
	) as SceneElement;

	scene.elements.push(node, text);
	return { node, text, metaId };
}

function edgeAnchors(from: NodeBox, to: NodeBox): {
	sx: number;
	sy: number;
	ex: number;
	ey: number;
} {
	const fc = { x: from.x + from.width / 2, y: from.y + from.height / 2 };
	const tc = { x: to.x + to.width / 2, y: to.y + to.height / 2 };
	const dx = tc.x - fc.x;
	const dy = tc.y - fc.y;
	if (Math.abs(dx) >= Math.abs(dy)) {
		return {
			sx: dx >= 0 ? from.x + from.width : from.x,
			sy: fc.y,
			ex: dx >= 0 ? to.x : to.x + to.width,
			ey: tc.y,
		};
	}
	return {
		sx: fc.x,
		sy: dy >= 0 ? from.y + from.height : from.y,
		ex: tc.x,
		ey: dy >= 0 ? to.y : to.y + to.height,
	};
}

function addEdgeElements(
	scene: Scene,
	usedSemanticIds: Set<string>,
	usedElementIds: Set<string>,
	input: EdgeInput,
	from: NodeBox,
	to: NodeBox,
): { edge: SceneElement; label?: SceneElement; metaId: string } {
	const metaId = safeId("edge", input.label ? `${input.from}_${input.to}_${input.label}` : `${input.from}_${input.to}`, usedSemanticIds);
	const id = elementId("arrow", usedElementIds);
	const anchors = edgeAnchors(from, to);
	const stroke = color(input.color, "#495057");
	const dx = anchors.ex - anchors.sx;
	const dy = anchors.ey - anchors.sy;
	const labelId = input.label ? elementId("text", usedElementIds) : undefined;
	const edge = baseElement("arrow", anchors.sx, anchors.sy, dx, dy, {
		id,
		points: [
			[0, 0],
			[dx, dy],
		],
		lastCommittedPoint: null,
		startBinding: { elementId: from.elementId, focus: 0, gap: 5 },
		endBinding: { elementId: to.elementId, focus: 0, gap: 5 },
		startArrowhead: input.bidirectional ? "arrow" : null,
		endArrowhead: "arrow",
		strokeColor: stroke,
		strokeStyle: input.style || "solid",
		elbowed: false,
		roundness: null,
		boundElements: labelId ? [{ type: "text", id: labelId }] : [],
		customData: {
			fwb: {
				id: metaId,
				kind: "edge",
				label: input.label,
				from: input.from,
				to: input.to,
			} satisfies FwbMeta,
		},
	}) as SceneElement;

	const fromElement = scene.elements.find((element) => element.id === from.elementId);
	const toElement = scene.elements.find((element) => element.id === to.elementId);
	for (const element of [fromElement, toElement]) {
		if (!element) continue;
		const bindings = Array.isArray(element.boundElements) ? (element.boundElements as Array<{ type: string; id: string }>) : [];
		if (!bindings.some((binding) => binding.type === "arrow" && binding.id === id)) {
			bindings.push({ type: "arrow", id });
		}
		element.boundElements = bindings;
	}

	let label: SceneElement | undefined;
	if (input.label && labelId) {
		const fontSize = 14;
		const measured = measureText(input.label, fontSize, 240);
		const midX = anchors.sx + dx / 2;
		const midY = anchors.sy + dy / 2;
		label = baseElement(
			"text",
			midX - measured.width / 2,
			midY - measured.height / 2,
			measured.width,
			measured.height,
			{
				id: labelId,
				text: input.label,
				originalText: input.label,
				rawText: input.label,
				fontSize,
				fontFamily: DEFAULT_FONT_FAMILY,
				textAlign: "center",
				verticalAlign: "middle",
				containerId: id,
				autoResize: true,
				lineHeight: 1.25,
				strokeColor: stroke,
				customData: {
					fwb: {
						id: metaId,
						kind: "edgeLabel",
						label: input.label,
						from: input.from,
						to: input.to,
					} satisfies FwbMeta,
				},
			},
		) as SceneElement;
	}

	scene.elements.push(edge);
	if (label) scene.elements.push(label);
	return { edge, label, metaId };
}

function topoLevels(nodes: NodeInput[], edges: EdgeInput[]): Map<string, number> {
	const ids = nodes.map((node, index) => node.id || `node_${index + 1}`);
	const incoming = new Map<string, number>();
	const outgoing = new Map<string, string[]>();
	for (const id of ids) {
		incoming.set(id, 0);
		outgoing.set(id, []);
	}
	for (const edge of edges) {
		if (!incoming.has(edge.from) || !incoming.has(edge.to)) continue;
		incoming.set(edge.to, (incoming.get(edge.to) || 0) + 1);
		outgoing.get(edge.from)?.push(edge.to);
	}
	const queue = ids.filter((id) => (incoming.get(id) || 0) === 0);
	if (queue.length === 0 && ids.length > 0) queue.push(ids[0]);
	const level = new Map<string, number>();
	queue.forEach((id) => level.set(id, 0));
	const visiting = new Set<string>();
	let guard = 0;
	while (queue.length > 0 && guard < 10_000) {
		guard += 1;
		const id = queue.shift()!;
		if (visiting.has(id)) continue;
		visiting.add(id);
		for (const next of outgoing.get(id) || []) {
			const candidate = (level.get(id) || 0) + 1;
			if (candidate > (level.get(next) ?? -1)) {
				level.set(next, candidate);
			}
			queue.push(next);
		}
	}
	for (const id of ids) {
		if (!level.has(id)) level.set(id, 0);
	}
	return level;
}

function layoutNodes(
	nodes: NodeInput[],
	edges: EdgeInput[],
	layout: Layout,
	startX: number,
	startY: number,
): Array<{ input: NodeInput; x: number; y: number; width: number; height: number; id: string }> {
	const withIds = nodes.map((node, index) => ({
		input: node,
		id: node.id || `node_${index + 1}`,
		size: nodeSize(node),
	}));
	const anyPositioned = withIds.some((node) => node.input.x !== undefined || node.input.y !== undefined);
	if (anyPositioned) {
		return withIds.map((node, index) => ({
			...node,
			x: node.input.x ?? startX + index * 220,
			y: node.input.y ?? startY,
		}));
	}

	if (layout === "grid") {
		const perRow = Math.min(4, Math.max(1, Math.ceil(Math.sqrt(withIds.length))));
		const cellW = Math.max(...withIds.map((node) => node.size.width)) + NODE_GAP;
		const cellH = Math.max(...withIds.map((node) => node.size.height)) + 58;
		return withIds.map((node, index) => ({
			...node,
			x: startX + (index % perRow) * cellW,
			y: startY + Math.floor(index / perRow) * cellH,
		}));
	}

	const level = topoLevels(nodes, edges);
	const groups = new Map<number, typeof withIds>();
	for (const node of withIds) {
		const value = level.get(node.id) || 0;
		if (!groups.has(value)) groups.set(value, []);
		groups.get(value)!.push(node);
	}

	if (layout === "mindmap") {
		const result: Array<{ input: NodeInput; x: number; y: number; width: number; height: number; id: string }> = [];
		const ordered = [...groups.keys()].sort((a, b) => a - b);
		const maxWidthByLevel = new Map<number, number>();
		for (const key of ordered) {
			maxWidthByLevel.set(key, Math.max(...(groups.get(key) || []).map((node) => node.size.width)));
		}
		let x = startX;
		let centerY = startY + 140;
		for (const key of ordered) {
			const items = groups.get(key) || [];
			const totalHeight =
				items.reduce((sum, item) => sum + item.size.height, 0) + Math.max(0, items.length - 1) * 46;
			let y = key === 0 ? centerY - items[0].size.height / 2 : centerY - totalHeight / 2;
			for (const item of items) {
				result.push({ ...item, x, y });
				if (key === 0) centerY = y + item.size.height / 2;
				y += item.size.height + 46;
			}
			x += (maxWidthByLevel.get(key) || 180) + 150;
		}
		return result;
	}

	const horizontal = layout === "horizontal";
	const orderedKeys = [...groups.keys()].sort((a, b) => a - b);
	const result: Array<{ input: NodeInput; x: number; y: number; width: number; height: number; id: string }> = [];
	if (horizontal) {
		let x = startX;
		for (const key of orderedKeys) {
			const items = groups.get(key) || [];
			const totalHeight =
				items.reduce((sum, item) => sum + item.size.height, 0) + Math.max(0, items.length - 1) * 56;
			let y = startY + 220 - totalHeight / 2;
			const widest = Math.max(...items.map((item) => item.size.width));
			for (const item of items) {
				result.push({ ...item, x: x + (widest - item.size.width) / 2, y });
				y += item.size.height + 56;
			}
			x += widest + 170;
		}
		return result;
	}

	let y = startY;
	for (const key of orderedKeys) {
		const items = groups.get(key) || [];
		const totalWidth =
			items.reduce((sum, item) => sum + item.size.width, 0) + Math.max(0, items.length - 1) * 70;
		let x = startX + 300 - totalWidth / 2;
		const tallest = Math.max(...items.map((item) => item.size.height));
		for (const item of items) {
			result.push({ ...item, x, y: y + (tallest - item.size.height) / 2 });
			x += item.size.width + 70;
		}
		y += tallest + 96;
	}
	return result;
}

function emptyScene(): Scene {
	return {
		type: "f-whiteboard",
		version: 1,
		revision: 0,
		updatedAt: new Date().toISOString(),
		updatedBy: "agent",
		elements: [],
		appState: {
			viewBackgroundColor: "transparent",
			currentItemFontFamily: DEFAULT_FONT_FAMILY,
			gridSize: null,
		},
		files: {},
	};
}

async function ensureScenePath(cwd: string): Promise<string> {
	// F 会把画板目录通过 F_BOARD_DIR 传进来（软件数据目录下，一个项目一个子目录）；
	// 直接跑 CLI 时退回项目内的 .f/whiteboard。
	const fromEnv = process.env.F_BOARD_DIR?.trim();
	if (fromEnv) return path.join(fromEnv, "scene.json");
	return path.join(cwd, SCENE_RELATIVE_PATH);
}

async function readScene(cwd: string): Promise<{ scenePath: string; scene: Scene }> {
	const scenePath = await ensureScenePath(cwd);
	let raw: string;
	try { raw = await readFile(scenePath, "utf8"); }
	catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
		return { scenePath, scene: emptyScene() };
	}
	const parsed = JSON.parse(raw) as Scene;
	if (!parsed || !Array.isArray(parsed.elements)) throw new Error("Invalid whiteboard scene; repair the existing file before editing.");
	return { scenePath, scene: { ...emptyScene(), ...parsed } };
}

async function writeScene(scenePath: string, scene: Scene, updatedBy: string): Promise<void> {
	scene.type = "f-whiteboard";
	scene.version = 1;
	scene.revision = (scene.revision || 0) + 1;
	scene.updatedAt = new Date().toISOString();
	scene.updatedBy = updatedBy;
	const temp = `${scenePath}.${process.pid}.${Date.now()}.tmp`;
	await mkdir(path.dirname(scenePath), { recursive: true });
	await writeFile(temp, JSON.stringify(scene, null, 2) + "\n", "utf8");
	await rename(temp, scenePath);
}

interface BoardMutationContext { cwd: string; sessionManager: { getSessionId(): string } }
interface BoardMutationParams { lease_id: string; expected_revision?: number }

function elementBounds(element: SceneElement) {
    const width = Math.abs(element.width), height = Math.abs(element.height);
    const angle = typeof element.angle === "number" ? element.angle : 0;
    const rotatedWidth = Math.abs(width * Math.cos(angle)) + Math.abs(height * Math.sin(angle));
    const rotatedHeight = Math.abs(width * Math.sin(angle)) + Math.abs(height * Math.cos(angle));
    const left = Math.min(element.x, element.x + element.width), top = Math.min(element.y, element.y + element.height);
    return { x: left + width / 2 - rotatedWidth / 2, y: top + height / 2 - rotatedHeight / 2,
        width: Math.max(rotatedWidth, 0.01), height: Math.max(rotatedHeight, 0.01) };
}

async function mutateBoard(ctx: BoardMutationContext, params: BoardMutationParams, mutate: (scene: Scene, lease: any) => number | void) {
    const directory = process.env.F_HARNESS_DIR ?? path.resolve(import.meta.dirname, "../../../harness");
    const { leasesFor, resourceOwner } = await import(pathToFileURL(path.join(directory, "src/aios/leases.mjs")).href);
    const leases = leasesFor(ctx), owner = resourceOwner(ctx);
    const scenePath = await ensureScenePath(ctx.cwd);
    return withFileMutationQueue(scenePath, () => leases.withBoardLease({ owner, leaseId: params.lease_id }, async (lease: any) => {
        const { scene } = await readScene(ctx.cwd);
        if (params.expected_revision !== undefined && params.expected_revision !== scene.revision)
            throw new Error("Whiteboard revision changed; read the board before editing again.");
        const before = structuredClone(scene);
        const changed = mutate(scene, lease);
        const old = new Map(before.elements.map(element => [element.id, element]));
        const current = new Map(scene.elements.map(element => [element.id, element]));
        const rectangles = [];
        for (const id of new Set([...old.keys(), ...current.keys()])) {
            const a = old.get(id), b = current.get(id);
            if (JSON.stringify(a) === JSON.stringify(b)) continue;
            if (a && !a.isDeleted) rectangles.push(elementBounds(a));
            if (b && !b.isDeleted) rectangles.push(elementBounds(b));
        }
        leases.checkBoard({ leases: [lease] }, { owner, leaseId: params.lease_id, rectangles });
        await writeScene(scenePath, scene, "agent");
        return { ...summaryOf(scene), ...(changed === undefined ? {} : { changed }) };
    }));
}

function summaryOf(scene: Scene): Record<string, unknown> {
	const elements = (scene.elements || []).filter((element) => !element.isDeleted);
	const nodes = elements
		.filter((element) => metaOf(element)?.kind === "node")
		.map((element) => {
			const meta = metaOf(element)!;
			return {
				id: meta.id,
				elementId: element.id,
				type: element.type,
				label: meta.label,
				x: Math.round(element.x),
				y: Math.round(element.y),
				width: Math.round(element.width),
				height: Math.round(element.height),
				fill: element.backgroundColor,
				stroke: element.strokeColor,
			};
		});
	const edges = elements
		.filter((element) => metaOf(element)?.kind === "edge")
		.map((element) => {
			const meta = metaOf(element)!;
			return {
				id: meta.id,
				elementId: element.id,
				from: meta.from,
				to: meta.to,
				label: meta.label,
				style: element.strokeStyle,
			};
		});
	const looseTexts = elements
		.filter((element) => element.type === "text" && metaOf(element)?.kind !== "label" && metaOf(element)?.kind !== "edge")
		.map((element) => ({
			elementId: element.id,
			text: typeof element.text === "string" ? element.text : "",
			x: Math.round(element.x),
			y: Math.round(element.y),
		}));
	return {
		revision: scene.revision,
		updatedAt: scene.updatedAt,
		updatedBy: scene.updatedBy,
		counts: { elements: elements.length, nodes: nodes.length, edges: edges.length },
		nodes,
		edges,
		looseTexts,
		note: "Use node/edge ids in whiteboard_edit. Manual Excalidraw elements without an fwb id can be addressed by elementId.",
	};
}

async function createToolExecute(ctx: BoardMutationContext, params: BoardMutationParams & {
	title?: string;
	layout?: Layout;
	mode?: "replace" | "append";
	nodes: NodeInput[];
	edges?: EdgeInput[];
	texts?: TextInput[];
}) {
	return mutateBoard(ctx, params, (scene, lease) => {
		const mode = params.mode || "append";
		if (mode === "replace") {
			scene.elements = [];
		}
		const usedSemanticIds = new Set<string>();
		const usedElementIds = new Set<string>();
		for (const element of scene.elements) {
			usedElementIds.add(element.id);
			const meta = metaOf(element);
			if (meta?.id) usedSemanticIds.add(meta.id);
		}
        if (!scene.elements.some(element => (element.customData as any)?.resourceLease === lease.id)) {
            const area = lease.rectangle;
            scene.elements.push(baseElement("rectangle", area.x, area.y, area.width, area.height, {
                id: elementId("region", usedElementIds), backgroundColor: "transparent", strokeColor: "#adb5bd",
                strokeStyle: "dashed", strokeWidth: 1, roughness: 0, customData: { resourceLease: lease.id },
            }) as SceneElement);
        }
		const startX = lease.rectangle.x + MARGIN;
		const startY = lease.rectangle.y + MARGIN;

		const placed = layoutNodes(params.nodes, params.edges || [], params.layout || "vertical", startX, startY);
		const boxes = new Map<string, NodeBox>();
		for (const item of placed) {
			const { node, metaId } = addNodeElements(scene, usedSemanticIds, usedElementIds, item.input, item.x, item.y);
			boxes.set(item.id, {
				metaId,
				elementId: node.id,
				textId: (node.boundElements as Array<{ type: string; id: string }>).find((binding) => binding.type === "text")?.id,
				x: node.x,
				y: node.y,
				width: node.width,
				height: node.height,
				label: item.input.label,
			});
		}

		for (const edge of params.edges || []) {
			const from = boxes.get(edge.from);
			const to = boxes.get(edge.to);
			if (!from || !to) continue;
			addEdgeElements(scene, usedSemanticIds, usedElementIds, edge, from, to);
		}

		let textY = startY;
		if (boxes.size > 0) {
			textY = Math.max(...Array.from(boxes.values()).map((box) => box.y + box.height)) + 50;
		}
		for (const text of params.texts || []) {
			const fontSize = text.fontSize || 24;
			const width = text.width || 560;
			const measured = measureText(text.text, fontSize, width);
			const textElement = baseElement("text", text.x ?? startX, text.y ?? textY, width, measured.height, {
				id: elementId("text", usedElementIds),
				text: text.text,
				originalText: text.text,
				rawText: text.text,
				fontSize,
				fontFamily: DEFAULT_FONT_FAMILY,
				textAlign: "left",
				verticalAlign: "top",
				containerId: null,
				autoResize: false,
				lineHeight: 1.25,
				strokeColor: color(text.color, "#1e1e1e"),
				customData: { fwb: { id: safeId("text", `text_${usedSemanticIds.size + 1}`, usedSemanticIds), kind: "text", label: text.text } satisfies FwbMeta },
			}) as SceneElement;
			scene.elements.push(textElement);
			textY += measured.height + 24;
		}

		if (params.title) {
			const titleElement = baseElement("text", startX, Math.max(24, startY - 68), 520, 42, {
				id: elementId("text", usedElementIds),
				text: params.title,
				originalText: params.title,
				rawText: params.title,
				fontSize: 28,
				fontFamily: DEFAULT_FONT_FAMILY,
				textAlign: "left",
				verticalAlign: "top",
				containerId: null,
				autoResize: false,
				lineHeight: 1.2,
				strokeColor: "#1e1e1e",
				customData: { fwb: { id: safeId("text", "title", usedSemanticIds), kind: "text", label: params.title } satisfies FwbMeta },
			}) as SceneElement;
			scene.elements.push(titleElement);
		}


	});
}

function updateBoundLabel(scene: Scene, node: SceneElement, label: string, fontSize: number): void {
	const meta = metaOf(node);
	if (!meta) return;
	const labelElement = scene.elements.find((element) => {
		const textMeta = metaOf(element);
		return element.type === "text" && textMeta?.kind === "label" && textMeta.id === meta.id;
	});
	if (labelElement) {
		labelElement.text = label;
		labelElement.originalText = label;
		labelElement.rawText = label;
		labelElement.fontSize = fontSize;
		labelElement.version = ((labelElement.version as number) || 1) + 1;
		labelElement.versionNonce = randomInt();
		labelElement.updated = now();
		meta.label = label;
	}
}

function refreshEdges(scene: Scene): void {
	const nodes = findNodes(scene);
	const nodeMap = new Map(nodes.map((node) => [node.metaId, node]));
	for (const edge of scene.elements) {
		const meta = metaOf(edge);
		if (meta?.kind !== "edge" || !meta.from || !meta.to) continue;
		const from = nodeMap.get(meta.from);
		const to = nodeMap.get(meta.to);
		if (!from || !to) continue;
		const anchors = edgeAnchors(from, to);
		const dx = anchors.ex - anchors.sx;
		const dy = anchors.ey - anchors.sy;
		edge.x = anchors.sx;
		edge.y = anchors.sy;
		edge.width = dx;
		edge.height = dy;
		edge.points = [
			[0, 0],
			[dx, dy],
		];
		edge.startBinding = { elementId: from.elementId, focus: 0, gap: 5 };
		edge.endBinding = { elementId: to.elementId, focus: 0, gap: 5 };
		edge.version = ((edge.version as number) || 1) + 1;
		edge.versionNonce = randomInt();
		edge.updated = now();
		const label = scene.elements.find((element) => {
			const textMeta = metaOf(element);
			return element.type === "text" && textMeta?.kind === "edgeLabel" && textMeta.id === meta.id;
		});
		if (label) {
			const midX = anchors.sx + dx / 2;
			const midY = anchors.sy + dy / 2;
			label.x = midX - label.width / 2;
			label.y = midY - label.height / 2;
			label.updated = now();
		}
	}
}

async function editToolExecute(ctx: BoardMutationContext, params: BoardMutationParams & { operations: Array<Record<string, unknown>> }) {
	return mutateBoard(ctx, params, (scene, lease) => {
        const operations = params.operations;
		const usedSemanticIds = new Set<string>();
		const usedElementIds = new Set<string>();
		for (const element of scene.elements) {
			usedElementIds.add(element.id);
			const meta = metaOf(element);
			if (meta?.id) usedSemanticIds.add(meta.id);
		}
		let changed = 0;
		let needsEdgeRefresh = false;

		for (const raw of operations) {
			const op = String(raw.op || "");
			const id = typeof raw.id === "string" ? raw.id : undefined;
			switch (op) {
				case "clear": {
					scene.elements = [];
					changed += 1;
					break;
				}
				case "delete": {
					if (!id) break;
					const target = findElementBySemanticId(scene, id);
					if (!target) break;
					const meta = metaOf(target);
					if (meta?.kind === "node") {
						const ids = new Set<string>([target.id]);
						for (const element of scene.elements) {
							const other = metaOf(element);
							if (other?.kind === "label" && other.id === meta.id) ids.add(element.id);
							if (other?.kind === "edge" && (other.from === meta.id || other.to === meta.id)) {
								ids.add(element.id);
								for (const candidate of scene.elements) {
									const candidateMeta = metaOf(candidate);
									if (candidateMeta?.kind === "edgeLabel" && candidateMeta.id === other.id && candidate.type === "text") {
										ids.add(candidate.id);
									}
								}
							}
						}
						scene.elements = scene.elements.filter(
							(element) => !ids.has(element.id) && !(metaOf(element)?.kind === "edgeLabel" && metaOf(element)?.id === meta.id && element.type === "text"),
						);
						changed += 1;
					} else if (meta?.kind === "edge") {
						scene.elements = scene.elements.filter((element) => {
							const other = metaOf(element);
							if (element.id === target.id) return false;
							if (other?.kind === "edgeLabel" && other.id === meta.id && element.type === "text") return false;
							return true;
						});
						for (const element of scene.elements) {
							const bindings = Array.isArray(element.boundElements) ? (element.boundElements as Array<{ type: string; id: string }>) : [];
							element.boundElements = bindings.filter((binding) => binding.id !== target.id);
						}
						changed += 1;
					} else {
						scene.elements = scene.elements.filter((element) => element.id !== target.id);
						changed += 1;
					}
					break;
				}
				case "add_node": {
					const label = typeof raw.label === "string" ? raw.label : "";
					if (!label.trim()) break;
					const input: NodeInput = {
						id: id || `node_${usedSemanticIds.size + 1}`,
						label,
						shape: (raw.shape as Shape) || "rectangle",
						x: typeof raw.x === "number" ? raw.x : undefined,
						y: typeof raw.y === "number" ? raw.y : undefined,
						width: typeof raw.width === "number" ? raw.width : undefined,
						height: typeof raw.height === "number" ? raw.height : undefined,
						fill: typeof raw.fill === "string" ? raw.fill : undefined,
						stroke: typeof raw.stroke === "string" ? raw.stroke : undefined,
						fontSize: typeof raw.fontSize === "number" ? raw.fontSize : undefined,
					};
					const nodes = findNodes(scene);
					const x = input.x ?? (nodes.length ? Math.max(...nodes.map((node) => node.x + node.width)) + NODE_GAP : MARGIN);
					const y = input.y ?? (nodes.length ? Math.min(...nodes.map((node) => node.y)) : MARGIN);
					addNodeElements(scene, usedSemanticIds, usedElementIds, input, x, y);
					changed += 1;
					break;
				}
				case "add_edge": {
					const fromId = typeof raw.from === "string" ? raw.from : "";
					const toId = typeof raw.to === "string" ? raw.to : "";
					const from = nodeBoxBySemanticId(scene, fromId);
					const to = nodeBoxBySemanticId(scene, toId);
					if (!from || !to) break;
					addEdgeElements(scene, usedSemanticIds, usedElementIds, {
						from: from.metaId,
						to: to.metaId,
						label: typeof raw.label === "string" ? raw.label : undefined,
						style: (raw.style as StrokeStyle) || "solid",
						color: typeof raw.color === "string" ? raw.color : undefined,
						bidirectional: Boolean(raw.bidirectional),
					}, from, to);
					changed += 1;
					break;
				}
				case "add_text": {
					const text = typeof raw.text === "string" ? raw.text : typeof raw.label === "string" ? raw.label : "";
					if (!text.trim()) break;
					const fontSize = typeof raw.fontSize === "number" ? raw.fontSize : 24;
					const width = typeof raw.width === "number" ? raw.width : 520;
					const measured = measureText(text, fontSize, width);
					const nodes = findNodes(scene);
					const x = typeof raw.x === "number" ? raw.x : nodes.length ? Math.min(...nodes.map((node) => node.x)) : MARGIN;
					const y = typeof raw.y === "number" ? raw.y : nodes.length ? Math.max(...nodes.map((node) => node.y + node.height)) + 56 : MARGIN;
					scene.elements.push(baseElement("text", x, y, width, measured.height, {
						id: elementId("text", usedElementIds),
						text,
						originalText: text,
						rawText: text,
						fontSize,
						fontFamily: DEFAULT_FONT_FAMILY,
						textAlign: "left",
						verticalAlign: "top",
						containerId: null,
						autoResize: false,
						lineHeight: 1.25,
						strokeColor: color(typeof raw.color === "string" ? raw.color : undefined, "#1e1e1e"),
						customData: { fwb: { id: safeId("text", `text_${usedSemanticIds.size + 1}`, usedSemanticIds), kind: "text", label: text } satisfies FwbMeta },
					}) as SceneElement);
					changed += 1;
					break;
				}
				case "update_node":
				case "move_node": {
					if (!id) break;
					const node = nodeElement(scene, id);
					if (!node) break;
					const meta = metaOf(node)!;
					const label = typeof raw.label === "string" ? raw.label : meta.label || "";
					const fontSize = typeof raw.fontSize === "number" ? raw.fontSize : DEFAULT_FONT_SIZE;
					if (typeof raw.label === "string") {
						updateBoundLabel(scene, node, raw.label, fontSize);
					}
					if (typeof raw.shape === "string" && SHAPES.includes(raw.shape as Shape)) {
						node.type = raw.shape;
						node.roundness = raw.shape === "rectangle" ? { type: 3 } : raw.shape === "ellipse" ? { type: 2 } : null;
						meta.shape = raw.shape as Shape;
					}
					if (typeof raw.fill === "string") node.backgroundColor = color(raw.fill, String(node.backgroundColor || "transparent"));
					if (typeof raw.stroke === "string") node.strokeColor = color(raw.stroke, String(node.strokeColor || "#1e1e1e"));
					if (typeof raw.x === "number") node.x = raw.x;
					if (typeof raw.y === "number") node.y = raw.y;
					if (typeof raw.width === "number") node.width = Math.max(60, raw.width);
					if (typeof raw.height === "number") node.height = Math.max(40, raw.height);

					if (typeof raw.label === "string") {
						const size = nodeSize({
							label,
							shape: (meta.shape || "rectangle") as Shape,
							width: node.width,
							height: node.height,
							fontSize,
						});
						if (node.width < size.width) node.width = size.width;
						if (node.height < size.height) node.height = size.height;
					}
					const labelElement = scene.elements.find((element) => {
						const textMeta = metaOf(element);
						return element.type === "text" && textMeta?.kind === "label" && textMeta.id === meta.id;
					});
					if (labelElement) {
						labelElement.width = Math.max(60, node.width - 32);
						labelElement.height = Math.max(28, Math.min(node.height - 16, labelElement.height as number));
						labelElement.x = node.x + (node.width - labelElement.width) / 2;
						labelElement.y = node.y + (node.height - labelElement.height) / 2;
					}
					node.version = ((node.version as number) || 1) + 1;
					node.versionNonce = randomInt();
					node.updated = now();
					needsEdgeRefresh = true;
					changed += 1;
					break;
				}
				case "update_edge": {
					if (!id) break;
					const edge = findEdge(scene, id);
					if (!edge) break;
					if (typeof raw.label === "string") {
						const meta = metaOf(edge)!;
						meta.label = raw.label;
						const label = scene.elements.find((element) => {
							const textMeta = metaOf(element);
							return element.type === "text" && textMeta?.kind === "edgeLabel" && textMeta.id === meta.id;
						});
						if (label) {
							label.text = raw.label;
							label.originalText = raw.label;
							label.rawText = raw.label;
						}
					}
					if (typeof raw.color === "string") edge.strokeColor = color(raw.color, String(edge.strokeColor || "#495057"));
					if (typeof raw.style === "string" && STROKE_STYLES.includes(raw.style as StrokeStyle)) edge.strokeStyle = raw.style;
					if (typeof raw.bidirectional === "boolean") edge.startArrowhead = raw.bidirectional ? "arrow" : null;
					edge.version = ((edge.version as number) || 1) + 1;
					edge.versionNonce = randomInt();
					edge.updated = now();
					changed += 1;
					break;
				}
				default:
					break;
			}
		}

		if (needsEdgeRefresh) refreshEdges(scene);
		return changed;
	});
}

function textResult(text: string) {
	return { content: [{ type: "text" as const, text }], details: undefined };
}

export default function (pi: ExtensionAPI) {
    if (process.env.F_DISABLED_PLUGINS?.split(',').includes('whiteboard')) return;
	pi.registerTool(defineTool({
		name: "whiteboard_read",
		label: "Read whiteboard",
		description:
			"Read the current F whiteboard scene. ALWAYS call this before editing an existing board so you can reuse the returned node and edge ids. Returns editable nodes, edges, labels, ids and positions. The scene lives in F_BOARD_DIR/scene.json when launched by F; otherwise it uses <project>/.f/whiteboard/scene.json.",
		parameters: Type.Object({}),
		async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
			const { scenePath, scene } = await readScene(ctx.cwd);
			const summary = summaryOf(scene);
			return {
				content: [{
					type: "text",
					text: JSON.stringify({ scenePath, ...summary }, null, 2),
				}],
				details: { scenePath, ...summary },
			};
		},
	}));

	pi.registerTool(defineTool({
		name: "whiteboard_create",
		label: "Create whiteboard diagram",
		description:
			"Create real editable Excalidraw elements on the F whiteboard. Use this for flowcharts, system architecture, algorithm diagrams, mind maps and technical explainers. Nodes become editable shapes with centered text; edges become real bound arrows. Prefer short node labels and stable ids. If x/y are omitted the tool lays the graph out automatically. Use layout=mindmap for radial mind maps, vertical for flowcharts, horizontal for pipelines, grid for overviews. First claim a rectangle using resource_scope. Pass lease_id. Default mode=append places content within that rectangle. mode=replace requires a lease covering all removed content. NEVER generate an image or screenshot.",
		parameters: CreateParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const summary = await createToolExecute(ctx, params);
			return {
				content: [{
					type: "text",
					text: `Created editable whiteboard elements.\n${JSON.stringify(summary, null, 2)}`,
				}],
				details: { action: "create", ...summary },
			};
		},
	}));

	pi.registerTool(defineTool({
		name: "whiteboard_edit",
		label: "Edit whiteboard",
		description:
			"Modify the existing F whiteboard while preserving manual edits and element identity. Claim a rectangle using resource_scope, then call whiteboard_read and pass lease_id, expected_revision and precise operations. Changes outside the reserved rectangle are rejected. Supported ops: add_node (id/label/shape/x/y/fill/stroke), add_edge (from/to/label/style/color/bidirectional), add_text (text/x/y/fontSize/color), update_node (id/label/shape/x/y/width/height/fill/stroke/fontSize), update_edge (id/label/style/color/bidirectional), move_node (id/x/y), delete (id), clear. All content stays fully editable in Excalidraw. Use this whenever the user asks to change, move, rename, recolor, extend or remove something on the current board.",
		parameters: EditParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const summary = await editToolExecute(ctx, params);
			return {
				content: [{
					type: "text",
					text: `Updated editable whiteboard elements.\n${JSON.stringify(summary, null, 2)}`,
				}],
				details: { action: "edit", ...summary },
			};
		},
	}));
}
