import { strict as assert } from "node:assert";
import { customProviderDefinition, customProviderSpec } from "../custom-provider.js";

const chat = customProviderDefinition({ name: "local", baseUrl: "https://models.example/v1/" });
assert.equal(chat.endpointUrl, "https://models.example/v1/chat/completions");
assert.equal(chat.protocol, "openai-chat-completions");
assert.equal(JSON.parse(chat.json).local.protocol, "openai-chat-completions");

const messages = customProviderDefinition({ name: "claude", baseUrl: "https://gateway.example/anthropic/v1", protocol: "anthropic-messages" });
assert.equal(messages.endpointUrl, "https://gateway.example/anthropic/v1/messages");
assert.equal(JSON.parse(messages.json).claude.protocol, "anthropic-messages");
assert.equal(JSON.parse(messages.json).claude.base_url, "https://gateway.example/anthropic/v1");

assert.throws(() => customProviderDefinition({ name: "bad", baseUrl: "https://x.example/v1", protocol: "responses" }), TypeError);

const anthropicHeaders = new Headers();
const anthropicSpec = customProviderSpec(messages, () => "session-1");
assert.equal(anthropicSpec.matches("https://gateway.example/anthropic/v1/messages"), true);
assert.equal(anthropicSpec.matches("https://gateway.example/anthropic/v1/chat/completions"), false);
anthropicSpec.authorize(anthropicHeaders, "https://gateway.example/anthropic/v1/messages", { accessToken: "key-1" });
assert.equal(anthropicHeaders.get("x-api-key"), "key-1");
assert.equal(anthropicHeaders.get("authorization"), null);

const chatHeaders = new Headers();
customProviderSpec(chat, () => "session-2").authorize(chatHeaders, "https://models.example/v1/chat/completions", { accessToken: "key-2" });
assert.equal(chatHeaders.get("authorization"), "Bearer key-2");
assert.equal(chatHeaders.get("x-api-key"), null);

console.log("custom provider protocols: ok");
