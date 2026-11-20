import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deflateSync } from "node:zlib";
import { runFx } from "../evals/eval-helpers";
import { completion, createConfiguredProviderFixture, toolCompletion } from "./fixtures/chat-completions";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

type PngCase = {
  name: string;
  width: number;
  height: number;
  colorType: number;
  bitDepth: number;
  channels: number;
  interlace?: boolean;
  palette?: number[];
  trns?: number[];
  sample: (x: number, y: number, c: number) => number;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const byte of bytes) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Buffer {
  const body = Buffer.concat([Buffer.from(type, "ascii"), Buffer.from(data)]);
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), 8 + data.length);
  return out;
}

const ADAM7 = [
  [0, 0, 8, 8],
  [4, 0, 8, 8],
  [0, 4, 4, 8],
  [2, 0, 4, 4],
  [0, 2, 2, 4],
  [1, 0, 2, 2],
  [0, 1, 1, 2],
];

function scanlines(testCase: PngCase, xStart: number, yStart: number, xStep: number, yStep: number): Buffer[] {
  const width = Math.ceil((testCase.width - xStart) / xStep);
  const height = Math.ceil((testCase.height - yStart) / yStep);
  if (width <= 0 || height <= 0) return [];
  const rows: Buffer[] = [];
  for (let row = 0; row < height; row++) {
    const y = yStart + row * yStep;
    const bytesPerSample = testCase.bitDepth / 8;
    const line = Buffer.alloc(1 + width * testCase.channels * bytesPerSample);
    line[0] = 0;
    let offset = 1;
    for (let col = 0; col < width; col++) {
      const x = xStart + col * xStep;
      for (let c = 0; c < testCase.channels; c++) {
        const value = testCase.sample(x, y, c);
        if (bytesPerSample === 2) line.writeUInt16BE(value, offset);
        else line[offset] = value;
        offset += bytesPerSample;
      }
    }
    rows.push(line);
  }
  return rows;
}

function encodePng(testCase: PngCase): Buffer {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(testCase.width, 0);
  header.writeUInt32BE(testCase.height, 4);
  header[8] = testCase.bitDepth;
  header[9] = testCase.colorType;
  header[10] = 0;
  header[11] = 0;
  header[12] = testCase.interlace ? 1 : 0;
  const passes = testCase.interlace
    ? ADAM7.map(([x, y, dx, dy]) => scanlines(testCase, x, y, dx, dy))
    : [scanlines(testCase, 0, 0, 1, 1)];
  const raw = Buffer.concat(passes.flat());
  const parts = [
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
  ];
  if (testCase.palette) parts.push(chunk("PLTE", Uint8Array.from(testCase.palette)));
  if (testCase.trns) parts.push(chunk("tRNS", Uint8Array.from(testCase.trns)));
  parts.push(chunk("IDAT", deflateSync(raw)), chunk("IEND", new Uint8Array(0)));
  return Buffer.concat(parts);
}

const PNG_CASES: PngCase[] = [
  {
    name: "8-bit RGB",
    width: 16,
    height: 16,
    colorType: 2,
    bitDepth: 8,
    channels: 3,
    sample: (x, y, c) => (x * 13 + y * 7 + c * 90) & 0xff,
  },
  {
    name: "8-bit RGBA with an odd size",
    width: 9,
    height: 7,
    colorType: 6,
    bitDepth: 8,
    channels: 4,
    sample: (x, y, c) => (x * 29 + y * 11 + c * 51) & 0xff,
  },
  {
    name: "16-bit grayscale",
    width: 12,
    height: 5,
    colorType: 0,
    bitDepth: 16,
    channels: 1,
    sample: (x, y) => (x * 4000 + y * 1000) & 0xffff,
  },
  {
    name: "palette with transparency",
    width: 10,
    height: 10,
    colorType: 3,
    bitDepth: 8,
    channels: 1,
    palette: [255, 0, 0, 0, 255, 0, 0, 0, 255, 128, 128, 128],
    trns: [255, 128, 0, 64],
    sample: (x, y) => (x + y) & 3,
  },
  {
    name: "Adam7 interlaced RGB",
    width: 11,
    height: 9,
    colorType: 2,
    bitDepth: 8,
    channels: 3,
    interlace: true,
    sample: (x, y, c) => (x * 17 + y * 23 + c * 61) & 0xff,
  },
  {
    name: "wider than 2000 pixels",
    width: 2100,
    height: 2,
    colorType: 2,
    bitDepth: 8,
    channels: 3,
    sample: (x, y, c) => (x + y + c) & 0xff,
  },
];

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-read-media-png-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(root: IsolatedRoot, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-read-media-png-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "yolo",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function toolResultPart(body: string, toolCallId: string): Record<string, unknown> {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const part = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((entry) => entry.type === "tool-result" && entry.toolCallId === toolCallId);
  expect(part).toBeDefined();
  return part as Record<string, unknown>;
}

function attachedImage(body: string): Record<string, unknown> | undefined {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: unknown }>;
  };
  return (request.prompt ?? [])
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .find((entry) => (entry as Record<string, unknown>).type === "file") as
    | Record<string, unknown>
    | undefined;
}

