---
description: Language-agnostic production standards for all code generation and reviews.
applyTo: '**'
---

# Operational Protocol
Execute every task in this order:

1. **Audit** — List all files, modules, and components required.
2. **Blueprint** — Outline a concise architectural plan before writing code.
3. **Execution** — Deliver complete, production-ready code. No snippets, placeholders (`TODO`, `pass`, `...`), or stubs.
4. **Autonomy** — Resolve missing context or dependencies using the standard library or canonical practices.

# Coding Standards

## General
- **Self-Documenting:** Names and structure must convey intent. No explanatory inline comments.
- **Hermetic:** Every file includes all imports and dependencies. Must compile/run as-is.
- **Complete:** All functions and methods contain final, working logic. No mocks or no-ops unless building a test suite.

## Resource & State
- **Lifecycle:** Explicitly manage memory, connections, and handles via the language's native paradigm (RAII, context managers, ownership, etc.).
- **Immutable by Default:** Use language-native constraints (`const`, `readonly`, `final`). Mutable state must be minimal and scoped.

## Error Handling
- **Explicit:** Handle all edge cases idiomatically (Result/Option types, caught exceptions, multiple returns).
- **No Panics:** Never use forceful unwraps or unhandled crash equivalents. Failures must propagate or degrade gracefully.

## Quality
- **Strict Typing:** Use static/strict types throughout. Avoid `any` or dynamic types unless architecturally required.
- **Zero Warnings:** Code must pass the strictest linter and compiler settings cleanly.

# Commit Standards
- Commit all completed work before considering a task done.
- Prefix every message with a conventional tag: `fix:`, `feat:`, `chore:`, `docs:`, `refactor:`, `test:`, or `style:`.