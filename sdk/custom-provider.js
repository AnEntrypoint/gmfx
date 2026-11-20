import { tokenString } from "./subscription.js";

const encoder = new TextEncoder();
const reservedNames = new Set(["gateway", "codex", "grok"]);
const namePattern = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
const loopbackHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);
const providerFields = new Set(["name", "baseUrl", "protocol", "models"]);
const endpointPaths = {
  "openai-chat-completions": "/chat/completions",
  "anthropic-messages": "/messages",
};
const modelSettingsNames = {
  contextWindow: "context_window",
  maxOutputTokens: "max_output_tokens",
  supportsToolUse: "supports_tool_use",
  supportsVision: "supports_vision",
};

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function endpointUrlOf(baseUrl, protocol) {
  if (typeof baseUrl !== "string") throw new TypeError("provider.baseUrl must be a string");
  let url;
  try {
    url = new URL(`${baseUrl.endsWith("/") ? baseUrl.slice(0, -1) : baseUrl}${endpointPaths[protocol]}`);
  } catch {
    throw new TypeError("provider.baseUrl must be an absolute URL");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new TypeError("provider.baseUrl must not carry credentials, a query or a fragment");
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopbackHosts.has(url.hostname))) {
    throw new TypeError("provider.baseUrl must use https, or http on localhost");
  }
  return `${url.origin}${url.pathname}`;
}

const maxModels = 256;
const maxModelIdBytes = 1024;
const maxLimit = 2 ** 32 - 1;

function modelMetadata(models) {
  if (!isPlainObject(models)) throw new TypeError("provider.models must be an object keyed by model id");
  const entries = Object.entries(models);
  if (entries.length > maxModels) throw new RangeError(`provider.models lists more than ${maxModels} models`);
  const metadata = {};
  for (const [id, model] of entries) {
    if (id.length === 0 || id.trim() !== id || /[\u0000-\u001f\u007f]/.test(id) || encoder.encode(id).length > maxModelIdBytes) {
      throw new TypeError(`provider.models has an invalid model id "${id}"`);
    }
    if (!isPlainObject(model)) throw new TypeError(`provider.models["${id}"] must be an object`);
    const entry = {};
    for (const [field, value] of Object.entries(model)) {
      const name = modelSettingsNames[field];
      if (name === undefined) throw new TypeError(`provider.models["${id}"] has unknown field ${field}`);
      const limit = field === "contextWindow" || field === "maxOutputTokens";
      if (limit ? !(Number.isInteger(value) && value > 0 && value <= maxLimit) : typeof value !== "boolean") {
        throw new TypeError(`provider.models["${id}"].${field} must be ${limit ? "a positive integer" : "a boolean"}`);
      }
      entry[name] = value;
    }
    if (model.contextWindow !== undefined && model.maxOutputTokens !== undefined && model.maxOutputTokens >= model.contextWindow) {
      throw new RangeError(`provider.models["${id}"].maxOutputTokens must be less than contextWindow`);
    }
    metadata[id] = entry;
  }
  return metadata;
}

export function customProviderDefinition(provider) {
  if (!isPlainObject(provider)) throw new TypeError("a custom provider must be an object { name, baseUrl, protocol?, models? }");
  for (const field of Object.keys(provider)) {
    if (!providerFields.has(field)) throw new TypeError(`a custom provider has unknown field ${field}`);
  }
  const { name, baseUrl, protocol = "openai-chat-completions", models } = provider;
  if (typeof name !== "string" || !namePattern.test(name) || reservedNames.has(name.toLowerCase())) {
    throw new TypeError("provider.name must be a letter followed by letters, digits, _ or -, at most 64 characters, and not gateway, codex or grok");
  }
  if (!Object.hasOwn(endpointPaths, protocol)) {
    throw new TypeError("provider.protocol must be \"openai-chat-completions\" or \"anthropic-messages\"");
  }
  const endpointUrl = endpointUrlOf(baseUrl, protocol);
  const definition = {
    protocol,
    base_url: baseUrl,
    auth: { type: "none" },
    ...(models === undefined ? {} : { model_metadata: modelMetadata(models) }),
  };
  return { name, protocol, endpointUrl, json: JSON.stringify({ [name]: definition }) };
}

export function customProviderSpec({ name, protocol, endpointUrl }, sessionId) {
  return {
    provider: name,
    matches: (endpoint) => endpoint === endpointUrl,
    sessionId: () => sessionId(),
    normalize(value) {
      if (!isPlainObject(value)) throw new TypeError("credentials() must return { apiKey } for a custom provider");
      return { accessToken: tokenString(value.apiKey, "apiKey", true, `provider "${name}"`) };
    },
    authorize(headers, _endpoint, credentials) {
      if (protocol === "anthropic-messages") headers.set("x-api-key", credentials.accessToken);
      else headers.set("authorization", `Bearer ${credentials.accessToken}`);
    },
  };
}