describe("ReadMediaFile decodes valid PNG files", () => {
  test.each(PNG_CASES.map((testCase) => [testCase.name, testCase] as const))(
    "%s is attached unchanged",
    async (_name, testCase) => {
      const root = createIsolatedRoot();
      const bytes = encodePng(testCase);
      const encoded = bytes.toString("base64");
      const gateway = startFakeGateway([
        fakeGatewayToolCall("media_read", "ReadMediaFile", { path: "image.png" }),
        (body) => {
          const part = toolResultPart(body, "media_read");
          const output = part.output as Record<string, unknown>;
          expect(JSON.stringify(output)).toContain("image attached (image/png");
          expect(JSON.stringify(output)).not.toContain("retained but not sent");
          expect(JSON.stringify(output)).not.toContain("cannot");
          const image = attachedImage(body);
          expect(image).toBeDefined();
          expect(image!.mediaType).toBe("image/png");
          expect((image!.data as Record<string, unknown>).type).toBe("data");
          expect((image!.data as Record<string, unknown>).data).toBe(encoded);
          return fakeGatewayFinalText("png attached");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use", "vision", "file-input"] }],
      });
      gateways.push(gateway);
      writeFileSync(join(root.workspace, "image.png"), bytes);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Read image.png with ReadMediaFile, then stop."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("png attached");
    },
    TIMEOUT,
  );
});

const CONFIGURED_VISION_MODEL = "claude-hy4[1m]";
const ONE_BY_ONE_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
  "base64",
);

describe("ReadMediaFile on a configured vision model", () => {
  test(
    "attaches the PNG bytes for a bracketed model id with supports_vision metadata",
    async () => {
      const f = createConfiguredProviderFixture((body) => {
        if (JSON.stringify(body.messages).includes("image attached")) {
          return completion(body.model, "png attached");
        }
        return toolCompletion(body.model, "ReadMediaFile", { path: "image.png" }, "call-png");
      });
      try {
        f.settings.providers.local.model_metadata = {
          [CONFIGURED_VISION_MODEL]: {
            context_window: 1000000,
            max_output_tokens: 64000,
            supports_tool_use: true,
            supports_vision: true,
          },
        };
        f.settings.models.local = CONFIGURED_VISION_MODEL;
        f.save();
        writeFileSync(join(f.workspace, "image.png"), ONE_BY_ONE_PNG);

        const result = await runFx(
          ["ask", "--json", "--no-save", "Read image.png with ReadMediaFile, then stop."],
          { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT },
        );

        expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
        expect(result.stdout).toContain("png attached");
        expect(f.requests).toHaveLength(2);
        const followUp = JSON.stringify(f.requests[1]!.body);
        expect(followUp).toContain("image attached (image/png");
        expect(followUp).not.toContain("retained but not sent");
        expect(followUp).toContain(ONE_BY_ONE_PNG.toString("base64"));
      } finally {
        f.close();
      }
    },
    TIMEOUT,
  );
});
