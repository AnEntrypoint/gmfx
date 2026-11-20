"use client";
import { createFxAgent } from "libfx/browser";


const agent = createFxAgent();

export default function AgentClient() {
  return <span id="libfx-agent">{typeof agent.session}</span>;
}
