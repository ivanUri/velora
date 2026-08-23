# Koko

AI-first browser runtime for automation, agents, and programmable web execution.

Koko is a lightweight headless browser engine built for AI workflows, browser automation, crawling, testing, and large-scale web interaction without relying on the Chromium monolith.

Unlike browser stacks designed primarily for human browsing, Koko treats the browser as programmable infrastructure: deterministic, embeddable, multi-session, and automation-native.

## Why Koko

Modern AI systems increasingly depend on browsers for search, navigation, extraction, task execution, and web-based tool use. Existing automation stacks are usually built on top of large Chromium-based runtimes that are heavy to embed, expensive to scale, and difficult to customize deeply.

Koko takes a different approach. It focuses on browser infrastructure for automation and AI from the start:

- Deterministic automation behavior
- Multi-session browser execution
- Programmable browser infrastructure
- Lifecycle correctness
- Embeddable runtime architecture
- AI agent integration

## Why Not Chromium?

Chromium is an excellent desktop browser, but it was not designed as a small, embeddable automation runtime. Most browser automation systems inherit Chromium's full browser stack even when they only need programmable page execution.

That creates real costs for AI agents and automation infrastructure:

- Large runtime footprint for every browser instance
- Higher memory and CPU overhead at scale
- Complex process, sandbox, profile, and lifecycle behavior
- Slower cold starts and heavier deployment artifacts
- Difficult deep customization below the automation API layer
- Architecture optimized for interactive browsing, not machine-driven execution

Koko is not trying to be a full desktop-browser replacement. It focuses on the subset that automation systems need most: deterministic navigation, DOM and Web API execution, protocol control, lifecycle correctness, and embeddable multi-session runtime behavior.

The goal is a browser runtime that can be treated like infrastructure: smaller, easier to control, easier to embed, and better suited for AI-native workloads.

## Core Principles

### AI-First Runtime

Koko is built for machine-driven browser execution, including:

- AI agents
- Autonomous browsing
- Orchestration systems
- MCP and CDP integrations
- Browser-native automation workflows

The browser is treated as programmable runtime infrastructure, not as a desktop application.

### Lightweight Browser Infrastructure

Koko avoids the Chromium-scale runtime model and focuses on:

- Lower runtime overhead
- Simpler embedding
- Predictable execution
- Controllable lifecycle management
- Scalable multi-session automation

### Lifecycle Correctness

Reliable automation depends heavily on browser lifecycle behavior. Koko focuses on correctness around:

- Navigation ordering
- Realm isolation
- `WindowProxy` semantics
- Execution context stability
- Teardown correctness
- Deterministic event ordering
- Microtask scheduling behavior

These details are critical for automation frameworks, AI agents, protocol integrations, browser instrumentation, and anti-flake execution.

### Built for Automation

Koko exposes browser behavior through automation-oriented interfaces:

- CDP-compatible runtime
- MCP integration support
- Server mode
- Embeddable SDK architecture
- Multi-session runtime model
- Programmable execution flows

The goal is not only to run a page, but to provide the foundation for browser-native automation systems.

## Features

- Lightweight headless browser engine
- AI-agent oriented runtime architecture
- CDP-compatible automation interface
- MCP integration support
- Multi-session browser runtime
- Browser lifecycle instrumentation
- Deterministic navigation handling
- Realm-aware execution model
- Embeddable SDK/runtime architecture
- Zig-based low-level runtime control
- Designed for scalable automation infrastructure

## Quick Start

### Install with Homebrew (macOS)

```bash
brew tap ivanUri/tap
brew install koko
koko serve --host 127.0.0.1 --port 9222
```

See [docs/homebrew.md](docs/homebrew.md) for publishing releases to the tap.

### Build Koko

```bash
zig build
```

### Run the Browser Server

```bash
zig build run -- serve --host 127.0.0.1 --port 9222
```

### Connect with Koko SDK (separate repo)

