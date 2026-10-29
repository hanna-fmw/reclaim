# reclaim

<!-- generated from ops project-rules.py - edit that, never this file -->
## Shared rules

For any agent working here, also one that runs without the owner's machine (a cloud runner, CI).

- **Secrets:** never print, commit or write a credential, and never create or edit `.env*` or other key
  files, not even with placeholders. Keys come from the environment at run time.
- **Git:** commit and push to main. Never set an author name or email (the repo's config decides), and no
  Co-Authored-By lines.
<!-- end generated -->
