# Changelog

## 0.1.0

Pre-release, this is not a production ready release !

- Query sources can provide candidate entity IDs before component loading.
- Systems can expose transaction-scoped change sets to later batches and phases
  of the current tick.
- Added preloaded entity despawns for systems that already queried the complete
  component set, avoiding a redundant backend component lookup.
