# learn overlay

## instruction-files
- primary: AGENTS.md
- notes: Project uses AGENTS.md (no CLAUDE.md or GEMINI.md)

## directory-scoping
- root: anything that affects how the project runs or how code behaves — architecture, Docker quirks, API semantics
- tests/: only test-infrastructural discoveries (how the stack starts, what breaks it), not test-case descriptions
- Never create nested instruction files for this project — it's a single-file API, everything belongs at root

## extraction-rules
- Watch for Docker image entrypoint behavior: what it creates, chmods, or overwrites at runtime. These silently break bind-mounts and config overlays and are never in the image docs.
- When a container exits with code 1, check logs before assuming code bugs — the jeko/invoiceplane image exits on missing dirs and read-only filesystems.
- Cross-file coupling is non-obvious here: docker-compose.test.yml, nginx-site.conf, nginx-entrypoint.sh, and seed.sql form a tight unit. A change to one almost always requires changes to the others. Flag this explicitly when learning touches any of them.
- Distinguish "how the code works" from "how the infrastructure around the code works". Both matter, but they go in different AGENTS.md sections (Architecture Quirks vs Docker Image Quirks).

## pitfalls
- The `env()` function's `$_SERVER` → `getenv()` fallback is easy to miss: env vars set in docker-compose.yml may not reach PHP-FPM workers due to `clear_env`. Always check nginx fastcgi_params, not just container env vars.
- Invoice status filtering (excludes drafts by default) is a common misunderstanding — searches that "should work" return 0 results if the target is a draft invoice. Always verify against `status=all`.
- Don't treat the upstream Docker Hub docs as sufficient — the actual entrypoint behavior (chmods, config generation) differs from what's documented and will bite you at runtime.