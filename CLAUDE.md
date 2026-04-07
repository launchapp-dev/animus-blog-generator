# Project Instructions

## Git Commits

Keep commit messages concise and descriptive. No AI co-author attribution.

## Animus Workflow

After ANY change to `.ao/workflows/custom.yaml`, you MUST run:

```bash
ao workflow config compile
```

The daemon compiles YAML in-memory on startup, but the runner needs the persisted compiled config on disk. Without this step, workflows fail with "no workflow found for subject".