CDP client and agent APIs live in the separate **koko-sdk** submodule (`koko-sdk`), not in this engine repo.

```text
Desktop/koko/      # this repo — zig build
Desktop/koko-sdk/  # npm install && npm run build
```

```ts
import { Browser } from "@koko/sdk";

const browser = await Browser.connect("http://127.0.0.1:9222");
const page = await browser.newPage();
await page.goto("https://example.com", { waitUntil: "load" });
console.log(await page.content());
await browser.close();
```

See `koko-sdk/README.md` for launch profiles, semantic tree, NodeHandle, and CLI `koko-fetch`.

### Fingerprint probes

Fingerprint probes live under `scripts/`. TLS notes: `docs/tls-impersonate.md`.

## Use Cases

Koko is designed for:

- AI agents
- Browser automation
- Crawling infrastructure
- Scraping systems
- Workflow automation
- Autonomous browsing
- Browser orchestration
- Testing platforms
- Cloud browser runtimes
- Embedded browser execution

## Architecture

Koko separates browser execution into explicit runtime layers:

```text
Core Engine -> Runtime -> Protocols -> Adapters -> Public API
```

High-level project structure:

```text
src/
  core/         # Browser engine, DOM, parser, JS bindings, Web APIs
  runtime/      # Lifecycle, services, network, storage, telemetry
  protocols/    # CDP and MCP protocol implementations
  adapters/     # CLI and server adapters
  public/       # Stable public API surface
  support/      # Shared utilities
  testing/      # Isolated test infrastructure

knowledge/     # Architecture notes and bug write-ups
```

WPT runs use an external tree (`~/Desktop/wpt-spa-tests`) — see `knowledge/architecture/wpt-spa-workflow.md`.

This structure keeps engine internals isolated, runtime services explicit, automation protocols modular, public APIs stable, and browser execution embeddable.

## Development Focus

Current development priorities include:

- Browser lifecycle correctness
- Automation stability
- Realm and navigation semantics
- CDP behavior consistency
- MCP integration
- Multi-session runtime infrastructure
- AI-agent integration
- Scalable browser execution

## Benchmarks

The reproducible Phase 1 harness compares Koko direct CDP with Chromium direct CDP on local deterministic fixtures. Playwright Chromium is available as an optional secondary baseline.

```bash
zig build benchmark -Doptimize=ReleaseFast -- --quick
zig build benchmark -Doptimize=ReleaseFast -- --suite navigation --iterations 30
zig build benchmark -Doptimize=ReleaseFast -- --baseline all
```

It measures startup-to-first-document, navigation to `DOMContentLoaded`, session lifecycle, and whole-process-tree idle memory. Raw observations, environment metadata, summaries, and a Markdown report are written to the gitignored `bench-results/` directory. See [`bench/README.md`](bench/README.md) for the measurement contract and limitations.

## Performance Direction

Koko is optimized toward:

- Lower runtime overhead
- Scalable automation workloads
- Controllable memory behavior
- Deterministic browser execution
- Reduced infrastructure cost compared to full Chromium stacks

The project prioritizes runtime correctness and controllable browser behavior over desktop-browser feature parity.

## Requirements

- Zig 0.16.0
- V8
- libcurl
- Rust toolchain for required dependencies
- Node.js for the TypeScript SDK and CLI helpers

## Build and Run

Build the runtime:

```bash
zig build
```

Run the default target:

```bash
zig build run
```

Run the CDP-compatible server:

```bash
zig build run -- serve --host 127.0.0.1 --port 9222
```

## Status

Koko is under active development. The project is currently focused on automation reliability, lifecycle correctness, runtime architecture, and browser execution infrastructure for AI systems.

## Credits

Koko builds upon prior browser-engine and runtime work from the open-source ecosystem. Additional architectural and runtime work is actively developed independently as part of the Koko runtime direction.

## License

See `LICENSE` and `LICENSING.md`.

<!-- push connectivity check 2026-07-22 16:39 -->
