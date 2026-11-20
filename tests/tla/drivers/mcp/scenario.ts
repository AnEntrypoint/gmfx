

import type { Verdict } from "./bridge";

export interface ScenarioContext {

  root: string;

  bin: { [name: string]: string };

  home: string;

  workdir: string;

  tracePath: string;

  caseDir: string;
}

export interface TraceExpectation {
  machine: string;
  instance?: string;

  specDir: string;
  wrapper: string;

  verdict: Verdict;

  constants?: { [name: string]: number };
}

export interface Scenario {

  name: string;

  unit: string;
  description: string;

  needs: string[];

  command(ctx: ScenarioContext): string[];

  setup?(ctx: ScenarioContext): void;
  expect: {
    exit: number;
    traces: TraceExpectation[];

    stdout?: (text: string) => string | null;
  };

  real?: boolean;

  timeoutMs?: number;
}
